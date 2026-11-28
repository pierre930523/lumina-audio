//! Async stream/spec opening and synchronous `start_opened_*` / `play_stream*` / `play_file` APIs.

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use core_types::{DeckTrackMetadata, StreamSourceSpec};
use tokio_util::sync::CancellationToken;

use crate::decoder::pcm::AudioDecoder;
use crate::decoder::source_opener::{
    OpenedStreamDecoder, open_decoder_for_source_spec_async,
    open_decoder_for_source_spec_async_with_l2, open_decoder_for_source_spec_async_with_refresh,
    open_decoder_for_stream_with_token,
};
use crate::engine::dsp_helpers::build_mismatch_callback;
use crate::engine::types::build_l2_play_gate_probe;
use crate::engine::{AudioPlayer, PlayerOrigin};
use crate::error::CoreAudioError;
use crate::stream::StreamSource;
use crate::streaming::{StreamError, StreamRefreshHandler};

impl AudioPlayer {
    /// Opens a [`StreamSourceSpec`] asynchronously using this player's L2 cache manager,
    /// format-mismatch recovery callback, and stable-play admission hook.
    ///
    /// Returns `(decoder, adopted_spec)` where `adopted_spec` reflects any initial
    /// `StreamFormatChanged` self-healing refresh performed during probe. The returned future is
    /// `Send + 'static` so callers can release locks guarding `&AudioPlayer` before `.await`ing.
    pub fn open_source_spec_async_with_l2(
        &self,
        spec: StreamSourceSpec,
        cancel: CancellationToken,
        refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    ) -> impl std::future::Future<
        Output = Result<(OpenedStreamDecoder, StreamSourceSpec), CoreAudioError>,
    > + Send
    + 'static {
        let inner = Arc::clone(&self.inner);
        async move {
            let effective_refresh = refresh_handler.or_else(|| inner.stream_refresh_handler());
            let l2_manager = inner.l2_cache_manager();
            let mismatch_cb = build_mismatch_callback(&inner, &spec);
            let play_gate = build_l2_play_gate_probe(&inner);
            open_decoder_for_source_spec_async_with_l2(
                spec,
                cancel,
                effective_refresh,
                l2_manager,
                mismatch_cb,
                Some(play_gate),
            )
            .await
        }
    }

    /// Opens a [`StreamSourceSpec`] asynchronously (non-blocking manifest fetch,
    /// cancellable `spawn_blocking` probe) without blocking a Tokio worker thread.
    pub async fn open_source_spec_async(
        spec: StreamSourceSpec,
        cancel: CancellationToken,
    ) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
        open_decoder_for_source_spec_async(spec, cancel).await
    }

    /// Opens a [`StreamSourceSpec`] asynchronously with an optional [`StreamRefreshHandler`] wired
    /// into underlying range/segmented proxies.
    pub async fn open_source_spec_async_with_refresh(
        spec: StreamSourceSpec,
        cancel: CancellationToken,
        refresh_handler: Option<Arc<dyn StreamRefreshHandler>>,
    ) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
        open_decoder_for_source_spec_async_with_refresh(spec, cancel, refresh_handler).await
    }

    /// Opens a legacy [`StreamSource`] asynchronously on Tokio's blocking pool with cancellation.
    pub async fn open_stream_async(
        stream: StreamSource,
        cancel: CancellationToken,
        timeout: Duration,
    ) -> Result<Box<dyn AudioDecoder>, CoreAudioError> {
        if cancel.is_cancelled() {
            return Err(CoreAudioError::Io(StreamError::Cancelled.to_io_error()));
        }
        tokio::task::spawn_blocking(move || {
            open_decoder_for_stream_with_token(&stream, cancel, timeout)
        })
        .await
        .map_err(|e| {
            CoreAudioError::Io(std::io::Error::other(format!(
                "Decoder open task failed: {e}"
            )))
        })?
    }

    /// Commits a pre-opened `decoder` for `spec` if `play_ep` and `cancel` are still current.
    pub fn start_opened_source_spec(
        &self,
        spec: &StreamSourceSpec,
        decoder: Box<dyn AudioDecoder>,
        source_label: &str,
        play_ep: u64,
        cancel: CancellationToken,
    ) -> Result<(), CoreAudioError> {
        self.start_opened_source_spec_with_metadata(
            spec,
            decoder,
            source_label,
            play_ep,
            cancel,
            None,
        )
    }

    /// Commits a pre-opened `decoder` for `spec` with deck track metadata if `play_ep` and
    /// `cancel` are still current.
    pub fn start_opened_source_spec_with_metadata(
        &self,
        spec: &StreamSourceSpec,
        decoder: Box<dyn AudioDecoder>,
        source_label: &str,
        play_ep: u64,
        cancel: CancellationToken,
        track_meta: Option<DeckTrackMetadata>,
    ) -> Result<(), CoreAudioError> {
        if let StreamSourceSpec::ExternalBackend {
            key, provider_id, ..
        } = spec
        {
            return Err(CoreAudioError::UnsupportedFormat(format!(
                "ExternalBackend ({provider_id}:{}) cannot enter Native audio engine",
                key.track_id
            )));
        }

        self.commit_opened_decoder(
            PlayerOrigin::SourceSpec(spec.clone()),
            decoder,
            source_label,
            cancel,
            Some(play_ep),
            track_meta,
        )
    }

    /// Commits a pre-opened legacy `stream` decoder if `play_ep` and `cancel` are still current.
    pub fn start_opened_decoder_with_epoch(
        &self,
        stream: &StreamSource,
        decoder: Box<dyn AudioDecoder>,
        source_label: &str,
        play_ep: u64,
        cancel: CancellationToken,
    ) -> Result<(), CoreAudioError> {
        self.start_opened_decoder_with_epoch_and_metadata(
            stream,
            decoder,
            source_label,
            play_ep,
            cancel,
            None,
        )
    }

    /// Commits a pre-opened legacy `stream` decoder with deck track metadata if `play_ep` and
    /// `cancel` are still current.
    pub fn start_opened_decoder_with_epoch_and_metadata(
        &self,
        stream: &StreamSource,
        decoder: Box<dyn AudioDecoder>,
        source_label: &str,
        play_ep: u64,
        cancel: CancellationToken,
        track_meta: Option<DeckTrackMetadata>,
    ) -> Result<(), CoreAudioError> {
        self.commit_opened_decoder(
            PlayerOrigin::Legacy(stream.clone()),
            decoder,
            source_label,
            cancel,
            Some(play_ep),
            track_meta,
        )
    }

    /// Opens a `StreamSource` (local file or HTTP/HTTPS stream), probes codec/container headers,
    /// stores ReplayGain tags, and starts streaming playback.
    pub fn play_stream(
        &self,
        stream: StreamSource,
        source_label: &str,
    ) -> Result<(), CoreAudioError> {
        self.play_stream_with_metadata(stream, source_label, None)
    }

    /// Opens a `StreamSource` with explicit deck track metadata and starts streaming playback.
    pub fn play_stream_with_metadata(
        &self,
        stream: StreamSource,
        source_label: &str,
        track_meta: Option<DeckTrackMetadata>,
    ) -> Result<(), CoreAudioError> {
        let cancel = CancellationToken::new();
        let Some(play_ep) = self.swap_cancel_and_bump_epoch(None, cancel.clone()) else {
            return Ok(());
        };
        let decoder = match open_decoder_for_stream_with_token(
            &stream,
            cancel.clone(),
            Duration::from_secs(10),
        ) {
            Ok(d) => d,
            Err(e) => {
                if cancel.is_cancelled() || self.inner.play_epoch.load(Ordering::SeqCst) != play_ep
                {
                    return Ok(());
                }
                return Err(e);
            }
        };
        self.commit_opened_decoder(
            PlayerOrigin::Legacy(stream),
            decoder,
            source_label,
            cancel,
            Some(play_ep),
            track_meta,
        )
    }

    /// Commits a pre-opened `decoder` into active playback without doing any network/probe I/O.
    pub fn start_opened_decoder(
        &self,
        stream: &StreamSource,
        decoder: Box<dyn AudioDecoder>,
        source_label: &str,
    ) -> Result<(), CoreAudioError> {
        self.start_opened_decoder_with_metadata(stream, decoder, source_label, None)
    }

    /// Commits a pre-opened `decoder` with deck track metadata into active playback.
    pub fn start_opened_decoder_with_metadata(
        &self,
        stream: &StreamSource,
        decoder: Box<dyn AudioDecoder>,
        source_label: &str,
        track_meta: Option<DeckTrackMetadata>,
    ) -> Result<(), CoreAudioError> {
        let cancel = CancellationToken::new();
        let Some(play_ep) = self.swap_cancel_and_bump_epoch(None, cancel.clone()) else {
            return Ok(());
        };
        self.commit_opened_decoder(
            PlayerOrigin::Legacy(stream.clone()),
            decoder,
            source_label,
            cancel,
            Some(play_ep),
            track_meta,
        )
    }

    /// Opens `path`, probes codec/container headers, and starts streaming playback.
    pub fn play_file(
        &self,
        path: impl AsRef<Path>,
        source_label: Option<String>,
    ) -> Result<(), CoreAudioError> {
        let stream = StreamSource::local_file(path.as_ref());
        let label = source_label.as_deref().unwrap_or("Local Library");
        self.play_stream(stream, label)
    }
}
