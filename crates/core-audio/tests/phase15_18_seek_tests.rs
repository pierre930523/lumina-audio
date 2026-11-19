use std::fs;
use std::path::PathBuf;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use core_audio::{AudioPlayer, PlaybackLifecycleState};
use core_types::SignalQuality;

fn temp_audio_path(tag: &str, ext: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    std::env::temp_dir().join(format!("lumina_p15_18_{tag}_{nanos}.{ext}"))
}

fn build_wav_i16(rate: u32, ch: u16, num_frames: usize) -> Vec<u8> {
    let block_align = ch * 2;
    let byte_rate = rate * (block_align as u32);
    let data_len = (num_frames as u32) * (block_align as u32);

    let mut buf = Vec::with_capacity(44 + data_len as usize);
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&(36 + data_len).to_le_bytes());
    buf.extend_from_slice(b"WAVEfmt ");
    buf.extend_from_slice(&16u32.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes()); // PCM
    buf.extend_from_slice(&ch.to_le_bytes());
    buf.extend_from_slice(&rate.to_le_bytes());
    buf.extend_from_slice(&byte_rate.to_le_bytes());
    buf.extend_from_slice(&block_align.to_le_bytes());
    buf.extend_from_slice(&16u16.to_le_bytes());
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_len.to_le_bytes());

    for i in 0..num_frames {
        let sample = ((i * 123) % 20000) as i16 - 10000;
        for _ in 0..ch {
            buf.extend_from_slice(&sample.to_le_bytes());
        }
    }
    buf
}

fn build_wav_i24_packed(rate: u32, ch: u16, num_frames: usize) -> Vec<u8> {
    let block_align = ch * 3;
    let byte_rate = rate * (block_align as u32);
    let data_len = (num_frames as u32) * (block_align as u32);

    let mut buf = Vec::with_capacity(44 + data_len as usize);
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&(36 + data_len).to_le_bytes());
    buf.extend_from_slice(b"WAVEfmt ");
    buf.extend_from_slice(&16u32.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes());
    buf.extend_from_slice(&ch.to_le_bytes());
    buf.extend_from_slice(&rate.to_le_bytes());
    buf.extend_from_slice(&byte_rate.to_le_bytes());
    buf.extend_from_slice(&block_align.to_le_bytes());
    buf.extend_from_slice(&24u16.to_le_bytes());
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_len.to_le_bytes());

    for i in 0..num_frames {
        let sample = ((i * 456) % 500_000) as i32 - 250_000;
        let le = sample.to_le_bytes();
        for _ in 0..ch {
            buf.extend_from_slice(&le[0..3]);
        }
    }
    buf
}

fn build_dsf_multiblock(num_blocks: usize, block_size: usize) -> Vec<u8> {
    let rate = 2_822_400u32;
    let channels = 2u32;
    let total_frames = (num_blocks * block_size * 8) as u64;
    let data_payload_len = (num_blocks * block_size * channels as usize) as u64;
    let file_size = 28 + 52 + 12 + data_payload_len;

    let mut buf = Vec::with_capacity(file_size as usize);
    buf.extend_from_slice(b"DSD ");
    buf.extend_from_slice(&28u64.to_le_bytes());
    buf.extend_from_slice(&file_size.to_le_bytes());
    buf.extend_from_slice(&0u64.to_le_bytes()); // metadata offset

    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&52u64.to_le_bytes());
    buf.extend_from_slice(&1u32.to_le_bytes());
    buf.extend_from_slice(&0u32.to_le_bytes());
    buf.extend_from_slice(&2u32.to_le_bytes());
    buf.extend_from_slice(&channels.to_le_bytes());
    buf.extend_from_slice(&rate.to_le_bytes());
    buf.extend_from_slice(&1u32.to_le_bytes());
    buf.extend_from_slice(&total_frames.to_le_bytes());
    buf.extend_from_slice(&(block_size as u32).to_le_bytes());
    buf.extend_from_slice(&0u32.to_le_bytes());

    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&(12 + data_payload_len).to_le_bytes());
    for b in 0..num_blocks {
        let l_byte = (b & 0xFF) as u8;
        let r_byte = ((b + 1) & 0xFF) as u8;
        buf.extend(std::iter::repeat_n(l_byte, block_size));
        buf.extend(std::iter::repeat_n(r_byte, block_size));
    }
    buf
}

