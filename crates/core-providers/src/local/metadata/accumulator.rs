use std::path::Path;

use core_types::AudioFormat;

use super::helpers::{
    append_split_artists, derive_album_and_artist_from_dir, derive_title_and_track_from_filename,
    disc_number_from_parent_dir, fill_opt_str, split_artists,
};
use super::{ExtractedMetadata, Id3v1ParsedTags, Mp4IlstParsedTags};
use crate::local::ape_meta::ApeParsedTags;
use crate::local::dsd_meta::{DsdMetadata, Id3v2ParsedTags};
use crate::local::encoding::sanitize_tag_text;
use crate::local::mapper::strip_disc_suffix_from_album;
use crate::local::riff_meta::RiffWavMetadata;

pub(super) const ALBUM_ARTIST_PRIO_EXACT: u8 = 4;
pub(super) const ALBUM_ARTIST_PRIO_ALIAS: u8 = 3;
pub(super) const ALBUM_ARTIST_PRIO_BAND: u8 = 2;
pub(super) const ALBUM_ARTIST_PRIO_FALLBACK: u8 = 1;

pub(super) const RECORD_LABEL_PRIO_LABEL: u8 = 3;
pub(super) const RECORD_LABEL_PRIO_PUBLISHER: u8 = 2;
pub(super) const RECORD_LABEL_PRIO_FALLBACK: u8 = 1;

#[derive(Default)]
pub(super) struct TagAccumulator {
    pub(super) title: Option<String>,
    pub(super) artist: Option<String>,
    pub(super) artists: Vec<String>,
    pub(super) album: Option<String>,
    pub(super) album_artist: Option<String>,
    pub(super) album_artist_priority: u8,
    pub(super) track_number: Option<u16>,
    pub(super) disc_number: Option<u16>,
    pub(super) release_year: Option<i32>,
    pub(super) isrc: Option<String>,
    pub(super) rg_track_db: Option<f64>,
    pub(super) rg_album_db: Option<f64>,
    pub(super) rg_track_peak: Option<f64>,
    pub(super) rg_album_peak: Option<f64>,
    pub(super) upc: Option<String>,
    pub(super) mb_rg_id: Option<String>,
    pub(super) edition: Option<String>,
    pub(super) record_label: Option<String>,
    pub(super) record_label_priority: u8,
    pub(super) compilation: Option<bool>,
    pub(super) genre: Option<String>,
    pub(super) composer: Option<String>,
    pub(super) lyrics: Option<String>,
    pub(super) pictures: Vec<core_types::ExtractedPicture>,
}

impl TagAccumulator {
    pub(super) fn set_album_artist(&mut self, raw: String, priority: u8) {
        let clean = sanitize_tag_text(&raw);
        if clean.is_empty() {
            return;
        }
        if self.album_artist.is_none() || priority > self.album_artist_priority {
            self.album_artist = Some(clean);
            self.album_artist_priority = priority;
        }
    }

    pub(super) fn set_record_label(&mut self, raw: String, priority: u8) {
        let clean = sanitize_tag_text(&raw);
        if clean.is_empty() {
            return;
        }
        if self.record_label.is_none() || priority > self.record_label_priority {
            self.record_label = Some(clean);
            self.record_label_priority = priority;
        }
    }

