use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use core_types::{
    AlbumVersion, AudioCodec, AudioFormat, CanonicalAlbum, NormalizedLoudness, ProviderKind,
    StreamKey, StreamSourceSpec, TrackSource,
};
use tokio::sync::RwLock;
use tokio_util::sync::CancellationToken;

use super::models::{
    YtDlpInfoJson, YtDlpSearchOrPlaylist, YtMusicConfig, YtMusicCredentialRefresher,
};
use super::runner::{
    GuardedProcessRunner, YtDlpCommandRunner, classify_yt_dlp_error, infer_audio_codec,
    infer_mime_type, parse_yt_dlp_single_json, select_best_audio_stream, yt_dlp_format_selector,
    yt_playlist_url, yt_track_url,
};
use crate::error::ProviderError;
use crate::local::extract_edition_label;
use crate::media_provider::{MediaPlaylist, MediaProvider, ProviderHealth};
use crate::process_guard::{BinaryKind, ProcessSpec};
use crate::resilience::{RetryPolicy, SingleFlightRefreshGate, execute_with_retry};
use crate::traits::extract_expire_at_from_url;

/// Isolated YouTube Music [`MediaProvider`] backed by guarded `yt-dlp` subprocess execution.
pub struct YtMusicProvider {
    config: RwLock<YtMusicConfig>,
    runner: Arc<dyn YtDlpCommandRunner>,
    refresh_gate: SingleFlightRefreshGate,
    refresher: Option<YtMusicCredentialRefresher>,
}

impl YtMusicProvider {
    pub fn new(config: YtMusicConfig) -> Self {
        Self::with_runner(config, Arc::new(GuardedProcessRunner))
    }

    pub fn with_runner(config: YtMusicConfig, runner: Arc<dyn YtDlpCommandRunner>) -> Self {
        Self {
            config: RwLock::new(config),
            runner,
            refresh_gate: SingleFlightRefreshGate::new(),
            refresher: None,
        }
    }

    pub fn with_credential_refresher(mut self, refresher: YtMusicCredentialRefresher) -> Self {
        self.refresher = Some(refresher);
        self
    }

    async fn build_yt_dlp_spec(
        &self,
        extra_args: Vec<String>,
    ) -> Result<(ProcessSpec, RetryPolicy), ProviderError> {
        let cfg = self.config.read().await.clone();
        let yt_dlp_path = cfg.binary_locator.resolve(BinaryKind::YtDlp)?;

        let mut spec = ProcessSpec::new(yt_dlp_path)
            .arg("--no-config")
            .arg("--force-ipv4")
            .arg("--no-warnings");

        if let Ok(deno_path) = cfg.binary_locator.resolve(BinaryKind::Deno) {
            spec = spec
                .arg("--js-runtimes")
                .arg(format!("deno:{}", deno_path.display()));
        }

        if let Ok(ffmpeg_path) = cfg.binary_locator.resolve(BinaryKind::Ffmpeg) {
            let ffmpeg_dir = ffmpeg_path.parent().unwrap_or(ffmpeg_path.as_path());
            spec = spec
                .arg("--ffmpeg-location")
                .arg(ffmpeg_dir.display().to_string());
        }

        if let Some(cookies_file) = cfg.cookies_file {
            spec = spec
                .arg("--cookies")
                .arg(cookies_file.display().to_string());
        }
        if let Some(browser) = cfg.cookies_from_browser.filter(|s| !s.trim().is_empty()) {
            spec = spec.arg("--cookies-from-browser").arg(browser);
        }
        if let Some(ua) = cfg.user_agent.filter(|s| !s.trim().is_empty()) {
            spec = spec.arg("--user-agent").arg(ua);
        }

        spec = spec.args(cfg.extra_yt_dlp_args);
        spec = spec.args(extra_args);
        Ok((spec, cfg.retry_policy))
    }

    async fn refresh_once_inner(
        &self,
        observed_epoch: u64,
        cancel: &CancellationToken,
    ) -> Result<(), ProviderError> {
        let Some(refresher) = self.refresher.clone() else {
            return Ok(());
        };

        self.refresh_gate
            .refresh_once(observed_epoch, cancel, || async {
                let updated = (refresher)().await?;
                let mut cfg = self.config.write().await;
                if updated.cookies_file.is_some() {
                    cfg.cookies_file = updated.cookies_file;
                }
                if updated.cookies_from_browser.is_some() {
                    cfg.cookies_from_browser = updated.cookies_from_browser;
                }
                Ok(())
            })
            .await
            .map(|_| ())
    }

