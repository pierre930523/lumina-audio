// Minimal JSON Scalar Decoders for metadata_overrides.value_json

pub(super) fn decode_json_opt_string(raw: &str) -> Option<Option<String>> {
    let trimmed = raw.trim();
    if trimmed == "null" {
        return Some(None);
    }
    decode_json_string(trimmed).map(Some)
}

pub(super) fn decode_json_string(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed == "null" {
        return None;
    }
    if trimmed.len() >= 2 && trimmed.starts_with('"') && trimmed.ends_with('"') {
        unescape_json_str(&trimmed[1..trimmed.len() - 1])
    } else if !trimmed.is_empty() {
        Some(trimmed.to_string())
    } else {
        None
    }
}

pub(super) fn decode_json_i64(raw: &str) -> Option<i64> {
    let trimmed = raw.trim();
    if let Ok(n) = trimmed.parse::<i64>() {
        return Some(n);
    }
    decode_json_string(trimmed).and_then(|s| s.trim().parse::<i64>().ok())
}

fn unescape_json_str(inner: &str) -> Option<String> {
    let mut out = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    while let Some(ch) = chars.next() {
        if ch != '\\' {
            out.push(ch);
            continue;
        }
        match chars.next()? {
            '"' => out.push('"'),
            '\\' => out.push('\\'),
            '/' => out.push('/'),
            'b' => out.push('\u{0008}'),
            'f' => out.push('\u{000C}'),
            'n' => out.push('\n'),
            'r' => out.push('\r'),
            't' => out.push('\t'),
            'u' => {
                let code = parse_hex4(&mut chars)?;
                if (0xD800..=0xDBFF).contains(&code) {
                    if chars.next() == Some('\\') && chars.next() == Some('u') {
                        let low = parse_hex4(&mut chars)?;
                        if (0xDC00..=0xDFFF).contains(&low) {
                            let combined = 0x10000
                                + (((u32::from(code) - 0xD800) << 10) | (u32::from(low) - 0xDC00));
                            if let Some(c) = char::from_u32(combined) {
                                out.push(c);
                            }
                        }
                    }
                } else if let Some(c) = char::from_u32(u32::from(code)) {
                    out.push(c);
                }
            }
            other => out.push(other),
        }
    }
    Some(out)
}

fn parse_hex4(chars: &mut std::str::Chars<'_>) -> Option<u16> {
    let mut val = 0u16;
    for _ in 0..4 {
        let d = chars.next()?.to_digit(16)? as u16;
        val = (val << 4) | d;
    }
    Some(val)
}
