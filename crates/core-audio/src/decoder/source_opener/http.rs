use std::sync::{Arc, mpsc};
use std::time::Duration;

use core_types::{StreamCipher, StreamKey, StreamSourceSpec, compute_l2_target_bytes};
use tokio_util::sync::CancellationToken;

use super::{L2PlayGateProbe, provider_needs_network_epoch_reset, stream_error_to_core};
use crate::error::CoreAudioError;
use crate::streaming::{
    BlockingStreamBridge, ByteStreamSource, ChunkedStreamProxy, DEEZER_ALIGNED_CHUNK_SIZE,
    DEEZER_INITIAL_CHUNK_SIZE, DEFAULT_INITIAL_CHUNK_SIZE, DecryptingByteStream,
    FormatMismatchCallback, HybridByteStream, L2CacheManager, StreamError, StreamRefreshHandler,
    should_admit_to_l2, streaming_runtime,
};

pub(super) fn run_on_streaming_runtime_cancellable<F, T>(
    fut: F,
    cancel: &CancellationToken,
) -> Result<T, StreamError>
where
    F: std::future::Future<Output = Result<T, StreamError>> + Send + 'static,
    T: Send + 'static,
{
    if cancel.is_cancelled() {
        return Err(StreamError::Cancelled);
    }
    let rt = streaming_runtime()?;
    let cancel_c = cancel.clone();
    let wrapped = async move {
        tokio::select! {
            biased;
            _ = cancel_c.cancelled() => Err(StreamError::Cancelled),
            res = fut => res,
        }
    };
    if tokio::runtime::Handle::try_current().is_ok() {
        let (tx, rx) = mpsc::sync_channel(1);
        rt.spawn(async move {
            let _ = tx.send(wrapped.await);
        });
        rx.recv()
            .map_err(|_| StreamError::Io("L2 runtime channel closed".to_string()))?
    } else {
        rt.block_on(wrapped)
    }
}

pub(super) fn compute_l2_target_bytes_for_spec(spec: &StreamSourceSpec) -> u64 {
    match spec {
        StreamSourceSpec::DirectRange {
            key,
            bitrate_bps,
            content_length,
            ..
        } => compute_l2_target_bytes(&key.provider_id, *bitrate_bps, *content_length, false),
        StreamSourceSpec::EncryptedRange {
            key,
            bitrate_bps,
            content_length,
            ..
        } => compute_l2_target_bytes(&key.provider_id, *bitrate_bps, *content_length, true),
        StreamSourceSpec::SegmentedManifest {
            key, bitrate_bps, ..
        } => compute_l2_target_bytes(&key.provider_id, *bitrate_bps, None, false),
        _ => 0,
    }
}

pub(super) async fn wait_for_l2_stable_play_gate(
    key: &StreamKey,
    min_play_ms: u64,
    bypass_l2_read: bool,
    cancel: &CancellationToken,
    play_gate_probe: &Option<L2PlayGateProbe>,
) -> Option<u64> {
    if bypass_l2_read || min_play_ms == 0 {
        return Some(min_play_ms);
    }
    let mut played_ms = 0u64;
    let step_ms = 50u64;
    while played_ms < min_play_ms {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => return None,
            _ = tokio::time::sleep(Duration::from_millis(step_ms)) => {}
        }
        if cancel.is_cancelled() {
            return None;
        }
        if let Some(probe) = play_gate_probe {
            let (is_playing_track, pos_ms) = probe(key)?;
            if is_playing_track {
                played_ms = played_ms.saturating_add(step_ms).max(pos_ms);
            }
        } else {
            played_ms = played_ms.saturating_add(step_ms);
        }
    }
    Some(played_ms)
}

fn spawn_direct_l2_admission_task(
    l2: Arc<L2CacheManager>,
    spec: StreamSourceSpec,
    proxy: Arc<ChunkedStreamProxy>,
    cancel: CancellationToken,
    bypass_l2_read: bool,
    play_gate_probe: Option<L2PlayGateProbe>,
) {
    let target_bytes = compute_l2_target_bytes_for_spec(&spec);
    let index_range_end = match &spec {
        StreamSourceSpec::DirectRange {
            index_range_end, ..
        } => *index_range_end,
        _ => None,
    };
    let key = spec.key().clone();
    let min_play_ms = l2.config().min_stable_play_ms;
    if !should_admit_to_l2(
        &key,
        target_bytes,
        min_play_ms,
        min_play_ms,
        0,
        index_range_end,
        false,
    ) {
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
            if !should_admit_to_l2(
                &key,
                target_bytes,
                played_ms,
                min_play_ms,
                0,
                index_range_end,
                false,
            ) {
                return;
            }
            if let Ok(prefix) = proxy.capture_prefix_bytes(target_bytes).await
                && !prefix.is_empty()
                && !cancel.is_cancelled()
            {
                let _ = l2.store_direct_head(&key, &prefix, proxy.len(), 0).await;
            }
        });
    }
}

