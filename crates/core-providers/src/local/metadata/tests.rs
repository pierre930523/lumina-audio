use std::fs::File;
use std::io::Write;

use core_types::AudioCodec;
use tempfile::tempdir;

use super::{ExtractOptions, MetadataExtractor, is_generic_directory_name, parse_audio_metadata};
use crate::local::dsd_meta::{parse_disc_u32, parse_track_and_disc_u32, parse_year};
use crate::local::ignore::should_ignore_name;

fn encode_syncsafe(n: u32) -> [u8; 4] {
    [
        ((n >> 21) & 0x7F) as u8,
        ((n >> 14) & 0x7F) as u8,
        ((n >> 7) & 0x7F) as u8,
        (n & 0x7F) as u8,
    ]
}

pub(super) fn id3v23_frame(id: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(10 + payload.len());
    out.extend_from_slice(id);
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(&[0, 0]);
    out.extend_from_slice(payload);
    out
}

pub(super) fn id3_utf8(s: &str) -> Vec<u8> {
    let mut v = vec![3u8];
    v.extend_from_slice(s.as_bytes());
    v
}

pub(super) fn id3_txxx(desc: &str, val: &str) -> Vec<u8> {
    let mut v = vec![3u8];
    v.extend_from_slice(desc.as_bytes());
    v.push(0);
    v.extend_from_slice(val.as_bytes());
    v
}

pub(super) fn build_id3v23(frames: Vec<Vec<u8>>) -> Vec<u8> {
    let body: Vec<u8> = frames.into_iter().flatten().collect();
    let mut out = Vec::with_capacity(10 + body.len());
    out.extend_from_slice(b"ID3");
    out.push(3);
    out.push(0);
    out.push(0);
    out.extend_from_slice(&encode_syncsafe(body.len() as u32));
    out.extend_from_slice(&body);
    out
}

pub(super) fn build_flac(prepended_id3: Option<&[u8]>, comments: &[(&str, &[u8])]) -> Vec<u8> {
    let mut out = Vec::new();
    if let Some(id3) = prepended_id3 {
        out.extend_from_slice(id3);
    }
    out.extend_from_slice(b"fLaC");
    // STREAMINFO block (34 bytes)
    let mut si = [0u8; 34];
    si[0..2].copy_from_slice(&4096u16.to_be_bytes());
    si[2..4].copy_from_slice(&4096u16.to_be_bytes());
    let packed: u64 = (44100u64 << 44) | (1u64 << 41) | (15u64 << 36) | 44100u64;
    si[10..18].copy_from_slice(&packed.to_be_bytes());
    let is_last = if comments.is_empty() { 0x80u8 } else { 0x00u8 };
    out.push(is_last);
    out.extend_from_slice(&[0, 0, 34]);
    out.extend_from_slice(&si);

    if !comments.is_empty() {
        let mut vc = Vec::new();
        let vendor = b"LuminaTest";
        vc.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
        vc.extend_from_slice(vendor);
        vc.extend_from_slice(&(comments.len() as u32).to_le_bytes());
        for (k, v) in comments {
            let mut entry = Vec::new();
            entry.extend_from_slice(k.as_bytes());
            entry.push(b'=');
            entry.extend_from_slice(v);
            vc.extend_from_slice(&(entry.len() as u32).to_le_bytes());
            vc.extend_from_slice(&entry);
        }
        let vc_len = vc.len() as u32;
        out.push(0x84);
        out.push(((vc_len >> 16) & 0xFF) as u8);
        out.push(((vc_len >> 8) & 0xFF) as u8);
        out.push((vc_len & 0xFF) as u8);
        out.extend_from_slice(&vc);
    }
    out
}

