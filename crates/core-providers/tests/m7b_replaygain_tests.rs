use std::fs::{self, File};
use std::io::Write;

use core_db::{LibraryRepository, open_test_database};
use core_types::ProviderKind;
use tempfile::tempdir;

use core_providers::{
    AlbumMapper, LibrarySyncService, LocalProvider, MetadataExtractor, MusicProvider,
};

fn approx_eq(a: Option<f64>, b: f64) {
    let val = a.unwrap_or_else(|| panic!("Expected Some({b}), got None"));
    assert!((val - b).abs() < 0.005, "Expected {b} +- 0.005, got {val}");
}

fn crc8(data: &[u8]) -> u8 {
    let mut crc = 0u8;
    for &b in data {
        crc ^= b;
        for _ in 0..8 {
            if (crc & 0x80) != 0 {
                crc = (crc << 1) ^ 0x07;
            } else {
                crc <<= 1;
            }
        }
    }
    crc
}

fn encode_syncsafe(val: u32) -> [u8; 4] {
    [
        ((val >> 21) & 0x7F) as u8,
        ((val >> 14) & 0x7F) as u8,
        ((val >> 7) & 0x7F) as u8,
        (val & 0x7F) as u8,
    ]
}

fn build_synthetic_flac_with_vorbis_comments(comments: &[&str]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(b"fLaC");

    // STREAMINFO block (type 0, NOT last -> 0x00, len 34)
    out.extend_from_slice(&[0x00, 0x00, 0x00, 0x22]);
    let mut si = [0u8; 34];
    si[0..2].copy_from_slice(&4096u16.to_be_bytes());
    si[2..4].copy_from_slice(&4096u16.to_be_bytes());
    let packed: u64 = (44100u64 << 44) | (1u64 << 41) | (15u64 << 36) | 44100u64;
    si[10..18].copy_from_slice(&packed.to_be_bytes());
    out.extend_from_slice(&si);

    // VORBIS_COMMENT block (last = 0x80 | 4 = 0x84)
    let mut vc = Vec::new();
    let vendor = b"LuminaTest";
    vc.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
    vc.extend_from_slice(vendor);
    vc.extend_from_slice(&(comments.len() as u32).to_le_bytes());
    for c in comments {
        let cb = c.as_bytes();
        vc.extend_from_slice(&(cb.len() as u32).to_le_bytes());
        vc.extend_from_slice(cb);
    }

    let vc_len = vc.len() as u32;
    out.push(0x84);
    out.push(((vc_len >> 16) & 0xFF) as u8);
    out.push(((vc_len >> 8) & 0xFF) as u8);
    out.push((vc_len & 0xFF) as u8);
    out.extend_from_slice(&vc);

    // Minimal valid FLAC frame header + CRC-8
    let hdr = [0xFFu8, 0xF8, 0xC9, 0x18, 0x00];
    out.extend_from_slice(&hdr);
    out.push(crc8(&hdr));
    out.extend_from_slice(&[0u8; 8]);
    out
}

fn id3v24_frame(id: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let mut f = Vec::new();
    f.extend_from_slice(id);
    f.extend_from_slice(&encode_syncsafe(payload.len() as u32));
    f.extend_from_slice(&[0x00, 0x00]);
    f.extend_from_slice(payload);
    f
}

fn build_id3v24_tag(frames: Vec<Vec<u8>>) -> Vec<u8> {
    let body: Vec<u8> = frames.into_iter().flatten().collect();
    let mut tag = Vec::new();
    tag.extend_from_slice(b"ID3\x04\x00\x00");
    tag.extend_from_slice(&encode_syncsafe(body.len() as u32));
    tag.extend_from_slice(&body);
    tag
}

fn build_txxx_payload(desc: &str, val: &str) -> Vec<u8> {
    let mut p = vec![0x03]; // UTF-8
    p.extend_from_slice(desc.as_bytes());
    p.push(0x00);
    p.extend_from_slice(val.as_bytes());
    p
}

