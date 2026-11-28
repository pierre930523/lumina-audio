use core_types::{
    AlbumDetail, AlbumVersion, AudioFormat, CanonicalAlbum, MetadataPolicy, ProviderKind,
    TrackSource,
};

use super::models::EnrichmentConfig;
use super::verify::{
    LocalAlbumSignals, MIN_MB_SEARCH_SCORE, is_unmatchable_local_album, verify_discogs_release,
    verify_discogs_search_result, verify_mb_release, verify_mb_release_group,
};
use crate::enrichment::discogs::{
    DiscogsExtraArtist, DiscogsRelease, DiscogsSearchResult, DiscogsTrack,
};
use crate::enrichment::musicbrainz::{
    MbArtistCredit, MbArtistRef, MbMedium, MbRelease, MbReleaseGroup, MbTrack,
};

fn sample_local_signals(
    title: &str,
    artist: &str,
    tracks: usize,
    dur_ms: u64,
) -> LocalAlbumSignals {
    let alb = CanonicalAlbum::new(title, artist).unwrap();
    let ver = AlbumVersion::new(
        &alb.id,
        ProviderKind::Local,
        "/music/alb",
        AudioFormat::cd_quality(),
    )
    .unwrap();
    let mut track_list = Vec::new();
    for i in 1..=tracks {
        track_list.push(
            TrackSource::new(
                &ver.id,
                ProviderKind::Local,
                format!("/music/alb/{i:02}.flac"),
                format!("Track {i}"),
                1,
                i as u16,
                dur_ms,
                AudioFormat::cd_quality(),
            )
            .unwrap(),
        );
    }
    let detail = AlbumDetail {
        album: alb,
        versions: vec![core_types::AlbumVersionDetail {
            version: ver,
            tracks: track_list,
        }],
        credits: Vec::new(),
        meta_policy: MetadataPolicy::Inherit,
        has_user_edits: false,
        primary_version_id: None,
        is_primary_locked: false,
        hidden_version_count: 0,
    };
    LocalAlbumSignals::from_detail(&detail)
}

#[test]
fn test_enrichment_config_defaults_safe() {
    let cfg = EnrichmentConfig::default();
    assert!(
        !cfg.merge_on_mbid_match,
        "merge_on_mbid_match must default to false to prevent destructive false merges"
    );
}

#[test]
fn test_unmatchable_local_album_guard() {
    assert!(is_unmatchable_local_album("Unknown Album", "Miles Davis"));
    assert!(is_unmatchable_local_album("Kind of Blue", "Unknown Artist"));
    assert!(is_unmatchable_local_album(
        "Greatest Hits",
        "Various Artists"
    ));
    assert!(!is_unmatchable_local_album("Kind of Blue", "Miles Davis"));
}

#[test]
fn test_mb_release_group_rejects_low_score_and_mismatch() {
    let local = sample_local_signals("Kind of Blue", "Miles Davis", 5, 300_000);

    // Reject score below MIN_MB_SEARCH_SCORE
    let low_score = MbReleaseGroup {
        id: "rg-low".into(),
        title: "Kind of Blue".into(),
        score: Some(MIN_MB_SEARCH_SCORE - 15),
        artist_credit: vec![MbArtistCredit {
            name: Some("Miles Davis".into()),
            artist: None,
        }],
        ..Default::default()
    };
    assert!(!verify_mb_release_group(&local, &low_score));

    // Reject completely different title even with high score
    let wrong_title = MbReleaseGroup {
        id: "rg-wrong".into(),
        title: "Bitches Brew".into(),
        score: Some(100),
        artist_credit: vec![MbArtistCredit {
            name: Some("Miles Davis".into()),
            artist: None,
        }],
        ..Default::default()
    };
    assert!(!verify_mb_release_group(&local, &wrong_title));

    // Reject different artist
    let wrong_artist = MbReleaseGroup {
        id: "rg-artist".into(),
        title: "Kind of Blue".into(),
        score: Some(98),
        artist_credit: vec![MbArtistCredit {
            name: None,
            artist: Some(MbArtistRef {
                id: "a1".into(),
                name: "John Coltrane".into(),
                ..Default::default()
            }),
        }],
        ..Default::default()
    };
    assert!(!verify_mb_release_group(&local, &wrong_artist));

    // Accept verified high-score match
    let good = MbReleaseGroup {
        id: "rg-good".into(),
        title: "Kind of Blue (Legacy Edition)".into(),
        score: Some(98),
        artist_credit: vec![MbArtistCredit {
            name: Some("Miles Davis".into()),
            artist: None,
        }],
        ..Default::default()
    };
    assert!(verify_mb_release_group(&local, &good));
}

#[test]
fn test_mb_release_isrc_rejects_compilation_and_track_count_mismatch() {
    let local = sample_local_signals("Kind of Blue", "Miles Davis", 5, 300_000);

    let compilation_rel = MbRelease {
        id: "rel-comp".into(),
        title: "Best of Jazz 100".into(),
        track_count: Some(25),
        ..Default::default()
    };
    assert!(!verify_mb_release(&local, &compilation_rel));

    let duration_mismatch = MbRelease {
        id: "rel-dur".into(),
        title: "Kind of Blue".into(),
        media: vec![MbMedium {
            track_count: Some(5),
            tracks: (0..5)
                .map(|_| MbTrack {
                    id: "t".into(),
                    title: "t".into(),
                    length: Some(60_000), // 5 min total vs 25 min local
                    recording: None,
                })
                .collect(),
        }],
        ..Default::default()
    };
    assert!(!verify_mb_release(&local, &duration_mismatch));

    let good_rel = MbRelease {
        id: "rel-ok".into(),
        title: "Kind of Blue".into(),
        media: vec![MbMedium {
            track_count: Some(5),
            tracks: (0..5)
                .map(|_| MbTrack {
                    id: "t".into(),
                    title: "t".into(),
                    length: Some(301_000),
                    recording: None,
                })
                .collect(),
        }],
        ..Default::default()
    };
    assert!(verify_mb_release(&local, &good_rel));
}

#[test]
fn test_discogs_verification_rejects_wrong_album_and_tracklist() {
    let local = sample_local_signals("Abbey Road", "The Beatles", 17, 180_000);

    let wrong_sr = DiscogsSearchResult {
        id: 1,
        title: "Other Band - Abbey Road Tribute".into(),
        ..Default::default()
    };
    assert!(!verify_discogs_search_result(&local, &wrong_sr));

    let good_sr = DiscogsSearchResult {
        id: 2,
        title: "The Beatles (2) - Abbey Road".into(),
        ..Default::default()
    };
    assert!(verify_discogs_search_result(&local, &good_sr));

    let bad_rel = DiscogsRelease {
        id: 2,
        title: "Abbey Road".into(),
        artists: vec![DiscogsExtraArtist {
            id: Some(1),
            name: "The Beatles".into(),
            role: String::new(),
        }],
        tracklist: vec![DiscogsTrack::default(); 2], // 2 tracks vs 17 local
        ..Default::default()
    };
    assert!(!verify_discogs_release(&local, &bad_rel));
}
