use std::io::Cursor;
use std::path::Path;

use core_types::AudioFormat;
use symphonia::core::meta::{MetadataBuilder, StandardTagKey, Tag, Value};

use super::accumulator::TagAccumulator;
use super::tests::{build_flac, build_id3v23, build_opus_ogg, id3_txxx, id3_utf8, id3v23_frame};
use super::{MetadataExtractor, scan_mp4_ilst_from_reader};

fn mp4_box(tag: &[u8; 4], body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + body.len());
    out.extend_from_slice(&((8 + body.len()) as u32).to_be_bytes());
    out.extend_from_slice(tag);
    out.extend_from_slice(body);
    out
}

fn mp4_data_utf8(s: &str) -> Vec<u8> {
    let mut body = vec![0, 0, 0, 1, 0, 0, 0, 0];
    body.extend_from_slice(s.as_bytes());
    mp4_box(b"data", &body)
}

fn mp4_freeform(mean: &str, name: &str, val: &str) -> Vec<u8> {
    let mut m = vec![0u8; 4];
    m.extend_from_slice(mean.as_bytes());
    let mut n = vec![0u8; 4];
    n.extend_from_slice(name.as_bytes());
    let mut body = mp4_box(b"mean", &m);
    body.extend_from_slice(&mp4_box(b"name", &n));
    body.extend_from_slice(&mp4_data_utf8(val));
    mp4_box(b"----", &body)
}

fn build_apev2(items: &[(&str, &str)]) -> Vec<u8> {
    let mut body = Vec::new();
    for (k, v) in items {
        body.extend_from_slice(&(v.len() as u32).to_le_bytes());
        body.extend_from_slice(&0u32.to_le_bytes());
        body.extend_from_slice(k.as_bytes());
        body.push(0);
        body.extend_from_slice(v.as_bytes());
    }
    let tag_size = (body.len() + 32) as u32;
    let mut out = body;
    out.extend_from_slice(b"APETAGEX");
    out.extend_from_slice(&2000u32.to_le_bytes());
    out.extend_from_slice(&tag_size.to_le_bytes());
    out.extend_from_slice(&(items.len() as u32).to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&[0u8; 8]);
    out
}

#[test]
fn test_record_label_vorbis_priority_and_isolation() {
    let residual_id3 = build_id3v23(vec![id3v23_frame(b"TPUB", &id3_utf8("Stale ID3 Label"))]);
    let flac_label = build_flac(
        Some(&residual_id3),
        &[
            ("TITLE", b"Blue Note Track"),
            ("ORGANIZATION", b"Org Fallback"),
            ("PUBLISHER", b"Publisher Co"),
            ("LABEL", b"Blue Note Records"),
        ],
    );
    let m1 = MetadataExtractor::extract_from_bytes(flac_label, "flac", None).unwrap();
    assert_eq!(m1.record_label.as_deref(), Some("Blue Note Records"));

    let flac_pub = build_flac(
        None,
        &[
            ("ORGANIZATION", b"Org Fallback"),
            ("PUBLISHER", b"ECM Records"),
        ],
    );
    let m2 = MetadataExtractor::extract_from_bytes(flac_pub, "flac", None).unwrap();
    assert_eq!(m2.record_label.as_deref(), Some("ECM Records"));

    let opus_org = build_opus_ogg(
        Some(&residual_id3),
        &[("TITLE", "Opus Org"), ("ORGANIZATION", "Warp Records")],
    );
    let m3 = MetadataExtractor::extract_from_bytes(opus_org, "opus", None).unwrap();
    assert_eq!(m3.record_label.as_deref(), Some("Warp Records"));
}

