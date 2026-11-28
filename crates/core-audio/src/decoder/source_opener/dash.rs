use std::collections::BTreeMap;
use std::sync::{Arc, mpsc};

use core_types::{StreamKey, StreamSourceSpec};
use tokio_util::sync::CancellationToken;

use super::http::{
    compute_l2_target_bytes_for_spec, run_on_streaming_runtime_cancellable,
    wait_for_l2_stable_play_gate,
};
use super::{
    L2PlayGateProbe, OpenedStreamDecoder, provider_needs_network_epoch_reset, stream_error_to_core,
};
use crate::decoder::pcm::{AudioDecoder, SymphoniaDecoder};
use crate::error::CoreAudioError;
use crate::streaming::{
    BlockingStreamBridge, DEFAULT_PREFETCH_AHEAD, DEFAULT_REFRESH_403_BACKOFFS,
    FormatMismatchCallback, HybridSegmentedConfig, HybridSegmentedStream, L2CacheManager,
    L2DashHit, ReqwestStreamTransport, SegmentedStreamProxy, StreamError, StreamHttpConfig,
    StreamRefreshHandler, should_admit_to_l2, streaming_runtime, subscribe_network_epoch,
};

fn open_segmented_proxy_sync(
    key: StreamKey,
    manifest_url_or_xml: String,
    headers: BTreeMap<String, String>,
    mime_type: Option<String>,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
) -> Result<SegmentedStreamProxy, CoreAudioError> {
    if cancel.is_cancelled() {
        return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
    }
    let rt = streaming_runtime().map_err(stream_error_to_core)?;
    let (tx, rx) = mpsc::sync_channel(1);
    let needs_epoch_reset = provider_needs_network_epoch_reset(&key.provider_id);
    rt.spawn(async move {
        let cancel_sel = cancel.clone();
        let res = tokio::select! {
            biased;
            _ = cancel_sel.cancelled() => Err(StreamError::Cancelled),
            r = async {
                let transport = Arc::new(ReqwestStreamTransport::shared()?);
                SegmentedStreamProxy::open_with_refresh(
                    manifest_url_or_xml,
                    &headers,
                    None,
                    mime_type,
                    transport,
                    StreamHttpConfig::default(),
                    cancel,
                    Some(key),
                    refresh_handler,
                    needs_epoch_reset,
                    DEFAULT_REFRESH_403_BACKOFFS,
                    subscribe_network_epoch(),
                )
                .await
            } => r,
        };
        let _ = tx.send(res);
    });
    rx.recv()
        .map_err(|_| CoreAudioError::Io(StreamError::Cancelled.to_io_error()))?
        .map_err(stream_error_to_core)
}

async fn open_segmented_proxy_async(
    key: StreamKey,
    manifest_url_or_xml: String,
    headers: BTreeMap<String, String>,
    mime_type: Option<String>,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
) -> Result<SegmentedStreamProxy, CoreAudioError> {
    if cancel.is_cancelled() {
        return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
    }
    let rt = streaming_runtime().map_err(stream_error_to_core)?;
    let (tx, rx) = tokio::sync::oneshot::channel();
    let needs_epoch_reset = provider_needs_network_epoch_reset(&key.provider_id);
    let cancel_outer = cancel.clone();
    rt.spawn(async move {
        let cancel_sel = cancel.clone();
        let res = tokio::select! {
            biased;
            _ = cancel_sel.cancelled() => Err(StreamError::Cancelled),
            r = async {
                let transport = Arc::new(ReqwestStreamTransport::shared()?);
                SegmentedStreamProxy::open_with_refresh(
                    manifest_url_or_xml,
                    &headers,
                    None,
                    mime_type,
                    transport,
                    StreamHttpConfig::default(),
                    cancel,
                    Some(key),
                    refresh_handler,
                    needs_epoch_reset,
                    DEFAULT_REFRESH_403_BACKOFFS,
                    subscribe_network_epoch(),
                )
                .await
            } => r,
        };
        let _ = tx.send(res);
    });
    tokio::select! {
        biased;
        _ = cancel_outer.cancelled() => Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error())),
        res = rx => res
            .map_err(|_| CoreAudioError::Io(StreamError::Cancelled.to_io_error()))?
            .map_err(stream_error_to_core),
    }
}

