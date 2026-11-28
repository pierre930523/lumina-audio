use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::fs::File;
use std::path::Path;

use symphonia::core::formats::FormatOptions;
use symphonia::core::io::{MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

use super::{ParsedMetadataSummary, RawTagField, TagBlockInspection, TagInspectionReport};
use crate::error::ProviderError;
use crate::local::ape_meta::{ApeParsedTags, parse_ape_from_reader};
use crate::local::dsd_meta::{Id3v2ParsedTags, parse_dff_with_raw, parse_dsf_with_raw};
use crate::local::mapper::compute_album_key;
use crate::local::metadata::{
    ExtractOptions, MetadataExtractor, detect_garbled_tags, parse_id3v1_from_reader,
    scan_aiff_from_reader, scan_id3v2_from_reader, scan_mp4_ilst_from_reader,
};
use crate::local::riff_meta::parse_wav_with_raw;

/// Inspects an audio file's raw tag blocks, detected/resolved encodings, final parsed metadata,
/// and exact computed [`AlbumKey`] using the same parsers and grouping logic as production scans.
pub fn inspect_audio_tags(path: &Path) -> Result<TagInspectionReport, ProviderError> {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();

    let mut tag_blocks: Vec<TagBlockInspection> = Vec::new();
    let mut warnings: Vec<String> = Vec::new();

    match ext.as_str() {
        "flac" => {
            if let Ok((_, raw)) = MetadataExtractor::extract_flac_raw(path) {
                let fields: Vec<RawTagField> = raw
                    .raw_vorbis_comments
                    .into_iter()
                    .map(|(k, b, v)| RawTagField {
                        key: k,
                        declared_encoding: Some("utf-8 (vorbis)".to_string()),
                        raw_hex: maybe_hex(&b),
                        value: v,
                    })
                    .collect();
                tag_blocks.push(TagBlockInspection {
                    tag_format: "VorbisComment".to_string(),
                    priority_rank: 1,
                    detected_encoding: raw.vorbis_encoding.to_string(),
                    fields,
                });

                if let Some(id3) = raw.prepended_id3 {
                    warnings.push(
                        "FLAC contains a non-standard prepended ID3v2 tag (Vorbis Comments take priority)"
                            .to_string(),
                    );
                    tag_blocks.push(id3v2_block(id3, 2));
                }
                if let Some(ape) = raw.ape_tags {
                    tag_blocks.push(ape_block(ape, 3));
                }
            }
        }
        "mp3" | "aac" => {
            if let Ok(mut file) = File::open(path) {
                if let Some(id3) = scan_id3v2_from_reader(&mut file, true) {
                    tag_blocks.push(id3v2_block(id3, 1));
                }
                if let Some(ape) = parse_ape_from_reader(&mut file) {
                    tag_blocks.push(ape_block(ape, 2));
                }
                if ext == "mp3" {
                    if let Some(v1) = parse_id3v1_from_reader(&mut file, true) {
                        let fields = v1
                            .raw_fields
                            .into_iter()
                            .map(|(k, b, v)| RawTagField {
                                key: k,
                                declared_encoding: Some("id3v1-legacy".to_string()),
                                raw_hex: maybe_hex(&b),
                                value: v,
                            })
                            .collect();
                        tag_blocks.push(TagBlockInspection {
                            tag_format: "ID3v1".to_string(),
                            priority_rank: 3,
                            detected_encoding: v1.detected_encoding.to_string(),
                            fields,
                        });
                    }
                }
            }
        }
        "wav" | "wave" => {
            if let Ok(wav) = parse_wav_with_raw(path) {
                if let Some(id3) = wav.id3_tags {
                    tag_blocks.push(id3v2_block(id3, 1));
                }
                if !wav.raw_info_fields.is_empty() {
                    let fields = wav
                        .raw_info_fields
                        .into_iter()
                        .map(|f| RawTagField {
                            key: f.key,
                            declared_encoding: Some("riff-info".to_string()),
                            raw_hex: maybe_hex(&f.raw_bytes),
                            value: f.decoded,
                        })
                        .collect();
                    tag_blocks.push(TagBlockInspection {
                        tag_format: "RIFF/INFO".to_string(),
                        priority_rank: 2,
                        detected_encoding: wav
                            .info_detected_encoding
                            .unwrap_or(wav.detected_encoding)
                            .to_string(),
                        fields,
                    });
                }
                if !wav.raw_bext_fields.is_empty() {
                    let fields = wav
                        .raw_bext_fields
                        .into_iter()
                        .map(|f| RawTagField {
                            key: f.key,
                            declared_encoding: Some("bwf-bext".to_string()),
                            raw_hex: maybe_hex(&f.raw_bytes),
                            value: f.decoded,
                        })
                        .collect();
                    tag_blocks.push(TagBlockInspection {
                        tag_format: "RIFF/bext".to_string(),
                        priority_rank: 3,
                        detected_encoding: wav.detected_encoding.to_string(),
                        fields,
                    });
                }
            }
        }
        "dsf" => {
            if let Ok(dsd) = parse_dsf_with_raw(path) {
                if !dsd.tags.raw_id3_frames.is_empty() {
                    let fields = dsd
                        .tags
                        .raw_id3_frames
                        .into_iter()
                        .map(|f| RawTagField {
                            key: if f.raw_frame_id == f.frame_id {
                                f.frame_id
                            } else {
                                format!("{} ({})", f.raw_frame_id, f.frame_id)
                            },
                            declared_encoding: f.declared_encoding.map(id3_enc_label),
                            raw_hex: maybe_hex(&f.raw_bytes),
                            value: f.decoded_value.unwrap_or_default(),
                        })
                        .collect();
                    tag_blocks.push(TagBlockInspection {
                        tag_format: "ID3v2 (DSF)".to_string(),
                        priority_rank: 1,
                        detected_encoding: dsd.tags.detected_encoding.to_string(),
                        fields,
                    });
                }
            }
        }
        "dff" => {
            if let Ok(dsd) = parse_dff_with_raw(path) {
                if !dsd.tags.raw_id3_frames.is_empty() {
                    let fields = dsd
                        .tags
                        .raw_id3_frames
                        .into_iter()
                        .map(|f| RawTagField {
                            key: f.frame_id,
                            declared_encoding: f.declared_encoding.map(id3_enc_label),
                            raw_hex: maybe_hex(&f.raw_bytes),
                            value: f.decoded_value.unwrap_or_default(),
                        })
                        .collect();
                    tag_blocks.push(TagBlockInspection {
                        tag_format: "ID3v2 (DSDIFF)".to_string(),
                        priority_rank: 1,
                        detected_encoding: dsd.tags.detected_encoding.to_string(),
                        fields,
                    });
                }
                if !dsd.tags.raw_diin_fields.is_empty() {
                    let fields = dsd
                        .tags
                        .raw_diin_fields
                        .into_iter()
                        .map(|(k, b, v)| RawTagField {
                            key: k,
                            declared_encoding: Some("dsdiff-diin".to_string()),
                            raw_hex: maybe_hex(&b),
                            value: v,
                        })
                        .collect();
                    tag_blocks.push(TagBlockInspection {
                        tag_format: "DSDIFF/DIIN".to_string(),
                        priority_rank: 2,
                        detected_encoding: dsd.tags.detected_encoding.to_string(),
                        fields,
                    });
                }
            }
        }
        "m4a" | "mp4" | "alac" => {
            if let Ok(mut file) = File::open(path) {
                if let Some(mp4) = scan_mp4_ilst_from_reader(&mut file, true) {
                    let fields = mp4
                        .raw_atoms
                        .into_iter()
                        .map(|(k, b, v)| RawTagField {
                            key: k,
                            declared_encoding: Some("mp4-ilst".to_string()),
                            raw_hex: maybe_hex(&b),
                            value: v,
                        })
                        .collect();
                    tag_blocks.push(TagBlockInspection {
                        tag_format: "MP4/ilst".to_string(),
                        priority_rank: 1,
                        detected_encoding: mp4.detected_encoding.to_string(),
                        fields,
                    });
                }
            }
        }
        "aiff" | "aif" => {
            if let Ok(mut file) = File::open(path) {
                if let Some(aiff) = scan_aiff_from_reader(&mut file, true) {
                    if let Some(id3) = aiff.id3 {
                        tag_blocks.push(id3v2_block(id3, 1));
                    }
                    if !aiff.raw_form_fields.is_empty() {
                        let fields = aiff
                            .raw_form_fields
                            .into_iter()
                            .map(|(k, b, v)| RawTagField {
                                key: k,
                                declared_encoding: Some("aiff-form".to_string()),
                                raw_hex: maybe_hex(&b),
                                value: v,
                            })
                            .collect();
                        tag_blocks.push(TagBlockInspection {
                            tag_format: "AIFF/FORM".to_string(),
                            priority_rank: 2,
                            detected_encoding: aiff.form_encoding.to_string(),
                            fields,
                        });
                    }
                }
            }
        }
        _ => {
            if let Some(sym_block) = collect_symphonia_raw_block(path, &ext) {
                tag_blocks.push(sym_block);
            }
        }
    }

    let meta = MetadataExtractor::extract_with_options(
        path,
        ExtractOptions {
            include_pictures: false,
        },
    )?;

    if let Some(garbled) = detect_garbled_tags(&meta) {
        warnings.push(garbled);
    }

    let album_key = compute_album_key(&meta, path);
    if album_key.is_unknown_fallback {
        warnings.push(
            "Album or Artist fell back to Unknown; grouping is scoped to effective directory"
                .to_string(),
        );
    }

    let mut resolved_encodings = BTreeMap::new();
    for blk in &tag_blocks {
        resolved_encodings.insert(blk.tag_format.clone(), blk.detected_encoding.clone());
    }

    Ok(TagInspectionReport {
        file_path: path.to_string_lossy().into_owned(),
        extension: ext,
        tag_blocks,
        resolved_encodings,
        parsed_metadata: ParsedMetadataSummary::from(&meta),
        album_key,
        warnings,
    })
}

fn id3v2_block(id3: Id3v2ParsedTags, priority_rank: u8) -> TagBlockInspection {
    let fields = id3
        .raw_frames
        .into_iter()
        .map(|f| RawTagField {
            key: if f.raw_frame_id == f.frame_id {
                f.frame_id
            } else {
                format!("{} ({})", f.raw_frame_id, f.frame_id)
            },
            declared_encoding: f.declared_encoding.map(id3_enc_label),
            raw_hex: maybe_hex(&f.raw_bytes),
            value: f.decoded_value.unwrap_or_default(),
        })
        .collect();
    TagBlockInspection {
        tag_format: format!("ID3v2.{}", id3.version_major),
        priority_rank,
        detected_encoding: id3.detected_encoding.to_string(),
        fields,
    }
}

fn ape_block(ape: ApeParsedTags, priority_rank: u8) -> TagBlockInspection {
    let fields = ape
        .raw_items
        .into_iter()
        .map(|it| RawTagField {
            key: it.key,
            declared_encoding: Some(if it.is_binary {
                "ape-binary".to_string()
            } else {
                "ape-utf8".to_string()
            }),
            raw_hex: if it.is_binary {
                None
            } else {
                maybe_hex(&it.raw_bytes)
            },
            value: if it.is_binary {
                format!("[binary, {} bytes]", it.raw_bytes.len())
            } else {
                it.decoded_values.join("; ")
            },
        })
        .collect();
    TagBlockInspection {
        tag_format: format!("APEv{}", ape.version / 1000),
        priority_rank,
        detected_encoding: ape.detected_encoding.to_string(),
        fields,
    }
}

fn collect_symphonia_raw_block(path: &Path, ext: &str) -> Option<TagBlockInspection> {
    let file = File::open(path).ok()?;
    let mss = MediaSourceStream::new(Box::new(file), MediaSourceStreamOptions::default());
    let mut hint = Hint::new();
    if !ext.is_empty() {
        hint.with_extension(ext);
    }
    let mut probed = symphonia::default::get_probe()
        .format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )
        .ok()?;

    let mut fields = Vec::new();
    if let Some(meta) = probed.format.metadata().current() {
        for tag in meta.tags() {
            let key = if tag.key.is_empty() {
                tag.std_key
                    .map(|k| format!("{k:?}"))
                    .unwrap_or_else(|| "UNKNOWN".to_string())
            } else {
                tag.key.clone()
            };
            fields.push(RawTagField {
                key,
                declared_encoding: Some("symphonia-container".to_string()),
                raw_hex: None,
                value: tag.value.to_string(),
            });
        }
    }
    if let Some(reader) = probed.metadata.get() {
        if let Some(meta) = reader.current() {
            for tag in meta.tags() {
                let key = if tag.key.is_empty() {
                    tag.std_key
                        .map(|k| format!("{k:?}"))
                        .unwrap_or_else(|| "UNKNOWN".to_string())
                } else {
                    tag.key.clone()
                };
                fields.push(RawTagField {
                    key,
                    declared_encoding: Some("symphonia-probed".to_string()),
                    raw_hex: None,
                    value: tag.value.to_string(),
                });
            }
        }
    }

    Some(TagBlockInspection {
        tag_format: format!("Symphonia ({})", ext.to_ascii_uppercase()),
        priority_rank: 1,
        detected_encoding: "utf-8".to_string(),
        fields,
    })
}

fn id3_enc_label(enc: u8) -> String {
    match enc {
        0 => "0:iso-8859-1".to_string(),
        1 => "1:utf-16-bom".to_string(),
        2 => "2:utf-16be".to_string(),
        3 => "3:utf-8".to_string(),
        other => format!("{other}:unknown"),
    }
}

fn maybe_hex(bytes: &[u8]) -> Option<String> {
    if bytes.is_empty() || bytes.iter().all(|&b| (0x20..0x7F).contains(&b) || b == 0) {
        return None;
    }
    let slice = &bytes[..bytes.len().min(64)];
    let mut s = String::with_capacity(slice.len() * 3);
    for (i, &b) in slice.iter().enumerate() {
        if i > 0 {
            s.push(' ');
        }
        let _ = write!(&mut s, "{b:02x}");
    }
    if bytes.len() > 64 {
        s.push_str(" ...");
    }
    Some(s)
}