fn ogg_page(serial: u32, seq: u32, granule: i64, header_type: u8, payload: &[u8]) -> Vec<u8> {
    let mut segs = Vec::new();
    let mut rem = payload.len();
    while rem >= 255 {
        segs.push(255u8);
        rem -= 255;
    }
    segs.push(rem as u8);

    let mut page = Vec::with_capacity(27 + segs.len() + payload.len());
    page.extend_from_slice(b"OggS");
    page.push(0); // version
    page.push(header_type);
    page.extend_from_slice(&granule.to_le_bytes());
    page.extend_from_slice(&serial.to_le_bytes());
    page.extend_from_slice(&seq.to_le_bytes());
    page.extend_from_slice(&0u32.to_le_bytes()); // CRC placeholder
    page.push(segs.len() as u8);
    page.extend_from_slice(&segs);
    page.extend_from_slice(payload);
    page
}

pub(super) fn build_opus_ogg(prepended_id3: Option<&[u8]>, comments: &[(&str, &str)]) -> Vec<u8> {
    let mut out = Vec::new();
    if let Some(id3) = prepended_id3 {
        out.extend_from_slice(id3);
    }
    let mut opus_head = Vec::new();
    opus_head.extend_from_slice(b"OpusHead");
    opus_head.push(1); // version
    opus_head.push(2); // channels
    opus_head.extend_from_slice(&312u16.to_le_bytes()); // pre-skip
    opus_head.extend_from_slice(&48000u32.to_le_bytes());
    opus_head.extend_from_slice(&0i16.to_le_bytes());
    opus_head.push(0);
    out.extend_from_slice(&ogg_page(42, 0, 0, 0x02, &opus_head));

    let mut tags = Vec::new();
    tags.extend_from_slice(b"OpusTags");
    let vendor = b"LuminaOpus";
    tags.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
    tags.extend_from_slice(vendor);
    tags.extend_from_slice(&(comments.len() as u32).to_le_bytes());
    for (k, v) in comments {
        let entry = format!("{k}={v}");
        tags.extend_from_slice(&(entry.len() as u32).to_le_bytes());
        tags.extend_from_slice(entry.as_bytes());
    }
    out.extend_from_slice(&ogg_page(42, 1, 0, 0x00, &tags));
    // Audio page with 48000 * 5 samples (5 seconds)
    out.extend_from_slice(&ogg_page(42, 2, 240_312, 0x04, &[0u8; 8]));
    out
}

#[test]
fn test_flac_strictly_ignores_residual_id3_when_vorbis_present() {
    let residual_id3 = build_id3v23(vec![
        id3v23_frame(b"TIT2", &id3_utf8("Residual ID3 Title")),
        id3v23_frame(b"TPE2", &id3_utf8("Stale ID3 AlbumArtist")),
        id3v23_frame(b"TCON", &id3_utf8("(17)")),
    ]);
    let flac = build_flac(
        Some(&residual_id3),
        &[
            ("TITLE", b"Clean Vorbis Title"),
            ("ARTIST", b"Artist A"),
            ("ARTIST", b"Artist B"),
            ("ALBUM", b"Clean Album"),
            ("TRACKNUMBER", b"01/12"),
            ("DISCNUMBER", b"1/2"),
        ],
    );

    let dir = tempdir().unwrap();
    let p = dir.path().join("clean.flac");
    File::create(&p).unwrap().write_all(&flac).unwrap();

    let meta = parse_audio_metadata(&p, ExtractOptions::default()).unwrap();
    assert_eq!(meta.title, "Clean Vorbis Title");
    assert_eq!(meta.artist, "Artist A; Artist B");
    assert_eq!(meta.artists, vec!["Artist A", "Artist B"]);
    assert_eq!(meta.album, "Clean Album");
    // Residual ID3 TPE2 & TCON MUST NOT leak when Vorbis Comments are present!
    assert_eq!(meta.album_artist, None);
    assert_eq!(meta.genre, None);
    assert_eq!(meta.track_number, 1);
    assert_eq!(meta.disc_number, 1);
    assert_eq!(meta.resolved_album_artist(), "Artist A");
}

