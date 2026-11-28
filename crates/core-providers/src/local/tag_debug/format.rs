use std::fmt::Write as _;

use super::TagInspectionReport;

/// Formats a [`TagInspectionReport`] into a readable plain-text diagnostic dump.
pub fn format_tag_inspection_report(report: &TagInspectionReport) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "=== Tag Inspection: {} ===", report.file_path);
    let _ = writeln!(
        out,
        "Format: {} | Duration: {} ms | Extension: .{}",
        report.parsed_metadata.format, report.parsed_metadata.duration_ms, report.extension
    );

    let _ = writeln!(out, "\n[1] Raw Tag Blocks (by priority):");
    if report.tag_blocks.is_empty() {
        let _ = writeln!(out, "  (no embedded tag blocks found)");
    } else {
        for blk in &report.tag_blocks {
            let _ = writeln!(
                out,
                "  #{} {} [detected_encoding: {}] ({} fields)",
                blk.priority_rank,
                blk.tag_format,
                blk.detected_encoding,
                blk.fields.len()
            );
            for f in &blk.fields {
                let enc_part = f
                    .declared_encoding
                    .as_deref()
                    .map(|e| format!(" [{e}]"))
                    .unwrap_or_default();
                let hex_part = f
                    .raw_hex
                    .as_deref()
                    .map(|h| format!(" (hex: {h})"))
                    .unwrap_or_default();
                let _ = writeln!(
                    out,
                    "    - {}{}: {:?}{}",
                    f.key, enc_part, f.value, hex_part
                );
            }
        }
    }

    let _ = writeln!(out, "\n[2] Resolved Encodings:");
    if report.resolved_encodings.is_empty() {
        let _ = writeln!(out, "  (none)");
    } else {
        for (fmt, enc) in &report.resolved_encodings {
            let _ = writeln!(out, "  - {fmt}: {enc}");
        }
    }

    let m = &report.parsed_metadata;
    let _ = writeln!(out, "\n[3] Final Parsed Metadata:");
    let _ = writeln!(out, "  Title:        {:?}", m.title);
    let _ = writeln!(out, "  Artist:       {:?}", m.artist);
    let _ = writeln!(out, "  Artists:      {:?}", m.artists);
    let _ = writeln!(out, "  Album:        {:?}", m.album);
    let _ = writeln!(out, "  AlbumArtist:  {:?}", m.album_artist);
    let _ = writeln!(
        out,
        "  Disc/Track:   Disc {} / Track {}",
        m.disc_number, m.track_number
    );
    let _ = writeln!(
        out,
        "  Year:         {:?} | Compilation: {:?} | Genre: {:?}",
        m.release_year, m.compilation, m.genre
    );
    if m.isrc.is_some() || m.upc.is_some() || m.musicbrainz_release_group_id.is_some() {
        let _ = writeln!(
            out,
            "  Identifiers:  ISRC={:?} UPC={:?} MB_RG={:?}",
            m.isrc, m.upc, m.musicbrainz_release_group_id
        );
    }

    let k = &report.album_key;
    let _ = writeln!(out, "\n[4] Computed AlbumKey:");
    let _ = writeln!(out, "  group_artist_key:         {:?}", k.group_artist_key);
    let _ = writeln!(out, "  group_album_key:          {:?}", k.group_album_key);
    let _ = writeln!(out, "  canonical_title:          {:?}", k.canonical_title);
    let _ = writeln!(out, "  edition_label:            {:?}", k.edition_label);
    let _ = writeln!(
        out,
        "  inferred_disc (title/dir): {:?} / {:?}",
        k.inferred_disc_from_title, k.inferred_disc_from_dir
    );
    let _ = writeln!(out, "  is_unknown_fallback:      {}", k.is_unknown_fallback);
    let _ = writeln!(out, "  effective_dir_key:        {:?}", k.effective_dir_key);
    let _ = writeln!(out, "  external_album_id:        {:?}", k.external_album_id);

    if !report.warnings.is_empty() {
        let _ = writeln!(out, "\n[Warnings]:");
        for w in &report.warnings {
            let _ = writeln!(out, "  ! {w}");
        }
    }

    out
}
