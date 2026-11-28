use quick_xml::Reader;
use quick_xml::events::{BytesStart, Event};

use super::super::StreamError;
use super::manifest::{
    ActiveContainer, AdaptationSetRaw, DashSegment, ParsedDashManifest, RepresentationRaw,
    SegmentListRaw, SegmentTemplateRaw,
};
use super::parser_builders::{
    build_segments_from_list, build_segments_from_template, handle_end_element,
    handle_start_element,
};

/// Parses an ISO 8601 duration string (e.g. `PT3M45.5S`, `PT1H2M3S`, `P0DT4M12S`) to milliseconds.
pub fn parse_iso8601_duration_ms(input: &str) -> Option<u64> {
    let s = input.trim();
    if !s.starts_with('P') {
        return None;
    }
    let rest = &s[1..];
    let (date_part, time_part) = match rest.split_once('T') {
        Some((d, t)) => (d, Some(t)),
        None => (rest, None),
    };

    let mut total_secs = 0.0f64;
    let mut num_buf = String::new();
    for ch in date_part.chars() {
        if ch.is_ascii_digit() || ch == '.' {
            num_buf.push(ch);
        } else {
            let val: f64 = num_buf.parse().ok()?;
            num_buf.clear();
            match ch {
                'D' => total_secs += val * 86_400.0,
                'W' => total_secs += val * 7.0 * 86_400.0,
                'M' => total_secs += val * 30.0 * 86_400.0,
                'Y' => total_secs += val * 365.0 * 86_400.0,
                _ => return None,
            }
        }
    }
    if !num_buf.is_empty() {
        return None;
    }

    if let Some(tp) = time_part {
        for ch in tp.chars() {
            if ch.is_ascii_digit() || ch == '.' {
                num_buf.push(ch);
            } else {
                let val: f64 = num_buf.parse().ok()?;
                num_buf.clear();
                match ch {
                    'H' => total_secs += val * 3600.0,
                    'M' => total_secs += val * 60.0,
                    'S' => total_secs += val,
                    _ => return None,
                }
            }
        }
        if !num_buf.is_empty() {
            return None;
        }
    }

    if !total_secs.is_finite() || total_secs < 0.0 {
        return None;
    }
    Some((total_secs * 1000.0).round() as u64)
}

pub(super) fn local_tag_name(raw: &[u8]) -> &[u8] {
    match raw.iter().rposition(|&b| b == b':') {
        Some(idx) => &raw[idx + 1..],
        None => raw,
    }
}

pub(super) fn attr_value(e: &BytesStart<'_>, target: &str) -> Option<String> {
    for attr in e.attributes().flatten() {
        let key = attr.key.as_ref();
        let local = local_tag_name(key);
        if local == target.as_bytes()
            && let Ok(val) = attr.unescape_value()
        {
            return Some(val.into_owned());
        }
    }
    None
}

pub(super) fn parse_u64_attr(e: &BytesStart<'_>, target: &str) -> Option<u64> {
    attr_value(e, target)?.trim().parse::<u64>().ok()
}

pub(super) fn parse_i64_attr(e: &BytesStart<'_>, target: &str) -> Option<i64> {
    attr_value(e, target)?.trim().parse::<i64>().ok()
}

pub(super) fn join_base_url(parent: Option<&str>, child: &str) -> Result<String, StreamError> {
    let trimmed = child.trim();
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        return Ok(trimmed.to_string());
    }
    let Some(base) = parent else {
        return Err(StreamError::InvalidManifest(format!(
            "Relative DASH URL '{trimmed}' requires a BaseURL"
        )));
    };
    let parsed_base = reqwest::Url::parse(base)
        .map_err(|e| StreamError::InvalidManifest(format!("Invalid DASH BaseURL '{base}': {e}")))?;
    let joined = parsed_base.join(trimmed).map_err(|e| {
        StreamError::InvalidManifest(format!(
            "Failed to join DASH URL '{trimmed}' against '{base}': {e}"
        ))
    })?;
    Ok(joined.to_string())
}

pub(super) fn expand_dash_template(
    template: &str,
    rep_id: &str,
    bandwidth: u64,
    number: u64,
    time: u64,
) -> String {
    let mut out = String::with_capacity(template.len() + 16);
    let chars: Vec<char> = template.chars().collect();
    let mut i = 0usize;
    while i < chars.len() {
        if chars[i] != '$' {
            out.push(chars[i]);
            i += 1;
            continue;
        }
        if let Some(rel_end) = chars[i + 1..].iter().position(|&c| c == '$') {
            let token: String = chars[i + 1..i + 1 + rel_end].iter().collect();
            if token.is_empty() {
                out.push('$');
            } else if token == "RepresentationID" {
                out.push_str(rep_id);
            } else if let Some(rest) = token.strip_prefix("Bandwidth") {
                out.push_str(&format_dash_number(bandwidth, rest));
            } else if let Some(rest) = token.strip_prefix("Number") {
                out.push_str(&format_dash_number(number, rest));
            } else if let Some(rest) = token.strip_prefix("Time") {
                out.push_str(&format_dash_number(time, rest));
            } else {
                out.push('$');
                out.push_str(&token);
                out.push('$');
            }
            i += rel_end + 2;
        } else {
            out.push('$');
            i += 1;
        }
    }
    out
}

