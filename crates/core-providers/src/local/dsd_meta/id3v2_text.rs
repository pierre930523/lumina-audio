use crate::local::encoding::{
    DetectedEncoding, decode_bytes_with_encoding, decode_with_detected_encoding, sanitize_tag_text,
};

pub fn parse_replay_gain_db_str(raw: &str) -> Option<f64> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let bytes = trimmed.as_bytes();
    let without_unit = if bytes.len() >= 2 && bytes[bytes.len() - 2..].eq_ignore_ascii_case(b"db") {
        trimmed[..bytes.len() - 2].trim()
    } else {
        trimmed
    };
    let parsed = without_unit.replace(',', ".").parse::<f64>().ok()?;
    parsed.is_finite().then_some(parsed)
}

pub fn parse_replay_gain_peak_str(raw: &str) -> Option<f64> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let parsed = trimmed.replace(',', ".").parse::<f64>().ok()?;
    (parsed.is_finite() && parsed >= 0.0).then_some(parsed)
}

pub(super) fn decode_utf8_or_fallback(bytes: &[u8]) -> String {
    if let Ok(s) = std::str::from_utf8(bytes) {
        s.to_string()
    } else {
        decode_with_detected_encoding(bytes).0
    }
}

pub(super) fn decode_utf16_slice(content: &[u8], force_be: bool) -> String {
    if content.len() < 2 {
        return String::new();
    }
    let (is_be, slice) = if !force_be && content[0] == 0xFE && content[1] == 0xFF {
        (true, &content[2..])
    } else if !force_be && content[0] == 0xFF && content[1] == 0xFE {
        (false, &content[2..])
    } else {
        (force_be, content)
    };

    let u16s: Vec<u16> = slice
        .chunks_exact(2)
        .map(|c| {
            if is_be {
                u16::from_be_bytes([c[0], c[1]])
            } else {
                u16::from_le_bytes([c[0], c[1]])
            }
        })
        .take_while(|&u| u != 0)
        .collect();
    String::from_utf16_lossy(&u16s).trim().to_string()
}

pub(super) fn decode_utf16_multi(content: &[u8], force_be: bool) -> Vec<String> {
    let mut out = Vec::new();
    let mut start = 0usize;
    while start + 1 < content.len() {
        let mut end = content.len();
        let mut i = start;
        while i + 1 < content.len() {
            if content[i] == 0 && content[i + 1] == 0 {
                end = i;
                break;
            }
            i += 2;
        }
        let s = sanitize_tag_text(&decode_utf16_slice(&content[start..end], force_be));
        if !s.is_empty() {
            out.push(s);
        }
        if end >= content.len() {
            break;
        }
        start = end + 2;
    }
    out
}

pub(super) fn decode_id3_text_values(
    payload: &[u8],
    enc0_resolved: DetectedEncoding,
) -> Vec<String> {
    if payload.len() < 2 {
        return Vec::new();
    }
    let encoding = payload[0];
    let content = &payload[1..];
    match encoding {
        0 => content
            .split(|&b| b == 0)
            .filter(|part| !part.is_empty())
            .map(|part| sanitize_tag_text(&decode_bytes_with_encoding(part, enc0_resolved)))
            .filter(|s| !s.is_empty())
            .collect(),
        1 => decode_utf16_multi(content, false),
        2 => decode_utf16_multi(content, true),
        3 => content
            .split(|&b| b == 0)
            .filter(|part| !part.is_empty())
            .map(|part| sanitize_tag_text(&decode_utf8_or_fallback(part)))
            .filter(|s| !s.is_empty())
            .collect(),
        _ => {
            let s = sanitize_tag_text(&decode_with_detected_encoding(content).0);
            if s.is_empty() { Vec::new() } else { vec![s] }
        }
    }
}

pub(super) fn decode_id3_text(payload: &[u8], enc0_resolved: DetectedEncoding) -> String {
    decode_id3_text_values(payload, enc0_resolved)
        .into_iter()
        .next()
        .unwrap_or_default()
}

pub(super) fn decode_id3_text_with_enc(
    encoding: u8,
    content: &[u8],
    enc0_resolved: DetectedEncoding,
) -> String {
    match encoding {
        0 => {
            let zero_pos = content
                .iter()
                .position(|&b| b == 0)
                .unwrap_or(content.len());
            decode_bytes_with_encoding(&content[..zero_pos], enc0_resolved)
        }
        1 => decode_utf16_slice(content, false),
        2 => decode_utf16_slice(content, true),
        3 => decode_utf8_or_fallback(content)
            .trim_matches('\0')
            .to_string(),
        _ => decode_with_detected_encoding(content).0,
    }
}