    async fn run_yt_dlp_json(
        &self,
        args: Vec<String>,
        cancel: &CancellationToken,
    ) -> Result<String, ProviderError> {
        let mut retried_after_refresh = false;
        loop {
            if cancel.is_cancelled() {
                return Err(ProviderError::Cancelled);
            }
            let observed_epoch = self.refresh_gate.current_epoch();
            let (spec, policy) = self.build_yt_dlp_spec(args.clone()).await?;

            let output = execute_with_retry(&policy, cancel, |_| {
                let spec_clone = spec.clone();
                let child_cancel = cancel.child_token();
                async move {
                    self.runner
                        .run(&spec_clone, child_cancel)
                        .await
                        .map_err(classify_yt_dlp_error)
                }
            })
            .await;

            match output {
                Ok(out) => return Ok(out.stdout_string_lossy()),
                Err(err)
                    if err.is_auth_expired()
                        && !retried_after_refresh
                        && self.refresher.is_some() =>
                {
                    retried_after_refresh = true;
                    self.refresh_once_inner(observed_epoch, cancel).await?;
                }
                Err(err) => return Err(err),
            }
        }
    }
}

#[async_trait]
impl MediaProvider for YtMusicProvider {
    fn provider_id(&self) -> &'static str {
        "youtube_music"
    }

    async fn search(
        &self,
        query: &str,
        limit: usize,
    ) -> Result<Vec<CanonicalAlbum>, ProviderError> {
        let cancel = CancellationToken::new();
        let clamped_limit = limit.clamp(1, 50);
        let search_expr = format!("ytsearch{clamped_limit}:{query}");
        let raw = self
            .run_yt_dlp_json(
                vec!["--flat-playlist".to_string(), "-J".to_string(), search_expr],
                &cancel,
            )
            .await?;

        let parsed: YtDlpSearchOrPlaylist = serde_json::from_str(raw.trim()).map_err(|e| {
            ProviderError::Network(format!("Failed to parse yt-dlp search JSON: {e}"))
        })?;

        let format = AudioFormat::pcm(AudioCodec::Opus, 48_000, 16, 2)?;
        let mut albums = Vec::with_capacity(parsed.entries.len());
        for entry in parsed.entries {
            let thumb = entry.best_thumbnail();
            let Some(id) = entry.id.filter(|s| !s.trim().is_empty()) else {
                continue;
            };
            let title = entry
                .album
                .or(entry.title)
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| "Unknown Track".to_string());
            let artist = entry
                .artist
                .or(entry.uploader)
                .or(entry.channel)
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| "Unknown Artist".to_string());
            let (base_title, edition) = extract_edition_label(&title);
            let mut album = CanonicalAlbum::new(&base_title, &artist)?;

            if let Some(thumb) = thumb {
                album = album.with_cover_url(thumb);
            }
            let mut version =
                AlbumVersion::new(&album.id, ProviderKind::YouTubeMusic, &id, format.clone())?;
            if let Some(ed) = edition {
                version = version.with_edition_label(ed);
            }
            album.add_version(version);
            albums.push(album);
        }

        Ok(albums)
    }

    async fn get_track(&self, track_id: &str) -> Result<TrackSource, ProviderError> {
        if track_id.trim().is_empty() {
            return Err(ProviderError::track_not_found("youtube_music", track_id));
        }
        let cancel = CancellationToken::new();
        let target = yt_track_url(track_id);
        let raw = self
            .run_yt_dlp_json(
                vec!["--no-playlist".to_string(), "-j".to_string(), target],
                &cancel,
            )
            .await?;

        let info: YtDlpInfoJson = parse_yt_dlp_single_json(&raw)?;
        let codec = infer_audio_codec(info.acodec.as_deref(), info.ext.as_deref());
        let sample_rate = info.asr.filter(|&sr| sr > 0).unwrap_or(48_000);
        let format = AudioFormat::pcm(codec, sample_rate, 16, 2)?;
        let duration_ms = info
            .duration
            .filter(|d| d.is_finite() && *d > 0.0)
            .map(|d| (d * 1000.0).round() as u64)
            .unwrap_or(1)
            .max(1);
        let version_id = info
            .album
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| "ytmusic-track".to_string());

        Ok(TrackSource::new(
            version_id,
            ProviderKind::YouTubeMusic,
            info.id.unwrap_or_else(|| track_id.to_string()),
            info.title
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| track_id.to_string()),
            info.disc_number.unwrap_or(1).max(1),
            info.track_number.unwrap_or(1).max(1),
            duration_ms,
            format,
        )?)
    }

    async fn get_playlist(&self, playlist_id: &str) -> Result<MediaPlaylist, ProviderError> {
        if playlist_id.trim().is_empty() {
            return Err(ProviderError::AlbumNotFound(
                "YouTube Music playlist id cannot be empty".to_string(),
            ));
        }
        let cancel = CancellationToken::new();
        let target = yt_playlist_url(playlist_id);
        let raw = self
            .run_yt_dlp_json(
                vec!["--flat-playlist".to_string(), "-J".to_string(), target],
                &cancel,
            )
            .await?;

        let parsed: YtDlpSearchOrPlaylist = serde_json::from_str(raw.trim()).map_err(|e| {
            ProviderError::Network(format!("Failed to parse yt-dlp playlist JSON: {e}"))
        })?;

        let artwork_url = parsed.best_thumbnail();
        let format = AudioFormat::pcm(AudioCodec::Opus, 48_000, 16, 2)?;
        let version_id = format!("ytmusic-playlist-{playlist_id}");
        let mut tracks = Vec::with_capacity(parsed.entries.len());
        for (idx, entry) in parsed.entries.into_iter().enumerate() {
            let Some(id) = entry.id.filter(|s| !s.trim().is_empty()) else {
                continue;
            };
            let title = entry
                .title
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| id.clone());
            let duration_ms = entry
                .duration
                .filter(|d| d.is_finite() && *d > 0.0)
                .map(|d| (d * 1000.0).round() as u64)
                .unwrap_or(1)
                .max(1);
            tracks.push(TrackSource::new(
                version_id.clone(),
                ProviderKind::YouTubeMusic,
                id,
                title,
                1,
                (idx + 1) as u16,
                duration_ms,
                format.clone(),
            )?);
        }

        Ok(MediaPlaylist {
            id: parsed.id.unwrap_or_else(|| playlist_id.to_string()),
            provider_id: self.provider_id().to_string(),
            title: parsed
                .title
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| "YouTube Music Playlist".to_string()),
            description: parsed.description.filter(|s| !s.trim().is_empty()),
            owner: parsed
                .uploader
                .or(parsed.channel)
                .filter(|s| !s.trim().is_empty()),
            artwork_url,
            tracks,
        })
    }

    async fn resolve_stream(
        &self,
        track_id: &str,
        quality: &str,
        cancel_token: CancellationToken,
    ) -> Result<StreamSourceSpec, ProviderError> {
        if cancel_token.is_cancelled() {
            return Err(ProviderError::Cancelled);
        }
        if track_id.trim().is_empty() {
            return Err(ProviderError::track_not_found("youtube_music", track_id));
        }

        let format_selector = yt_dlp_format_selector(quality);
        let target = yt_track_url(track_id);
        let raw = self
            .run_yt_dlp_json(
                vec![
                    "--no-playlist".to_string(),
                    "-j".to_string(),
                    "-f".to_string(),
                    format_selector.to_string(),
                    target,
                ],
                &cancel_token,
            )
            .await?;

        let info: YtDlpInfoJson = parse_yt_dlp_single_json(&raw)?;
        let selected = select_best_audio_stream(&info).ok_or_else(|| {
            ProviderError::StreamResolutionFailed(format!(
                "yt-dlp JSON output for '{track_id}' contained no playable audio stream URL"
            ))
        })?;

        let expire_at = extract_expire_at_from_url(&selected.url);
        let loudness = info
            .loudness_db
            .or(info.loudness_db_camel)
            .filter(|v| v.is_finite())
            .map(|v| NormalizedLoudness::from_ytm_loudness_db(v as f32));

        let hint_extension = selected.ext.clone().or_else(|| Some("webm".to_string()));
        let mime_type = selected
            .mime_type
            .or_else(|| infer_mime_type(hint_extension.as_deref(), selected.acodec.as_deref()));

        Ok(StreamSourceSpec::DirectRange {
            key: StreamKey::new(self.provider_id(), track_id, quality),
            url: selected.url,
            headers: selected.headers,
            content_length: selected.content_length,
            bitrate_bps: selected.bitrate_bps,
            mime_type,
            hint_extension,
            expire_at,
            init_range_end: None,
            index_range_start: None,
            index_range_end: None,
            loudness,
            album_loudness: None,
        })
    }

    async fn health_check(&self) -> Result<ProviderHealth, ProviderError> {
        let start = Instant::now();
        let cfg = self.config.read().await.clone();
        let authenticated = cfg.cookies_file.is_some()
            || cfg
                .cookies_from_browser
                .as_deref()
                .is_some_and(|s| !s.trim().is_empty());

        match cfg.binary_locator.resolve(BinaryKind::YtDlp) {
            Ok(yt_dlp_path) => {
                let has_deno = cfg.binary_locator.resolve(BinaryKind::Deno).is_ok();
                let has_ffmpeg = cfg.binary_locator.resolve(BinaryKind::Ffmpeg).is_ok();
                Ok(ProviderHealth {
                    provider_id: self.provider_id().to_string(),
                    healthy: true,
                    authenticated,
                    latency_ms: start.elapsed().as_millis() as u64,
                    detail: Some(format!(
                        "yt-dlp ready ({}; deno={}, ffmpeg={})",
                        yt_dlp_path.display(),
                        has_deno,
                        has_ffmpeg
                    )),
                })
            }
            Err(err) => Ok(ProviderHealth {
                provider_id: self.provider_id().to_string(),
                healthy: false,
                authenticated,
                latency_ms: start.elapsed().as_millis() as u64,
                detail: Some(err.to_string()),
            }),
        }
    }

    async fn refresh_credentials(&self) -> Result<(), ProviderError> {
        let cancel = CancellationToken::new();
        let epoch = self.refresh_gate.current_epoch();
        self.refresh_once_inner(epoch, &cancel).await
    }
}