    pub(super) fn apply_id3v2(&mut self, id3: Id3v2ParsedTags, include_pictures: bool) {
        let rg_track_db = id3.effective_rg_track_db();
        let rg_album_db = id3.effective_rg_album_db();
        let rg_track_peak = id3.effective_rg_track_peak();
        let rg_album_peak = id3.effective_rg_album_peak();

        fill_opt_str(&mut self.title, id3.title);
        if self.artists.is_empty() {
            for a in id3.artists {
                append_split_artists(&mut self.artists, &a);
            }
        }
        if self.artist.is_none() {
            if let Some(art) = id3.artist {
                let clean = sanitize_tag_text(&art);
                if !clean.is_empty() {
                    if self.artists.is_empty() {
                        append_split_artists(&mut self.artists, &clean);
                    }
                    self.artist = Some(clean);
                }
            }
        }
        fill_opt_str(&mut self.album, id3.album);
        fill_opt_str(&mut self.album_artist, id3.album_artist);
        if self.track_number.is_none() {
            self.track_number = id3.track_number;
        }
        if self.disc_number.is_none() {
            self.disc_number = id3.disc_number;
        }
        if self.release_year.is_none() {
            self.release_year = id3.release_year;
        }
        if self.isrc.is_none() {
            self.isrc = id3.isrc;
        }
        if self.rg_track_db.is_none() {
            self.rg_track_db = rg_track_db;
        }
        if self.rg_album_db.is_none() {
            self.rg_album_db = rg_album_db;
        }
        if self.rg_track_peak.is_none() {
            self.rg_track_peak = rg_track_peak;
        }
        if self.rg_album_peak.is_none() {
            self.rg_album_peak = rg_album_peak;
        }
        if self.upc.is_none() {
            self.upc = id3.upc;
        }
        if self.mb_rg_id.is_none() {
            self.mb_rg_id = id3.musicbrainz_release_group_id;
        }
        fill_opt_str(&mut self.edition, id3.edition_label);
        fill_opt_str(&mut self.record_label, id3.record_label);
        if self.compilation.is_none() {
            self.compilation = id3.compilation;
        }
        fill_opt_str(&mut self.genre, id3.genre);
        fill_opt_str(&mut self.composer, id3.composer);
        if self.lyrics.is_none() {
            self.lyrics = id3.lyrics.filter(|s| !s.trim().is_empty());
        }
        if include_pictures && self.pictures.is_empty() {
            self.pictures = id3.pictures;
        }
    }

    pub(super) fn apply_ape(&mut self, ape: ApeParsedTags, include_pictures: bool) {
        fill_opt_str(&mut self.title, ape.title);
        let had_artists = !self.artists.is_empty();
        if !had_artists {
            for a in &ape.artists {
                append_split_artists(&mut self.artists, a);
            }
        }
        if self.artist.is_none() {
            if ape.artists.len() > 1 {
                let joined = ape
                    .artists
                    .iter()
                    .map(|a| sanitize_tag_text(a))
                    .filter(|a| !a.is_empty())
                    .collect::<Vec<_>>()
                    .join("; ");
                if !joined.is_empty() {
                    self.artist = Some(joined);
                }
            } else if let Some(art) = ape.artist {
                let clean = sanitize_tag_text(&art);
                if !clean.is_empty() {
                    if self.artists.is_empty() {
                        append_split_artists(&mut self.artists, &clean);
                    }
                    self.artist = Some(clean);
                }
            }
        }
        fill_opt_str(&mut self.album, ape.album);
        fill_opt_str(&mut self.album_artist, ape.album_artist);
        if self.track_number.is_none() {
            self.track_number = ape.track_number;
        }
        if self.disc_number.is_none() {
            self.disc_number = ape.disc_number;
        }
        if self.release_year.is_none() {
            self.release_year = ape.release_year;
        }
        if self.isrc.is_none() {
            self.isrc = ape.isrc;
        }
        if self.rg_track_db.is_none() {
            self.rg_track_db = ape.replay_gain_track_db;
        }
        if self.rg_album_db.is_none() {
            self.rg_album_db = ape.replay_gain_album_db;
        }
        if self.rg_track_peak.is_none() {
            self.rg_track_peak = ape.replay_gain_track_peak;
        }
        if self.rg_album_peak.is_none() {
            self.rg_album_peak = ape.replay_gain_album_peak;
        }
        if self.upc.is_none() {
            self.upc = ape.upc;
        }
        if self.mb_rg_id.is_none() {
            self.mb_rg_id = ape.musicbrainz_release_group_id;
        }
        fill_opt_str(&mut self.edition, ape.edition_label);
        fill_opt_str(&mut self.record_label, ape.record_label);
        if self.compilation.is_none() {
            self.compilation = ape.compilation;
        }
        fill_opt_str(&mut self.genre, ape.genre);
        fill_opt_str(&mut self.composer, ape.composer);
        if self.lyrics.is_none() {
            self.lyrics = ape.lyrics.filter(|s| !s.trim().is_empty());
        }
        if include_pictures && self.pictures.is_empty() {
            self.pictures = ape.pictures;
        }
    }