fn build_rva2_payload(ident: &str, gain_db: f64, peak_16bit: u16) -> Vec<u8> {
    let mut p = Vec::new();
    p.extend_from_slice(ident.as_bytes());
    p.push(0x00);
    p.push(0x01); // Master volume
    let adj = (gain_db * 512.0).round() as i16;
    p.extend_from_slice(&adj.to_be_bytes());
    p.push(16u8); // 16-bit peak
    p.extend_from_slice(&peak_16bit.to_be_bytes());
    p
}

fn build_mp3_with_id3(tag: Vec<u8>) -> Vec<u8> {
    let mut out = tag;
    // Silent MPEG-1 Layer III 128kbps 44.1kHz stereo frame (417 bytes)
    out.extend_from_slice(&[0xFF, 0xFB, 0x90, 0x00]);
    out.extend_from_slice(&vec![0u8; 413]);
    out
}

fn mp4_box(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let total_len = (8 + payload.len()) as u32;
    let mut out = Vec::with_capacity(total_len as usize);
    out.extend_from_slice(&total_len.to_be_bytes());
    out.extend_from_slice(kind);
    out.extend_from_slice(payload);
    out
}

fn mp4_freeform_atom(mean: &str, name: &str, data_type: u32, data_bytes: &[u8]) -> Vec<u8> {
    let mut mean_payload = vec![0u8; 4];
    mean_payload.extend_from_slice(mean.as_bytes());
    let mut name_payload = vec![0u8; 4];
    name_payload.extend_from_slice(name.as_bytes());
    let mut data_payload = Vec::new();
    data_payload.extend_from_slice(&data_type.to_be_bytes());
    data_payload.extend_from_slice(&[0u8; 4]);
    data_payload.extend_from_slice(data_bytes);

    let mut inner = Vec::new();
    inner.extend_from_slice(&mp4_box(b"mean", &mean_payload));
    inner.extend_from_slice(&mp4_box(b"name", &name_payload));
    inner.extend_from_slice(&mp4_box(b"data", &data_payload));
    mp4_box(b"----", &inner)
}