fn crc8_flac(data: &[u8]) -> u8 {
    let mut crc = 0u8;
    for &b in data {
        crc ^= b;
        for _ in 0..8 {
            crc = if (crc & 0x80) != 0 {
                (crc << 1) ^ 0x07
            } else {
                crc << 1
            };
        }
    }
    crc
}

fn crc16_flac(data: &[u8]) -> u16 {
    let mut crc = 0u16;
    for &b in data {
        crc ^= (b as u16) << 8;
        for _ in 0..8 {
            crc = if (crc & 0x8000) != 0 {
                (crc << 1) ^ 0x8005
            } else {
                crc << 1
            };
        }
    }
    crc
}

fn push_flac_utf8_u64(out: &mut Vec<u8>, val: u64) {
    if val < 0x80 {
        out.push(val as u8);
    } else if val < 0x800 {
        out.push(0xC0 | ((val >> 6) as u8));
        out.push(0x80 | ((val & 0x3F) as u8));
    } else {
        out.push(0xE0 | ((val >> 12) as u8));
        out.push(0x80 | (((val >> 6) & 0x3F) as u8));
        out.push(0x80 | ((val & 0x3F) as u8));
    }
}

fn build_flac_16bit(num_blocks: usize) -> Vec<u8> {
    let sample_rate = 48_000u32;
    let block_frames = 256usize;
    let channels = 2u8;
    let total_frames = (block_frames * num_blocks) as u64;

    let mut frame_offsets = Vec::with_capacity(num_blocks);
    let mut frames_blob = Vec::new();
    let sample_rate_code = 0x0Au8; // 48 kHz
    let bps_code = 0x04u8; // 16 bit

    for block_idx in 0..num_blocks {
        frame_offsets.push(frames_blob.len() as u64);
        let mut frame = vec![
            0xFF,
            0xF8,
            (0x08 << 4) | sample_rate_code,
            ((channels - 1) << 4) | (bps_code << 1),
        ];
        push_flac_utf8_u64(&mut frame, block_idx as u64);
        let hdr_crc = crc8_flac(&frame);
        frame.push(hdr_crc);

        for _c in 0..channels as usize {
            frame.push(0x02); // VERBATIM
            for f in 0..block_frames {
                let s = ((block_idx * block_frames + f) * 111 % 16000) as i16;
                frame.extend_from_slice(&s.to_be_bytes());
            }
        }
        let c16 = crc16_flac(&frame);
        frame.extend_from_slice(&c16.to_be_bytes());
        frames_blob.extend_from_slice(&frame);
    }

    let mut out = Vec::with_capacity(128 + frames_blob.len());
    out.extend_from_slice(b"fLaC");
    // STREAMINFO with SEEKTABLE
    out.push(0x00);
    out.extend_from_slice(&[0x00, 0x00, 34]);
    out.extend_from_slice(&(block_frames as u16).to_be_bytes());
    out.extend_from_slice(&(block_frames as u16).to_be_bytes());
    out.extend_from_slice(&[0, 0, 0]);
    out.extend_from_slice(&[0, 0, 0]);
    let packed_hi: u32 =
        (sample_rate << 12) | (((channels as u32 - 1) & 7) << 9) | (((16 - 1) & 31) << 4);
    let packed_total: u64 = ((packed_hi as u64) << 32) | (total_frames & 0x0F_FFFF_FFFF);
    out.extend_from_slice(&packed_total.to_be_bytes());
    out.extend_from_slice(&[0u8; 16]);

    // SEEKTABLE
    let mut points = Vec::new();
    for b in (0..num_blocks).step_by(8) {
        let sample_no = (b * block_frames) as u64;
        let offset = frame_offsets[b];
        points.push((sample_no, offset, block_frames as u16));
    }
    let table_len = (points.len() * 18) as u32;
    out.push(0x83); // last metadata block, type = 3
    out.push(((table_len >> 16) & 0xFF) as u8);
    out.push(((table_len >> 8) & 0xFF) as u8);
    out.push((table_len & 0xFF) as u8);
    for (sample_no, offset, n_samples) in points {
        out.extend_from_slice(&sample_no.to_be_bytes());
        out.extend_from_slice(&offset.to_be_bytes());
        out.extend_from_slice(&n_samples.to_be_bytes());
    }

    out.extend_from_slice(&frames_blob);
    out
}

