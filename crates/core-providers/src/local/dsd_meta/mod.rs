mod dsdiff;
mod dsf;
mod id3v2;
mod id3v2_extra;
mod id3v2_frames;
mod id3v2_text;

use core_types::{AudioFormat, ExtractedPicture};

use super::encoding::DetectedEncoding;

pub use dsdiff::{
    parse_dff, parse_dff_reader, parse_dff_reader_ext, parse_dff_reader_with_options,
    parse_dff_with_extract_options, parse_dff_with_raw,
};
pub use dsf::{
    parse_dsf, parse_dsf_reader, parse_dsf_reader_ext, parse_dsf_reader_with_options,
    parse_dsf_with_extract_options, parse_dsf_with_raw,
};
pub use id3v2::{
    decode_syncsafe, parse_id3v2_body, parse_id3v2_body_ext, parse_id3v2_body_with_options,
    parse_id3v2_from_reader, parse_id3v2_from_reader_ext, parse_id3v2_from_reader_with_options,
    parse_id3v2_from_slice, parse_id3v2_from_slice_ext, parse_id3v2_from_slice_with_options,
};
pub use id3v2_extra::{
    parse_id3v2_footer_from_reader, parse_id3v2_footer_from_reader_ext,
    parse_id3v2_footer_from_slice, parse_id3v2_footer_from_slice_ext,
};
pub use id3v2_text::{
    parse_disc_number, parse_disc_u32, parse_replay_gain_db_str, parse_replay_gain_peak_str,
    parse_slash_number, parse_track_and_disc_number, parse_track_and_disc_u32, parse_year,
};

#[derive(Debug, Clone)]
pub struct RawId3Frame {
    pub frame_id: String,
    pub raw_frame_id: String,
    pub declared_encoding: Option<u8>,
    pub raw_bytes: Vec<u8>,
    pub decoded_value: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct DsdTags {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub artists: Vec<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_number: Option<u16>,
    pub disc_number: Option<u16>,
    pub release_year: Option<i32>,
    pub isrc: Option<String>,
    pub upc: Option<String>,
    pub musicbrainz_release_group_id: Option<String>,
    pub edition_label: Option<String>,
    pub record_label: Option<String>,
    pub compilation: Option<bool>,
    pub replay_gain_track_db: Option<f64>,
    pub replay_gain_album_db: Option<f64>,
    pub replay_gain_track_peak: Option<f64>,
    pub replay_gain_album_peak: Option<f64>,
    pub genre: Option<String>,
    pub composer: Option<String>,
    pub lyrics: Option<String>,
    pub pictures: Vec<ExtractedPicture>,
    pub detected_encoding: DetectedEncoding,
    pub raw_id3_frames: Vec<RawId3Frame>,
    pub raw_diin_fields: Vec<(String, Vec<u8>, String)>,
}

#[derive(Debug, Clone)]
pub struct DsdMetadata {
    pub format: AudioFormat,
    pub duration_ms: u64,
    pub tags: DsdTags,
}

#[derive(Debug, Clone, Default)]
pub struct Id3v2ParsedTags {
    pub version_major: u8,
    pub detected_encoding: DetectedEncoding,
    pub raw_frames: Vec<RawId3Frame>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub artists: Vec<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_number: Option<u16>,
    pub disc_number: Option<u16>,
    pub release_year: Option<i32>,
    pub isrc: Option<String>,
    pub upc: Option<String>,
    pub musicbrainz_release_group_id: Option<String>,
    pub edition_label: Option<String>,
    pub record_label: Option<String>,
    pub compilation: Option<bool>,
    pub txxx_rg_track_db: Option<f64>,
    pub txxx_rg_album_db: Option<f64>,
    pub txxx_rg_track_peak: Option<f64>,
    pub txxx_rg_album_peak: Option<f64>,
    pub rva2_rg_track_db: Option<f64>,
    pub rva2_rg_album_db: Option<f64>,
    pub rva2_rg_track_peak: Option<f64>,
    pub rva2_rg_album_peak: Option<f64>,
    pub genre: Option<String>,
    pub composer: Option<String>,
    pub lyrics: Option<String>,
    pub pictures: Vec<ExtractedPicture>,
}

impl Id3v2ParsedTags {
    pub fn effective_rg_track_db(&self) -> Option<f64> {
        self.txxx_rg_track_db.or(self.rva2_rg_track_db)
    }

    pub fn effective_rg_album_db(&self) -> Option<f64> {
        self.txxx_rg_album_db.or(self.rva2_rg_album_db)
    }

    pub fn effective_rg_track_peak(&self) -> Option<f64> {
        self.txxx_rg_track_peak.or(self.rva2_rg_track_peak)
    }

    pub fn effective_rg_album_peak(&self) -> Option<f64> {
        self.txxx_rg_album_peak.or(self.rva2_rg_album_peak)
    }
}
