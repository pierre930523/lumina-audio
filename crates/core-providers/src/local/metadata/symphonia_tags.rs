use symphonia::core::meta::{MetadataRevision, StandardTagKey, StandardVisualKey, Value};

use super::accumulator::{
    ALBUM_ARTIST_PRIO_ALIAS, ALBUM_ARTIST_PRIO_BAND, ALBUM_ARTIST_PRIO_EXACT,
    ALBUM_ARTIST_PRIO_FALLBACK, RECORD_LABEL_PRIO_FALLBACK, RECORD_LABEL_PRIO_LABEL,
    RECORD_LABEL_PRIO_PUBLISHER, TagAccumulator,
};
use super::helpers::{
    append_split_artists, normalize_custom_tag_key, normalize_isrc, normalize_upc, parse_bool_flag,
};
use crate::local::dsd_meta::{
    parse_disc_number, parse_replay_gain_db_str, parse_replay_gain_peak_str,
    parse_track_and_disc_number, parse_year,
};
use crate::local::encoding::{
    recover_latin1_mojibake_block, sanitize_multiline_tag_text, sanitize_tag_text,
};

impl TagAccumulator {
    pub(super) fn apply_symphonia_revision(
        &mut self,
        meta: &MetadataRevision,
        include_pictures: bool,
    ) {
        if include_pictures && self.pictures.is_empty() {
            for vis in meta.visuals() {
                let pt = match vis.usage {
                    Some(StandardVisualKey::FrontCover) => core_types::PictureType::FrontCover,
                    Some(StandardVisualKey::BackCover) => core_types::PictureType::BackCover,
                    _ => core_types::PictureType::Other,
                };
                self.pictures.push(core_types::ExtractedPicture {
                    picture_type: pt,
                    mime_type: vis.media_type.clone(),
                    data: vis.data.to_vec(),
                });
            }
        }

        let tags = meta.tags();
        // Pass 1: Tag-wide mojibake recovery across all String tag values in this revision so every
        // field of the same file decodes under ONE shared legacy encoding (Shift-JIS/Big5/GBK/UTF-8).
        let raw_strings: Vec<&str> = tags
            .iter()
            .filter_map(|t| match &t.value {
                Value::String(s) => Some(s.as_str()),
                _ => None,
            })
            .collect();
        let (recovered_strings, _) = recover_latin1_mojibake_block(&raw_strings);
        let mut str_cursor = 0usize;

        let had_artists_before = !self.artists.is_empty();
        let had_artist_before = self.artist.is_some();
        let had_record_label_before = self.record_label.is_some();
        let mut rev_artist_values: Vec<String> = Vec::new();

        for tag in tags {
            let recovered_str = if matches!(tag.value, Value::String(_)) {
                let s = recovered_strings
                    .get(str_cursor)
                    .cloned()
                    .unwrap_or_default();
                str_cursor += 1;
                Some(s)
            } else {
                None
            };

            if let Some(StandardTagKey::Compilation) = tag.std_key {
                if self.compilation.is_none() {
                    self.compilation = match &tag.value {
                        Value::Flag => Some(true),
                        Value::Boolean(b) => Some(*b),
                        Value::UnsignedInt(u) => Some(*u != 0),
                        Value::SignedInt(i) => Some(*i != 0),
                        Value::String(_) => recovered_str.as_deref().and_then(parse_bool_flag),
                        _ => None,
                    };
                }
                continue;
            }

            let raw_str = match &tag.value {
                Value::String(_) => recovered_str.unwrap_or_default(),
                Value::UnsignedInt(u) => u.to_string(),
                Value::SignedInt(i) => i.to_string(),
                Value::Float(f) => f.to_string(),
                _ => continue,
            };

            let key_upper = tag.key.trim().to_ascii_uppercase();
            let norm_key = normalize_custom_tag_key(&tag.key);
            let is_lyrics = matches!(tag.std_key, Some(StandardTagKey::Lyrics))
                || matches!(
                    norm_key.as_str(),
                    "LYRICS" | "UNSYNCEDLYRICS" | "SYNCEDLYRICS"
                );
            let tag_str = if is_lyrics {
                sanitize_multiline_tag_text(&raw_str)
            } else {
                sanitize_tag_text(&raw_str)
            };
            if tag_str.is_empty() {
                continue;
            }

            if let Some(std_key) = tag.std_key {
                match std_key {
                    StandardTagKey::TrackTitle if self.title.is_none() => {
                        self.title = Some(tag_str);
                    }
                    StandardTagKey::Artist => {
                        if !had_artists_before {
                            append_split_artists(&mut self.artists, &tag_str);
                        }
                        if !had_artist_before
                            && !rev_artist_values
                                .iter()
                                .any(|e| e.eq_ignore_ascii_case(&tag_str))
                        {
                            rev_artist_values.push(tag_str);
                        }
                    }
                    StandardTagKey::Album if self.album.is_none() => {
                        self.album = Some(tag_str);
                    }
                    StandardTagKey::AlbumArtist => {
                        let prio = if key_upper == "ALBUMARTIST" {
                            ALBUM_ARTIST_PRIO_EXACT
                        } else if matches!(norm_key.as_str(), "ALBUMARTIST" | "ALBUMARTISTS") {
                            ALBUM_ARTIST_PRIO_ALIAS
                        } else if matches!(key_upper.as_str(), "TPE2" | "AART" | "BAND") {
                            ALBUM_ARTIST_PRIO_BAND
                        } else {
                            ALBUM_ARTIST_PRIO_FALLBACK
                        };
                        self.set_album_artist(tag_str, prio);
                    }
                    StandardTagKey::Genre if self.genre.is_none() => {
                        self.genre = Some(tag_str);
                    }
                    StandardTagKey::Composer if self.composer.is_none() => {
                        self.composer = Some(tag_str);
                    }
                    StandardTagKey::Lyrics if self.lyrics.is_none() => {
                        self.lyrics = Some(tag_str);
                    }
                    StandardTagKey::TrackNumber if self.track_number.is_none() => {
                        let (trk, disc) = parse_track_and_disc_number(&tag_str);
                        if let Some(num) = trk {
                            self.track_number = Some(num);
                        }
                        if self.disc_number.is_none() {
                            if let Some(d) = disc {
                                self.disc_number = Some(d);
                            }
                        }
                    }
                    StandardTagKey::DiscNumber if self.disc_number.is_none() => {
                        if let Some(num) = parse_disc_number(&tag_str) {
                            self.disc_number = Some(num);
                        }
                    }
                    StandardTagKey::Date | StandardTagKey::ReleaseDate
                        if self.release_year.is_none() =>
                    {
                        if let Some(yr) = parse_year(&tag_str) {
                            self.release_year = Some(yr);
                        }
                    }
                    StandardTagKey::IdentIsrc if self.isrc.is_none() => {
                        if let Some(clean) = normalize_isrc(&tag_str) {
                            self.isrc = Some(clean);
                        }
                    }
                    StandardTagKey::IdentBarcode
                    | StandardTagKey::IdentUpc
                    | StandardTagKey::IdentEanUpn
                        if self.upc.is_none() =>
                    {
                        self.upc = normalize_upc(&tag_str);
                    }
                    StandardTagKey::MusicBrainzReleaseGroupId if self.mb_rg_id.is_none() => {
                        self.mb_rg_id = Some(tag_str);
                    }
                    StandardTagKey::Label if !had_record_label_before => {
                        let prio = if matches!(norm_key.as_str(), "LABEL" | "RECORDLABEL" | "TPUB")
                        {
                            RECORD_LABEL_PRIO_LABEL
                        } else if norm_key == "PUBLISHER" || key_upper == "©PUB" {
                            RECORD_LABEL_PRIO_PUBLISHER
                        } else {
                            RECORD_LABEL_PRIO_FALLBACK
                        };
                        self.set_record_label(tag_str, prio);
                    }
                    StandardTagKey::ReplayGainTrackGain if self.rg_track_db.is_none() => {
                        self.rg_track_db = parse_replay_gain_db_value(&tag.value);
                    }
                    StandardTagKey::ReplayGainAlbumGain if self.rg_album_db.is_none() => {
                        self.rg_album_db = parse_replay_gain_db_value(&tag.value);
                    }
                    StandardTagKey::ReplayGainTrackPeak if self.rg_track_peak.is_none() => {
                        self.rg_track_peak = parse_replay_gain_peak_value(&tag.value);
                    }
                    StandardTagKey::ReplayGainAlbumPeak if self.rg_album_peak.is_none() => {
                        self.rg_album_peak = parse_replay_gain_peak_value(&tag.value);
                    }
                    _ => {}
                }
            } else {
                match norm_key.as_str() {
                    "TITLE" if self.title.is_none() => self.title = Some(tag_str),
                    "ARTIST" => {
                        if !had_artists_before {
                            append_split_artists(&mut self.artists, &tag_str);
                        }
                        if !had_artist_before
                            && !rev_artist_values
                                .iter()
                                .any(|e| e.eq_ignore_ascii_case(&tag_str))
                        {
                            rev_artist_values.push(tag_str);
                        }
                    }
                    "ALBUM" if self.album.is_none() => self.album = Some(tag_str),
                    "ALBUMARTIST" | "ALBUMARTISTS" => {
                        let prio = if key_upper == "ALBUMARTIST" {
                            ALBUM_ARTIST_PRIO_EXACT
                        } else {
                            ALBUM_ARTIST_PRIO_ALIAS
                        };
                        self.set_album_artist(tag_str, prio);
                    }
                    "BAND" | "ENSEMBLE" => {
                        self.set_album_artist(tag_str, ALBUM_ARTIST_PRIO_BAND);
                    }
                    "TRACKNUMBER" | "TRACK" if self.track_number.is_none() => {
                        let (trk, disc) = parse_track_and_disc_number(&tag_str);
                        if let Some(num) = trk {
                            self.track_number = Some(num);
                        }
                        if self.disc_number.is_none() {
                            if let Some(d) = disc {
                                self.disc_number = Some(d);
                            }
                        }
                    }
                    "DISCNUMBER" | "DISC" if self.disc_number.is_none() => {
                        self.disc_number = parse_disc_number(&tag_str);
                    }
                    "DATE" | "YEAR" if self.release_year.is_none() => {
                        self.release_year = parse_year(&tag_str);
                    }
                    "ISRC" if self.isrc.is_none() => {
                        self.isrc = normalize_isrc(&tag_str);
                    }
                    "REPLAYGAINTRACKGAIN" if self.rg_track_db.is_none() => {
                        self.rg_track_db = parse_replay_gain_db_value(&tag.value);
                    }
                    "REPLAYGAINALBUMGAIN" if self.rg_album_db.is_none() => {
                        self.rg_album_db = parse_replay_gain_db_value(&tag.value);
                    }
                    "REPLAYGAINTRACKPEAK" if self.rg_track_peak.is_none() => {
                        self.rg_track_peak = parse_replay_gain_peak_value(&tag.value);
                    }
                    "REPLAYGAINALBUMPEAK" if self.rg_album_peak.is_none() => {
                        self.rg_album_peak = parse_replay_gain_peak_value(&tag.value);
                    }
                    "UPC" | "BARCODE" | "EAN" if self.upc.is_none() => {
                        self.upc = normalize_upc(&tag_str);
                    }
                    "MUSICBRAINZRELEASEGROUPID" if self.mb_rg_id.is_none() => {
                        self.mb_rg_id = Some(tag_str);
                    }
                    "EDITION" | "VERSION" | "RELEASETYPE" if self.edition.is_none() => {
                        self.edition = Some(tag_str);
                    }
                    "LABEL" | "RECORDLABEL" | "TPUB" if !had_record_label_before => {
                        self.set_record_label(tag_str, RECORD_LABEL_PRIO_LABEL);
                    }
                    "PUBLISHER" if !had_record_label_before => {
                        self.set_record_label(tag_str, RECORD_LABEL_PRIO_PUBLISHER);
                    }
                    "ORGANIZATION" if !had_record_label_before => {
                        self.set_record_label(tag_str, RECORD_LABEL_PRIO_FALLBACK);
                    }
                    "COMPILATION" if self.compilation.is_none() => {
                        self.compilation = parse_bool_flag(&tag_str);
                    }
                    "GENRE" if self.genre.is_none() => self.genre = Some(tag_str),
                    "COMPOSER" if self.composer.is_none() => self.composer = Some(tag_str),
                    "LYRICS" | "UNSYNCEDLYRICS" | "SYNCEDLYRICS" if self.lyrics.is_none() => {
                        self.lyrics = Some(tag_str);
                    }
                    _ => {}
                }
            }
        }

        if !had_artist_before && !rev_artist_values.is_empty() {
            self.artist = Some(rev_artist_values.join("; "));
        }
    }
}

fn parse_replay_gain_db_value(value: &Value) -> Option<f64> {
    match value {
        Value::Float(f) => f.is_finite().then_some(*f),
        Value::SignedInt(i) => Some(*i as f64),
        Value::UnsignedInt(u) => Some(*u as f64),
        Value::String(s) => parse_replay_gain_db_str(s),
        _ => None,
    }
}

fn parse_replay_gain_peak_value(value: &Value) -> Option<f64> {
    match value {
        Value::Float(f) => (f.is_finite() && *f >= 0.0).then_some(*f),
        Value::String(s) => parse_replay_gain_peak_str(s),
        _ => None,
    }
}
