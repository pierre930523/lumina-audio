use encoding_rs::{UTF_16BE, UTF_16LE, WINDOWS_1252};
use unicode_normalization::UnicodeNormalization;

use super::DetectedEncoding;
use super::detect::{detect_tag_block_encoding, strip_trailing_nuls};

/// Decodes a single byte slice, returning both the decoded string and the resolved encoding.
pub fn decode_with_detected_encoding(bytes: &[u8]) -> (String, DetectedEncoding) {
    if bytes.is_empty() {
        return (String::new(), DetectedEncoding::Ascii);
    }

    if let Some((text, enc)) = decode_with_bom(bytes) {
        return (text, enc);
    }

    let trimmed = strip_trailing_nuls(bytes);
    if trimmed.is_empty() {
        return (String::new(), DetectedEncoding::Ascii);
    }
    if trimmed.iter().all(|&b| b < 0x80) {
        return (
            String::from_utf8_lossy(trimmed).into_owned(),
            DetectedEncoding::Ascii,
        );
    }
    if let Ok(valid_utf8) = std::str::from_utf8(trimmed) {
        return (valid_utf8.to_string(), DetectedEncoding::Utf8);
    }

    let enc = detect_tag_block_encoding(&[trimmed]);
    (decode_bytes_with_encoding(trimmed, enc), enc)
}

/// Decodes raw bytes with a previously resolved [`DetectedEncoding`].
pub fn decode_bytes_with_encoding(bytes: &[u8], enc: DetectedEncoding) -> String {
    if bytes.is_empty() {
        return String::new();
    }

    if let Some((text, _)) = decode_with_bom(bytes) {
        return text;
    }

    let trimmed = strip_trailing_nuls(bytes);
    if trimmed.is_empty() {
        return String::new();
    }

    match enc {
        DetectedEncoding::Ascii => String::from_utf8_lossy(trimmed).into_owned(),
        DetectedEncoding::Utf8 | DetectedEncoding::Utf8Bom => {
            if let Ok(s) = std::str::from_utf8(trimmed) {
                s.to_string()
            } else {
                WINDOWS_1252.decode(trimmed).0.into_owned()
            }
        }
        DetectedEncoding::Utf16Le => UTF_16LE.decode(bytes).0.into_owned(),
        DetectedEncoding::Utf16Be => UTF_16BE.decode(bytes).0.into_owned(),
        other => other.to_encoding_rs().decode(trimmed).0.into_owned(),
    }
}

/// Attempts to recover mojibake from strings where raw UTF-8 or CJK bytes were blindly cast
/// byte-for-byte into Latin-1 (`U+0080..=U+00FF`, e.g., Symphonia ID3v2 ISO-8859-1 frames).
///
/// Genuine Western Latin-1 strings (e.g., `"Café"`, `"Björk"`, `"Tiësto"`) are left untouched
/// and return `None` as the recovered encoding.
pub fn recover_latin1_mojibake(s: &str) -> (String, Option<DetectedEncoding>) {
    if s.is_empty() {
        return (String::new(), None);
    }

    let mut has_high_latin1 = false;
    for ch in s.chars() {
        let code = ch as u32;
        if code > 0xFF {
            // Already contains real Unicode beyond Latin-1; do not alter.
            return (s.to_string(), None);
        }
        if code >= 0x80 {
            has_high_latin1 = true;
        }
    }

    if !has_high_latin1 {
        return (s.to_string(), None);
    }

    let raw_bytes: Vec<u8> = s.chars().map(|c| c as u8).collect();
    if let Ok(utf8_str) = std::str::from_utf8(&raw_bytes) {
        return (utf8_str.to_string(), Some(DetectedEncoding::Utf8));
    }

    let detected = detect_tag_block_encoding(&[&raw_bytes]);
    if detected.is_cjk() {
        let decoded = decode_bytes_with_encoding(&raw_bytes, detected);
        if !decoded.contains('\u{FFFD}') && !decoded.is_empty() {
            return (decoded, Some(detected));
        }
    }

    (s.to_string(), None)
}