#[test]
fn test_record_label_id3v2_tpub_txxx_and_dsf() {
    let id3_tpub = build_id3v23(vec![
        id3v23_frame(b"TXXX", &id3_txxx("LABEL", "TXXX Label")),
        id3v23_frame(b"TXXX", &id3_txxx("PUBLISHER", "TXXX Pub")),
        id3v23_frame(b"TPUB", &id3_utf8("Deutsche Grammophon")),
    ]);
    let p1 = crate::local::dsd_meta::parse_id3v2_from_slice(&id3_tpub).unwrap();
    assert_eq!(p1.record_label.as_deref(), Some("Deutsche Grammophon"));

    let id3_txxx_both = build_id3v23(vec![
        id3v23_frame(b"TXXX", &id3_txxx("PUBLISHER", "Fallback Pub")),
        id3v23_frame(b"TXXX", &id3_txxx("LABEL", "4AD")),
    ]);
    let p2 = crate::local::dsd_meta::parse_id3v2_from_slice(&id3_txxx_both).unwrap();
    assert_eq!(p2.record_label.as_deref(), Some("4AD"));

    let id3_txxx_pub = build_id3v23(vec![id3v23_frame(
        b"TXXX",
        &id3_txxx("PUBLISHER", "Sub Pop"),
    )]);
    let p3 = crate::local::dsd_meta::parse_id3v2_from_slice(&id3_txxx_pub).unwrap();
    assert_eq!(p3.record_label.as_deref(), Some("Sub Pop"));

    let audio_payload = [0xAAu8; 32];
    let meta_off: u64 = 28 + 52 + 12 + audio_payload.len() as u64;
    let mut dsf = Vec::new();
    dsf.extend_from_slice(b"DSD ");
    dsf.extend_from_slice(&28u64.to_le_bytes());
    dsf.extend_from_slice(&(meta_off + id3_tpub.len() as u64).to_le_bytes());
    dsf.extend_from_slice(&meta_off.to_le_bytes());
    let mut fmt = [0u8; 52];
    fmt[0..4].copy_from_slice(b"fmt ");
    fmt[4..12].copy_from_slice(&52u64.to_le_bytes());
    fmt[24..28].copy_from_slice(&2u32.to_le_bytes());
    fmt[28..32].copy_from_slice(&2_822_400u32.to_le_bytes());
    fmt[36..44].copy_from_slice(&2_822_400u64.to_le_bytes());
    dsf.extend_from_slice(&fmt);
    dsf.extend_from_slice(b"data");
    dsf.extend_from_slice(&((12 + audio_payload.len()) as u64).to_le_bytes());
    dsf.extend_from_slice(&audio_payload);
    dsf.extend_from_slice(&id3_tpub);
    let dsf_meta = MetadataExtractor::extract_from_bytes(dsf, "dsf", None).unwrap();
    assert_eq!(
        dsf_meta.record_label.as_deref(),
        Some("Deutsche Grammophon")
    );
}

#[test]
fn test_record_label_mp4_ape_symphonia_and_accumulator_merge() {
    let mut ilst_body = mp4_box(b"\xa9pub", &mp4_data_utf8("Apple Pub"));
    ilst_body.extend_from_slice(&mp4_freeform("com.apple.iTunes", "LABEL", "Impulse!"));
    let mut meta_body = vec![0u8; 4];
    meta_body.extend_from_slice(&mp4_box(b"ilst", &ilst_body));
    let mp4_bytes = mp4_box(b"moov", &mp4_box(b"meta", &meta_body));
    let mut cur = Cursor::new(&mp4_bytes);
    let parsed_mp4 = scan_mp4_ilst_from_reader(&mut cur, false).unwrap();
    assert_eq!(parsed_mp4.record_label.as_deref(), Some("Impulse!"));

    let mut cpub_meta = vec![0u8; 4];
    cpub_meta.extend_from_slice(&mp4_box(
        b"ilst",
        &mp4_box(b"\xa9pub", &mp4_data_utf8("Capitol")),
    ));
    let cpub_bytes = mp4_box(b"moov", &mp4_box(b"meta", &cpub_meta));
    let mut cur2 = Cursor::new(&cpub_bytes);
    let parsed_cpub = scan_mp4_ilst_from_reader(&mut cur2, false).unwrap();
    assert_eq!(parsed_cpub.record_label.as_deref(), Some("Capitol"));

    let ape_bytes = build_apev2(&[("PUBLISHER", "Pub Fallback"), ("LABEL", "Ninja Tune")]);
    let parsed_ape = crate::local::ape_meta::parse_ape_from_slice(&ape_bytes).unwrap();
    assert_eq!(parsed_ape.record_label.as_deref(), Some("Ninja Tune"));

    // Accumulator merge: higher-priority ID3v2 label must not be overwritten by APE or Symphonia
    let id3_bytes = build_id3v23(vec![id3v23_frame(b"TPUB", &id3_utf8("Verve Records"))]);
    let parsed_id3 = crate::local::dsd_meta::parse_id3v2_from_slice(&id3_bytes).unwrap();
    let mut acc = TagAccumulator::default();
    acc.apply_id3v2(parsed_id3, false);
    acc.apply_ape(parsed_ape, false);
    let mut rev = MetadataBuilder::new();
    rev.add_tag(Tag::new(
        Some(StandardTagKey::Label),
        "LABEL",
        Value::String("Lower Symphonia Label".to_string()),
    ));
    acc.apply_symphonia_revision(&rev.metadata(), false);
    let merged = acc.finalize(Path::new("01 - Track.mp3"), AudioFormat::cd_quality(), 1000);
    assert_eq!(merged.record_label.as_deref(), Some("Verve Records"));

    // Symphonia-only priority: LABEL/TPUB > PUBLISHER > ORGANIZATION
    let mut sym_acc = TagAccumulator::default();
    let mut rev2 = MetadataBuilder::new();
    rev2.add_tag(Tag::new(
        Some(StandardTagKey::Label),
        "ORGANIZATION",
        Value::String("Org Name".to_string()),
    ));
    rev2.add_tag(Tag::new(
        None,
        "TPUB",
        Value::String("Prestige Records".to_string()),
    ));
    sym_acc.apply_symphonia_revision(&rev2.metadata(), false);
    let sym_meta = sym_acc.finalize(Path::new("01 - Track.mp3"), AudioFormat::cd_quality(), 1000);
    assert_eq!(sym_meta.record_label.as_deref(), Some("Prestige Records"));
}
