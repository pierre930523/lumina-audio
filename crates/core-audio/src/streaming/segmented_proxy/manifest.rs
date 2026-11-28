use super::super::l2_cache::DashL2Package;
use super::super::{FormatMismatchReason, normalize_mime_base};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DashSegment {
    pub index: usize,
    pub number: u64,
    pub time: u64,
    pub start_ms: u64,
    pub duration_ms: u64,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedDashManifest {
    pub init_url: Option<String>,
    pub segments: Vec<DashSegment>,
    pub bandwidth: u64,
    pub mime_type: Option<String>,
    pub codecs: Option<String>,
    pub duration_ms: Option<u64>,
}

#[derive(Debug, Clone, Default)]
pub(super) struct SegmentTemplateRaw {
    pub(super) initialization: Option<String>,
    pub(super) media: Option<String>,
    pub(super) timescale: Option<u64>,
    pub(super) start_number: Option<u64>,
    pub(super) duration: Option<u64>,
    pub(super) presentation_time_offset: Option<u64>,
    pub(super) timeline: Vec<TimelineEntryRaw>,
}

impl SegmentTemplateRaw {
    pub(super) fn merged_with(&self, child: &Self) -> Self {
        Self {
            initialization: child
                .initialization
                .clone()
                .or_else(|| self.initialization.clone()),
            media: child.media.clone().or_else(|| self.media.clone()),
            timescale: child.timescale.or(self.timescale),
            start_number: child.start_number.or(self.start_number),
            duration: child.duration.or(self.duration),
            presentation_time_offset: child
                .presentation_time_offset
                .or(self.presentation_time_offset),
            timeline: if !child.timeline.is_empty() {
                child.timeline.clone()
            } else {
                self.timeline.clone()
            },
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub(super) struct TimelineEntryRaw {
    pub(super) t: Option<u64>,
    pub(super) d: u64,
    pub(super) r: i64,
}

#[derive(Debug, Clone, Default)]
pub(super) struct SegmentListRaw {
    pub(super) initialization_url: Option<String>,
    pub(super) timescale: Option<u64>,
    pub(super) duration: Option<u64>,
    pub(super) segment_urls: Vec<String>,
}

impl SegmentListRaw {
    pub(super) fn merged_with(&self, child: &Self) -> Self {
        Self {
            initialization_url: child
                .initialization_url
                .clone()
                .or_else(|| self.initialization_url.clone()),
            timescale: child.timescale.or(self.timescale),
            duration: child.duration.or(self.duration),
            segment_urls: if !child.segment_urls.is_empty() {
                child.segment_urls.clone()
            } else {
                self.segment_urls.clone()
            },
        }
    }
}

#[derive(Debug, Clone, Default)]
pub(super) struct RepresentationRaw {
    pub(super) id: String,
    pub(super) bandwidth: u64,
    pub(super) mime_type: Option<String>,
    pub(super) codecs: Option<String>,
    pub(super) base_url: Option<String>,
    pub(super) segment_template: Option<SegmentTemplateRaw>,
    pub(super) segment_list: Option<SegmentListRaw>,
    pub(super) is_audio: Option<bool>,
}

#[derive(Debug, Clone, Default)]
pub(super) struct AdaptationSetRaw {
    pub(super) content_type: Option<String>,
    pub(super) mime_type: Option<String>,
    pub(super) codecs: Option<String>,
    pub(super) base_url: Option<String>,
    pub(super) segment_template: Option<SegmentTemplateRaw>,
    pub(super) segment_list: Option<SegmentListRaw>,
    pub(super) has_audio_channel_config: bool,
    pub(super) representations: Vec<RepresentationRaw>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ActiveContainer {
    Mpd,
    Period,
    AdaptationSet,
    Representation,
    SegmentTemplate,
    SegmentTimeline,
    SegmentList,
    Other,
}

pub(super) fn manifests_compatible(old: &ParsedDashManifest, new: &ParsedDashManifest) -> bool {
    if old.init_url.is_some() != new.init_url.is_some() {
        return false;
    }
    if let (Some(a), Some(b)) = (&old.mime_type, &new.mime_type)
        && normalize_mime_base(a) != normalize_mime_base(b)
    {
        return false;
    }
    if let (Some(a), Some(b)) = (&old.codecs, &new.codecs)
        && !a.trim().eq_ignore_ascii_case(b.trim())
    {
        return false;
    }
    if old.segments.len() != new.segments.len() {
        return false;
    }
    old.segments
        .iter()
        .zip(new.segments.iter())
        .all(|(a, b)| a.start_ms == b.start_ms && a.duration_ms == b.duration_ms)
}

/// Validates compatibility between a cached [`DashL2Package`] and a freshly parsed [`ParsedDashManifest`].
pub fn validate_dash_package_compatibility(
    pkg: &DashL2Package,
    manifest: &ParsedDashManifest,
) -> Result<(), FormatMismatchReason> {
    let pkg_has_init = !pkg.init_bytes.is_empty();
    let man_has_init = manifest.init_url.is_some();
    if pkg_has_init != man_has_init {
        return Err(FormatMismatchReason::DashSpecMismatch {
            detail: format!(
                "init presence mismatch (cached={pkg_has_init}, manifest={man_has_init})"
            ),
        });
    }

    if !pkg.mime_type.trim().is_empty()
        && let Some(ref man_mime) = manifest.mime_type
        && normalize_mime_base(&pkg.mime_type) != normalize_mime_base(man_mime)
    {
        return Err(FormatMismatchReason::DashSpecMismatch {
            detail: format!(
                "mime_type changed (cached={}, manifest={man_mime})",
                pkg.mime_type
            ),
        });
    }

    let pkg_codecs = pkg
        .codecs
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_ascii_lowercase);
    let man_codecs = manifest
        .codecs
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_ascii_lowercase);
    if pkg_codecs != man_codecs {
        return Err(FormatMismatchReason::DashSpecMismatch {
            detail: format!("codecs changed (cached={pkg_codecs:?}, manifest={man_codecs:?})"),
        });
    }

    if let (Some(cached_dur), Some(fresh_dur)) = (pkg.total_duration_ms, manifest.duration_ms)
        && cached_dur != fresh_dur
    {
        return Err(FormatMismatchReason::DashSpecMismatch {
            detail: format!("duration changed (cached={cached_dur}ms, manifest={fresh_dur}ms)"),
        });
    }

    if manifest.segments.len() < pkg.segments.len() {
        return Err(FormatMismatchReason::DashSpecMismatch {
            detail: format!(
                "segment count shrunk (cached={}, manifest={})",
                pkg.segments.len(),
                manifest.segments.len()
            ),
        });
    }

    for (idx, cached_seg) in pkg.segments.iter().enumerate() {
        let fresh = &manifest.segments[idx];
        if fresh.number != cached_seg.number
            || fresh.start_ms != cached_seg.start_ms
            || fresh.duration_ms != cached_seg.duration_ms
        {
            return Err(FormatMismatchReason::DashSpecMismatch {
                detail: format!(
                    "segment[{idx}] metadata changed (cached=#{}@{}ms+{}ms, manifest=#{}@{}ms+{}ms)",
                    cached_seg.number,
                    cached_seg.start_ms,
                    cached_seg.duration_ms,
                    fresh.number,
                    fresh.start_ms,
                    fresh.duration_ms
                ),
            });
        }
    }

    Ok(())
}

pub(crate) fn infer_dash_extension(mime: Option<&str>, codecs: Option<&str>) -> Option<String> {
    if let Some(m) = mime {
        let lower = m.to_ascii_lowercase();
        if lower.contains("webm") {
            return Some("webm".to_string());
        }
        if lower.contains("mp4") {
            return Some("m4a".to_string());
        }
    }
    if let Some(c) = codecs {
        let lower = c.to_ascii_lowercase();
        if lower.contains("opus") || lower.contains("vorbis") {
            return Some("webm".to_string());
        }
    }
    Some("m4a".to_string())
}
