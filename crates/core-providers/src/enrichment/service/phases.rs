use std::collections::{HashMap, HashSet};

use core_types::TrackMetadataLayer;

use super::super::discogs::{DiscogsClient, clean_discogs_artist_name, extract_discogs_credits};
use super::super::musicbrainz::{MbArtistCredit, MusicBrainzClient, extract_mb_credits};
use super::models::CreditRowCandidate;
use super::verify::{
    LocalAlbumSignals, artist_names_match, verify_discogs_release, verify_discogs_search_result,
    verify_mb_release, verify_mb_release_detail, verify_mb_release_group,
};
use crate::error::ProviderError;

pub(super) struct EnrichmentDraft {
    pub(super) resolved_title: Option<String>,
    pub(super) resolved_album_artist: Option<String>,
    pub(super) resolved_release_year: Option<i32>,
    pub(super) resolved_mb_rg_id: Option<String>,
    pub(super) resolved_upc: Option<String>,
    pub(super) resolved_bio: Option<String>,
    pub(super) resolved_cover: Option<String>,
    pub(super) primary_artist_mbid: Option<String>,
    pub(super) primary_artist_bio: Option<String>,
    pub(super) primary_artist_image: Option<String>,
    pub(super) track_cloud_meta: HashMap<(u16, u16), TrackMetadataLayer>,
    pub(super) credit_candidates: Vec<CreditRowCandidate>,
    pub(super) seen_credit_keys: HashSet<(String, String)>,
    pub(super) upstream_errors: Vec<String>,
    pub(super) last_upstream_err: Option<ProviderError>,
}

impl EnrichmentDraft {
    pub(super) fn new(initial_mb_rg_id: Option<String>) -> Self {
        Self {
            resolved_title: None,
            resolved_album_artist: None,
            resolved_release_year: None,
            resolved_mb_rg_id: initial_mb_rg_id,
            resolved_upc: None,
            resolved_bio: None,
            resolved_cover: None,
            primary_artist_mbid: None,
            primary_artist_bio: None,
            primary_artist_image: None,
            track_cloud_meta: HashMap::new(),
            credit_candidates: Vec::new(),
            seen_credit_keys: HashSet::new(),
            upstream_errors: Vec::new(),
            last_upstream_err: None,
        }
    }

    pub(super) fn record_err(&mut self, stage: &str, err: ProviderError) {
        if !matches!(
            err,
            ProviderError::AlbumNotFound(_) | ProviderError::TrackNotFound(_)
        ) {
            self.upstream_errors.push(format!("{stage}: {err}"));
            self.last_upstream_err = Some(err);
        }
    }
}

fn parse_year_prefix(raw: Option<&str>) -> Option<i32> {
    let s = raw?.trim();
    if s.len() < 4 {
        return None;
    }
    let yr: i32 = s[..4].parse().ok()?;
    (1000..=3000).contains(&yr).then_some(yr)
}