fn build_synthetic_m4a_with_replaygain() -> Vec<u8> {
    let ftyp = mp4_box(b"ftyp", b"M4A \x00\x00\x00\x00M4A mp42isom");

    let mut mvhd_payload = vec![0u8; 100];
    mvhd_payload[12..16].copy_from_slice(&44100u32.to_be_bytes());
    mvhd_payload[16..20].copy_from_slice(&44100u32.to_be_bytes());
    let mvhd = mp4_box(b"mvhd", &mvhd_payload);

    let mut tkhd_payload = vec![0u8; 84];
    tkhd_payload[12..16].copy_from_slice(&1u32.to_be_bytes());
    let tkhd = mp4_box(b"tkhd", &tkhd_payload);

    let mut mdhd_payload = vec![0u8; 24];
    mdhd_payload[12..16].copy_from_slice(&44100u32.to_be_bytes());
    mdhd_payload[16..20].copy_from_slice(&44100u32.to_be_bytes());
    let mdhd = mp4_box(b"mdhd", &mdhd_payload);

    let mut hdlr_soun = vec![0u8; 24];
    hdlr_soun[8..12].copy_from_slice(b"soun");
    let hdlr = mp4_box(b"hdlr", &hdlr_soun);

    // mp4a sample entry (28 bytes + esds)
    let mut mp4a_payload = vec![0u8; 28];
    mp4a_payload[16..18].copy_from_slice(&2u16.to_be_bytes()); // channels
    mp4a_payload[18..20].copy_from_slice(&16u16.to_be_bytes()); // sample size
    mp4a_payload[24..28].copy_from_slice(&(44100u32 << 16).to_be_bytes());
    let mp4a = mp4_box(b"mp4a", &mp4a_payload);

    let mut stsd_payload = vec![0u8; 8];
    stsd_payload[4..8].copy_from_slice(&1u32.to_be_bytes());
    stsd_payload.extend_from_slice(&mp4a);
    let stsd = mp4_box(b"stsd", &stsd_payload);
    let stts = mp4_box(b"stts", &[0u8; 8]);
    let stsc = mp4_box(b"stsc", &[0u8; 8]);
    let stsz = mp4_box(b"stsz", &[0u8; 12]);
    let stco = mp4_box(b"stco", &[0u8; 8]);

    let mut stbl_inner = Vec::new();
    stbl_inner.extend_from_slice(&stsd);
    stbl_inner.extend_from_slice(&stts);
    stbl_inner.extend_from_slice(&stsc);
    stbl_inner.extend_from_slice(&stsz);
    stbl_inner.extend_from_slice(&stco);
    let stbl = mp4_box(b"stbl", &stbl_inner);
    let minf = mp4_box(b"minf", &stbl);
    let mut mdia_inner = Vec::new();
    mdia_inner.extend_from_slice(&mdhd);
    mdia_inner.extend_from_slice(&hdlr);
    mdia_inner.extend_from_slice(&minf);
    let mdia = mp4_box(b"mdia", &mdia_inner);
    let mut trak_inner = Vec::new();
    trak_inner.extend_from_slice(&tkhd);
    trak_inner.extend_from_slice(&mdia);
    let trak = mp4_box(b"trak", &trak_inner);

    // udta -> meta -> hdlr + ilst
    let mut meta_hdlr_payload = vec![0u8; 24];
    meta_hdlr_payload[8..12].copy_from_slice(b"mdir");
    let meta_hdlr = mp4_box(b"hdlr", &meta_hdlr_payload);

    let mut ilst_inner = Vec::new();
    let mut nam_data = vec![0, 0, 0, 1, 0, 0, 0, 0];
    nam_data.extend_from_slice(b"MP4 Track");
    ilst_inner.extend_from_slice(&mp4_box(b"\xa9nam", &mp4_box(b"data", &nam_data)));
    let mut art_data = vec![0, 0, 0, 1, 0, 0, 0, 0];
    art_data.extend_from_slice(b"MP4 Artist");
    ilst_inner.extend_from_slice(&mp4_box(b"\xa9ART", &mp4_box(b"data", &art_data)));
    let mut alb_data = vec![0, 0, 0, 1, 0, 0, 0, 0];
    alb_data.extend_from_slice(b"MP4 Album");
    ilst_inner.extend_from_slice(&mp4_box(b"\xa9alb", &mp4_box(b"data", &alb_data)));

    ilst_inner.extend_from_slice(&mp4_freeform_atom(
        "com.apple.iTunes",
        "replaygain_track_gain",
        1,
        b"-7.10 dB",
    ));
    ilst_inner.extend_from_slice(&mp4_freeform_atom(
        "com.apple.iTunes",
        "REPLAYGAIN_ALBUM_GAIN",
        1,
        b"-6.25 dB",
    ));
    ilst_inner.extend_from_slice(&mp4_freeform_atom(
        "com.apple.iTunes",
        "REPLAYGAIN_TRACK_PEAK",
        23,
        &0.875f32.to_be_bytes(),
    ));
    ilst_inner.extend_from_slice(&mp4_freeform_atom(
        "com.apple.iTunes",
        "REPLAYGAIN_ALBUM_PEAK",
        1,
        b"0.930000",
    ));
    let ilst = mp4_box(b"ilst", &ilst_inner);

    let mut meta_inner = vec![0u8; 4]; // fullbox version+flags
    meta_inner.extend_from_slice(&meta_hdlr);
    meta_inner.extend_from_slice(&ilst);
    let meta = mp4_box(b"meta", &meta_inner);
    let udta = mp4_box(b"udta", &meta);

    let mut moov_inner = Vec::new();
    moov_inner.extend_from_slice(&mvhd);
    moov_inner.extend_from_slice(&trak);
    moov_inner.extend_from_slice(&udta);
    let moov = mp4_box(b"moov", &moov_inner);
    let mdat = mp4_box(b"mdat", &[]);

    let mut out = Vec::new();
    out.extend_from_slice(&ftyp);
    out.extend_from_slice(&moov);
    out.extend_from_slice(&mdat);
    out
}

