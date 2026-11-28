use std::path::Path;

use core_db::{
    CatalogQueryRepository, FolderRepository, ImmediateTx, IngestionRepository, LibraryRepository,
};
use core_types::{AlbumMetadataLayer, CanonicalAlbum, TrackMetadataLayer, TrackSource};

use crate::error::ProviderError;
use crate::library::db_err;

/// Builds the scanner-owned `file_meta_json` layer for a `CanonicalAlbum`.
pub(crate) fn build_album_file_layer(
    album: &CanonicalAlbum,
    effective_title: &str,
    artist_name: &str,
    upc: Option<&str>,
    mb_rg_id: Option<&str>,
) -> AlbumMetadataLayer {
    let clean_opt = |v: Option<&str>| {
        v.map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
    };
    let album_artist =
        clean_opt(album.album_artist.as_deref()).or_else(|| clean_opt(Some(artist_name)));
    let cover = clean_opt(album.cover_url.as_deref());

    AlbumMetadataLayer {
        title: Some(effective_title.to_string()),
        sort_title: Some(CanonicalAlbum::derive_sort_title(effective_title)),
        album_artist,
        release_year: album.release_year,
        upc: clean_opt(upc),
        musicbrainz_release_group_id: clean_opt(mb_rg_id),
        editorial_bio: None,
        cover_url: cover.clone(),
        merged_cover_path: cover,
    }
}

/// Builds the scanner-owned `file_meta_json` layer for a `TrackSource`.
///
/// Leaves `album_title` unset so album-level renames/merges remain authoritative unless
/// a user explicitly overrides a track's album assignment.
pub(crate) fn build_track_file_layer(
    track: &TrackSource,
    release_year: Option<i32>,
    embedded_lyrics: Option<&str>,
) -> TrackMetadataLayer {
    let clean_opt = |v: Option<&str>| {
        v.map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
    };

    TrackMetadataLayer {
        title: Some(track.title.clone()),
        artist_name: clean_opt(track.artist_name.as_deref()),
        album_artist: clean_opt(track.album_artist.as_deref()),
        album_title: None,
        disc_number: Some(track.disc_number).filter(|&n| n > 0),
        track_number: Some(track.track_number).filter(|&n| n > 0),
        release_year: release_year.or(track.release_year),
        genre: clean_opt(track.genre.as_deref()),
        composer: clean_opt(track.composer.as_deref()),
        isrc: clean_opt(track.isrc.as_deref()),
        lyrics: clean_opt(embedded_lyrics),
    }
}

/// Persists scanner-discovered album metadata strictly into `file_meta_json` (or supplementary
/// `cloud_meta_json` when a lower-priority streaming provider matches an existing local album)
/// and triggers three-layer resolution so `cloud_meta_json` and `user_edits_json` are never clobbered.
///
/// MUST be called AFTER the album's `album_versions` and `track_sources` are inserted in the
/// same transaction so `recompute_album_effective_tx` sees present tracks and syncs `search_fts`.
pub(crate) async fn persist_album_file_layer_tx(
    tx: &mut ImmediateTx,
    album_id: &str,
    incoming_provider_id: &str,
    is_new_album: bool,
    file_layer: &AlbumMetadataLayer,
) -> Result<bool, ProviderError> {
    let write_to_file_layer = if is_new_album {
        true
    } else {
        CatalogQueryRepository::should_overwrite_album_core_tx(
            tx.conn(),
            album_id,
            incoming_provider_id,
        )
        .await
        .map_err(db_err)?
    };

    if write_to_file_layer {
        LibraryRepository::write_album_file_meta_tx(tx.conn(), album_id, file_layer)
            .await
            .map_err(db_err)?;
        Ok(true)
    } else {
        let supp = AlbumMetadataLayer {
            upc: file_layer.upc.clone(),
            musicbrainz_release_group_id: file_layer.musicbrainz_release_group_id.clone(),
            cover_url: file_layer.cover_url.clone(),
            merged_cover_path: file_layer.merged_cover_path.clone(),
            ..Default::default()
        };
        if !core_types::LayeredMetadata::is_empty(&supp) {
            LibraryRepository::write_album_cloud_meta_tx(tx.conn(), album_id, &supp)
                .await
                .map_err(db_err)?;
        }
        Ok(false)
    }
}

/// Finalizes per-track layered metadata, multi-artist links, `record_label` columns, and
/// case-preserving `library_folders` display names inside the commit `ImmediateTx`.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn finalize_probed_track_layers_tx(
    tx: &mut ImmediateTx,
    provider_id: &str,
    track_source_id: &str,
    canonical_album_id: &str,
    canonical_track_id: Option<&str>,
    file_layer_trk: &TrackSource,
    release_year: Option<i32>,
    embedded_lyrics: Option<&str>,
    artists_list: &[String],
    original_path: &Path,
    record_label: Option<&str>,
) -> Result<(), ProviderError> {
    // Strict write isolation: scanner writes ONLY `file_meta_json` and lets
    // the three-layer resolver recompute display columns, canonical_tracks & FTS.
    let track_file_layer = build_track_file_layer(file_layer_trk, release_year, embedded_lyrics);
    LibraryRepository::write_track_file_meta_tx(tx.conn(), track_source_id, &track_file_layer)
        .await
        .map_err(db_err)?;

    if let Some(ct_id) = canonical_track_id
        && artists_list.len() > 1
    {
        let _ =
            IngestionRepository::link_track_artists_tx(tx.conn(), ct_id, artists_list, "performer")
                .await;
    }

    let clean_label = record_label.map(str::trim).filter(|s| !s.is_empty());
    LibraryRepository::update_track_record_label_tx(tx.conn(), track_source_id, clean_label)
        .await
        .map_err(db_err)?;
    if clean_label.is_some() {
        LibraryRepository::update_album_record_label_tx(tx.conn(), canonical_album_id, clean_label)
            .await
            .map_err(db_err)?;
    }

    if provider_id.eq_ignore_ascii_case("local") {
        let display_path = original_path.to_string_lossy();
        let _ = FolderRepository::sync_track_folder_tx(
            tx.conn(),
            provider_id,
            &file_layer_trk.external_track_id,
            Some(display_path.as_ref()),
            None,
            false,
            false,
        )
        .await
        .map_err(db_err)?;
    }

    Ok(())
}