    pub(super) fn apply_id3v1(&mut self, v1: Id3v1ParsedTags) {
        fill_opt_str(&mut self.title, v1.title);
        if self.artist.is_none() {
            if let Some(art) = v1.artist {
                let clean = sanitize_tag_text(&art);
                if !clean.is_empty() {
                    if self.artists.is_empty() {
                        append_split_artists(&mut self.artists, &clean);
                    }
                    self.artist = Some(clean);
                }
            }
        }
        fill_opt_str(&mut self.album, v1.album);
        if self.release_year.is_none() {
            self.release_year = v1.release_year;
        }
        if self.track_number.is_none() {
            self.track_number = v1.track_number;
        }
        fill_opt_str(&mut self.genre, v1.genre);
    }

    pub(super) fn apply_mp4_ilst(&mut self, mp4: Mp4IlstParsedTags, include_pictures: bool) {
        fill_opt_str(&mut self.title, mp4.title);
        if self.artists.is_empty() {
            for a in mp4.artists {
                append_split_artists(&mut self.artists, &a);
            }
        }
        if self.artist.is_none() {
            if let Some(art) = mp4.artist {
                let clean = sanitize_tag_text(&art);
                if !clean.is_empty() {
                    if self.artists.is_empty() {
                        append_split_artists(&mut self.artists, &clean);
                    }
                    self.artist = Some(clean);
                }
            }
        }
        fill_opt_str(&mut self.album, mp4.album);
        fill_opt_str(&mut self.album_artist, mp4.album_artist);
        if self.track_number.is_none() {
            self.track_number = mp4.track_number;
        }
        if self.disc_number.is_none() {
            self.disc_number = mp4.disc_number;
        }
        if self.release_year.is_none() {
            self.release_year = mp4.release_year;
        }
        fill_opt_str(&mut self.genre, mp4.genre);
        fill_opt_str(&mut self.composer, mp4.composer);
        fill_opt_str(&mut self.record_label, mp4.record_label);
        if self.compilation.is_none() {
            self.compilation = mp4.compilation;
        }
        if self.lyrics.is_none() {
            self.lyrics = mp4.lyrics.filter(|s| !s.trim().is_empty());
        }
        if include_pictures && self.pictures.is_empty() {
            self.pictures = mp4.pictures;
        }
    }

    pub(super) fn finalize(
        mut self,
        fallback_path: &Path,
        format: AudioFormat,
        duration_ms: u64,
    ) -> ExtractedMetadata {
        let (title_fallback, track_num_fallback) =
            derive_title_and_track_from_filename(fallback_path);
        let (album_fallback, artist_fallback) = derive_album_and_artist_from_dir(fallback_path);

        let title = self
            .title
            .map(|s| sanitize_tag_text(&s))
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| sanitize_tag_text(&title_fallback));
        let title = if title.is_empty() {
            "Unknown Title".to_string()
        } else {
            title
        };

        let artist = self
            .artist
            .map(|s| sanitize_tag_text(&s))
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| sanitize_tag_text(&artist_fallback));
        let artist = if artist.is_empty() {
            "Unknown Artist".to_string()
        } else {
            artist
        };

        let album = self
            .album
            .map(|s| sanitize_tag_text(&s))
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| sanitize_tag_text(&album_fallback));
        let album = if album.is_empty() {
            "Unknown Album".to_string()
        } else {
            album
        };

        let album_artist = self
            .album_artist
            .map(|s| sanitize_tag_text(&s))
            .filter(|s| !s.is_empty());
        let track_number = self.track_number.unwrap_or(track_num_fallback).max(1);
        let (_, title_disc) = strip_disc_suffix_from_album(&album);
        let disc_number = self
            .disc_number
            .or(title_disc)
            .or_else(|| disc_number_from_parent_dir(fallback_path))
            .unwrap_or(1)
            .max(1);
        if self.artists.is_empty() {
            self.artists = split_artists(&artist);
        } else {
            self.artists = self
                .artists
                .into_iter()
                .map(|a| sanitize_tag_text(&a))
                .filter(|a| !a.is_empty())
                .collect();
        }

        ExtractedMetadata {
            title,
            artist,
            artists: self.artists,
            album,
            album_artist,
            track_number,
            disc_number,
            release_year: self.release_year,
            isrc: self
                .isrc
                .map(|s| sanitize_tag_text(&s))
                .filter(|s| !s.is_empty()),
            duration_ms: duration_ms.max(1),
            format,
            cover_url: None,
            replay_gain_track_db: self.rg_track_db,
            replay_gain_album_db: self.rg_album_db,
            replay_gain_track_peak: self.rg_track_peak,
            replay_gain_album_peak: self.rg_album_peak,
            upc: self
                .upc
                .map(|s| sanitize_tag_text(&s))
                .filter(|s| !s.is_empty()),
            musicbrainz_release_group_id: self
                .mb_rg_id
                .map(|s| sanitize_tag_text(&s))
                .filter(|s| !s.is_empty()),
            edition_label: self
                .edition
                .map(|s| sanitize_tag_text(&s))
                .filter(|s| !s.is_empty()),
            record_label: self
                .record_label
                .map(|s| sanitize_tag_text(&s))
                .filter(|s| !s.is_empty()),
            compilation: self.compilation,
            genre: self
                .genre
                .map(|s| sanitize_tag_text(&s))
                .filter(|s| !s.is_empty()),
            composer: self
                .composer
                .map(|s| sanitize_tag_text(&s))
                .filter(|s| !s.is_empty()),
            embedded_lyrics: self.lyrics,
            pictures: self.pictures,
        }
    }
}