/// Tag-wide mojibake recovery across ALL string values from a single tag block (e.g., Symphonia
/// container tags or MP4 atoms), ensuring every field in the file decodes under the SAME
/// detected legacy encoding rather than conflicting per-field guesses.
pub fn recover_latin1_mojibake_block(strings: &[&str]) -> (Vec<String>, Option<DetectedEncoding>) {
    if strings.is_empty() {
        return (Vec::new(), None);
    }

    let mut raw_entries: Vec<Option<Vec<u8>>> = Vec::with_capacity(strings.len());
    let mut has_high_latin1 = false;

    for &s in strings {
        let mut all_latin1 = true;
        let mut field_high = false;
        for ch in s.chars() {
            let code = ch as u32;
            if code > 0xFF {
                all_latin1 = false;
                break;
            }
            if code >= 0x80 {
                field_high = true;
            }
        }
        if all_latin1 && field_high {
            has_high_latin1 = true;
            raw_entries.push(Some(s.chars().map(|c| c as u8).collect()));
        } else {
            raw_entries.push(None);
        }
    }

    if !has_high_latin1 {
        return (strings.iter().map(|s| (*s).to_string()).collect(), None);
    }

    let raw_slices: Vec<&[u8]> = raw_entries
        .iter()
        .filter_map(|opt| opt.as_deref())
        .collect();

    // If every high-byte field is valid UTF-8 when reinterpreted as raw bytes, recover as UTF-8.
    if raw_slices.iter().all(|b| std::str::from_utf8(b).is_ok()) {
        let out = strings
            .iter()
            .zip(raw_entries.iter())
            .map(|(&orig, opt)| match opt {
                Some(bytes) => std::str::from_utf8(bytes)
                    .map(str::to_string)
                    .unwrap_or_else(|_| orig.to_string()),
                None => orig.to_string(),
            })
            .collect();
        return (out, Some(DetectedEncoding::Utf8));
    }

    let detected = detect_tag_block_encoding(&raw_slices);
    if detected.is_cjk() {
        let mut recovered = Vec::with_capacity(strings.len());
        let mut any_error = false;
        for (&orig, opt) in strings.iter().zip(raw_entries.iter()) {
            if let Some(bytes) = opt {
                let decoded = decode_bytes_with_encoding(bytes, detected);
                if decoded.contains('\u{FFFD}') || decoded.is_empty() {
                    any_error = true;
                    recovered.push(orig.to_string());
                } else {
                    recovered.push(decoded);
                }
            } else {
                recovered.push(orig.to_string());
            }
        }
        if !any_error {
            return (recovered, Some(detected));
        }
    }

    (strings.iter().map(|s| (*s).to_string()).collect(), None)
}

/// Cleans a single-line tag field: strips NULs and control characters, normalizes Unicode to NFC,
/// and trims leading/trailing whitespace.
pub fn sanitize_tag_text(raw: &str) -> String {
    let mut cleaned = String::with_capacity(raw.len());
    for ch in raw.chars() {
        if ch == '\0' {
            continue;
        }
        if ch == '\r' || ch == '\n' || ch == '\t' {
            cleaned.push(' ');
            continue;
        }
        let code = ch as u32;
        if code < 0x20 || code == 0x7F {
            continue;
        }
        cleaned.push(ch);
    }
    cleaned.nfc().collect::<String>().trim().to_string()
}

/// Cleans multi-line tag text (such as embedded lyrics): preserves newlines while stripping NULs
/// and non-printable control characters, normalizing to NFC, and trimming outer whitespace.
pub fn sanitize_multiline_tag_text(raw: &str) -> String {
    let mut cleaned = String::with_capacity(raw.len());
    for ch in raw.chars() {
        if ch == '\0' {
            continue;
        }
        let code = ch as u32;
        if (code < 0x20 && !matches!(ch, '\n' | '\r' | '\t')) || code == 0x7F {
            continue;
        }
        cleaned.push(ch);
    }
    cleaned.nfc().collect::<String>().trim().to_string()
}

/// Backwards-compatible text decoder used by `lyrics.rs` and `lyrics_tests.rs`.
pub fn decode_text_cjk(bytes: &[u8]) -> String {
    decode_with_detected_encoding(bytes).0
}

fn decode_with_bom(bytes: &[u8]) -> Option<(String, DetectedEncoding)> {
    if bytes.len() >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
        return Some((
            String::from_utf8_lossy(&bytes[3..]).into_owned(),
            DetectedEncoding::Utf8Bom,
        ));
    }
    if bytes.len() >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE {
        let (cow, _, _) = UTF_16LE.decode(&bytes[2..]);
        return Some((cow.into_owned(), DetectedEncoding::Utf16Le));
    }
    if bytes.len() >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF {
        let (cow, _, _) = UTF_16BE.decode(&bytes[2..]);
        return Some((cow.into_owned(), DetectedEncoding::Utf16Be));
    }
    None
}