#[test]
fn test_opus_ogg_native_parser_ignores_residual_id3_and_respects_albumartist_order() {
    let residual_id3 = build_id3v23(vec![
        id3v23_frame(b"TIT2", &id3_utf8("Wrong ID3")),
        id3v23_frame(b"TPE2", &id3_utf8("Wrong Residual AA")),
    ]);
    let opus = build_opus_ogg(
        Some(&residual_id3),
        &[
            ("TITLE", "  Cafe\u{0301} Opus  "),
            ("ARTIST", "Opus Performer"),
            ("ALBUM", "Opus Album"),
            ("ALBUM ARTIST", "Spaced Album Artist"),
            ("ALBUMARTIST", "Exact Album Artist"),
            ("TRACKNUMBER", "03/10"),
            ("DISCNUMBER", "2/2"),
            ("DATE", "05-12-2021"),
        ],
    );

    let dir = tempdir().unwrap();
    let p = dir.path().join("track.opus");
    File::create(&p).unwrap().write_all(&opus).unwrap();

    let meta = parse_audio_metadata(&p, ExtractOptions::default()).unwrap();
    assert_eq!(meta.format.codec, AudioCodec::Opus);
    assert_eq!(meta.format.sample_rate_hz, 48_000);
    assert_eq!(meta.duration_ms, 5_000);
    assert_eq!(meta.title, "Café Opus"); // NFC + trimmed
    assert_eq!(meta.album_artist.as_deref(), Some("Exact Album Artist"));
    assert_eq!(meta.track_number, 3);
    assert_eq!(meta.disc_number, 2);
    assert_eq!(meta.release_year, Some(2021));
}

#[test]
fn test_id3v2_albumartist_precedence_and_tcon_genre_decode() {
    // TXXX:ALBUMARTIST > TXXX:ALBUM ARTIST > TPE2
    let id3 = build_id3v23(vec![
        id3v23_frame(b"TIT2", &id3_utf8("Song")),
        id3v23_frame(b"TPE1", &id3_utf8("Soloist")),
        id3v23_frame(b"TPE2", &id3_utf8("Orchestra TPE2")),
        id3v23_frame(b"TXXX", &id3_txxx("ALBUM ARTIST", "Spaced AA")),
        id3v23_frame(b"TXXX", &id3_txxx("ALBUMARTIST", "Authoritative AA")),
        id3v23_frame(b"TCON", &id3_utf8("(17)")),
        id3v23_frame(b"TYER", &id3_utf8("12/05/1999")),
    ]);

    let parsed = crate::local::dsd_meta::parse_id3v2_from_slice(&id3).unwrap();
    assert_eq!(parsed.album_artist.as_deref(), Some("Authoritative AA"));
    assert_eq!(parsed.genre.as_deref(), Some("Rock"));
    assert_eq!(parsed.release_year, Some(1999));
}

#[test]
fn test_wav_does_not_promote_bext_and_skips_pictures_when_disabled() {
    let mut wav = Vec::new();
    wav.extend_from_slice(b"RIFF\x00\x00\x00\x00WAVE");
    wav.extend_from_slice(b"fmt \x10\x00\x00\x00");
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&44100u32.to_le_bytes());
    wav.extend_from_slice(&(44100u32 * 4).to_le_bytes());
    wav.extend_from_slice(&4u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&[0u8; 16]);
    // bext chunk with DAW junk that must NOT become title/artist
    let mut bext = vec![0u8; 346];
    bext[..17].copy_from_slice(b"Pro Tools Export!");
    bext[256..265].copy_from_slice(b"Pro Tools");
    wav.extend_from_slice(b"bext");
    wav.extend_from_slice(&(bext.len() as u32).to_le_bytes());
    wav.extend_from_slice(&bext);
    // ID3 chunk with APIC picture
    let mut apic = vec![0u8];
    apic.extend_from_slice(b"image/jpeg\0");
    apic.push(3); // FrontCover
    apic.push(0);
    apic.extend_from_slice(&[0xFF, 0xD8, 0xFF, 0xD9]);
    let id3 = build_id3v23(vec![id3v23_frame(b"APIC", &apic)]);
    wav.extend_from_slice(b"id3 ");
    wav.extend_from_slice(&(id3.len() as u32).to_le_bytes());
    wav.extend_from_slice(&id3);
    if id3.len() % 2 == 1 {
        wav.push(0);
    }

    let dir = tempdir().unwrap();
    let p = dir.path().join("02 - Real Track.wav");
    File::create(&p).unwrap().write_all(&wav).unwrap();

    let meta_no_pic = parse_audio_metadata(
        &p,
        ExtractOptions {
            include_pictures: false,
        },
    )
    .unwrap();
    assert_eq!(meta_no_pic.title, "Real Track"); // Filename fallback, NOT "Pro Tools Export!"
    assert_ne!(meta_no_pic.artist, "Pro Tools");
    assert!(meta_no_pic.pictures.is_empty());

    let meta_with_pic = MetadataExtractor::extract(&p).unwrap();
    assert_eq!(meta_with_pic.pictures.len(), 1);
}

