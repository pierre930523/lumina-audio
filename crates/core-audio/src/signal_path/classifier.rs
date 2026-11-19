use core_types::{AudioFormat, OutputBackendKind, SignalPath, SignalPathNode, SignalQuality};
use crate::dsp::DspPipeline;

/// Configuration for inspecting and generating a transparent Roon-style Signal Path.
#[derive(Debug, Clone)]
pub struct SignalPathContext<'a> {
    pub source_label: &'a str,
    pub format: &'a AudioFormat,
    pub dsp_bypass: bool,
    pub dsp_active: bool,
    pub resampled_to_hz: Option<u32>,
    pub backend: OutputBackendKind,
    pub device_name: &'a str,
}

pub struct SignalPathEngine;

impl SignalPathEngine {
    /// Builds a full, transparent Signal Path adhering to strict stage ordering:
    /// `Source` -> `64-bit DSP` -> `Sample Rate Conversion` -> `Output`.
    pub fn build(ctx: &SignalPathContext<'_>) -> SignalPath {
        Self::build_with_dsp_detail(ctx, None)
    }

    /// Builds a full Signal Path with an optional custom description for the `64-bit DSP` node.
    pub fn build_with_dsp_detail(ctx: &SignalPathContext<'_>, dsp_detail: Option<&str>) -> SignalPath {
        let mut nodes = Vec::new();
        let mut overall = SignalQuality::Lossless;

        // 1. Source Stage
        let dsd_str = if ctx.format.is_dsd { " DSD" } else { "" };
        let label = ctx.source_label;

        let src_desc = format!(
            "{} ({}-bit / {} Hz{})",
            label,
            ctx.format.bit_depth,
            ctx.format.sample_rate_hz,
            dsd_str
        );

        let source_quality = if ctx.format.codec.is_lossless() {
            SignalQuality::Lossless
        } else {
            overall = SignalQuality::HighQuality;
            SignalQuality::HighQuality
        };

        nodes.push(SignalPathNode {
            stage: "Source".into(),
            detail: src_desc,
            quality: source_quality,
        });

        // 2. 64-bit DSP Stage (omitted if bypassed or completely inactive)
        if !ctx.dsp_bypass && ctx.dsp_active {
            if overall != SignalQuality::HighQuality {
                overall = SignalQuality::Enhanced;
            }
            nodes.push(SignalPathNode {
                stage: "64-bit DSP".into(),
                detail: dsp_detail
                    .filter(|s| !s.trim().is_empty())
                    .unwrap_or("Active (PEQ / Crossfeed / Gain)")
                    .to_string(),
                quality: SignalQuality::Enhanced,
            });
        }

        // 3. Sample Rate Conversion Stage (SRC)
        if let Some(target_hz) = ctx.resampled_to_hz {
            if overall != SignalQuality::HighQuality {
                overall = SignalQuality::Enhanced;
            }
            nodes.push(SignalPathNode {
                stage: "Sample Rate Conversion".into(),
                detail: format!(
                    "{} Hz -> {} Hz (64-bit Sinc)",
                    ctx.format.sample_rate_hz, target_hz
                ),
                quality: SignalQuality::Enhanced,
            });
        }

        // 4. Output Stage
        let out_quality = match ctx.backend {
            OutputBackendKind::WindowsAsio
            | OutputBackendKind::WindowsWasapiExclusive
            | OutputBackendKind::MacOsCoreAudioHog
            | OutputBackendKind::MobileDirect => SignalQuality::Lossless,
            OutputBackendKind::WindowsWasapiShared => {
                overall = SignalQuality::HighQuality;
                SignalQuality::HighQuality
            }
            _ => {
                if overall != SignalQuality::HighQuality {
                    overall = SignalQuality::Enhanced;
                }
                SignalQuality::Enhanced
            }
        };

        nodes.push(SignalPathNode {
            stage: "Output".into(),
            detail: format!("{} ({:?})", ctx.device_name, ctx.backend),
            quality: out_quality,
        });

        SignalPath { overall, nodes }
    }

    /// Evaluates signal path directly from a live DspPipeline instance.
    pub fn build_from_dsp(
        source_label: &str,
        format: &AudioFormat,
        dsp: &DspPipeline,
        resampled_to_hz: Option<u32>,
        backend: OutputBackendKind,
        device_name: &str,
    ) -> SignalPath {
        let ctx = SignalPathContext {
            source_label,
            format,
            dsp_bypass: dsp.is_bypassed(),
            dsp_active: dsp.is_dsp_active(),
            resampled_to_hz,
            backend,
            device_name,
        };
        Self::build(&ctx)
    }
}
