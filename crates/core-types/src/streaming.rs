use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fmt;

pub const DEFAULT_DEEZER_BLOCK_SIZE: usize = 2048;
pub const DEFAULT_DEEZER_STRIDE: usize = 3;

fn default_deezer_block_size() -> usize {
    DEFAULT_DEEZER_BLOCK_SIZE
}

fn default_deezer_stride() -> usize {
    DEFAULT_DEEZER_STRIDE
}

fn default_loudness_peak() -> f32 {
    1.0
}

/// Raw deserialization wire format for [`NormalizedLoudness`] so serde JSON payloads
/// from FFI/clients always pass through [`NormalizedLoudness::new`] clamping & NaN guards.
#[derive(Debug, Clone, Copy, Deserialize)]
struct RawNormalizedLoudness {
    gain_db: f32,
    #[serde(default = "default_loudness_peak")]
    peak: f32,
}

/// Unified loudness normalization metadata targeting a common `-14.0 LUFS` reference.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(from = "RawNormalizedLoudness")]
pub struct NormalizedLoudness {
    pub gain_db: f32,
    #[serde(default = "default_loudness_peak")]
    pub peak: f32,
}

impl From<RawNormalizedLoudness> for NormalizedLoudness {
    fn from(raw: RawNormalizedLoudness) -> Self {
        Self::new(raw.gain_db, raw.peak)
    }
}

impl NormalizedLoudness {
    pub const TARGET_LUFS: f32 = -14.0;
    pub const MIN_GAIN_DB: f32 = -24.0;
    pub const MAX_POSITIVE_GAIN_DB: f32 = 6.0;

    /// Constructs a sanitized loudness adjustment targeting `-14.0 LUFS`.
    ///
    /// Finite `gain_db` is clamped to `[-24.0, +6.0]` dB (non-finite defaults to `0.0`);
    /// finite positive `peak` is preserved (otherwise defaults to `1.0`).
    pub fn new(gain_db: f32, peak: f32) -> Self {
        let gain_db = if gain_db.is_finite() {
            gain_db.clamp(Self::MIN_GAIN_DB, Self::MAX_POSITIVE_GAIN_DB)
        } else {
            0.0
        };
        let peak = if peak.is_finite() && peak > 0.0 {
            peak
        } else {
            1.0
        };
        Self { gain_db, peak }
    }

    /// Returns a sanitized copy with `gain_db` clamped to `[-24.0, +6.0]` dB and valid `peak`.
    pub fn sanitized(self) -> Self {
        Self::new(self.gain_db, self.peak)
    }

    /// Converts YouTube Music `loudnessDb` (positive = louder than -14 LUFS) to target gain.
    pub fn from_ytm_loudness_db(loudness_db: f32) -> Self {
        Self::new(-loudness_db, 1.0)
    }

    /// Converts ReplayGain 2.0 (-18 LUFS reference) to -14 LUFS target gain.
    pub fn from_replay_gain(gain_db: f32, peak: Option<f32>) -> Self {
        Self::new(gain_db + 4.0, peak.unwrap_or(1.0))
    }

    /// Converts Deezer `GAIN` (-15 LUFS reference) to -14 LUFS target gain.
    pub fn from_deezer_gain(gain_db: f32) -> Self {
        Self::new(gain_db + 1.0, 1.0)
    }

    /// Converts EBU R128 Q7.8 fixed-point gain (-23 LUFS reference) to -14 LUFS target gain.
    pub fn from_r128_q78(q78: i16) -> Self {
        Self::new((q78 as f32 / 256.0) + 9.0, 1.0)
    }
}

/// Composite cache/resolution key uniquely identifying a track stream at a specific quality.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct StreamKey {
    pub provider_id: String,
    pub track_id: String,
    pub quality_key: String,
}

impl StreamKey {
    /// Creates a composite stream key from provider identifier, track identifier, and quality key.
    pub fn new(
        provider_id: impl Into<String>,
        track_id: impl Into<String>,
        quality_key: impl Into<String>,
    ) -> Self {
        Self {
            provider_id: provider_id.into(),
            track_id: track_id.into(),
            quality_key: quality_key.into(),
        }
    }
}

impl fmt::Display for StreamKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}:{}:{}",
            self.provider_id, self.track_id, self.quality_key
        )
    }
}

/// Streaming transport, caching, and session reset capabilities for a provider.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct StreamProviderCapabilities {
    pub supports_l1_url_cache: bool,
    pub supports_l2_head_cache: bool,
    pub requires_range_chunking: bool,
    pub needs_network_epoch_reset: bool,
    pub default_l1_safety_margin_sec: u64,
}

impl StreamProviderCapabilities {
    pub const fn new(
        supports_l1_url_cache: bool,
        supports_l2_head_cache: bool,
        requires_range_chunking: bool,
        needs_network_epoch_reset: bool,
        default_l1_safety_margin_sec: u64,
    ) -> Self {
        Self {
            supports_l1_url_cache,
            supports_l2_head_cache,
            requires_range_chunking,
            needs_network_epoch_reset,
            default_l1_safety_margin_sec,
        }
    }