struct MsbBitWriter {
    bytes: Vec<u8>,
    bit_pos: usize,
}

impl MsbBitWriter {
    fn new(byte_len: usize) -> Self {
        Self {
            bytes: vec![0u8; byte_len],
            bit_pos: 0,
        }
    }

    fn write_bits(&mut self, val: u32, count: usize) {
        for i in (0..count).rev() {
            let bit = if i < 32 { ((val >> i) & 1) as u8 } else { 0 };
            let byte_idx = self.bit_pos / 8;
            let bit_in_byte = 7 - (self.bit_pos % 8);
            self.bytes[byte_idx] |= bit << bit_in_byte;
            self.bit_pos += 1;
        }
    }
}

fn build_mp3_cbr(num_frames: usize) -> Vec<u8> {
    let frame_len = (144 * 128 * 1000) / 44_100;
    let mut out = Vec::with_capacity(num_frames * frame_len);
    for _ in 0..num_frames {
        let mut frame = vec![0u8; frame_len];
        frame[0] = 0xFF;
        frame[1] = 0xFB; // MPEG1 Layer III, no CRC
        frame[2] = 9 << 4; // 128 kbps, 44.1 kHz
        frame[3] = 0x00;

        let mut side = MsbBitWriter::new(32);
        side.write_bits(0, 9); // main_data_begin = 0
        side.write_bits(0, 3);
        side.write_bits(0, 8);
        for _ in 0..4 {
            side.write_bits(0, 59);
        }
        frame[4..36].copy_from_slice(&side.bytes);
        out.extend_from_slice(&frame);
    }
    out
}

// ============================================================================
// Phase 15: Seek Percentage Matrix Across Formats (0%, 10%, 25%, 50%, 75%, 90%, 100%)
// ============================================================================