pub(super) fn open_bridge_for_sync_spec(
    spec: &StreamSourceSpec,
    cancel: CancellationToken,
    refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    l2_manager: Option<Arc<L2CacheManager>>,
    bypass_l2_read: bool,
    on_mismatch: Option<FormatMismatchCallback>,
    play_gate_probe: Option<L2PlayGateProbe>,
) -> Result<BlockingStreamBridge, CoreAudioError> {
    match spec {
        StreamSourceSpec::DirectRange {
            key,
            url,
            headers,
            content_length,
            bitrate_bps,
            hint_extension,
            mime_type,
            loudness,
            album_loudness,
            ..
        } => {
            let l2_hit = if !bypass_l2_read && let Some(ref l2) = l2_manager {
                let l2_c = Arc::clone(l2);
                let key_c = key.clone();
                match run_on_streaming_runtime_cancellable(
                    async move { l2_c.lookup_direct_head(&key_c).await },
                    &cancel,
                ) {
                    Ok(hit) => hit,
                    Err(StreamError::Cancelled) => {
                        return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
                    }
                    Err(_) => None,
                }
            } else {
                None
            };
            let eff_len = l2_hit
                .as_ref()
                .and_then(|h| h.total_content_length)
                .or(*content_length);
            let mut raw_proxy = ChunkedStreamProxy::new(
                url.as_str(),
                headers,
                eff_len,
                hint_extension.clone(),
                mime_type.clone(),
            )
            .map_err(stream_error_to_core)?
            .with_expected_kind("direct_range")
            .with_spec_metadata(*bitrate_bps, *loudness, *album_loudness)
            .with_cancellation_token(cancel.clone());
            raw_proxy = if let Some(handler) = refresh_handler {
                raw_proxy.with_refresh_context(
                    key.clone(),
                    handler,
                    provider_needs_network_epoch_reset(&key.provider_id),
                )
            } else {
                raw_proxy.with_stream_key(key.clone())
            };
            let proxy = Arc::new(raw_proxy);
            if let (Some(hit), Some(l2)) = (l2_hit, l2_manager.as_ref())
                && let Ok(hybrid) = HybridByteStream::new(
                    key.clone(),
                    hit,
                    Arc::clone(&proxy),
                    Arc::clone(l2),
                    on_mismatch,
                )
            {
                return BlockingStreamBridge::new(Arc::new(hybrid)).map_err(stream_error_to_core);
            }
            if let Some(l2) = l2_manager {
                spawn_direct_l2_admission_task(
                    l2,
                    spec.clone(),
                    Arc::clone(&proxy),
                    cancel,
                    bypass_l2_read,
                    play_gate_probe,
                );
            }
            BlockingStreamBridge::new(proxy).map_err(stream_error_to_core)
        }
        StreamSourceSpec::EncryptedRange {
            key,
            url,
            headers,
            content_length,
            bitrate_bps,
            hint_extension,
            mime_type,
            cipher,
            loudness,
            album_loudness,
            ..
        } => match cipher {
            StreamCipher::DeezerBlowfish {
                track_id,
                block_size,
                stride,
            } => {
                let l2_hit = if !bypass_l2_read && let Some(ref l2) = l2_manager {
                    let l2_c = Arc::clone(l2);
                    let key_c = key.clone();
                    match run_on_streaming_runtime_cancellable(
                        async move { l2_c.lookup_direct_head(&key_c).await },
                        &cancel,
                    ) {
                        Ok(hit) => hit,
                        Err(StreamError::Cancelled) => {
                            return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
                        }
                        Err(_) => None,
                    }
                } else {
                    None
                };
                let eff_len = l2_hit
                    .as_ref()
                    .and_then(|h| h.total_content_length)
                    .or(*content_length);
                let stripe = block_size.saturating_mul(*stride).max(1);
                let chunk_size = if stripe == 6144 {
                    DEEZER_ALIGNED_CHUNK_SIZE
                } else {
                    ((512 * 1024) / stripe).max(1).saturating_mul(stripe)
                };
                let initial_chunk_size = if stripe == 6144 {
                    DEEZER_INITIAL_CHUNK_SIZE
                } else {
                    (DEFAULT_INITIAL_CHUNK_SIZE / stripe)
                        .max(1)
                        .saturating_mul(stripe)
                };
                let mut raw_proxy = ChunkedStreamProxy::new(
                    url.as_str(),
                    headers,
                    eff_len,
                    hint_extension.clone(),
                    mime_type.clone(),
                )
                .map_err(stream_error_to_core)?
                .with_expected_kind("encrypted_range")
                .with_spec_metadata(*bitrate_bps, *loudness, *album_loudness)
                .with_initial_chunk_size(initial_chunk_size)
                .with_chunk_size(chunk_size)
                .with_range_alignment(stripe)
                .with_cancellation_token(cancel.clone());
                raw_proxy = if let Some(handler) = refresh_handler {
                    raw_proxy.with_refresh_context(
                        key.clone(),
                        handler,
                        provider_needs_network_epoch_reset(&key.provider_id),
                    )
                } else {
                    raw_proxy.with_stream_key(key.clone())
                };
                let proxy = Arc::new(raw_proxy);
                if let (Some(hit), Some(l2)) = (l2_hit, l2_manager.as_ref())
                    && let Ok(hybrid) = HybridByteStream::new(
                        key.clone(),
                        hit,
                        Arc::clone(&proxy),
                        Arc::clone(l2),
                        on_mismatch,
                    )
                {
                    let decrypting = Arc::new(
                        DecryptingByteStream::with_geometry(
                            Arc::new(hybrid),
                            track_id,
                            *block_size,
                            *stride,
                        )
                        .map_err(stream_error_to_core)?,
                    );
                    return BlockingStreamBridge::new(decrypting).map_err(stream_error_to_core);
                }
                if let Some(l2) = l2_manager {
                    spawn_direct_l2_admission_task(
                        l2,
                        spec.clone(),
                        Arc::clone(&proxy),
                        cancel,
                        bypass_l2_read,
                        play_gate_probe,
                    );
                }
                let decrypting = Arc::new(
                    DecryptingByteStream::with_geometry(proxy, track_id, *block_size, *stride)
                        .map_err(stream_error_to_core)?,
                );
                BlockingStreamBridge::new(decrypting).map_err(stream_error_to_core)
            }
        },
        _ => Err(CoreAudioError::InvalidConfig(
            "Expected DirectRange or EncryptedRange StreamSourceSpec".to_string(),
        )),
    }
}
