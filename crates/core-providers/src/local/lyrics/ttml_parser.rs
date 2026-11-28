use super::models::{
    LyricLine, LyricWord, LyricsFormat, LyricsKind, LyricsManager, LyricsResult, LyricsSource,
};

impl LyricsManager {
    /// Parses TTML XML timed text (`<p begin="..." end="...">` and word-level `<span begin="..." end="...">`).
    pub fn parse_ttml(content: &str, source: LyricsSource) -> Option<LyricsResult> {
        use quick_xml::Reader;
        use quick_xml::events::Event;

        let mut reader = Reader::from_str(content);
        reader.config_mut().trim_text(false);

        let mut lines: Vec<LyricLine> = Vec::new();
        let mut buf = Vec::new();

        let mut in_p = false;
        let mut p_start: Option<u64> = None;
        let mut p_end: Option<u64> = None;
        let mut p_text = String::new();
        let mut p_words: Vec<LyricWord> = Vec::new();

        let mut in_span = false;
        let mut span_start: Option<u64> = None;
        let mut span_end: Option<u64> = None;
        let mut span_text = String::new();

        loop {
            match reader.read_event_into(&mut buf) {
                Ok(Event::Start(ref e)) => {
                    let local =
                        String::from_utf8_lossy(e.local_name().as_ref()).to_ascii_lowercase();
                    match local.as_str() {
                        "p" => {
                            in_p = true;
                            p_start = None;
                            p_end = None;
                            p_text.clear();
                            p_words.clear();
                            for attr in e.attributes().flatten() {
                                let k = String::from_utf8_lossy(attr.key.local_name().as_ref())
                                    .to_ascii_lowercase();
                                let v = String::from_utf8_lossy(&attr.value);
                                if k == "begin" {
                                    p_start = parse_ttml_time_ms(&v);
                                } else if k == "end" {
                                    p_end = parse_ttml_time_ms(&v);
                                }
                            }
                        }
                        "span" if in_p => {
                            in_span = true;
                            span_start = None;
                            span_end = None;
                            span_text.clear();
                            for attr in e.attributes().flatten() {
                                let k = String::from_utf8_lossy(attr.key.local_name().as_ref())
                                    .to_ascii_lowercase();
                                let v = String::from_utf8_lossy(&attr.value);
                                if k == "begin" {
                                    span_start = parse_ttml_time_ms(&v);
                                } else if k == "end" {
                                    span_end = parse_ttml_time_ms(&v);
                                }
                            }
                        }
                        _ => {}
                    }
                }
                Ok(Event::Text(ref e)) => {
                    if in_p {
                        let txt = e.unescape().unwrap_or_default();
                        if in_span {
                            span_text.push_str(&txt);
                        } else {
                            p_text.push_str(&txt);
                        }
                    }
                }
                Ok(Event::End(ref e)) => {
                    let local =
                        String::from_utf8_lossy(e.local_name().as_ref()).to_ascii_lowercase();
                    match local.as_str() {
                        "span" if in_span => {
                            let cleaned = span_text.trim();
                            if !cleaned.is_empty() {
                                if !p_text.is_empty() && !p_text.ends_with(char::is_whitespace) {
                                    p_text.push(' ');
                                }
                                p_text.push_str(cleaned);
                                if let Some(ws) = span_start {
                                    let we = span_end.unwrap_or(ws);
                                    p_words.push(LyricWord {
                                        text: cleaned.to_string(),
                                        start_ms: ws,
                                        end_ms: we.max(ws),
                                    });
                                }
                            }
                            in_span = false;
                            span_text.clear();
                        }
                        "p" if in_p => {
                            let collapsed: String =
                                p_text.split_whitespace().collect::<Vec<_>>().join(" ");
                            if !collapsed.is_empty() {
                                let effective_start =
                                    p_start.or_else(|| p_words.first().map(|w| w.start_ms));
                                let effective_end =
                                    p_end.or_else(|| p_words.last().map(|w| w.end_ms));
                                lines.push(LyricLine {
                                    start_ms: effective_start,
                                    end_ms: effective_end,
                                    text: collapsed,
                                    words: std::mem::take(&mut p_words),
                                });
                            }
                            in_p = false;
                            in_span = false;
                            p_text.clear();
                        }
                        _ => {}
                    }
                }
                Ok(Event::Eof) => break,
                Err(_) => return None,
                _ => {}
            }
            buf.clear();
        }

        if lines.is_empty() {
            return None;
        }

        lines.sort_by_key(|l| l.start_ms.unwrap_or(u64::MAX));
        let has_timing = lines.iter().any(|l| l.start_ms.is_some());

        Some(LyricsResult {
            found: true,
            kind: if has_timing {
                LyricsKind::Synced
            } else {
                LyricsKind::Unsynced
            },
            source,
            format: LyricsFormat::Ttml,
            offset_ms: 0,
            lines,
        })
    }
}

pub(super) fn is_ttml_content(content: &str) -> bool {
    let trimmed = content.trim_start_matches('\u{FEFF}').trim_start();
    (trimmed.starts_with("<?xml") || trimmed.starts_with("<tt"))
        && (trimmed.contains("<tt") && trimmed.contains("<p"))
}

fn parse_ttml_time_ms(raw: &str) -> Option<u64> {
    let s = raw.trim();
    if s.is_empty() {
        return None;
    }
    if let Some(ms_str) = s.strip_suffix("ms") {
        let val = ms_str.trim().parse::<f64>().ok()?;
        return (val.is_finite() && val >= 0.0).then_some(val.round() as u64);
    }
    if let Some(sec_str) = s.strip_suffix('s') {
        let val = sec_str.trim().parse::<f64>().ok()?;
        return (val.is_finite() && val >= 0.0).then_some((val * 1000.0).round() as u64);
    }

    let parts: Vec<&str> = s.split(':').collect();
    match parts.len() {
        3 => {
            let hours = parts[0].trim().parse::<u64>().ok()?;
            let mins = parts[1].trim().parse::<u64>().ok()?;
            let secs = parts[2].trim().parse::<f64>().ok()?;
            if !secs.is_finite() || secs < 0.0 {
                return None;
            }
            Some(hours * 3_600_000 + mins * 60_000 + (secs * 1000.0).round() as u64)
        }
        2 => {
            let mins = parts[0].trim().parse::<u64>().ok()?;
            let secs = parts[1].trim().parse::<f64>().ok()?;
            if !secs.is_finite() || secs < 0.0 {
                return None;
            }
            Some(mins * 60_000 + (secs * 1000.0).round() as u64)
        }
        _ => None,
    }
}
