use encoding_rs::{BIG5, EUC_KR, GB18030, GBK, SHIFT_JIS, UTF_8, UTF_16BE, UTF_16LE};

use super::DetectedEncoding;

/// Detects a single shared encoding across multiple raw byte samples from the same tag block
/// (e.g., all ID3v2 `encoding=0` frames, all ID3v1 fields, or all RIFF `LIST INFO` entries).
pub fn detect_tag_block_encoding(samples: &[&[u8]]) -> DetectedEncoding {
    let cleaned: Vec<&[u8]> = samples
        .iter()
        .map(|s| strip_trailing_nuls(s))
        .filter(|s| !s.is_empty())
        .collect();

    if cleaned.is_empty() {
        return DetectedEncoding::Ascii;
    }

    // Inspect ALL samples for an explicit BOM (not just the first, which may be ASCII e.g. TRCK).
    for sample in &cleaned {
        if let Some(bom_enc) = detect_bom(sample) {
            return bom_enc;
        }
    }

    if cleaned.iter().all(|s| s.iter().all(|&b| b < 0x80)) {
        return DetectedEncoding::Ascii;
    }

    if cleaned.iter().all(|s| std::str::from_utf8(s).is_ok()) {
        return DetectedEncoding::Utf8;
    }

    let mut combined = Vec::new();
    for (idx, sample) in cleaned.iter().enumerate() {
        if idx > 0 {
            combined.push(b'\n');
        }
        combined.extend_from_slice(sample);
    }

    // Western Latin-1 / Windows-1252 safety guard:
    // Prevent accented Western names ("Café", "Björk", "Sigur Rós", "Tiësto", "Amélie", "Naïve")
    // from being mangled into spurious CJK or UTF-8 replacement characters.
    if looks_like_western_latin1(&cleaned) {
        return DetectedEncoding::Windows1252;
    }

    let mut detector = chardetng::EncodingDetector::new();
    detector.feed(&combined, true);
    let guessed = detector.guess(None, true);
    let mapped_guess = map_encoding_rs(guessed);

    // Check whether chardetng's guess decodes cleanly without replacement characters.
    let (_, _, guess_err) = mapped_guess.to_encoding_rs().decode(&combined);

    if mapped_guess.is_cjk() && !guess_err {
        // Double-check Big5 vs GBK tie-break on short samples where chardetng can occasionally flip.
        if matches!(mapped_guess, DetectedEncoding::Gbk | DetectedEncoding::Big5) {
            if let Some(override_enc) = tiebreak_short_cjk(&combined, mapped_guess) {
                return override_enc;
            }
        }
        return mapped_guess;
    }

    if mapped_guess == DetectedEncoding::Windows1252 {
        // On very short CJK tags (e.g., 4-8 bytes like "周杰倫" / "久石譲"), chardetng may fall
        // back to Windows-1252 when uncertain. Recover CJK ONLY when high-byte density +
        // consecutive high-byte pairs clearly indicate multi-byte CJK rather than Western text.
        if looks_like_multibyte_cjk(&combined) {
            if let Some(best_cjk) = best_cjk_candidate(&combined) {
                return best_cjk;
            }
        }
        return DetectedEncoding::Windows1252;
    }

    if !guess_err {
        return mapped_guess;
    }

    // Fallback: pick the best error-free CJK candidate, or safely fall back to Windows-1252
    // (never lossy UTF-8 replacement chars).
    best_cjk_candidate(&combined).unwrap_or(DetectedEncoding::Windows1252)
}

pub(super) fn strip_trailing_nuls(bytes: &[u8]) -> &[u8] {
    let mut end = bytes.len();
    while end > 0 && bytes[end - 1] == 0 {
        end -= 1;
    }
    &bytes[..end]
}

fn detect_bom(bytes: &[u8]) -> Option<DetectedEncoding> {
    if bytes.len() >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
        Some(DetectedEncoding::Utf8Bom)
    } else if bytes.len() >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE {
        Some(DetectedEncoding::Utf16Le)
    } else if bytes.len() >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF {
        Some(DetectedEncoding::Utf16Be)
    } else {
        None
    }
}

fn map_encoding_rs(enc: &'static encoding_rs::Encoding) -> DetectedEncoding {
    if enc == UTF_8 {
        DetectedEncoding::Utf8
    } else if enc == SHIFT_JIS {
        DetectedEncoding::ShiftJis
    } else if enc == GBK || enc == GB18030 {
        DetectedEncoding::Gbk
    } else if enc == BIG5 {
        DetectedEncoding::Big5
    } else if enc == EUC_KR {
        DetectedEncoding::EucKr
    } else if enc == UTF_16LE {
        DetectedEncoding::Utf16Le
    } else if enc == UTF_16BE {
        DetectedEncoding::Utf16Be
    } else {
        DetectedEncoding::Windows1252
    }
}