    pub const fn youtube_music() -> Self {
        Self::new(true, true, true, true, 1800)
    }

    pub const fn qobuz() -> Self {
        Self::new(true, true, true, false, 60)
    }

    pub const fn tidal() -> Self {
        Self::new(true, true, true, false, 60)
    }

    pub const fn deezer() -> Self {
        Self::new(true, true, true, false, 120)
    }

    pub const fn apple_music() -> Self {
        Self::new(false, false, false, false, 0)
    }

    pub const fn local() -> Self {
        Self::new(false, false, false, false, 0)
    }

    /// Resolves streaming capabilities for a normalized provider identifier.
    pub fn for_provider(provider_id: &str) -> Self {
        match provider_id.trim().to_ascii_lowercase().as_str() {
            "youtube_music" | "ytm" => Self::youtube_music(),
            "qobuz" => Self::qobuz(),
            "tidal" => Self::tidal(),
            "deezer" => Self::deezer(),
            "apple_music" => Self::apple_music(),
            "local" => Self::local(),
            _ => Self::default(),
        }
    }
}

/// Identifies one of the two native playback decks in the dual-deck gapless engine.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
pub enum DeckId {
    #[default]
    DeckA = 0,
    DeckB = 1,
}

impl DeckId {
    /// Returns the opposite deck.
    #[inline]
    pub const fn other(self) -> Self {
        match self {
            Self::DeckA => Self::DeckB,
            Self::DeckB => Self::DeckA,
        }
    }

    /// Returns the zero-based array index (`0` for Deck A, `1` for Deck B).
    #[inline]
    pub const fn index(self) -> usize {
        self as usize
    }

    /// Maps a numeric deck index (`0` or `1`) back into a [`DeckId`], defaulting to [`DeckId::DeckA`].
    #[inline]
    pub const fn from_index(idx: u8) -> Self {
        match idx {
            1 => Self::DeckB,
            _ => Self::DeckA,
        }
    }

    /// Returns the canonical snake-case string representation (`"deck_a"` or `"deck_b"`).
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::DeckA => "deck_a",
            Self::DeckB => "deck_b",
        }
    }
}

impl fmt::Display for DeckId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Lifecycle states of an individual deck in the dual-deck state machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
#[repr(u8)]
pub enum DeckState {
    #[default]
    Idle = 0,
    Resolving = 1,
    Prebuffering = 2,
    StandbyReady = 3,
    Playing = 4,
    Seeking = 5,
    #[serde(rename = "RECOVERING_403", alias = "RECOVERING403")]
    Recovering403 = 6,
    Draining = 7,
}

impl DeckState {
    /// Converts a raw `u8` discriminant into a [`DeckState`], falling back to [`DeckState::Idle`].
    #[inline]
    pub const fn from_u8(v: u8) -> Self {
        match v {
            0 => Self::Idle,
            1 => Self::Resolving,
            2 => Self::Prebuffering,
            3 => Self::StandbyReady,
            4 => Self::Playing,
            5 => Self::Seeking,
            6 => Self::Recovering403,
            7 => Self::Draining,
            _ => Self::Idle,
        }
    }

    /// Returns the canonical uppercase string name of this deck state.
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Idle => "IDLE",
            Self::Resolving => "RESOLVING",
            Self::Prebuffering => "PREBUFFERING",
            Self::StandbyReady => "STANDBY_READY",
            Self::Playing => "PLAYING",
            Self::Seeking => "SEEKING",
            Self::Recovering403 => "RECOVERING_403",
            Self::Draining => "DRAINING",
        }
    }
}

impl fmt::Display for DeckState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Snapshot of the dual-deck engine state, standby readiness, and transition telemetry.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct DualDeckStatusSnapshot {
    pub active_deck: DeckId,
    pub deck_a_state: DeckState,
    pub deck_b_state: DeckState,
    pub deck_a_key: Option<StreamKey>,
    pub deck_b_key: Option<StreamKey>,
    pub standby_buffered_ms: u64,
    pub gapless_transitions: u64,
    pub manual_zero_latency_switches: u64,
    pub format_mismatch_recoveries: u64,
}

pub const L2_MIN_TARGET_BYTES: u64 = 524_288;
pub const L2_MAX_TARGET_BYTES: u64 = 4_194_304;
pub const L2_DEEZER_STRIPE_ALIGNMENT: u64 = 6_144;
pub const L2_TAIL_FINGERPRINT_LEN: usize = 64;
pub const L2_DEFAULT_HIGH_WATERMARK_BYTES: u64 = 1024 * 1024 * 1024;
pub const L2_DEFAULT_LOW_WATERMARK_BYTES: u64 = 800 * 1024 * 1024;

/// Storage layout format for an L2 head-chunk entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum L2CacheKind {
    DirectHead,
    DashInitSegs,
}

