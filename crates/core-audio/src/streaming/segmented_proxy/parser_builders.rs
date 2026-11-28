use quick_xml::events::BytesStart;

use super::super::StreamError;
use super::manifest::{
    ActiveContainer, AdaptationSetRaw, DashSegment, ParsedDashManifest, RepresentationRaw,
    SegmentListRaw, SegmentTemplateRaw, TimelineEntryRaw,
};
use super::parser::{
    attr_value, expand_dash_template, join_base_url, parse_i64_attr, parse_iso8601_duration_ms,
    parse_u64_attr,
};

#[allow(clippy::too_many_arguments)]
pub(super) fn handle_start_element(
    e: &BytesStart<'_>,
    local: &[u8],
    is_empty: bool,
    stack: &mut Vec<ActiveContainer>,
    mpd_duration_ms: &mut Option<u64>,
    period_duration_ms: &mut Option<u64>,
    in_first_period: &mut bool,
    parsed_first_period: &mut bool,
    reading_base_url: &mut bool,
    current_as: &mut Option<AdaptationSetRaw>,
    current_rep: &mut Option<RepresentationRaw>,
    current_tmpl: &mut Option<SegmentTemplateRaw>,
    current_list: &mut Option<SegmentListRaw>,
) -> Result<(), StreamError> {
    match local {
        b"MPD" => {
            if let Some(dur) = attr_value(e, "mediaPresentationDuration") {
                *mpd_duration_ms = parse_iso8601_duration_ms(&dur);
            }
            if !is_empty {
                stack.push(ActiveContainer::Mpd);
            }
        }
        b"Period" => {
            if !*parsed_first_period {
                *in_first_period = true;
                if let Some(dur) = attr_value(e, "duration") {
                    *period_duration_ms = parse_iso8601_duration_ms(&dur);
                }
            }
            if !is_empty {
                stack.push(ActiveContainer::Period);
            }
        }
        b"BaseURL" if *in_first_period || stack.last() == Some(&ActiveContainer::Mpd) => {
            if !is_empty {
                *reading_base_url = true;
            }
        }
        b"AdaptationSet" if *in_first_period => {
            *current_as = Some(AdaptationSetRaw {
                content_type: attr_value(e, "contentType"),
                mime_type: attr_value(e, "mimeType"),
                codecs: attr_value(e, "codecs"),
                ..Default::default()
            });
            if !is_empty {
                stack.push(ActiveContainer::AdaptationSet);
            }
        }
        b"AudioChannelConfiguration" if *in_first_period => {
            if let Some(aset) = current_as.as_mut() {
                aset.has_audio_channel_config = true;
            }
            if let Some(rep) = current_rep.as_mut() {
                rep.is_audio = Some(true);
            }
            if !is_empty {
                stack.push(ActiveContainer::Other);
            }
        }
        b"Representation" if *in_first_period => {
            *current_rep = Some(RepresentationRaw {
                id: attr_value(e, "id").unwrap_or_else(|| "0".to_string()),
                bandwidth: parse_u64_attr(e, "bandwidth").unwrap_or(0),
                mime_type: attr_value(e, "mimeType"),
                codecs: attr_value(e, "codecs"),
                ..Default::default()
            });
            if !is_empty {
                stack.push(ActiveContainer::Representation);
            }
        }
        b"SegmentTemplate" if *in_first_period => {
            *current_tmpl = Some(SegmentTemplateRaw {
                initialization: attr_value(e, "initialization"),
                media: attr_value(e, "media"),
                timescale: parse_u64_attr(e, "timescale"),
                start_number: parse_u64_attr(e, "startNumber"),
                duration: parse_u64_attr(e, "duration"),
                presentation_time_offset: parse_u64_attr(e, "presentationTimeOffset"),
                timeline: Vec::new(),
            });
            if !is_empty {
                stack.push(ActiveContainer::SegmentTemplate);
            }
        }
        b"SegmentTimeline" if *in_first_period => {
            if !is_empty {
                stack.push(ActiveContainer::SegmentTimeline);
            }
        }
        b"S" if *in_first_period && stack.last() == Some(&ActiveContainer::SegmentTimeline) => {
            let d = parse_u64_attr(e, "d").ok_or_else(|| {
                StreamError::InvalidManifest(
                    "DASH SegmentTimeline <S> missing 'd' attribute".to_string(),
                )
            })?;
            let t = parse_u64_attr(e, "t");
            let r = parse_i64_attr(e, "r").unwrap_or(0);
            if let Some(tmpl) = current_tmpl.as_mut() {
                tmpl.timeline.push(TimelineEntryRaw { t, d, r });
            }
            if !is_empty {
                stack.push(ActiveContainer::Other);
            }
        }
        b"SegmentList" if *in_first_period => {
            *current_list = Some(SegmentListRaw {
                initialization_url: None,
                timescale: parse_u64_attr(e, "timescale"),
                duration: parse_u64_attr(e, "duration"),
                segment_urls: Vec::new(),
            });
            if !is_empty {
                stack.push(ActiveContainer::SegmentList);
            }
        }
        b"Initialization"
            if *in_first_period && stack.last() == Some(&ActiveContainer::SegmentList) =>
        {
            if let Some(src) = attr_value(e, "sourceURL")
                && let Some(list) = current_list.as_mut()
            {
                list.initialization_url = Some(src);
            }
            if !is_empty {
                stack.push(ActiveContainer::Other);
            }
        }
        b"SegmentURL"
            if *in_first_period && stack.last() == Some(&ActiveContainer::SegmentList) =>
        {
            if let Some(media) = attr_value(e, "media")
                && let Some(list) = current_list.as_mut()
            {
                list.segment_urls.push(media);
            }
            if !is_empty {
                stack.push(ActiveContainer::Other);
            }
        }
        _ => {
            if !is_empty {
                stack.push(ActiveContainer::Other);
            }
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(super) fn handle_end_element(
    local: &[u8],
    stack: &mut Vec<ActiveContainer>,
    in_first_period: &mut bool,
    parsed_first_period: &mut bool,
    reading_base_url: &mut bool,
    adaptation_sets: &mut Vec<AdaptationSetRaw>,
    current_as: &mut Option<AdaptationSetRaw>,
    current_rep: &mut Option<RepresentationRaw>,
    current_tmpl: &mut Option<SegmentTemplateRaw>,
    current_list: &mut Option<SegmentListRaw>,
) {
    match local {
        b"BaseURL" => {
            *reading_base_url = false;
        }
        b"SegmentTemplate" => {
            if let Some(tmpl) = current_tmpl.take() {
                if let Some(rep) = current_rep.as_mut() {
                    rep.segment_template = Some(tmpl);
                } else if let Some(aset) = current_as.as_mut() {
                    aset.segment_template = Some(tmpl);
                }
            }
            if stack.last() == Some(&ActiveContainer::SegmentTemplate) {
                stack.pop();
            }
        }
        b"SegmentList" => {
            if let Some(list) = current_list.take() {
                if let Some(rep) = current_rep.as_mut() {
                    rep.segment_list = Some(list);
                } else if let Some(aset) = current_as.as_mut() {
                    aset.segment_list = Some(list);
                }
            }
            if stack.last() == Some(&ActiveContainer::SegmentList) {
                stack.pop();
            }
        }
        b"SegmentTimeline" => {
            if stack.last() == Some(&ActiveContainer::SegmentTimeline) {
                stack.pop();
            }
        }
        b"Representation" => {
            if let Some(rep) = current_rep.take()
                && let Some(aset) = current_as.as_mut()
            {
                aset.representations.push(rep);
            }
            if stack.last() == Some(&ActiveContainer::Representation) {
                stack.pop();
            }
        }
        b"AdaptationSet" => {
            if let Some(aset) = current_as.take() {
                adaptation_sets.push(aset);
            }
            if stack.last() == Some(&ActiveContainer::AdaptationSet) {
                stack.pop();
            }
        }
        b"Period" => {
            if *in_first_period {
                *in_first_period = false;
                *parsed_first_period = true;
            }
            if stack.last() == Some(&ActiveContainer::Period) {
                stack.pop();
            }
        }
        b"MPD" => {
            if stack.last() == Some(&ActiveContainer::Mpd) {
                stack.pop();
            }
        }
        b"SegmentURL" | b"Initialization" | b"S" | b"AudioChannelConfiguration" => {
            if stack.last() == Some(&ActiveContainer::Other) {
                stack.pop();
            }
        }
        _ => {
            if stack.last() == Some(&ActiveContainer::Other) {
                stack.pop();
            }
        }
    }
}

pub(super) fn build_segments_from_template(
    tmpl: &SegmentTemplateRaw,
    rep: &RepresentationRaw,
    base_url: Option<&str>,
    mime_type: Option<String>,
    codecs: Option<String>,
    duration_ms: Option<u64>,
) -> Result<ParsedDashManifest, StreamError> {
    let timescale = tmpl.timescale.unwrap_or(1).max(1);
    let start_number = tmpl.start_number.unwrap_or(1);
    let pto = tmpl.presentation_time_offset.unwrap_or(0);

    let init_url = tmpl
        .initialization
        .as_deref()
        .map(|raw| {
            let expanded = expand_dash_template(raw, &rep.id, rep.bandwidth, start_number, 0);
            join_base_url(base_url, &expanded)
        })
        .transpose()?;

    let media_tmpl = tmpl.media.as_deref().ok_or_else(|| {
        StreamError::InvalidManifest("DASH SegmentTemplate missing 'media' attribute".to_string())
    })?;

    let mut segments = Vec::new();
    if !tmpl.timeline.is_empty() {
        let mut cursor_ticks = 0u64;
        for entry in &tmpl.timeline {
            if let Some(t) = entry.t {
                cursor_ticks = t;
            }
            if entry.d == 0 {
                return Err(StreamError::InvalidManifest(
                    "DASH SegmentTimeline <S> has d=0".to_string(),
                ));
            }
            let repeat_count = if entry.r < 0 {
                1
            } else {
                (entry.r as usize) + 1
            };
            for _ in 0..repeat_count {
                let index = segments.len();
                let number = start_number + index as u64;
                let rel_ticks = cursor_ticks.saturating_sub(pto);
                let start_ms = ((rel_ticks as u128 * 1000) / timescale as u128) as u64;
                let seg_dur_ms = ((entry.d as u128 * 1000) / timescale as u128) as u64;
                let expanded =
                    expand_dash_template(media_tmpl, &rep.id, rep.bandwidth, number, cursor_ticks);
                let url = join_base_url(base_url, &expanded)?;
                segments.push(DashSegment {
                    index,
                    number,
                    time: cursor_ticks,
                    start_ms,
                    duration_ms: seg_dur_ms,
                    url,
                });
                cursor_ticks = cursor_ticks.saturating_add(entry.d);
            }
        }
    } else if let Some(fixed_dur) = tmpl.duration.filter(|&d| d > 0) {
        let pres_ms = duration_ms.ok_or_else(|| {
            StreamError::InvalidManifest(
                "DASH fixed-duration SegmentTemplate requires mediaPresentationDuration or Period duration"
                    .to_string(),
            )
        })?;
        let total_ticks = ((pres_ms as u128) * (timescale as u128)).div_ceil(1000);
        let seg_count = total_ticks.div_ceil(fixed_dur as u128).max(1) as usize;
        for index in 0..seg_count {
            let number = start_number + index as u64;
            let time = (index as u64).saturating_mul(fixed_dur);
            let start_ms = ((time as u128 * 1000) / timescale as u128) as u64;
            let seg_dur_ms = ((fixed_dur as u128 * 1000) / timescale as u128) as u64;
            let expanded = expand_dash_template(media_tmpl, &rep.id, rep.bandwidth, number, time);
            let url = join_base_url(base_url, &expanded)?;
            segments.push(DashSegment {
                index,
                number,
                time,
                start_ms,
                duration_ms: seg_dur_ms,
                url,
            });
        }
    } else {
        return Err(StreamError::InvalidManifest(
            "DASH SegmentTemplate requires either SegmentTimeline or fixed duration".to_string(),
        ));
    }

    if segments.is_empty() {
        return Err(StreamError::InvalidManifest(
            "DASH SegmentTemplate produced 0 segments".to_string(),
        ));
    }

    let computed_duration_ms = duration_ms.or_else(|| {
        segments
            .last()
            .map(|last| last.start_ms.saturating_add(last.duration_ms))
    });

    Ok(ParsedDashManifest {
        init_url,
        segments,
        bandwidth: rep.bandwidth,
        mime_type,
        codecs,
        duration_ms: computed_duration_ms,
    })
}

pub(super) fn build_segments_from_list(
    list: &SegmentListRaw,
    rep: &RepresentationRaw,
    base_url: Option<&str>,
    mime_type: Option<String>,
    codecs: Option<String>,
    duration_ms: Option<u64>,
) -> Result<ParsedDashManifest, StreamError> {
    if list.segment_urls.is_empty() {
        return Err(StreamError::InvalidManifest(
            "DASH SegmentList contained no SegmentURL elements".to_string(),
        ));
    }

    let init_url = list
        .initialization_url
        .as_deref()
        .map(|u| join_base_url(base_url, u))
        .transpose()?;

    let timescale = list.timescale.unwrap_or(1).max(1);
    let per_seg_ms = list
        .duration
        .map(|d| ((d as u128 * 1000) / timescale as u128) as u64)
        .or_else(|| duration_ms.map(|total| total / list.segment_urls.len() as u64))
        .unwrap_or(0);

    let mut segments = Vec::with_capacity(list.segment_urls.len());
    for (index, raw_url) in list.segment_urls.iter().enumerate() {
        let url = join_base_url(base_url, raw_url)?;
        let start_ms = (index as u64).saturating_mul(per_seg_ms);
        segments.push(DashSegment {
            index,
            number: (index + 1) as u64,
            time: 0,
            start_ms,
            duration_ms: per_seg_ms,
            url,
        });
    }

    Ok(ParsedDashManifest {
        init_url,
        segments,
        bandwidth: rep.bandwidth,
        mime_type,
        codecs,
        duration_ms,
    })
}