pub(super) fn format_dash_number(val: u64, format_suffix: &str) -> String {
    if let Some(spec) = format_suffix.strip_prefix('%')
        && let Some(width_str) = spec.strip_suffix('d')
        && let Ok(width) = width_str.trim_start_matches('0').parse::<usize>()
    {
        return format!("{val:0width$}");
    }
    val.to_string()
}

/// Parses an unencrypted MPEG-DASH MPD XML document into a resolved segment list for the
/// highest-bandwidth audio representation.
pub fn parse_mpd_xml(xml: &str, base_url: Option<&str>) -> Result<ParsedDashManifest, StreamError> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);

    let mut stack: Vec<ActiveContainer> = Vec::new();
    let mut mpd_duration_ms: Option<u64> = None;
    let mut period_duration_ms: Option<u64> = None;
    let mut mpd_base_url: Option<String> = base_url.map(str::to_string);
    let mut period_base_url: Option<String> = None;
    let mut in_first_period = false;
    let mut parsed_first_period = false;
    let mut reading_base_url = false;

    let mut adaptation_sets: Vec<AdaptationSetRaw> = Vec::new();
    let mut current_as: Option<AdaptationSetRaw> = None;
    let mut current_rep: Option<RepresentationRaw> = None;
    let mut current_tmpl: Option<SegmentTemplateRaw> = None;
    let mut current_list: Option<SegmentListRaw> = None;

    let mut buf = Vec::new();
    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(e)) => {
                let local = local_tag_name(e.name().as_ref()).to_vec();
                if local.eq_ignore_ascii_case(b"ContentProtection") {
                    return Err(StreamError::DrmRestricted(
                        "DASH MPD contains ContentProtection DRM".to_string(),
                    ));
                }
                handle_start_element(
                    &e,
                    &local,
                    false,
                    &mut stack,
                    &mut mpd_duration_ms,
                    &mut period_duration_ms,
                    &mut in_first_period,
                    &mut parsed_first_period,
                    &mut reading_base_url,
                    &mut current_as,
                    &mut current_rep,
                    &mut current_tmpl,
                    &mut current_list,
                )?;
            }
            Ok(Event::Empty(e)) => {
                let local = local_tag_name(e.name().as_ref()).to_vec();
                if local.eq_ignore_ascii_case(b"ContentProtection") {
                    return Err(StreamError::DrmRestricted(
                        "DASH MPD contains ContentProtection DRM".to_string(),
                    ));
                }
                handle_start_element(
                    &e,
                    &local,
                    true,
                    &mut stack,
                    &mut mpd_duration_ms,
                    &mut period_duration_ms,
                    &mut in_first_period,
                    &mut parsed_first_period,
                    &mut reading_base_url,
                    &mut current_as,
                    &mut current_rep,
                    &mut current_tmpl,
                    &mut current_list,
                )?;
                handle_end_element(
                    &local,
                    &mut stack,
                    &mut in_first_period,
                    &mut parsed_first_period,
                    &mut reading_base_url,
                    &mut adaptation_sets,
                    &mut current_as,
                    &mut current_rep,
                    &mut current_tmpl,
                    &mut current_list,
                );
            }
            Ok(Event::Text(e)) => {
                if reading_base_url {
                    let text = e.unescape().map_err(|err| {
                        StreamError::InvalidManifest(format!("Invalid BaseURL text: {err}"))
                    })?;
                    let trimmed = text.trim();
                    if !trimmed.is_empty() {
                        let parent_container = stack.last().copied();
                        match parent_container {
                            Some(ActiveContainer::Mpd) => {
                                mpd_base_url =
                                    Some(join_base_url(mpd_base_url.as_deref(), trimmed)?);
                            }
                            Some(ActiveContainer::Period) if in_first_period => {
                                let parent = period_base_url.as_deref().or(mpd_base_url.as_deref());
                                period_base_url = Some(join_base_url(parent, trimmed)?);
                            }
                            Some(ActiveContainer::AdaptationSet) if in_first_period => {
                                if let Some(ref mut aset) = current_as {
                                    let parent = aset
                                        .base_url
                                        .as_deref()
                                        .or(period_base_url.as_deref())
                                        .or(mpd_base_url.as_deref());
                                    aset.base_url = Some(join_base_url(parent, trimmed)?);
                                }
                            }
                            Some(ActiveContainer::Representation) if in_first_period => {
                                if let Some(ref mut rep) = current_rep {
                                    let parent = rep
                                        .base_url
                                        .as_deref()
                                        .or(current_as.as_ref().and_then(|a| a.base_url.as_deref()))
                                        .or(period_base_url.as_deref())
                                        .or(mpd_base_url.as_deref());
                                    rep.base_url = Some(join_base_url(parent, trimmed)?);
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
            Ok(Event::End(e)) => {
                let local = local_tag_name(e.name().as_ref()).to_vec();
                handle_end_element(
                    &local,
                    &mut stack,
                    &mut in_first_period,
                    &mut parsed_first_period,
                    &mut reading_base_url,
                    &mut adaptation_sets,
                    &mut current_as,
                    &mut current_rep,
                    &mut current_tmpl,
                    &mut current_list,
                );
            }
            Ok(Event::Eof) => break,
            Err(e) => {
                return Err(StreamError::InvalidManifest(format!(
                    "Failed to parse DASH MPD XML: {e}"
                )));
            }
            _ => {}
        }
        buf.clear();
    }

    if adaptation_sets.is_empty() {
        return Err(StreamError::InvalidManifest(
            "DASH MPD contained no AdaptationSet elements".to_string(),
        ));
    }

    let duration_ms = period_duration_ms.or(mpd_duration_ms);
    let effective_period_base = period_base_url.or(mpd_base_url);

    let mut audio_candidates: Vec<(
        &AdaptationSetRaw,
        &RepresentationRaw,
        Option<String>,
        Option<String>,
    )> = Vec::new();
    let mut untyped_candidates: Vec<(
        &AdaptationSetRaw,
        &RepresentationRaw,
        Option<String>,
        Option<String>,
    )> = Vec::new();

    for aset in &adaptation_sets {
        let as_is_audio = aset
            .content_type
            .as_deref()
            .is_some_and(|ct| ct.eq_ignore_ascii_case("audio"))
            || aset
                .mime_type
                .as_deref()
                .is_some_and(|m| m.to_ascii_lowercase().starts_with("audio/"))
            || aset.has_audio_channel_config;
        let as_is_non_audio = aset
            .content_type
            .as_deref()
            .is_some_and(|ct| !ct.eq_ignore_ascii_case("audio"))
            || aset.mime_type.as_deref().is_some_and(|m| {
                let low = m.to_ascii_lowercase();
                !low.starts_with("audio/") && !low.is_empty()
            });

        for rep in &aset.representations {
            let eff_mime = rep.mime_type.clone().or_else(|| aset.mime_type.clone());
            let eff_codecs = rep.codecs.clone().or_else(|| aset.codecs.clone());
            let rep_is_audio = as_is_audio
                || rep.is_audio == Some(true)
                || eff_mime
                    .as_deref()
                    .is_some_and(|m| m.to_ascii_lowercase().starts_with("audio/"));
            let rep_is_non_audio = as_is_non_audio
                || rep.is_audio == Some(false)
                || eff_mime.as_deref().is_some_and(|m| {
                    let low = m.to_ascii_lowercase();
                    !low.starts_with("audio/") && !low.is_empty()
                });

            if rep_is_audio {
                audio_candidates.push((aset, rep, eff_mime, eff_codecs));
            } else if !rep_is_non_audio {
                untyped_candidates.push((aset, rep, eff_mime, eff_codecs));
            }
        }
    }

    let pool = if !audio_candidates.is_empty() {
        audio_candidates
    } else {
        untyped_candidates
    };

    let (chosen_as, chosen_rep, chosen_mime, chosen_codecs) = pool
        .into_iter()
        .max_by_key(|(_, rep, _, _)| rep.bandwidth)
        .ok_or_else(|| {
            StreamError::InvalidManifest(
                "DASH MPD contained no playable audio Representation".to_string(),
            )
        })?;

    let rep_base_url = chosen_rep
        .base_url
        .clone()
        .or_else(|| chosen_as.base_url.clone())
        .or(effective_period_base);

    let merged_tmpl = match (&chosen_as.segment_template, &chosen_rep.segment_template) {
        (Some(parent), Some(child)) => Some(parent.merged_with(child)),
        (None, Some(child)) => Some(child.clone()),
        (Some(parent), None) => Some(parent.clone()),
        (None, None) => None,
    };
    let merged_list = match (&chosen_as.segment_list, &chosen_rep.segment_list) {
        (Some(parent), Some(child)) => Some(parent.merged_with(child)),
        (None, Some(child)) => Some(child.clone()),
        (Some(parent), None) => Some(parent.clone()),
        (None, None) => None,
    };

    if let Some(tmpl) = merged_tmpl {
        build_segments_from_template(
            &tmpl,
            chosen_rep,
            rep_base_url.as_deref(),
            chosen_mime,
            chosen_codecs,
            duration_ms,
        )
    } else if let Some(list) = merged_list {
        build_segments_from_list(
            &list,
            chosen_rep,
            rep_base_url.as_deref(),
            chosen_mime,
            chosen_codecs,
            duration_ms,
        )
    } else if let Some(url) = rep_base_url {
        Ok(ParsedDashManifest {
            init_url: None,
            segments: vec![DashSegment {
                index: 0,
                number: 1,
                time: 0,
                start_ms: 0,
                duration_ms: duration_ms.unwrap_or(0),
                url,
            }],
            bandwidth: chosen_rep.bandwidth,
            mime_type: chosen_mime,
            codecs: chosen_codecs,
            duration_ms,
        })
    } else {
        Err(StreamError::InvalidManifest(
            "Selected DASH audio Representation has neither SegmentTemplate, SegmentList, nor BaseURL"
                .to_string(),
        ))
    }
}
