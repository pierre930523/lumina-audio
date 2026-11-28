mod accumulator;
mod aiff;
mod extract;
mod flac;
mod helpers;
mod id3v1;
mod mp4;
mod ogg;
mod preparse;
#[cfg(test)]
mod record_label_tests;
mod symphonia_tags;
#[cfg(test)]
mod tests;
mod vorbis_comments;

use core_types::AudioFormat;

use super::ape_meta::ApeParsedTags;
use super::dsd_meta::Id3v2ParsedTags;
use super::encoding::DetectedEncoding;

pub use extract::{MetadataExtractor, parse_audio_metadata};
pub use helpers::{
    derive_album_and_artist_from_dir, derive_title_and_track_from_filename, detect_garbled_tags,
    extract_disc_number_from_dir_name, is_generic_directory_name, split_artists,
};

pub(crate) use aiff::scan_aiff_from_reader;
pub(crate) use helpers::normalize_custom_tag_key;
pub(crate) use id3v1::parse_id3v1_from_reader;
pub(crate) use mp4::scan_mp4_ilst_from_reader;
pub(crate) use preparse::scan_id3v2_from_reader;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExtractOptions {
    pub include_pictures: bool,
}

impl Default for ExtractOptions {
    fn default() -> Self {
        Self {
            include_pictures: true,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ExtractedMetadata {
    pub title: String,
    pub artist: String,
    pub artists: Vec<String>,
    pub album: String,
    pub album_artist: Option<String>,
    pub track_number: u16,
    pub disc_number: u16,
    pub release_year: Option<i32>,
    pub isrc: Option<String>,
    pub duration_ms: u64,
    pub format: AudioFormat,
    pub cover_url: Option<String>,
    pub replay_gain_track_db: Option<f64>,
    pub replay_gain_album_db: Option<f64>,
    pub replay_gain_track_peak: Option<f64>,
    pub replay_gain_album_peak: Option<f64>,
    pub upc: Option<String>,
    pub musicbrainz_release_group_id: Option<String>,
    pub edition_label: Option<String>,
    pub record_label: Option<String>,
    pub compilation: Option<bool>,
    pub genre: Option<String>,
    pub composer: Option<String>,
    pub embedded_lyrics: Option<String>,
    pub pictures: Vec<core_types::ExtractedPicture>,
}

impl Default for ExtractedMetadata {
    fn default() -> Self {
        Self {
            title: String::new(),
            artist: String::new(),
            artists: Vec::new(),
            album: String::new(),
            album_artist: None,
            track_number: 1,
            disc_number: 1,
            release_year: None,
            isrc: None,
            duration_ms: 1000,
            format: AudioFormat::cd_quality(),
            cover_url: None,
            replay_gain_track_db: None,
            replay_gain_album_db: None,
            replay_gain_track_peak: None,
            replay_gain_album_peak: None,
            upc: None,
            musicbrainz_release_group_id: None,
            edition_label: None,
            record_label: None,
            compilation: None,
            genre: None,
            composer: None,
            embedded_lyrics: None,
            pictures: Vec::new(),
        }
    }
}

impl ExtractedMetadata {
    /// Resolves the authoritative album artist following the unified fallback chain:
    /// `ALBUMARTIST / ALBUM ARTIST / TXXX:ALBUMARTIST / TPE2 / aART > Compilation("Various Artists") > primary ARTIST`.
    pub fn resolved_album_artist(&self) -> &str {
        if let Some(ref aa) = self.album_artist {
            let t = aa.trim();
            if !t.is_empty() {
                return t;
            }
        }
        if self.compilation == Some(true) {
            return "Various Artists";
        }
        if let Some(primary) = self
            .artists
            .first()
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
        {
            return primary;
        }
        let art = self.artist.trim();
        if art.is_empty() {
            "Unknown Artist"
        } else {
            art
        }
    }

    pub fn track_number_opt(&self) -> Option<u32> {
        (self.track_number > 0).then_some(u32::from(self.track_number))
    }

    pub fn disc_number_opt(&self) -> Option<u32> {
        (self.disc_number > 0).then_some(u32::from(self.disc_number))
    }
}

#[derive(Debug, Clone, Default)]
pub(crate) struct Id3v1ParsedTags {
    pub detected_encoding: DetectedEncoding,
    pub raw_fields: Vec<(String, Vec<u8>, String)>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub release_year: Option<i32>,
    pub track_number: Option<u16>,
    pub genre: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct Mp4IlstParsedTags {
    pub detected_encoding: DetectedEncoding,
    pub raw_atoms: Vec<(String, Vec<u8>, String)>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub artists: Vec<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_number: Option<u16>,
    pub disc_number: Option<u16>,
    pub release_year: Option<i32>,
    pub genre: Option<String>,
    pub composer: Option<String>,
    pub record_label: Option<String>,
    pub compilation: Option<bool>,
    pub lyrics: Option<String>,
    pub pictures: Vec<core_types::ExtractedPicture>,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct AiffParsedTags {
    pub id3: Option<Id3v2ParsedTags>,
    pub form_title: Option<String>,
    pub form_artist: Option<String>,
    pub form_encoding: DetectedEncoding,
    pub raw_form_fields: Vec<(String, Vec<u8>, String)>,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct FlacRawMetadata {
    pub vorbis_encoding: DetectedEncoding,
    pub raw_vorbis_comments: Vec<(String, Vec<u8>, String)>,
    pub prepended_id3: Option<Id3v2ParsedTags>,
    pub ape_tags: Option<ApeParsedTags>,
}