fn spawn_dash_l2_admission_task(
    l2: Arc<L2CacheManager>,
    spec: StreamSourceSpec,
    proxy: Arc<SegmentedStreamProxy>,
    cancel: CancellationToken,
    bypass_l2_read: bool,
    play_gate_probe: Option<L2PlayGateProbe>,
) {
    let target_bytes = compute_l2_target_bytes_for_spec(&spec);
    let key = spec.key().clone();
    let min_play_ms = l2.config().min_stable_play_ms;
    if !should_admit_to_l2(&key, target_bytes, min_play_ms, min_play_ms, 0, None, false) {
        return;
    }
    if let Ok(rt) = streaming_runtime() {
        rt.spawn(async move {
            let Some(played_ms) = wait_for_l2_stable_play_gate(
                &key,
                min_play_ms,
                bypass_l2_read,
                &cancel,
                &play_gate_probe,
            )
            .await
            else {
                return;
            };
            if !should_admit_to_l2(&key, target_bytes, played_ms, min_play_ms, 0, None, false) {
                return;
            }
            if let Ok(pkg) = proxy.export_l2_package(target_bytes as usize).await
                && !cancel.is_cancelled()
            {
                let _ = l2.store_dash_head(&key, &pkg, 0).await;
            }
        });
    }
}

async fn lookup_dash_head_async(
    l2: Arc<L2CacheManager>,
    key: StreamKey,
    cancel: &CancellationToken,
) -> Option<L2DashHit> {
    if cancel.is_cancelled() {
        return None;
    }
    let rt = streaming_runtime().ok()?;
    let (tx, rx) = tokio::sync::oneshot::channel();
    let cancel_inner = cancel.clone();
    rt.spawn(async move {
        let hit = tokio::select! {
            biased;
            _ = cancel_inner.cancelled() => None,
            res = l2.lookup_dash_head(&key) => res.ok().flatten(),
        };
        let _ = tx.send(hit);
    });
    tokio::select! {
        biased;
        _ = cancel.cancelled() => None,
        res = rx => res.ok().flatten(),
    }
}

fn clean_audio_mime(mime_type: Option<&str>) -> Option<String> {
    mime_type
        .map(str::trim)
        .filter(|m| !m.is_empty() && !m.eq_ignore_ascii_case("application/dash+xml"))
        .map(str::to_string)
}