fn build_synthetic_dsf_with_id3(tag: Vec<u8>) -> Vec<u8> {
    let data_len: u64 = 128;
    let metadata_offset: u64 = 28 + 52 + 12 + data_len;
    let file_size: u64 = metadata_offset + tag.len() as u64;

    let mut out = Vec::new();
    out.extend_from_slice(b"DSD ");
    out.extend_from_slice(&28u64.to_le_bytes());
    out.extend_from_slice(&file_size.to_le_bytes());
    out.extend_from_slice(&metadata_offset.to_le_bytes());

    // 'fmt ' chunk (52 bytes)
    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&52u64.to_le_bytes());
    out.extend_from_slice(&1u32.to_le_bytes()); // format version
    out.extend_from_slice(&0u32.to_le_bytes()); // format id
    out.extend_from_slice(&2u32.to_le_bytes()); // channel type
    out.extend_from_slice(&2u32.to_le_bytes()); // channels
    out.extend_from_slice(&2_822_400u32.to_le_bytes()); // sample rate
    out.extend_from_slice(&1u32.to_le_bytes()); // bps
    out.extend_from_slice(&2_822_400u64.to_le_bytes()); // sample count
    out.extend_from_slice(&4096u32.to_le_bytes()); // block size
    out.extend_from_slice(&0u32.to_le_bytes()); // reserved

    // 'data' chunk
    out.extend_from_slice(b"data");
    out.extend_from_slice(&(12 + data_len).to_le_bytes());
    out.extend_from_slice(&vec![0x69u8; data_len as usize]);

    out.extend_from_slice(&tag);
    out
}

#[tokio::test]
async fn test_replaygain_flac_vorbis_extraction_and_db_roundtrip() {
    let dir = tempdir().unwrap();
    let alb_dir = dir.path().join("Artist").join("FlacAlbum");
    fs::create_dir_all(&alb_dir).unwrap();

    let flac_bytes = build_synthetic_flac_with_vorbis_comments(&[
        "TITLE=Vorbis Song",
        "ARTIST=Vorbis Artist",
        "ALBUM=Vorbis Album",
        "REPLAYGAIN_TRACK_GAIN=-6.50 dB",
        "replaygain_album_gain=+1.2 dB",
        "ReplayGain_Track_Peak=0.950000",
        "REPLAYGAIN_ALBUM_PEAK=0.985",
        "UPC=012345678905",
        "MUSICBRAINZ_RELEASEGROUPID=11111111-2222-3333-4444-555555555555",
    ]);
    let flac_path = alb_dir.join("01 - Vorbis Song.flac");
    File::create(&flac_path)
        .unwrap()
        .write_all(&flac_bytes)
        .unwrap();

    // Direct extraction + extract_from_bytes
    let meta = MetadataExtractor::extract(&flac_path).unwrap();
    approx_eq(meta.replay_gain_track_db, -6.50);
    approx_eq(meta.replay_gain_album_db, 1.2);
    approx_eq(meta.replay_gain_track_peak, 0.95);
    approx_eq(meta.replay_gain_album_peak, 0.985);
    assert_eq!(meta.upc.as_deref(), Some("012345678905"));
    assert_eq!(
        meta.musicbrainz_release_group_id.as_deref(),
        Some("11111111-2222-3333-4444-555555555555")
    );

    let mem_meta =
        MetadataExtractor::extract_from_bytes(flac_bytes, "flac", Some(&flac_path)).unwrap();
    approx_eq(mem_meta.replay_gain_track_db, -6.50);

    // LocalProvider -> SyncResult -> LibrarySyncService -> core-db roundtrip
    let local = LocalProvider::from_root(dir.path());
    let sync = local.sync_library().await.unwrap();
    assert_eq!(sync.tracks.len(), 1);
    approx_eq(sync.tracks[0].replay_gain_track_db, -6.50);

    let pool = open_test_database().await.unwrap();
    LibrarySyncService::persist_sync_result(&pool, &sync)
        .await
        .unwrap();

    let fetched = LibraryRepository::find_track_source_by_id(&pool, &sync.tracks[0].id)
        .await
        .unwrap()
        .unwrap();
    approx_eq(fetched.replay_gain_track_db, -6.50);
    approx_eq(fetched.replay_gain_album_db, 1.2);
    approx_eq(fetched.replay_gain_track_peak, 0.95);
    approx_eq(fetched.replay_gain_album_peak, 0.985);

    // LocalProvider::resolve_stream preserves ReplayGain
    let resolved = local.resolve_stream(&fetched).await.unwrap();
    approx_eq(resolved.replay_gain_track_db, -6.50);
    approx_eq(resolved.replay_gain_album_peak, 0.985);
}