#[test]
fn test_phase15_seek_percentage_matrix_playing_and_paused() {
    let wav16_path = temp_audio_path("p15_16k", "wav");
    let wav24_path = temp_audio_path("p15_24k", "wav");
    let flac_path = temp_audio_path("p15_flac", "flac");
    let mp3_path = temp_audio_path("p15_mp3", "mp3");
    let dsf_path = temp_audio_path("p15_dsf", "dsf");

    // 2 seconds of audio @ 44.1k = 88,200 frames
    fs::write(&wav16_path, build_wav_i16(44_100, 2, 88_200)).unwrap();
    // 2 seconds of audio @ 96k = 192,000 frames
    fs::write(&wav24_path, build_wav_i24_packed(96_000, 2, 192_000)).unwrap();
    // 2 seconds of FLAC @ 48k = 375 blocks of 256 frames
    fs::write(&flac_path, build_flac_16bit(375)).unwrap();
    // 2 seconds of MP3 @ 128kbps = 78 frames
    fs::write(&mp3_path, build_mp3_cbr(78)).unwrap();
    // 2 seconds of DSD64 @ 2.8224MHz = 172 blocks of 4096 bytes
    fs::write(&dsf_path, build_dsf_multiblock(172, 4096)).unwrap();

    let fixtures = [
        (&wav16_path, "WAV-16bit-44.1k"),
        (&wav24_path, "WAV-24bit-96k"),
        (&flac_path, "FLAC-16bit-48k"),
        (&mp3_path, "MP3-CBR-128k"),
        (&dsf_path, "DSF-DSD64"),
    ];

    for (path, label) in fixtures {
        let player = AudioPlayer::new_headless();
        player.play_file(path, Some(label.to_string())).unwrap();

        // Contract #1 Accessor Checks
        assert_eq!(player.playback_state(), PlaybackLifecycleState::Playing);
        assert_eq!(player.state_code(), PlaybackLifecycleState::Playing as i32);
        assert!(!player.is_device_lost());
        assert_eq!(player.clock_source(), "stream_frames");

        thread::sleep(Duration::from_millis(50));
        let dur_ms = player.duration_ms();
        assert!(dur_ms > 0, "{label}: duration must be positive");

        let percentages = [0, 10, 25, 50, 75, 90, 100];
        let mut prev_epoch = player.seek_epoch();

        for pct in percentages {
            let target_ms = (dur_ms * pct) / 100;
            player.seek_ms(target_ms);

            let new_epoch = player.seek_epoch();
            assert!(
                new_epoch > prev_epoch,
                "{label}: seek_epoch must increment on seek to {pct}%"
            );
            prev_epoch = new_epoch;

            // Target position must match target without resetting to 0
            let pos = player.position_ms();
            if pct > 0 {
                assert!(
                    pos > 0,
                    "{label}: position_ms at {pct}% must not reset to 0 (got {pos})"
                );
            }
            assert!(
                pos >= target_ms.saturating_sub(50),
                "{label}: seek target {target_ms} ms mismatch (got {pos} ms)"
            );

            // Format preservation: signal path must remain valid
            let sp = player.current_signal_path();
            assert!(matches!(
                sp.overall,
                SignalQuality::Lossless | SignalQuality::Enhanced | SignalQuality::HighQuality
            ));

            thread::sleep(Duration::from_millis(20));
        }

        // Test Seeking while Paused: seek back to 30%, then pause and seek to 50%
        player.seek_ms(dur_ms / 3);
        thread::sleep(Duration::from_millis(20));
        player.pause();
        assert_eq!(
            player.playback_state(),
            PlaybackLifecycleState::Paused,
            "{label}: must transition to Paused"
        );

        let pause_target = dur_ms / 2;
        player.seek_ms(pause_target);
        // Paused state must be preserved
        assert_eq!(
            player.playback_state(),
            PlaybackLifecycleState::Paused,
            "{label}: paused seek must preserve Paused state"
        );
        assert!(
            player.position_ms().abs_diff(pause_target) <= 25,
            "{label}: paused seek position {} must match target {pause_target} within alignment quantum",
            player.position_ms()
        );

        player.stop();
        player.shutdown();
    }

    let _ = fs::remove_file(wav16_path);
    let _ = fs::remove_file(wav24_path);
    let _ = fs::remove_file(flac_path);
    let _ = fs::remove_file(mp3_path);
    let _ = fs::remove_file(dsf_path);
}

// ============================================================================
// Phase 16: Paused Seek -> Resume Pipeline & Stale Audio Prevention
// ============================================================================

#[test]
fn test_phase16_paused_seek_and_resume_zero_stale_playback() {
    let wav_path = temp_audio_path("p16_pause_resume", "wav");
    fs::write(&wav_path, build_wav_i16(48_000, 2, 96_000)).unwrap(); // 2000 ms

    let player = AudioPlayer::new_headless();
    player.play_file(&wav_path, Some("PauseResumeWav".into())).unwrap();

    thread::sleep(Duration::from_millis(60));
    assert_eq!(player.playback_state(), PlaybackLifecycleState::Playing);

    // Pause playback
    player.pause();
    assert_eq!(player.playback_state(), PlaybackLifecycleState::Paused);

    // Seek to 1500 ms while paused
    let epoch_before = player.seek_epoch();
    player.seek_ms(1500);
    assert_eq!(player.seek_epoch(), epoch_before + 1);
    assert_eq!(player.playback_state(), PlaybackLifecycleState::Paused);
    assert_eq!(player.position_ms(), 1500);

    // Resume playback
    player.resume();
    assert_eq!(player.playback_state(), PlaybackLifecycleState::Playing);

    thread::sleep(Duration::from_millis(80));
    // Verify playback progresses forward from 1500 ms without jumping back to 0
    let pos_after = player.position_ms();
    assert!(
        pos_after >= 1500,
        "Position after resume must progress from target 1500ms (got {pos_after}ms)"
    );

    player.stop();
    player.shutdown();
    let _ = fs::remove_file(wav_path);
}