fn build_hybrid_segmented_cfg(
    key: &StreamKey,
    headers: &BTreeMap<String, String>,
    audio_mime: Option<String>,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    on_mismatch: Option<FormatMismatchCallback>,
) -> HybridSegmentedConfig {
    HybridSegmentedConfig {
        headers: headers.clone(),
        hint_extension: None,
        mime_type: audio_mime,
        http_config: StreamHttpConfig::default(),
        refresh_handler,
        needs_network_epoch_reset: provider_needs_network_epoch_reset(&key.provider_id),
        refresh_backoffs: DEFAULT_REFRESH_403_BACKOFFS,
        prefetch_ahead: DEFAULT_PREFETCH_AHEAD,
        epoch_rx: None,
        on_mismatch,
    }
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn open_dash_spec_async(
    current_spec: &StreamSourceSpec,
    key: &StreamKey,
    manifest_url_or_xml: &str,
    headers: &BTreeMap<String, String>,
    mime_type: Option<&str>,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    l2_manager: Option<Arc<L2CacheManager>>,
    bypass_l2_read: bool,
    on_mismatch: Option<FormatMismatchCallback>,
    play_gate_probe: Option<L2PlayGateProbe>,
) -> Result<(OpenedStreamDecoder, StreamSourceSpec), CoreAudioError> {
    let audio_mime = clean_audio_mime(mime_type);

    if !bypass_l2_read
        && let Some(ref l2) = l2_manager
        && let Some(hit) = lookup_dash_head_async(Arc::clone(l2), key.clone(), &cancel).await
    {
        let cfg = build_hybrid_segmented_cfg(
            key,
            headers,
            audio_mime.clone(),
            refresh_handler.clone(),
            on_mismatch,
        );
        if let Ok(hybrid) = HybridSegmentedStream::open_shared(
            key.clone(),
            hit,
            manifest_url_or_xml.to_string(),
            Arc::clone(l2),
            cancel.clone(),
            cfg,
        ) {
            let dur_ms = hybrid.total_duration_ms();
            let spec_clone = current_spec.clone();
            let cancel_clone = cancel.clone();
            let opened = tokio::task::spawn_blocking(move || {
                if cancel_clone.is_cancelled() {
                    return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
                }
                let bridge =
                    BlockingStreamBridge::new(Arc::new(hybrid)).map_err(stream_error_to_core)?;
                let decoder = SymphoniaDecoder::from_blocking_bridge_with_duration(
                    bridge,
                    &spec_clone,
                    dur_ms,
                )?;
                Ok((Box::new(decoder) as OpenedStreamDecoder, spec_clone))
            })
            .await
            .map_err(|e| {
                CoreAudioError::Io(std::io::Error::other(format!(
                    "Decoder open task failed: {e}"
                )))
            })?;
            if opened.is_ok() {
                return opened;
            }
        }
    }

    let proxy = open_segmented_proxy_async(
        key.clone(),
        manifest_url_or_xml.to_string(),
        headers.clone(),
        audio_mime,
        cancel.clone(),
        refresh_handler,
    )
    .await?;

    if cancel.is_cancelled() {
        return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
    }
    let dur_ms = proxy.manifest().duration_ms;
    let proxy_arc = Arc::new(proxy);
    if let Some(ref l2) = l2_manager {
        spawn_dash_l2_admission_task(
            Arc::clone(l2),
            current_spec.clone(),
            Arc::clone(&proxy_arc),
            cancel.clone(),
            bypass_l2_read,
            play_gate_probe,
        );
    }
    let spec_clone = current_spec.clone();
    let cancel_clone = cancel;
    tokio::task::spawn_blocking(move || {
        if cancel_clone.is_cancelled() {
            return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
        }
        let bridge = BlockingStreamBridge::new(proxy_arc).map_err(stream_error_to_core)?;
        let decoder =
            SymphoniaDecoder::from_blocking_bridge_with_duration(bridge, &spec_clone, dur_ms)?;
        Ok((Box::new(decoder) as OpenedStreamDecoder, spec_clone))
    })
    .await
    .map_err(|e| {
        CoreAudioError::Io(std::io::Error::other(format!(
            "Decoder open task failed: {e}"
        )))
    })?
}

#[allow(clippy::too_many_arguments)]
pub(super) fn open_dash_spec_sync(
    spec: &StreamSourceSpec,
    key: &StreamKey,
    manifest_url_or_xml: &str,
    headers: &BTreeMap<String, String>,
    mime_type: Option<&str>,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    l2_manager: Option<Arc<L2CacheManager>>,
    bypass_l2_read: bool,
    on_mismatch: Option<FormatMismatchCallback>,
    play_gate_probe: Option<L2PlayGateProbe>,
) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
    let audio_mime = clean_audio_mime(mime_type);
    if !bypass_l2_read && let Some(ref l2) = l2_manager {
        let l2_c = Arc::clone(l2);
        let key_c = key.clone();
        let dash_hit = match run_on_streaming_runtime_cancellable(
            async move { l2_c.lookup_dash_head(&key_c).await },
            &cancel,
        ) {
            Ok(hit) => hit,
            Err(StreamError::Cancelled) => {
                return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
            }
            Err(_) => None,
        };
        if let Some(hit) = dash_hit {
            let cfg = build_hybrid_segmented_cfg(
                key,
                headers,
                audio_mime.clone(),
                refresh_handler.clone(),
                on_mismatch,
            );
            if let Ok(hybrid) = HybridSegmentedStream::open_shared(
                key.clone(),
                hit,
                manifest_url_or_xml.to_string(),
                Arc::clone(l2),
                cancel.clone(),
                cfg,
            ) {
                let dur_ms = hybrid.total_duration_ms();
                let bridge =
                    BlockingStreamBridge::new(Arc::new(hybrid)).map_err(stream_error_to_core)?;
                let decoder =
                    SymphoniaDecoder::from_blocking_bridge_with_duration(bridge, spec, dur_ms)?;
                return Ok(Box::new(decoder));
            }
        }
    }
    let proxy = open_segmented_proxy_sync(
        key.clone(),
        manifest_url_or_xml.to_string(),
        headers.clone(),
        audio_mime,
        cancel.clone(),
        refresh_handler,
    )?;
    let dur_ms = proxy.manifest().duration_ms;
    let proxy_arc = Arc::new(proxy);
    if let Some(l2) = l2_manager {
        spawn_dash_l2_admission_task(
            l2,
            spec.clone(),
            Arc::clone(&proxy_arc),
            cancel,
            bypass_l2_read,
            play_gate_probe,
        );
    }
    let bridge = BlockingStreamBridge::new(proxy_arc).map_err(stream_error_to_core)?;
    let decoder = SymphoniaDecoder::from_blocking_bridge_with_duration(bridge, spec, dur_ms)?;
    Ok(Box::new(decoder))
}