#[test]
fn test_dsf_stale_header_file_size_still_reads_id3_metadata() {
    let id3 = build_id3v23(vec![
        id3v23_frame(b"TIT2", &id3_utf8("DSF Song")),
        id3v23_frame(b"TPE1", &id3_utf8("DSF Artist")),
    ]);
    let audio_payload = [0xAAu8; 32];
    let metadata_offset: u64 = 28 + 52 + 12 + audio_payload.len() as u64;
    // Deliberately write stale file_size == metadata_offset (tagger forgot to bump file_size)
    let mut dsf = Vec::new();
    dsf.extend_from_slice(b"DSD ");
    dsf.extend_from_slice(&28u64.to_le_bytes());
    dsf.extend_from_slice(&metadata_offset.to_le_bytes());
    dsf.extend_from_slice(&metadata_offset.to_le_bytes());
    // fmt chunk (52 bytes)
    let mut fmt = [0u8; 52];
    fmt[0..4].copy_from_slice(b"fmt ");
    fmt[4..12].copy_from_slice(&52u64.to_le_bytes());
    fmt[24..28].copy_from_slice(&2u32.to_le_bytes());
    fmt[28..32].copy_from_slice(&2_822_400u32.to_le_bytes());
    fmt[36..44].copy_from_slice(&2_822_400u64.to_le_bytes());
    dsf.extend_from_slice(&fmt);
    // data chunk
    dsf.extend_from_slice(b"data");
    dsf.extend_from_slice(&((12 + audio_payload.len()) as u64).to_le_bytes());
    dsf.extend_from_slice(&audio_payload);
    dsf.extend_from_slice(&id3);

    let meta = MetadataExtractor::extract_from_bytes(dsf, "dsf", None).unwrap();
    assert_eq!(meta.title, "DSF Song");
    assert_eq!(meta.artist, "DSF Artist");
}

#[test]
fn test_numeric_parsers_generic_dirs_and_ignore_rules() {
    assert_eq!(parse_track_and_disc_u32("01/12"), (Some(1), None));
    assert_eq!(parse_track_and_disc_u32("2-05/10"), (Some(5), Some(2)));
    assert_eq!(parse_disc_u32("1/2"), Some(1));
    assert_eq!(parse_year("05-12-2021"), Some(2021));
    assert_eq!(parse_year("2023-07-01"), Some(2023));

    assert!(is_generic_directory_name("2024"));
    assert!(is_generic_directory_name("lossless"));
    assert!(is_generic_directory_name("音乐"));
    assert!(is_generic_directory_name("無損"));
    assert!(!is_generic_directory_name("Kind of Blue"));

    for junk in [
        "._01.flac",
        ".DS_Store",
        "@eaDir",
        "@tmp",
        "@recycle",
        "#snapshot",
        "ehthumbs.db",
    ] {
        assert!(should_ignore_name(junk), "expected '{junk}' to be ignored");
    }
    assert!(!should_ignore_name("01 - Track.flac"));
}
