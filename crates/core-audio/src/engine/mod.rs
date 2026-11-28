//! Audio playback engine facade (`AudioPlayer`), shared state (`PlayerInner`),
//! coordinator, dual-deck feeders, and output session management.

pub(crate) mod coordinator;
pub(crate) mod dsp_helpers;
pub(crate) mod dual_deck;
mod player_commit;
mod player_control;
mod player_devices;
mod player_lifecycle;
mod player_queue;
mod player_standby;
mod player_start;
mod player_status;
pub(crate) mod session;
#[cfg(test)]
mod tests;
pub(crate) mod types;

use std::sync::{Arc, mpsc};
use std::thread;

pub use crate::backend::cpal_shared::{
    enumerate_cpal_devices, rank_sample_format, select_best_config_index,
};
pub use crate::backend::device_fsm::OutputDeviceState;
pub use crate::dsp::StreamingSincResampler;
use crate::engine::coordinator::{PlayerCommand, coordinator_loop};
use crate::engine::session::relay_loop;
#[allow(unused_imports)]
pub(crate) use crate::pipeline::fade::AudioFadeControl;
pub use core_types::PlaybackLifecycleState;
#[allow(unused_imports)]
pub(crate) use dsp_helpers::{
    compute_effective_replay_gain_db, is_any_dsp_active, position_ms_from_inner,
    record_playback_error, record_playback_error_with_code, to_internal_replay_gain,
    to_parametric_bands,
};
pub use types::{ActiveTrackMeta, DEFAULT_IDLE_RECLAIM_THRESHOLD, PlayerOrigin};
#[allow(unused_imports)]
pub(crate) use types::{
    PlayerInner, TrackReplayGainTags, VIRTUAL_DEVICE_ID, VIRTUAL_DEVICE_NAME,
    decode_device_fsm_state, default_shared_dsp_config, encode_device_fsm_state,
};

/// Real streaming audio player supporting Symphonia PCM, HTTP/HTTPS range-buffered streams,
/// DSF/DSDIFF DSD decimation, 64-bit float DSP with live reconfiguration & one-click bypass,
/// lock-free SPSC ring buffering, and `cpal` device enumeration & output.
#[derive(Clone)]
pub struct AudioPlayer {
    pub(super) inner: Arc<PlayerInner>,
    pub(super) cmd_tx: mpsc::Sender<PlayerCommand>,
}

impl std::fmt::Debug for AudioPlayer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AudioPlayer")
            .field("headless", &self.inner.headless)
            .field("state_code", &self.state_code())
            .finish()
    }
}

impl Default for AudioPlayer {
    fn default() -> Self {
        Self::new()
    }
}

impl AudioPlayer {
    /// Creates an audio player bound to the host's real audio output device (`cpal`),
    /// falling back gracefully to a paced virtual output consumer if no device is available.
    pub fn new() -> Self {
        Self::create(false)
    }

    /// Creates a deterministic headless player that runs the full decode, DSP, and SPSC
    /// ring-buffer pipeline into a paced virtual DAC consumer without touching physical speakers.
    pub fn new_headless() -> Self {
        Self::create(true)
    }

    fn create(headless: bool) -> Self {
        let _ = crate::visualizer::init_global_tap();
        let inner = Arc::new(PlayerInner::new(headless));
        let (cmd_tx, cmd_rx) = mpsc::channel();
        let _ = inner.cmd_tx_slot.set(cmd_tx.clone());
        let coord_inner = Arc::clone(&inner);
        let coord_tx = cmd_tx.clone();

        let relay_weak = Arc::downgrade(&inner);
        let relay_tx = cmd_tx.clone();
        let relay_jh = thread::Builder::new()
            .name("lumina-deck-relay".to_string())
            .spawn(move || relay_loop(relay_weak, relay_tx))
            .expect("spawn audio deck relay thread");
        let _ = inner.dual_deck.relay_thread.set(relay_jh.thread().clone());

        thread::Builder::new()
            .name("lumina-audio-coordinator".to_string())
            .spawn(move || coordinator_loop(coord_inner, cmd_rx, coord_tx))
            .expect("spawn audio coordinator thread");

        Self { inner, cmd_tx }
    }

    pub fn shutdown(&self) {
        self.stop();
        self.inner.dual_deck.stop_relay();
        let _ = self.cmd_tx.send(PlayerCommand::Shutdown);
    }
}