#[test]
fn test_replaygain_mp3_txxx_precedence_and_rva2_fallback() {
    let dir = tempdir().unwrap();

    // 1. MP3 with both lowercase TXXX and RVA2 (TXXX must win for track gain, RVA2 fills album)
    let mut tit2 = vec![0x03];
    tit2.extend_from_slice(b"MP3 Track");
    let mut tpe1 = vec![0x03];
    tpe1.extend_from_slice(b"MP3 Artist");
    let mut talb = vec![0x03];
    talb.extend_from_slice(b"MP3 Album");

    let tag_both = build_id3v24_tag(vec![
        id3v24_frame(b"TIT2", &tit2),
        id3v24_frame(b"TPE1", &tpe1),
        id3v24_frame(b"TALB", &talb),
        id3v24_frame(
            b"TXXX",
            &build_txxx_payload("replaygain_track_gain", "-4.25 dB"),
        ),
        id3v24_frame(
            b"TXXX",
            &build_txxx_payload("replaygain_track_peak", "0.910"),
        ),
        id3v24_frame(b"RVA2", &build_rva2_payload("track", -9.0, 29491)),
        id3v24_frame(b"RVA2", &build_rva2_payload("album", -3.0, 16384)),
    ]);
    let mp3_both_path = dir.path().join("01 - Both.mp3");
    File::create(&mp3_both_path)
        .unwrap()
        .write_all(&build_mp3_with_id3(tag_both))
        .unwrap();

    let meta_both = MetadataExtractor::extract(&mp3_both_path).unwrap();
    approx_eq(meta_both.replay_gain_track_db, -4.25); // TXXX won over RVA2 (-9.0)
    approx_eq(meta_both.replay_gain_track_peak, 0.910);
    approx_eq(meta_both.replay_gain_album_db, -3.0); // RVA2 filled album
    approx_eq(meta_both.replay_gain_album_peak, 0.5); // 16384 / 32768

    // 2. MP3 with RVA2 only
    let tag_rva2_only = build_id3v24_tag(vec![
        id3v24_frame(b"TIT2", &tit2),
        id3v24_frame(b"RVA2", &build_rva2_payload("track", -5.5, 32768)),
        id3v24_frame(b"RVA2", &build_rva2_payload("album", -2.25, 24576)),
    ]);
    let mp3_rva2_path = dir.path().join("02 - Rva2Only.mp3");
    File::create(&mp3_rva2_path)
        .unwrap()
        .write_all(&build_mp3_with_id3(tag_rva2_only))
        .unwrap();

    let meta_rva2 = MetadataExtractor::extract(&mp3_rva2_path).unwrap();
    approx_eq(meta_rva2.replay_gain_track_db, -5.5);
    approx_eq(meta_rva2.replay_gain_track_peak, 1.0);
    approx_eq(meta_rva2.replay_gain_album_db, -2.25);
    approx_eq(meta_rva2.replay_gain_album_peak, 0.75);
}