pub(super) fn build_wav_extracted(wav: RiffWavMetadata, path: &Path) -> ExtractedMetadata {
    let mut acc = TagAccumulator {
        title: wav.title,
        artist: wav.artist,
        artists: Vec::new(),
        album: wav.album,
        album_artist: wav.album_artist,
        album_artist_priority: 0,
        track_number: wav.track_number,
        disc_number: wav.disc_number,
        release_year: wav.release_year,
        isrc: wav.isrc,
        rg_track_db: wav.replay_gain_track_db,
        rg_album_db: wav.replay_gain_album_db,
        rg_track_peak: wav.replay_gain_track_peak,
        rg_album_peak: wav.replay_gain_album_peak,
        upc: wav.upc,
        mb_rg_id: wav.musicbrainz_release_group_id,
        edition: wav.edition_label,
        record_label: wav.record_label,
        record_label_priority: 0,
        compilation: wav.compilation,
        genre: wav.genre,
        composer: wav.composer,
        lyrics: wav.lyrics,
        pictures: wav.pictures,
    };
    for a in wav.artists {
        append_split_artists(&mut acc.artists, &a);
    }
    acc.finalize(path, wav.format, wav.duration_ms)
}

pub(super) fn build_dsf_extracted(dsd: DsdMetadata, path: &Path) -> ExtractedMetadata {
    build_dsd_extracted(dsd, path)
}

pub(super) fn build_dff_extracted(dsd: DsdMetadata, path: &Path) -> ExtractedMetadata {
    build_dsd_extracted(dsd, path)
}

fn build_dsd_extracted(dsd: DsdMetadata, path: &Path) -> ExtractedMetadata {
    let mut acc = TagAccumulator {
        title: dsd.tags.title,
        artist: dsd.tags.artist,
        artists: Vec::new(),
        album: dsd.tags.album,
        album_artist: dsd.tags.album_artist,
        album_artist_priority: 0,
        track_number: dsd.tags.track_number,
        disc_number: dsd.tags.disc_number,
        release_year: dsd.tags.release_year,
        isrc: dsd.tags.isrc,
        rg_track_db: dsd.tags.replay_gain_track_db,
        rg_album_db: dsd.tags.replay_gain_album_db,
        rg_track_peak: dsd.tags.replay_gain_track_peak,
        rg_album_peak: dsd.tags.replay_gain_album_peak,
        upc: dsd.tags.upc,
        mb_rg_id: dsd.tags.musicbrainz_release_group_id,
        edition: dsd.tags.edition_label,
        record_label: dsd.tags.record_label,
        record_label_priority: 0,
        compilation: dsd.tags.compilation,
        genre: dsd.tags.genre,
        composer: dsd.tags.composer,
        lyrics: dsd.tags.lyrics,
        pictures: dsd.tags.pictures,
    };
    for a in dsd.tags.artists {
        append_split_artists(&mut acc.artists, &a);
    }
    acc.finalize(path, dsd.format, dsd.duration_ms)
}