impl L2CacheKind {
    /// Returns the canonical snake-case string representation for SQLite storage.
    #[inline]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::DirectHead => "direct_head",
            Self::DashInitSegs => "dash_init_segs",
        }
    }

    /// Parses a canonical cache kind string (`"direct_head"` or `"dash_init_segs"`).
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "direct_head" => Some(Self::DirectHead),
            "dash_init_segs" => Some(Self::DashInitSegs),
            _ => None,
        }
    }
}

impl fmt::Display for L2CacheKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Computes the dynamic ~8-second L2 head-chunk byte budget for a stream.
///
/// The raw budget is derived from `(bitrate_bps / 8) * 8`, clamped to
/// `[L2_MIN_TARGET_BYTES, L2_MAX_TARGET_BYTES]`. For Deezer (or when
/// `force_deezer_alignment` is set), the budget is rounded up to a 6,144-byte
/// Blowfish stripe boundary within `[528_384, 4_190_208]`, then capped at
/// `total_content_length` when known.
pub fn compute_l2_target_bytes(
    provider_id: &str,
    bitrate_bps: Option<u64>,
    total_content_length: Option<u64>,
    force_deezer_alignment: bool,
) -> u64 {
    let mut target = (bitrate_bps.unwrap_or(L2_MIN_TARGET_BYTES) / 8)
        .saturating_mul(8)
        .clamp(L2_MIN_TARGET_BYTES, L2_MAX_TARGET_BYTES);

    if force_deezer_alignment || provider_id.trim().eq_ignore_ascii_case("deezer") {
        let blocks = target
            .div_ceil(L2_DEEZER_STRIPE_ALIGNMENT)
            .clamp(86, L2_MAX_TARGET_BYTES / L2_DEEZER_STRIPE_ALIGNMENT);
        target = blocks * L2_DEEZER_STRIPE_ALIGNMENT;
    }

    if let Some(total) = total_content_length {
        target = target.min(total);
    }

    target
}

/// Adaptive streaming manifest format.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ManifestFormat {
    Dash,
    Hls,
}

/// Stream payload encryption specification for encrypted range transports.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum StreamCipher {
    DeezerBlowfish {
        track_id: String,
        #[serde(default = "default_deezer_block_size")]
        block_size: usize,
        #[serde(default = "default_deezer_stride")]
        stride: usize,
    },
}

/// Declarative stream source specification passed from resolvers to audio proxies/backends.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum StreamSourceSpec {
    DirectRange {
        key: StreamKey,
        url: String,
        #[serde(default, alias = "http_headers")]
        headers: BTreeMap<String, String>,
        #[serde(default)]
        content_length: Option<u64>,
        #[serde(default)]
        bitrate_bps: Option<u64>,
        #[serde(default)]
        mime_type: Option<String>,
        #[serde(default)]
        hint_extension: Option<String>,
        #[serde(default)]
        expire_at: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        init_range_end: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        index_range_start: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        index_range_end: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        loudness: Option<NormalizedLoudness>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        album_loudness: Option<NormalizedLoudness>,
    },
    SegmentedManifest {
        key: StreamKey,
        manifest_url_or_xml: String,
        format: ManifestFormat,
        #[serde(default, alias = "http_headers")]
        headers: BTreeMap<String, String>,
        #[serde(default)]
        bitrate_bps: Option<u64>,
        #[serde(default)]
        mime_type: Option<String>,
        #[serde(default)]
        expire_at: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        loudness: Option<NormalizedLoudness>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        album_loudness: Option<NormalizedLoudness>,
    },
    EncryptedRange {
        key: StreamKey,
        url: String,
        #[serde(default, alias = "http_headers")]
        headers: BTreeMap<String, String>,
        #[serde(default)]
        content_length: Option<u64>,
        #[serde(default)]
        bitrate_bps: Option<u64>,
        #[serde(default)]
        mime_type: Option<String>,
        #[serde(default)]
        hint_extension: Option<String>,
        cipher: StreamCipher,
        #[serde(default)]
        expire_at: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        loudness: Option<NormalizedLoudness>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        album_loudness: Option<NormalizedLoudness>,
    },
    LocalFile {
        key: StreamKey,
        path: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        loudness: Option<NormalizedLoudness>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        album_loudness: Option<NormalizedLoudness>,
    },
    ExternalBackend {
        key: StreamKey,
        provider_id: String,
        track_uri: String,
        #[serde(default)]
        external_web_url: Option<String>,
        #[serde(default)]
        preview_url: Option<String>,
        #[serde(default)]
        notice: Option<String>,
    },
}

impl StreamSourceSpec {
    /// Returns the composite stream key associated with this source specification.
    pub fn key(&self) -> &StreamKey {
        match self {
            Self::DirectRange { key, .. }
            | Self::SegmentedManifest { key, .. }
            | Self::EncryptedRange { key, .. }
            | Self::LocalFile { key, .. }
            | Self::ExternalBackend { key, .. } => key,
        }
    }

    /// Returns track-level normalized loudness metadata, if present.
    pub fn loudness(&self) -> Option<NormalizedLoudness> {
        match self {
            Self::DirectRange { loudness, .. }
            | Self::SegmentedManifest { loudness, .. }
            | Self::EncryptedRange { loudness, .. }
            | Self::LocalFile { loudness, .. } => *loudness,
            Self::ExternalBackend { .. } => None,
        }
    }

