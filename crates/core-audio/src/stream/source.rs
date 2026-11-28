use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StreamOrigin {
    LocalFile(PathBuf),
    Http {
        url: String,
        headers: HashMap<String, String>,
    },
    Synth {
        track_id: String,
        title: String,
        duration_ms: u64,
        sample_rate_hz: u32,
        channels: u16,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct StreamSource {
    pub origin: StreamOrigin,
    pub hint_extension: Option<String>,
    pub replay_gain_track_db: Option<f64>,
    pub replay_gain_album_db: Option<f64>,
    pub replay_gain_track_peak: Option<f64>,
    pub replay_gain_album_peak: Option<f64>,
}

impl StreamSource {
    pub fn local_file(path: impl Into<PathBuf>) -> Self {
        let pb = path.into();
        let hint_extension = pb
            .extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_ascii_lowercase());
        Self {
            origin: StreamOrigin::LocalFile(pb),
            hint_extension,
            replay_gain_track_db: None,
            replay_gain_album_db: None,
            replay_gain_track_peak: None,
            replay_gain_album_peak: None,
        }
    }

    pub fn http(
        url: impl Into<String>,
        headers: HashMap<String, String>,
        hint_extension: Option<String>,
    ) -> Self {
        Self {
            origin: StreamOrigin::Http {
                url: url.into(),
                headers,
            },
            hint_extension: hint_extension.map(|s| s.trim_start_matches('.').to_ascii_lowercase()),
            replay_gain_track_db: None,
            replay_gain_album_db: None,
            replay_gain_track_peak: None,
            replay_gain_album_peak: None,
        }
    }

    pub fn synth(track_id: impl Into<String>, title: impl Into<String>, duration_ms: u64) -> Self {
        let effective_duration_ms = if duration_ms == 0 {
            245_000
        } else {
            duration_ms
        };
        Self {
            origin: StreamOrigin::Synth {
                track_id: track_id.into(),
                title: title.into(),
                duration_ms: effective_duration_ms,
                sample_rate_hz: 48_000,
                channels: 2,
            },
            hint_extension: None,
            replay_gain_track_db: None,
            replay_gain_album_db: None,
            replay_gain_track_peak: None,
            replay_gain_album_peak: None,
        }
    }

    pub fn with_replay_gain(
        mut self,
        track_db: Option<f64>,
        album_db: Option<f64>,
        track_peak: Option<f64>,
        album_peak: Option<f64>,
    ) -> Self {
        self.replay_gain_track_db = track_db;
        self.replay_gain_album_db = album_db;
        self.replay_gain_track_peak = track_peak;
        self.replay_gain_album_peak = album_peak;
        self
    }

    pub fn display_path(&self) -> PathBuf {
        match &self.origin {
            StreamOrigin::LocalFile(p) => p.clone(),
            StreamOrigin::Http { url, .. } => PathBuf::from(url),
            StreamOrigin::Synth { track_id, .. } => PathBuf::from(format!("synth://{track_id}")),
        }
    }
}