fn is_western_win1252_byte(b: u8) -> bool {
    (0xC0..=0xFF).contains(&b)
        || matches!(
            b,
            0x80 | 0x85
                | 0x91..=0x97
                | 0xA0..=0xA3
                | 0xA9
                | 0xAB
                | 0xAE
                | 0xB0
                | 0xB4
                | 0xB7
                | 0xBB
                | 0xBF
        )
}

fn is_western_latin_letter(b: u8) -> bool {
    (0xC0..=0xFF).contains(&b) && b != 0xD7 && b != 0xF7
}

fn is_western_opening_or_closing_punct(b: u8) -> bool {
    matches!(b, 0x91..=0x94 | 0xA1 | 0xAB | 0xBB | 0xBF)
}

/// Returns `true` when legacy bytes clearly resemble Western European ISO-8859-1 / Windows-1252
/// text — including accented words with adjacent accented letters or guillemets such as
/// `"Café"`, `"Björk"`, `"Tiësto"`, `"créée"`, `"Ação"`, `"«Été»"`, `"¡Órale!"` — while
/// rejecting multi-byte CJK (GBK / Big5 / Shift-JIS / EUC-KR).
fn looks_like_western_latin1(samples: &[&[u8]]) -> bool {
    let mut non_ascii = 0usize;
    let mut non_ascii_letters = 0usize;
    let mut ascii_letters = 0usize;

    for sample in samples {
        let len = sample.len();
        let mut i = 0usize;
        while i < len {
            let b = sample[i];
            if b.is_ascii_alphabetic() {
                ascii_letters += 1;
                i += 1;
                continue;
            }
            if b < 0x80 {
                i += 1;
                continue;
            }

            if !is_western_win1252_byte(b) {
                return false;
            }

            // Measure contiguous high-byte run
            let run_start = i;
            while i < len && sample[i] >= 0x80 {
                if !is_western_win1252_byte(sample[i]) {
                    return false;
                }
                non_ascii += 1;
                if is_western_latin_letter(sample[i]) {
                    non_ascii_letters += 1;
                }
                i += 1;
            }
            let run = &sample[run_start..i];

            // Strip optional leading/trailing Western quote/guillemet/inverted-punct («Été», ¡Órale!)
            let mut inner_start = 0usize;
            let mut inner_end = run.len();
            if inner_start < inner_end && is_western_opening_or_closing_punct(run[inner_start]) {
                inner_start += 1;
            }
            if inner_start < inner_end && is_western_opening_or_closing_punct(run[inner_end - 1]) {
                inner_end -= 1;
            }
            let inner = &run[inner_start..inner_end];

            // Runs of 3+ consecutive high bytes inside a word indicate multi-byte CJK, not Latin-1.
            if inner.len() >= 3 {
                return false;
            }

            if inner.len() == 2 {
                // Only allow a 2-byte adjacent accented-letter pair (e.g. "créée", "Ação")
                // embedded adjacent to ASCII letters (never 2 punctuation bytes or isolated CJK pair).
                if !inner.iter().all(|&x| is_western_latin_letter(x)) {
                    return false;
                }
                let prev_ascii = run_start > 0 && sample[run_start - 1].is_ascii_alphabetic();
                let next_ascii = i < len && sample[i].is_ascii_alphabetic();
                if !prev_ascii && !next_ascii {
                    return false;
                }
            } else if inner.len() == 1 && is_western_latin_letter(inner[0]) {
                let prev_ascii = run_start > 0 && sample[run_start - 1].is_ascii_alphabetic();
                let next_ascii = i < len && sample[i].is_ascii_alphabetic();
                if !prev_ascii && !next_ascii {
                    return false;
                }
            } else if inner.is_empty() && run.len() > 2 {
                return false;
            }
        }
    }

    non_ascii > 0 && ascii_letters > 0 && ascii_letters * 2 >= non_ascii_letters
}

fn looks_like_multibyte_cjk(bytes: &[u8]) -> bool {
    let mut non_ascii = 0usize;
    let mut non_ws = 0usize;
    let mut consecutive_high_pairs = 0usize;

    for (i, &b) in bytes.iter().enumerate() {
        if !b.is_ascii_whitespace() {
            non_ws += 1;
        }
        if b >= 0x80 {
            non_ascii += 1;
            if i > 0 && bytes[i - 1] >= 0x80 {
                consecutive_high_pairs += 1;
            }
        }
    }

    if non_ascii < 2 {
        return false;
    }

    // Either consecutive high-byte pairs exist OR dense high bytes typical of Shift-JIS/Big5
    consecutive_high_pairs > 0 || (non_ws > 0 && non_ascii * 2 >= non_ws)
}