fn fold_fullwidth_numeric(text: &str) -> String {
    text.chars()
        .map(|c| match c {
            '\u{FF10}'..='\u{FF19}' => char::from_u32((c as u32) - 0xFF10 + ('0' as u32)).unwrap(),
            '\u{FF0F}' => '/',
            '\u{FF0D}' | '\u{2013}' | '\u{2014}' => '-',
            '\u{FF0E}' => '.',
            '\u{3000}' => ' ',
            _ => c,
        })
        .collect()
}

/// Extracts ONLY the first contiguous run of ASCII digits as a positive (`>= 1`) `u32`.
/// Returns `None` if no digits are present or if the parsed number is `0`.
fn extract_first_positive_u32(text: &str) -> Option<u32> {
    let mut digits = String::new();
    for ch in text.chars() {
        if ch.is_ascii_digit() {
            digits.push(ch);
        } else if !digits.is_empty() {
            break;
        }
    }
    if digits.is_empty() {
        return None;
    }
    let val = digits.parse::<u32>().ok()?;
    (val > 0).then_some(val)
}

/// Parses track and optional disc number strings (e.g. `"01/12"`, `"1-02"`, `"Track 03 of 12"`)
/// into pure `Option<u32>` values.
pub fn parse_track_and_disc_u32(text: &str) -> (Option<u32>, Option<u32>) {
    let folded = fold_fullwidth_numeric(text);
    let clean = folded.trim();
    if clean.is_empty() {
        return (None, None);
    }
    // Disc-Track pattern like "1-02", "01-05", "1.02"
    if let Some((disc_str, trk_str)) = clean.split_once('-').or_else(|| clean.split_once('.')) {
        let disc_trim = disc_str.trim();
        let trk_trim = trk_str.trim().split('/').next().unwrap_or("").trim();
        if let (Ok(disc), Ok(trk)) = (disc_trim.parse::<u32>(), trk_trim.parse::<u32>()) {
            if disc > 0 && trk > 0 {
                return (Some(trk), Some(disc));
            }
        }
    }
    // "02/12", "1 / 12", "02", "Track 03 of 12" -> extract ONLY first digit run before '/'
    let num_part = clean.split('/').next().unwrap_or(clean).trim();
    if let Some(trk) = extract_first_positive_u32(num_part) {
        return (Some(trk), None);
    }
    (None, None)
}

/// Parses disc number strings such as `"1/2"`, `"1 / 2"`, `"02"`, `"Disc 1/2"`, `"Disc 1 of 2"`,
/// `"CD 2"`, `"Part 2"`, `"1-2"` (returns `Some(1)`), and returns `None` for `"0"` / `"0/2"`.
pub fn parse_disc_u32(text: &str) -> Option<u32> {
    let folded = fold_fullwidth_numeric(text);
    let clean = folded.trim();
    if clean.is_empty() {
        return None;
    }
    let first_part = clean.split('/').next().unwrap_or(clean).trim();
    extract_first_positive_u32(first_part)
}

pub fn parse_track_and_disc_number(text: &str) -> (Option<u16>, Option<u16>) {
    let (trk, disc) = parse_track_and_disc_u32(text);
    (
        trk.map(|v| v.min(u32::from(u16::MAX)) as u16),
        disc.map(|v| v.min(u32::from(u16::MAX)) as u16),
    )
}

pub fn parse_disc_number(text: &str) -> Option<u16> {
    parse_disc_u32(text).map(|v| v.min(u32::from(u16::MAX)) as u16)
}

/// Parses slash-separated or `disc-track` numbers (preserves `parse_slash_number("1-02") == Some(2)`
/// for existing callers; prefer [`parse_disc_number`] / [`parse_disc_u32`] for `TPOS`/`DISCNUMBER`).
pub fn parse_slash_number(text: &str) -> Option<u16> {
    parse_track_and_disc_number(text).0
}

/// Scans all contiguous ASCII digit runs in `text` (after fullwidth folding) and returns the first
/// 4-digit year in `1000..=3000`. Handles ISO (`"2022-03-14"`), US/EU (`"05-12-2021"`, `"12/05/1999"`),
/// and plain years (`"1994"`).
pub fn parse_year(text: &str) -> Option<i32> {
    let folded = fold_fullwidth_numeric(text);
    let mut digits = String::new();
    for c in folded.chars() {
        if c.is_ascii_digit() {
            digits.push(c);
        } else if !digits.is_empty() {
            if let Some(yr) = parse_year_run(&digits) {
                return Some(yr);
            }
            digits.clear();
        }
    }
    parse_year_run(&digits)
}

fn parse_year_run(digits: &str) -> Option<i32> {
    if digits.len() >= 4 {
        let year = digits[..4].parse::<i32>().ok()?;
        if (1000..=3000).contains(&year) {
            return Some(year);
        }
    }
    None
}