fn format_mb_artist_credits(credits: &[MbArtistCredit]) -> Option<String> {
    let names: Vec<&str> = credits
        .iter()
        .filter_map(|ac| {
            ac.name
                .as_deref()
                .or_else(|| ac.artist.as_ref().map(|a| a.name.as_str()))
                .map(str::trim)
                .filter(|s| !s.is_empty())
        })
        .collect();
    if names.is_empty() {
        None
    } else {
        Some(names.join(", "))
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn run_musicbrainz_phase(
    mb: &MusicBrainzClient,
    title: &str,
    artist_name: &str,
    first_isrc: Option<&str>,
    had_mb_rg_initially: bool,
    fetch_artist_bios: bool,
    signals: &LocalAlbumSignals,
    mb_artist_cache: &mut HashMap<String, Option<String>>,
    draft: &mut EnrichmentDraft,
) {
    let mut chosen_release_id: Option<String> = None;

    if draft.resolved_mb_rg_id.is_none() {
        if let Some(isrc) = first_isrc {
            match mb.lookup_by_isrc(isrc).await {
                Ok(isrc_res) => {
                    'isrc_search: for rec in isrc_res.recordings {
                        for rel in rec.releases {
                            if verify_mb_release(signals, &rel) {
                                if let Some(ref rg) = rel.release_group {
                                    draft.resolved_mb_rg_id = Some(rg.id.clone());
                                }
                                chosen_release_id = Some(rel.id);
                                break 'isrc_search;
                            }
                        }
                    }
                }
                Err(e) => draft.record_err("MusicBrainz ISRC lookup", e),
            }
        }
    }

    if draft.resolved_mb_rg_id.is_none() && chosen_release_id.is_none() {
        match mb.search_release_groups(title, artist_name, 5).await {
            Ok(groups) => {
                if let Some(verified) = groups
                    .into_iter()
                    .find(|g| verify_mb_release_group(signals, g))
                {
                    draft.resolved_mb_rg_id = Some(verified.id);
                    if !verified.title.trim().is_empty() {
                        draft.resolved_title = Some(verified.title.trim().to_string());
                    }
                    if draft.resolved_release_year.is_none() {
                        draft.resolved_release_year =
                            parse_year_prefix(verified.first_release_date.as_deref());
                    }
                    if draft.resolved_album_artist.is_none() {
                        draft.resolved_album_artist =
                            format_mb_artist_credits(&verified.artist_credit);
                    }
                }
            }
            Err(e) => draft.record_err("MusicBrainz search", e),
        }
    }

    if chosen_release_id.is_none() {
        if let Some(ref rg_id) = draft.resolved_mb_rg_id.clone() {
            match mb.lookup_release_group(rg_id).await {
                Ok(rg_detail) => {
                    if draft.resolved_title.is_none() && !rg_detail.title.trim().is_empty() {
                        draft.resolved_title = Some(rg_detail.title.trim().to_string());
                    }
                    if draft.resolved_album_artist.is_none() {
                        draft.resolved_album_artist =
                            format_mb_artist_credits(&rg_detail.artist_credit);
                    }
                    if let Some(rel) = rg_detail
                        .releases
                        .iter()
                        .find(|r| verify_mb_release(signals, r))
                        .or_else(|| {
                            had_mb_rg_initially
                                .then(|| rg_detail.releases.first())
                                .flatten()
                        })
                    {
                        chosen_release_id = Some(rel.id.clone());
                    }
                }
                Err(e) => draft.record_err("MusicBrainz release-group lookup", e),
            }
        }
    }

    if let Some(ref rel_id) = chosen_release_id {
        match mb.lookup_release_with_credits(rel_id).await {
            Ok(rel_detail) => {
                let verified =
                    had_mb_rg_initially || verify_mb_release_detail(signals, &rel_detail);
                if verified {
                    if draft.resolved_mb_rg_id.is_none() {
                        if let Some(ref rg) = rel_detail.release_group {
                            draft.resolved_mb_rg_id = Some(rg.id.clone());
                        }
                    }
                    let mb_title = rel_detail
                        .release_group
                        .as_ref()
                        .map(|rg| rg.title.trim())
                        .filter(|s| !s.is_empty())
                        .or_else(|| {
                            let t = rel_detail.title.trim();
                            (!t.is_empty()).then_some(t)
                        });
                    if let Some(t) = mb_title {
                        draft.resolved_title = Some(t.to_string());
                    }
                    if let Some(aa) = format_mb_artist_credits(&rel_detail.artist_credit) {
                        draft.resolved_album_artist = Some(aa);
                    }
                    if draft.resolved_release_year.is_none() {
                        draft.resolved_release_year = rel_detail
                            .release_group
                            .as_ref()
                            .and_then(|rg| parse_year_prefix(rg.first_release_date.as_deref()))
                            .or_else(|| parse_year_prefix(rel_detail.date.as_deref()));
                    }
                    if let Some(bc) = rel_detail
                        .barcode
                        .as_deref()
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                    {
                        draft.resolved_upc = Some(bc.to_string());
                    }
                    if let Some(ac) = rel_detail.artist_credit.first() {
                        if let Some(ref a) = ac.artist {
                            if !a.id.trim().is_empty()
                                && artist_names_match(&signals.norm_artist, &a.name)
                            {
                                draft.primary_artist_mbid = Some(a.id.trim().to_string());
                            }
                        }
                    }

                    // Populate track-level cloud metadata by (disc_number, track_number)
                    for (m_idx, medium) in rel_detail.media.iter().enumerate() {
                        let disc_no = (m_idx + 1).min(u16::MAX as usize) as u16;
                        for (t_idx, trk) in medium.tracks.iter().enumerate() {
                            let track_no = (t_idx + 1).min(u16::MAX as usize) as u16;
                            let t_title = trk.title.trim();
                            if !t_title.is_empty() {
                                draft.track_cloud_meta.insert(
                                    (disc_no, track_no),
                                    TrackMetadataLayer {
                                        title: Some(t_title.to_string()),
                                        artist_name: draft.resolved_album_artist.clone(),
                                        album_artist: draft.resolved_album_artist.clone(),
                                        disc_number: Some(disc_no),
                                        track_number: Some(track_no),
                                        ..Default::default()
                                    },
                                );
                            }
                        }
                    }

                    for cand in extract_mb_credits(&rel_detail) {
                        let key = (
                            cand.artist_name.to_ascii_lowercase(),
                            cand.role.to_ascii_lowercase(),
                        );
                        if draft.seen_credit_keys.insert(key) {
                            let bio = if fetch_artist_bios {
                                fetch_mb_artist_bio_cached(
                                    mb,
                                    cand.artist_mbid.as_deref(),
                                    mb_artist_cache,
                                )
                                .await
                            } else {
                                None
                            };
                            draft.credit_candidates.push(CreditRowCandidate {
                                artist_name: cand.artist_name,
                                mbid: cand.artist_mbid,
                                bio,
                                image_url: None,
                                role: cand.role,
                            });
                        }
                    }
                } else if !had_mb_rg_initially {
                    draft.resolved_mb_rg_id = None;
                }
            }
            Err(e) => draft.record_err("MusicBrainz release lookup", e),
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn run_discogs_phase(
    dg: &DiscogsClient,
    title: &str,
    artist_name: &str,
    fetch_artist_bios: bool,
    signals: &LocalAlbumSignals,
    dg_artist_cache: &mut HashMap<u64, (Option<String>, Option<String>)>,
    draft: &mut EnrichmentDraft,
) {
    let results = match dg
        .search_releases(title, artist_name, draft.resolved_upc.as_deref(), 5)
        .await
    {
        Ok(r) => r,
        Err(e) => {
            draft.record_err("Discogs search", e);
            return;
        }
    };

    let Some(first) = results
        .into_iter()
        .find(|r| verify_discogs_search_result(signals, r))
    else {
        return;
    };

    let rel = match dg.get_release(first.id).await {
        Ok(r) => r,
        Err(e) => {
            draft.record_err("Discogs release lookup", e);
            return;
        }
    };

    if !verify_discogs_release(signals, &rel) {
        return;
    }

    let extracted = extract_discogs_credits(&rel);
    if draft.resolved_title.is_none() && !rel.title.trim().is_empty() {
        draft.resolved_title = Some(rel.title.trim().to_string());
    }
    if draft.resolved_album_artist.is_none() && !rel.artists.is_empty() {
        let joined: Vec<String> = rel
            .artists
            .iter()
            .map(|a| clean_discogs_artist_name(&a.name))
            .filter(|s| !s.is_empty())
            .collect();
        if !joined.is_empty() {
            draft.resolved_album_artist = Some(joined.join(", "));
        }
    }
    if draft.resolved_release_year.is_none() {
        draft.resolved_release_year = extracted.year;
    }
    if draft.resolved_upc.is_none() {
        draft.resolved_upc = extracted.upc;
    }
    if draft.resolved_bio.is_none() {
        draft.resolved_bio = extracted.editorial_bio;
    }
    if draft.resolved_cover.is_none() {
        draft.resolved_cover = extracted.cover_url;
    }

    for (idx, trk) in rel.tracklist.iter().enumerate() {
        let track_no = (idx + 1).min(u16::MAX as usize) as u16;
        let t_title = trk.title.trim();
        if !t_title.is_empty() {
            draft
                .track_cloud_meta
                .entry((1, track_no))
                .or_insert_with(|| TrackMetadataLayer {
                    title: Some(t_title.to_string()),
                    artist_name: draft.resolved_album_artist.clone(),
                    album_artist: draft.resolved_album_artist.clone(),
                    disc_number: Some(1),
                    track_number: Some(track_no),
                    ..Default::default()
                });
        }
    }

    if (draft.resolved_bio.is_none() || draft.resolved_cover.is_none())
        && rel.master_id.or(first.master_id).is_some()
    {
        let mid = rel.master_id.or(first.master_id).unwrap();
        match dg.get_master(mid).await {
            Ok(master) => {
                if draft.resolved_bio.is_none() {
                    draft.resolved_bio = master
                        .notes
                        .as_deref()
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .map(str::to_string);
                }
                if draft.resolved_cover.is_none() {
                    draft.resolved_cover = master
                        .images
                        .first()
                        .map(|i| i.uri.trim().to_string())
                        .filter(|s| !s.is_empty());
                }
                if draft.resolved_release_year.is_none() {
                    draft.resolved_release_year = master.year.filter(|y| (1000..=3000).contains(y));
                }
            }
            Err(e) => draft.record_err("Discogs master lookup", e),
        }
    }

    // Collect supplementary artist bio/image (committed inside runner's single ImmediateTx).
    if fetch_artist_bios {
        if let Some(first_art) = rel.artists.first() {
            if let Some(aid) = first_art.id {
                let clean = clean_discogs_artist_name(&first_art.name);
                if !clean.is_empty() && artist_names_match(&signals.norm_artist, &clean) {
                    let (bio, img) = fetch_discogs_artist_cached(dg, aid, dg_artist_cache).await;
                    if draft.primary_artist_bio.is_none() {
                        draft.primary_artist_bio = bio;
                    }
                    if draft.primary_artist_image.is_none() {
                        draft.primary_artist_image = img;
                    }
                }
            }
        }
    }

    for cand in extracted.credits {
        let key = (
            cand.artist_name.to_ascii_lowercase(),
            cand.role.to_ascii_lowercase(),
        );
        if draft.seen_credit_keys.insert(key) {
            let (bio, img) = if fetch_artist_bios {
                if let Some(aid) = cand.discogs_artist_id {
                    fetch_discogs_artist_cached(dg, aid, dg_artist_cache).await
                } else {
                    (None, None)
                }
            } else {
                (None, None)
            };

            draft.credit_candidates.push(CreditRowCandidate {
                artist_name: cand.artist_name,
                mbid: None,
                bio,
                image_url: img,
                role: cand.role,
            });
        }
    }
}

async fn fetch_mb_artist_bio_cached(
    mb: &MusicBrainzClient,
    mbid_opt: Option<&str>,
    cache: &mut HashMap<String, Option<String>>,
) -> Option<String> {
    let mbid = mbid_opt?;
    if let Some(cached) = cache.get(mbid) {
        return cached.clone();
    }
    let fetched = mb
        .lookup_artist(mbid)
        .await
        .ok()
        .and_then(|ad| ad.disambiguation)
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    cache.insert(mbid.to_string(), fetched.clone());
    fetched
}

async fn fetch_discogs_artist_cached(
    dg: &DiscogsClient,
    artist_id: u64,
    cache: &mut HashMap<u64, (Option<String>, Option<String>)>,
) -> (Option<String>, Option<String>) {
    if let Some(cached) = cache.get(&artist_id) {
        return cached.clone();
    }
    let val = match dg.get_artist(artist_id).await {
        Ok(art) => {
            let bio = art
                .profile
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string);
            let img = art
                .images
                .first()
                .map(|i| i.uri.trim().to_string())
                .filter(|s| !s.is_empty());
            (bio, img)
        }
        Err(_) => (None, None),
    };
    cache.insert(artist_id, val.clone());
    val
}