fn best_cjk_candidate(bytes: &[u8]) -> Option<DetectedEncoding> {
    let candidates = [
        DetectedEncoding::ShiftJis,
        DetectedEncoding::Gbk,
        DetectedEncoding::Big5,
        DetectedEncoding::EucKr,
    ];

    let mut valid: Vec<(DetectedEncoding, usize)> = Vec::new();
    for enc in candidates {
        let (decoded, _, had_err) = enc.to_encoding_rs().decode(bytes);
        if had_err || decoded.contains('\u{FFFD}') {
            continue;
        }
        let score = score_cjk_decoded(bytes, &decoded, enc);
        if score > 0 {
            valid.push((enc, score));
        }
    }

    if valid.len() == 1 {
        return Some(valid[0].0);
    }

    valid
        .into_iter()
        .max_by_key(|&(_, score)| score)
        .map(|(enc, _)| enc)
}

fn tiebreak_short_cjk(bytes: &[u8], guessed: DetectedEncoding) -> Option<DetectedEncoding> {
    if bytes.len() > 48 {
        return None;
    }
    let (s_gbk, _, err_gbk) = GBK.decode(bytes);
    let (s_big5, _, err_big5) = BIG5.decode(bytes);
    if err_gbk && !err_big5 {
        return Some(DetectedEncoding::Big5);
    }
    if err_big5 && !err_gbk {
        return Some(DetectedEncoding::Gbk);
    }
    if err_gbk && err_big5 {
        return None;
    }
    let score_gbk = score_cjk_decoded(bytes, &s_gbk, DetectedEncoding::Gbk);
    let score_big5 = score_cjk_decoded(bytes, &s_big5, DetectedEncoding::Big5);
    if guessed == DetectedEncoding::Gbk && score_big5 > score_gbk + 20 {
        Some(DetectedEncoding::Big5)
    } else if guessed == DetectedEncoding::Big5 && score_gbk > score_big5 + 20 {
        Some(DetectedEncoding::Gbk)
    } else {
        None
    }
}

fn score_cjk_decoded(bytes: &[u8], decoded: &str, enc: DetectedEncoding) -> usize {
    if decoded.is_empty() || decoded.contains('\u{FFFD}') {
        return 0;
    }
    let mut score = 0usize;
    match enc {
        DetectedEncoding::ShiftJis => {
            for c in decoded.chars() {
                let u = c as u32;
                if (0x3040..=0x30FF).contains(&u) {
                    // Hiragana & Katakana are strong Shift-JIS indicators
                    score += 20;
                } else if (0x4E00..=0x9FFF).contains(&u) {
                    score += 3;
                } else if (0xFF65..=0xFF9F).contains(&u) {
                    // Half-width katakana
                    score += 4;
                }
            }
            for w in bytes.windows(2) {
                if w[0] == 0x82 || w[0] == 0x83 {
                    score += 6;
                } else if (0x88..=0x9F).contains(&w[0]) && (w[1] >= 0x40) {
                    score += 2;
                }
            }
        }
        DetectedEncoding::Big5 => {
            for c in decoded.chars() {
                let u = c as u32;
                if matches!(
                    c,
                    '繁' | '體'
                        | '詞'
                        | '測'
                        | '試'
                        | '妳'
                        | '說'
                        | '線'
                        | '專'
                        | '輯'
                        | '樂'
                        | '團'
                        | '倫'
                        | '陳'
                        | '張'
                        | '劉'
                        | '黃'
                        | '葉'
                        | '愛'
                        | '夢'
                        | '風'
                        | '聽'
                        | '聲'
                        | '錄'
                        | '音'
                        | '演'
                        | '唱'
                        | '會'
                        | '語'
                        | '國'
                        | '臺'
                ) {
                    score += 25;
                } else if (0x4E00..=0x9FFF).contains(&u) {
                    score += 3;
                }
            }
            for &b in bytes {
                if (0xA4..=0xC6).contains(&b) {
                    score += 1;
                }
            }
        }
        DetectedEncoding::Gbk => {
            for c in decoded.chars() {
                let u = c as u32;
                if matches!(
                    c,
                    '简' | '体'
                        | '词'
                        | '测'
                        | '试'
                        | '电'
                        | '线'
                        | '说'
                        | '专'
                        | '辑'
                        | '乐'
                        | '团'
                        | '伦'
                        | '陈'
                        | '张'
                        | '刘'
                        | '黄'
                        | '叶'
                        | '爱'
                        | '梦'
                        | '风'
                        | '听'
                        | '声'
                        | '录'
                        | '演'
                        | '会'
                        | '语'
                        | '国'
                        | '台'
                        | '这'
                        | '们'
                ) {
                    score += 25;
                } else if (0x4E00..=0x9FFF).contains(&u) {
                    score += 3;
                }
            }
            for &b in bytes {
                if (0xB0..=0xD7).contains(&b) {
                    score += 1;
                }
            }
        }
        DetectedEncoding::EucKr => {
            for c in decoded.chars() {
                let u = c as u32;
                if (0xAC00..=0xD7A3).contains(&u) {
                    // Hangul syllables
                    score += 25;
                }
            }
        }
        _ => {}
    }
    score
}