// ============================================================================
// Phase 17: Seek from Ended (EOF Drain) State Restarts Output Pipeline Cleanly
// ============================================================================

#[test]
fn test_phase17_ended_seek_and_restart() {
    let wav_path = temp_audio_path("p17_ended", "wav");
    // Short 200ms audio to hit EOF quickly
    fs::write(&wav_path, build_wav_i16(44_100, 2, 8_820)).unwrap();

    let player = AudioPlayer::new_headless();
    player.play_file(&wav_path, Some("EndedWav".into())).unwrap();

    // Wait for stream to drain to EOF
    let start = std::time::Instant::now();
    while player.playback_state() == PlaybackLifecycleState::Playing
        && start.elapsed() < Duration::from_millis(1500)
    {
        thread::sleep(Duration::from_millis(20));
    }

    // Must reach Ended state (8) or Stopped cleanly
    let cur_state = player.playback_state();
    assert!(
        cur_state == PlaybackLifecycleState::Ended || cur_state == PlaybackLifecycleState::Stopped,
        "Player must reach Ended or Stopped after draining (got {cur_state:?})"
    );

    // Seeking from Ended must restart decoding from seek target
    let epoch_before = player.seek_epoch();
    player.seek_ms(50);
    assert!(player.seek_epoch() > epoch_before);
    assert_eq!(player.position_ms(), 50);

    thread::sleep(Duration::from_millis(50));
    assert!(
        player.playback_state() == PlaybackLifecycleState::Playing
            || player.position_ms() >= 50
    );

    player.stop();
    player.shutdown();
    let _ = fs::remove_file(wav_path);
}

// ============================================================================
// Phase 18: Repeated Random Seeks & Gapless Track Switching Preservation
// ============================================================================

#[test]
fn test_phase18_repeated_and_random_seeks_during_playback_and_track_switch() {
    let p_a = temp_audio_path("p18_track_a", "wav");
    let p_b = temp_audio_path("p18_track_b", "wav");
    fs::write(&p_a, build_wav_i16(44_100, 2, 88_200)).unwrap(); // 2000 ms
    fs::write(&p_b, build_wav_i16(44_100, 2, 88_200)).unwrap(); // 2000 ms

    let player = AudioPlayer::new_headless();
    player.set_strict_bit_perfect(true).unwrap();
    player.queue_next_file(&p_b, Some("Track B".into()));
    player.play_file(&p_a, Some("Track A".into())).unwrap();
    player.queue_next_file(&p_b, Some("Track B".into()));

    // Verify 1-click zero-cost DSP bypass flag preservation across seeks
    assert!(player.is_dsp_bypassed());

    let random_targets = [100, 800, 200, 1500, 300, 1800, 50, 1200, 500, 1000];
    let mut last_epoch = player.seek_epoch();

    for &target in &random_targets {
        player.seek_ms(target);
        let new_epoch = player.seek_epoch();
        assert!(new_epoch > last_epoch, "Seek epoch must advance monotonically");
        last_epoch = new_epoch;

        let pos = player.position_ms();
        assert!(
            pos >= target.saturating_sub(40),
            "Position {pos} must match target {target}"
        );
        assert!(
            player.is_dsp_bypassed(),
            "DSP bypass must be preserved across random seeks"
        );
        thread::sleep(Duration::from_millis(15));
    }

    // Verify Contract #1 clean accessors
    assert_eq!(player.state_code(), player.playback_state() as i32);
    assert_eq!(player.state_name(), player.playback_state().as_str());
    assert!(!player.is_device_lost());
    assert_eq!(player.clock_source(), "stream_frames");

    player.stop();
    assert_eq!(player.playback_state(), PlaybackLifecycleState::Stopped);
    assert_eq!(player.position_ms(), 0);

    player.shutdown();
    let _ = fs::remove_file(p_a);
    let _ = fs::remove_file(p_b);
}