#[test]
fn test_replaygain_m4a_itunes_freeform_and_dsf_id3v2() {
    let dir = tempdir().unwrap();

    // 1. M4A with ----:com.apple.iTunes:* (UTF-8 & Float32)
    let m4a_bytes = build_synthetic_m4a_with_replaygain();
    let m4a_path = dir.path().join("01 - MP4 Track.m4a");
    File::create(&m4a_path)
        .unwrap()
        .write_all(&m4a_bytes)
        .unwrap();

    let m4a_meta = MetadataExtractor::extract(&m4a_path).unwrap();
    assert_eq!(m4a_meta.title, "MP4 Track");
    approx_eq(m4a_meta.replay_gain_track_db, -7.10);
    approx_eq(m4a_meta.replay_gain_album_db, -6.25);
    approx_eq(m4a_meta.replay_gain_track_peak, 0.875);
    approx_eq(m4a_meta.replay_gain_album_peak, 0.93);

    // 2. DSF with trailing ID3v2.4 TXXX + RVA2
    let mut tit2 = vec![0x03];
    tit2.extend_from_slice(b"DSD Nocturne");
    let mut tpe1 = vec![0x03];
    tpe1.extend_from_slice(b"DSD Pianist");
    let mut talb = vec![0x03];
    talb.extend_from_slice(b"DSD Sessions");

    let dsf_tag = build_id3v24_tag(vec![
        id3v24_frame(b"TIT2", &tit2),
        id3v24_frame(b"TPE1", &tpe1),
        id3v24_frame(b"TALB", &talb),
        id3v24_frame(
            b"TXXX",
            &build_txxx_payload("REPLAYGAIN_TRACK_GAIN", "-3.75 dB"),
        ),
        id3v24_frame(b"RVA2", &build_rva2_payload("album", -4.0, 32768)),
    ]);
    let dsf_bytes = build_synthetic_dsf_with_id3(dsf_tag);
    let dsf_path = dir.path().join("01 - DSD Nocturne.dsf");
    File::create(&dsf_path)
        .unwrap()
        .write_all(&dsf_bytes)
        .unwrap();

    let dsf_meta = MetadataExtractor::extract(&dsf_path).unwrap();
    assert_eq!(dsf_meta.title, "DSD Nocturne");
    approx_eq(dsf_meta.replay_gain_track_db, -3.75);
    approx_eq(dsf_meta.replay_gain_album_db, -4.0);
    approx_eq(dsf_meta.replay_gain_album_peak, 1.0);

    // AlbumMapper propagation
    let (_albums, tracks) =
        AlbumMapper::map_scanned_items(vec![(m4a_path, m4a_meta)], ProviderKind::Local).unwrap();
    assert_eq!(tracks.len(), 1);
    approx_eq(tracks[0].replay_gain_track_db, -7.10);
    approx_eq(tracks[0].replay_gain_track_peak, 0.875);
}

#[test]
fn test_replaygain_non_ascii_utf8_trailing_chars_never_panic() {
    use core_providers::local::dsd_meta::parse_replay_gain_db_str;

    assert_eq!(parse_replay_gain_db_str("-6.5 分"), None);
    assert_eq!(parse_replay_gain_db_str("-6.5 ｄＢ"), None);
    assert_eq!(parse_replay_gain_db_str("0.0 ㏈"), None);
    assert_eq!(parse_replay_gain_db_str("あ"), None);
    assert_eq!(parse_replay_gain_db_str("-6.50 dB"), Some(-6.50));
    assert_eq!(parse_replay_gain_db_str("-6,50 DB"), Some(-6.50));

    // Also verify end-to-end FLAC Vorbis extraction with multi-byte UTF-8 noise does not panic
    let flac_bytes = build_synthetic_flac_with_vorbis_comments(&[
        "TITLE=UTF8 Safe",
        "ARTIST=UTF8 Artist",
        "ALBUM=UTF8 Album",
        "REPLAYGAIN_TRACK_GAIN=-6.5 分",
        "REPLAYGAIN_ALBUM_GAIN=-3.2 ｄＢ",
    ]);
    let meta = MetadataExtractor::extract_from_bytes(flac_bytes, "flac", None).unwrap();
    assert_eq!(meta.replay_gain_track_db, None);
    assert_eq!(meta.replay_gain_album_db, None);
}