    /// Returns album-level normalized loudness metadata, if present.
    pub fn album_loudness(&self) -> Option<NormalizedLoudness> {
        match self {
            Self::DirectRange { album_loudness, .. }
            | Self::SegmentedManifest { album_loudness, .. }
            | Self::EncryptedRange { album_loudness, .. }
            | Self::LocalFile { album_loudness, .. } => *album_loudness,
            Self::ExternalBackend { .. } => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn test_stream_key_equality_and_hashing() {
        let k1 = StreamKey::new("qobuz", "12345", "hi_res_192");
        let k2 = StreamKey::new("qobuz", "12345", "hi_res_192");
        let k3 = StreamKey::new("qobuz", "12345", "lossless");
        let k4 = StreamKey::new("tidal", "12345", "hi_res_192");

        assert_eq!(k1, k2);
        assert_ne!(k1, k3);
        assert_ne!(k1, k4);
        assert_eq!(k1.to_string(), "qobuz:12345:hi_res_192");

        let mut set = HashSet::new();
        set.insert(k1.clone());
        assert!(set.contains(&k2));
        assert!(!set.contains(&k3));
        assert!(!set.contains(&k4));
    }

    #[test]
    fn test_stream_provider_capabilities_presets() {
        assert_eq!(
            StreamProviderCapabilities::youtube_music(),
            StreamProviderCapabilities {
                supports_l1_url_cache: true,
                supports_l2_head_cache: true,
                requires_range_chunking: true,
                needs_network_epoch_reset: true,
                default_l1_safety_margin_sec: 1800,
            }
        );
        assert_eq!(
            StreamProviderCapabilities::qobuz(),
            StreamProviderCapabilities {
                supports_l1_url_cache: true,
                supports_l2_head_cache: true,
                requires_range_chunking: true,
                needs_network_epoch_reset: false,
                default_l1_safety_margin_sec: 60,
            }
        );
        assert_eq!(
            StreamProviderCapabilities::tidal(),
            StreamProviderCapabilities {
                supports_l1_url_cache: true,
                supports_l2_head_cache: true,
                requires_range_chunking: true,
                needs_network_epoch_reset: false,
                default_l1_safety_margin_sec: 60,
            }
        );
        assert_eq!(
            StreamProviderCapabilities::deezer(),
            StreamProviderCapabilities {
                supports_l1_url_cache: true,
                supports_l2_head_cache: true,
                requires_range_chunking: true,
                needs_network_epoch_reset: false,
                default_l1_safety_margin_sec: 120,
            }
        );
        assert_eq!(
            StreamProviderCapabilities::apple_music(),
            StreamProviderCapabilities::default()
        );
        assert_eq!(
            StreamProviderCapabilities::local(),
            StreamProviderCapabilities::default()
        );

        let caps_json = serde_json::to_string(&StreamProviderCapabilities::youtube_music()).unwrap();
        let caps_back: StreamProviderCapabilities = serde_json::from_str(&caps_json).unwrap();
        assert_eq!(caps_back, StreamProviderCapabilities::youtube_music());
    }

    #[test]
    fn test_stream_source_spec_all_variants_serde_roundtrip() {
        let mut headers = BTreeMap::new();
        headers.insert("Authorization".to_string(), "Bearer tok".to_string());

        let direct = StreamSourceSpec::DirectRange {
            key: StreamKey::new("qobuz", "99", "27"),
            url: "https://cdn.example.com/99.flac".to_string(),
            headers: headers.clone(),
            content_length: Some(42_000_000),
            bitrate_bps: Some(4_608_000),
            mime_type: Some("audio/flac".to_string()),
            hint_extension: Some("flac".to_string()),
            expire_at: Some(1_760_000_000),
            init_range_end: None,
            index_range_start: None,
            index_range_end: None,
            loudness: None,
            album_loudness: None,
        };
        let direct_val = serde_json::to_value(&direct).unwrap();
        assert_eq!(direct_val["kind"], "direct_range");
        assert!(direct_val.get("init_range_end").is_none());
        assert!(direct_val.get("loudness").is_none());
        assert!(direct_val.get("album_loudness").is_none());
        assert_eq!(
            serde_json::from_value::<StreamSourceSpec>(direct_val).unwrap(),
            direct
        );

        let direct_with_ranges = StreamSourceSpec::DirectRange {
            key: StreamKey::new("youtube_music", "dQw4w9WgXcQ", "default"),
            url: "https://rr1.googlevideo.com/videoplayback?itag=251".to_string(),
            headers: BTreeMap::new(),
            content_length: Some(4_194_304),
            bitrate_bps: Some(160_000),
            mime_type: Some("audio/webm; codecs=\"opus\"".to_string()),
            hint_extension: Some("webm".to_string()),
            expire_at: Some(1_760_000_000),
            init_range_end: Some(740),
            index_range_start: Some(741),
            index_range_end: Some(1105),
            loudness: None,
            album_loudness: None,
        };
        let ranged_val = serde_json::to_value(&direct_with_ranges).unwrap();
        assert_eq!(ranged_val["init_range_end"], 740);
        assert_eq!(ranged_val["index_range_start"], 741);
        assert_eq!(ranged_val["index_range_end"], 1105);
        assert_eq!(
            serde_json::from_value::<StreamSourceSpec>(ranged_val).unwrap(),
            direct_with_ranges
        );

        let segmented = StreamSourceSpec::SegmentedManifest {
            key: StreamKey::new("tidal", "123", "HI_RES_LOSSLESS"),
            manifest_url_or_xml: "<MPD/>".to_string(),
            format: ManifestFormat::Dash,
            headers: headers.clone(),
            bitrate_bps: Some(3_200_000),
            mime_type: Some("application/dash+xml".to_string()),
            expire_at: None,
            loudness: None,
            album_loudness: None,
        };
        let seg_val = serde_json::to_value(&segmented).unwrap();
        assert_eq!(seg_val["kind"], "segmented_manifest");
        assert_eq!(seg_val["format"], "dash");
        assert_eq!(
            serde_json::from_value::<StreamSourceSpec>(seg_val).unwrap(),
            segmented
        );

        let hls: ManifestFormat = serde_json::from_str(r#""hls""#).unwrap();
        assert_eq!(hls, ManifestFormat::Hls);

        let encrypted = StreamSourceSpec::EncryptedRange {
            key: StreamKey::new("deezer", "554433", "FLAC"),
            url: "https://e-cdns-proxy.dzcdn.net/stream".to_string(),
            headers,
            content_length: Some(30_000_000),
            bitrate_bps: Some(1_411_200),
            mime_type: Some("audio/flac".to_string()),
            hint_extension: Some("flac".to_string()),
            cipher: StreamCipher::DeezerBlowfish {
                track_id: "554433".to_string(),
                block_size: DEFAULT_DEEZER_BLOCK_SIZE,
                stride: DEFAULT_DEEZER_STRIDE,
            },
            expire_at: Some(1_760_001_000),
            loudness: None,
            album_loudness: None,
        };
        let enc_val = serde_json::to_value(&encrypted).unwrap();
        assert_eq!(enc_val["kind"], "encrypted_range");
        assert_eq!(enc_val["cipher"]["kind"], "deezer_blowfish");
        assert_eq!(enc_val["cipher"]["block_size"], 2048);
        assert_eq!(enc_val["cipher"]["stride"], 3);
        assert_eq!(
            serde_json::from_value::<StreamSourceSpec>(enc_val).unwrap(),
            encrypted
        );

        // Verify StreamCipher defaults when block_size and stride are omitted
        let minimal_cipher_json = r#"{
            "kind": "encrypted_range",
            "key": { "provider_id": "deezer", "track_id": "777", "quality_key": "MP3_320" },
            "url": "https://cdn.dzcdn.net/777",
            "cipher": { "kind": "deezer_blowfish", "track_id": "777" }
        }"#;
        let minimal_enc: StreamSourceSpec = serde_json::from_str(minimal_cipher_json).unwrap();
        match minimal_enc {
            StreamSourceSpec::EncryptedRange { cipher, headers, .. } => {
                assert!(headers.is_empty());
                assert_eq!(
                    cipher,
                    StreamCipher::DeezerBlowfish {
                        track_id: "777".to_string(),
                        block_size: 2048,
                        stride: 3,
                    }
                );
            }
            other => panic!("expected EncryptedRange, got {other:?}"),
        }

        let local = StreamSourceSpec::LocalFile {
            key: StreamKey::new("local", "C:/Music/01.flac", "native"),
            path: "C:/Music/01.flac".to_string(),
            loudness: None,
            album_loudness: None,
        };
        let local_val = serde_json::to_value(&local).unwrap();
        assert_eq!(local_val["kind"], "local_file");
        assert_eq!(
            serde_json::from_value::<StreamSourceSpec>(local_val).unwrap(),
            local
        );

        let external = StreamSourceSpec::ExternalBackend {
            key: StreamKey::new("apple_music", "1440857781", "lossless"),
            provider_id: "apple_music".to_string(),
            track_uri: "apple:1440857781".to_string(),
            external_web_url: Some("https://music.apple.com/us/song/1440857781".to_string()),
            preview_url: Some("https://audio-ssl.itunes.apple.com/preview.m4a".to_string()),
            notice: Some("FairPlay external playback".to_string()),
        };
        let ext_val = serde_json::to_value(&external).unwrap();
        assert_eq!(ext_val["kind"], "external_backend");
        assert_eq!(
            serde_json::from_value::<StreamSourceSpec>(ext_val).unwrap(),
            external
        );
        assert_eq!(external.key(), &StreamKey::new("apple_music", "1440857781", "lossless"));
        assert_eq!(external.loudness(), None);
        assert_eq!(external.album_loudness(), None);
    }

    #[test]
    fn test_normalized_loudness_helpers_and_sanitization() {
        assert_eq!(NormalizedLoudness::TARGET_LUFS, -14.0);

        // Clamping & non-finite / invalid peak sanitization
        assert_eq!(
            NormalizedLoudness::new(-40.0, 0.95),
            NormalizedLoudness { gain_db: -24.0, peak: 0.95 }
        );
        assert_eq!(
            NormalizedLoudness::new(25.0, 1.02),
            NormalizedLoudness { gain_db: 6.0, peak: 1.02 }
        );
        // Serde deserialization must also enforce the [-24.0, +6.0] dB cap and valid peak.
        let deser_capped: NormalizedLoudness =
            serde_json::from_str(r#"{"gain_db":18.5,"peak":-2.0}"#).unwrap();
        assert_eq!(
            deser_capped,
            NormalizedLoudness { gain_db: 6.0, peak: 1.0 }
        );
        let deser_floor: NormalizedLoudness =
            serde_json::from_str(r#"{"gain_db":-48.0}"#).unwrap();
        assert_eq!(
            deser_floor,
            NormalizedLoudness { gain_db: -24.0, peak: 1.0 }
        );
        assert_eq!(
            NormalizedLoudness::new(f32::NAN, 0.0),
            NormalizedLoudness { gain_db: 0.0, peak: 1.0 }
        );
        assert_eq!(
            NormalizedLoudness::new(f32::INFINITY, -0.5),
            NormalizedLoudness { gain_db: 0.0, peak: 1.0 }
        );
        assert_eq!(
            NormalizedLoudness::new(-3.0, f32::NAN),
            NormalizedLoudness { gain_db: -3.0, peak: 1.0 }
        );

        // YTM loudnessDb (+3.5 dB louder than -14 LUFS => -3.5 dB attenuation)
        assert_eq!(
            NormalizedLoudness::from_ytm_loudness_db(3.5),
            NormalizedLoudness { gain_db: -3.5, peak: 1.0 }
        );
        assert_eq!(
            NormalizedLoudness::from_ytm_loudness_db(-2.25),
            NormalizedLoudness { gain_db: 2.25, peak: 1.0 }
        );

        // ReplayGain 2.0 (-18 LUFS => +4.0 dB shift to -14 LUFS)
        assert_eq!(
            NormalizedLoudness::from_replay_gain(-7.5, Some(0.988)),
            NormalizedLoudness { gain_db: -3.5, peak: 0.988 }
        );
        assert_eq!(
            NormalizedLoudness::from_replay_gain(-6.0, None),
            NormalizedLoudness { gain_db: -2.0, peak: 1.0 }
        );

        // Deezer GAIN (-15 LUFS => +1.0 dB shift to -14 LUFS)
        let dz = NormalizedLoudness::from_deezer_gain(-4.2);
        assert!((dz.gain_db - (-3.2)).abs() < 1e-5);
        assert_eq!(dz.peak, 1.0);

        // EBU R128 Q7.8 (-23 LUFS => +9.0 dB shift to -14 LUFS; -2304 / 256 = -9.0 dB => 0.0 dB)
        assert_eq!(
            NormalizedLoudness::from_r128_q78(-2304),
            NormalizedLoudness { gain_db: 0.0, peak: 1.0 }
        );
        assert_eq!(
            NormalizedLoudness::from_r128_q78(-3072),
            NormalizedLoudness { gain_db: -3.0, peak: 1.0 }
        );
    }

    #[test]
    fn test_stream_source_spec_loudness_serde_and_backward_compat() {
        let track_loudness = NormalizedLoudness::from_replay_gain(-8.0, Some(0.95));
        let album_loudness = NormalizedLoudness::from_replay_gain(-6.5, Some(0.99));

        // 1. Round-trip with loudness populated
        let spec = StreamSourceSpec::LocalFile {
            key: StreamKey::new("local", "/music/track.flac", "native"),
            path: "/music/track.flac".to_string(),
            loudness: Some(track_loudness),
            album_loudness: Some(album_loudness),
        };
        assert_eq!(spec.loudness(), Some(track_loudness));
        assert_eq!(spec.album_loudness(), Some(album_loudness));
        let val = serde_json::to_value(&spec).unwrap();
        assert_eq!(val["loudness"]["gain_db"], -4.0);
        assert!((val["loudness"]["peak"].as_f64().unwrap() - 0.95).abs() < 1e-6);
        assert_eq!(val["album_loudness"]["gain_db"], -2.5);
        let decoded: StreamSourceSpec = serde_json::from_value(val).unwrap();
        assert_eq!(decoded, spec);

        // 2. Backward compatibility: legacy JSON omitting loudness/album_loudness across all 4 variants
        let legacy_payloads = [
            r#"{"kind":"direct_range","key":{"provider_id":"qobuz","track_id":"1","quality_key":"27"},"url":"https://cdn.example.com/1.flac"}"#,
            r#"{"kind":"segmented_manifest","key":{"provider_id":"tidal","track_id":"2","quality_key":"HI_RES"},"manifest_url_or_xml":"<MPD/>","format":"dash"}"#,
            r#"{"kind":"encrypted_range","key":{"provider_id":"deezer","track_id":"3","quality_key":"FLAC"},"url":"https://cdn.dzcdn.net/3","cipher":{"kind":"deezer_blowfish","track_id":"3"}}"#,
            r#"{"kind":"local_file","key":{"provider_id":"local","track_id":"4","quality_key":"native"},"path":"C:/Music/4.flac"}"#,
        ];
        for raw in legacy_payloads {
            let parsed: StreamSourceSpec = serde_json::from_str(raw).unwrap();
            assert_eq!(parsed.loudness(), None);
            assert_eq!(parsed.album_loudness(), None);
            let reserialized = serde_json::to_value(&parsed).unwrap();
            assert!(reserialized.get("loudness").is_none());
            assert!(reserialized.get("album_loudness").is_none());
        }
    }

    #[test]
    fn test_stream_provider_capabilities_for_provider() {
        assert_eq!(
            StreamProviderCapabilities::for_provider("youtube_music"),
            StreamProviderCapabilities::youtube_music()
        );
        assert_eq!(
            StreamProviderCapabilities::for_provider("ytm"),
            StreamProviderCapabilities::youtube_music()
        );
        assert_eq!(
            StreamProviderCapabilities::for_provider(" YTM "),
            StreamProviderCapabilities::youtube_music()
        );
        assert_eq!(
            StreamProviderCapabilities::for_provider("qobuz"),
            StreamProviderCapabilities::qobuz()
        );
        assert_eq!(
            StreamProviderCapabilities::for_provider("tidal"),
            StreamProviderCapabilities::tidal()
        );
        assert_eq!(
            StreamProviderCapabilities::for_provider("Deezer"),
            StreamProviderCapabilities::deezer()
        );
        assert_eq!(
            StreamProviderCapabilities::for_provider("apple_music"),
            StreamProviderCapabilities::apple_music()
        );
        assert!(!StreamProviderCapabilities::for_provider("apple_music").supports_l2_head_cache);
        assert_eq!(
            StreamProviderCapabilities::for_provider("local"),
            StreamProviderCapabilities::local()
        );
        assert!(!StreamProviderCapabilities::for_provider("local").supports_l2_head_cache);
        assert_eq!(
            StreamProviderCapabilities::for_provider("spotify"),
            StreamProviderCapabilities::default()
        );
        assert_eq!(
            StreamProviderCapabilities::for_provider(""),
            StreamProviderCapabilities::default()
        );
    }

    #[test]
    fn test_deck_id_state_and_snapshot_roundtrip() {
        assert_eq!(DeckId::DeckA.other(), DeckId::DeckB);
        assert_eq!(DeckId::DeckB.other(), DeckId::DeckA);
        assert_eq!(DeckId::DeckA.index(), 0);
        assert_eq!(DeckId::DeckB.index(), 1);
        assert_eq!(DeckId::from_index(0), DeckId::DeckA);
        assert_eq!(DeckId::from_index(1), DeckId::DeckB);
        assert_eq!(DeckId::from_index(255), DeckId::DeckA);
        assert_eq!(DeckId::DeckA.as_str(), "deck_a");
        assert_eq!(DeckId::DeckB.as_str(), "deck_b");
        assert_eq!(serde_json::to_string(&DeckId::DeckA).unwrap(), r#""deck_a""#);
        assert_eq!(serde_json::to_string(&DeckId::DeckB).unwrap(), r#""deck_b""#);
        assert_eq!(serde_json::from_str::<DeckId>(r#""deck_b""#).unwrap(), DeckId::DeckB);

        let expected_states = [
            (0u8, DeckState::Idle, "IDLE"),
            (1, DeckState::Resolving, "RESOLVING"),
            (2, DeckState::Prebuffering, "PREBUFFERING"),
            (3, DeckState::StandbyReady, "STANDBY_READY"),
            (4, DeckState::Playing, "PLAYING"),
            (5, DeckState::Seeking, "SEEKING"),
            (6, DeckState::Recovering403, "RECOVERING_403"),
            (7, DeckState::Draining, "DRAINING"),
        ];
        for (raw, state, label) in expected_states {
            assert_eq!(DeckState::from_u8(raw), state);
            assert_eq!(state as u8, raw);
            assert_eq!(state.as_str(), label);
            assert_eq!(state.to_string(), label);
            let json = serde_json::to_string(&state).unwrap();
            assert_eq!(json, format!(r#""{label}""#));
            assert_eq!(serde_json::from_str::<DeckState>(&json).unwrap(), state);
        }
        assert_eq!(DeckState::from_u8(8), DeckState::Idle);
        assert_eq!(DeckState::from_u8(255), DeckState::Idle);
        assert_eq!(
            serde_json::from_str::<DeckState>(r#""RECOVERING403""#).unwrap(),
            DeckState::Recovering403
        );

        let snapshot = DualDeckStatusSnapshot {
            active_deck: DeckId::DeckB,
            deck_a_state: DeckState::StandbyReady,
            deck_b_state: DeckState::Playing,
            deck_a_key: Some(StreamKey::new("tidal", "100", "HI_RES")),
            deck_b_key: Some(StreamKey::new("qobuz", "200", "27")),
            standby_buffered_ms: 2_850,
            gapless_transitions: 4,
            manual_zero_latency_switches: 2,
            format_mismatch_recoveries: 1,
        };
        let snap_json = serde_json::to_string(&snapshot).unwrap();
        let snap_back: DualDeckStatusSnapshot = serde_json::from_str(&snap_json).unwrap();
        assert_eq!(snap_back, snapshot);
    }

    #[test]
    fn test_l2_cache_kind_and_compute_l2_target_bytes() {
        assert_eq!(L2CacheKind::DirectHead.as_str(), "direct_head");
        assert_eq!(L2CacheKind::DashInitSegs.as_str(), "dash_init_segs");
        assert_eq!(L2CacheKind::parse("direct_head"), Some(L2CacheKind::DirectHead));
        assert_eq!(
            L2CacheKind::parse(" DASH_INIT_SEGS "),
            Some(L2CacheKind::DashInitSegs)
        );
        assert_eq!(L2CacheKind::parse("unknown"), None);
        assert_eq!(
            serde_json::to_string(&L2CacheKind::DashInitSegs).unwrap(),
            r#""dash_init_segs""#
        );

        // YTM / lossy streams clamp up to L2_MIN_TARGET_BYTES (512 KiB)
        assert_eq!(
            compute_l2_target_bytes("youtube_music", Some(128_000), None, false),
            L2_MIN_TARGET_BYTES
        );
        assert_eq!(
            compute_l2_target_bytes("ytm", Some(160_000), Some(3_500_000), false),
            524_288
        );
        assert_eq!(
            compute_l2_target_bytes("qobuz", None, None, false),
            L2_MIN_TARGET_BYTES
        );

        // 16-bit / 44.1 kHz CD FLAC (~1,411,200 bps => ~1.41 MB for 8s)
        assert_eq!(
            compute_l2_target_bytes("qobuz", Some(1_411_200), Some(30_000_000), false),
            1_411_200
        );

        // 24-bit / 96 kHz Hi-Res FLAC (4,608,000 bps => clamped to 4 MiB)
        assert_eq!(
            compute_l2_target_bytes("tidal", Some(4_608_000), Some(120_000_000), false),
            L2_MAX_TARGET_BYTES
        );

        // Deezer 6,144-byte stripe alignment
        let dz_lossy = compute_l2_target_bytes("deezer", Some(320_000), Some(8_000_000), false);
        assert_eq!(dz_lossy, 86 * L2_DEEZER_STRIPE_ALIGNMENT); // 528_384
        assert_eq!(dz_lossy % L2_DEEZER_STRIPE_ALIGNMENT, 0);

        let dz_cd = compute_l2_target_bytes("deezer", Some(1_411_200), Some(30_000_000), false);
        assert_eq!(dz_cd, 230 * L2_DEEZER_STRIPE_ALIGNMENT); // 1_413_120
        assert_eq!(dz_cd % L2_DEEZER_STRIPE_ALIGNMENT, 0);

        let dz_hires = compute_l2_target_bytes("qobuz", Some(4_608_000), Some(90_000_000), true);
        assert_eq!(dz_hires, 682 * L2_DEEZER_STRIPE_ALIGNMENT); // 4_190_208
        assert_eq!(dz_hires % L2_DEEZER_STRIPE_ALIGNMENT, 0);
        assert!(dz_hires <= L2_MAX_TARGET_BYTES);

        // Small total_content_length clamping (both non-Deezer and Deezer)
        assert_eq!(
            compute_l2_target_bytes("qobuz", Some(1_411_200), Some(200_000), false),
            200_000
        );
        assert_eq!(
            compute_l2_target_bytes("deezer", Some(320_000), Some(123_456), false),
            123_456
        );
    }

    #[test]
    fn test_stream_source_spec_headers_and_http_headers_alias() {
        let json_alias = r#"{
            "kind": "direct_range",
            "key": { "provider_id": "youtube_music", "track_id": "abc12345678", "quality_key": "251" },
            "url": "https://rr1.googlevideo.com/videoplayback?itag=251",
            "http_headers": { "User-Agent": "LuminaAgent/1.0", "Origin": "https://music.youtube.com" },
            "mime_type": "audio/webm; codecs=\"opus\""
        }"#;
        let parsed: StreamSourceSpec = serde_json::from_str(json_alias).unwrap();
        match &parsed {
            StreamSourceSpec::DirectRange { headers, .. } => {
                assert_eq!(headers.get("User-Agent").map(String::as_str), Some("LuminaAgent/1.0"));
                assert_eq!(
                    headers.get("Origin").map(String::as_str),
                    Some("https://music.youtube.com")
                );
            }
            other => panic!("expected DirectRange, got {other:?}"),
        }
        let serialized = serde_json::to_value(&parsed).unwrap();
        assert!(serialized.get("headers").is_some(), "canonical wire key must remain 'headers'");
        assert!(serialized.get("http_headers").is_none());
    }
}
