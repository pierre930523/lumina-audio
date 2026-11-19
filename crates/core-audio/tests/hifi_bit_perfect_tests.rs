use std::path::PathBuf;
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use core_audio::dsd::{DopFramer, DsdiffReader, DsfReader};
use core_audio::pcm::{AudioChunk, AudioDecoder, SymphoniaDecoder};
use core_audio::verification::{
    pack_chunk_to_wire_bytes, unpack_wire_bytes_to_chunk, AudioVerificationEngine,
    VerificationConfig, WireSampleFormat,
};
use core_audio::{AudioDeviceManager, AudioFormatManager, AudioPlayer, PlaybackLifecycleState};
use core_types::{
    AudioCodec, AudioDeviceCapabilities, ChannelLayout, DeviceTransportKind, DsdOutputMode,
    DsdRate, DspPipelineConfig, Endianness, Interleaving, OutputBackendKind, OutputMode, PeqBandConfig,
    PeqFilterKind, PlaybackEnginePolicy, ReplayGainConfig, ReplayGainMode, SampleFormatKind,
    UnifiedAudioFormat, VerificationStatus,
};

static REAL_HW_LOCK: Mutex<()> = Mutex::new(());

fn temp_audio_path(tag: &str, ext: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    std::env::temp_dir().join(format!("lumina_p9_{tag}_{nanos}.{ext}"))
}

fn build_wav_i16(rate: u32, ch: u16, samples: &[i16]) -> Vec<u8> {
    let data_bytes = (samples.len() * 2) as u32;
    let block_align = ch * 2;
    let byte_rate = rate * (block_align as u32);
    let mut out = Vec::with_capacity(44 + data_bytes as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_bytes).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&ch.to_le_bytes());
    out.extend_from_slice(&rate.to_le_bytes());
    out.extend_from_slice(&byte_rate.to_le_bytes());
    out.extend_from_slice(&block_align.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_bytes.to_le_bytes());
    for &s in samples {
        out.extend_from_slice(&s.to_le_bytes());
    }
    out
}

fn build_wav_i24_packed(rate: u32, ch: u16, samples_i32: &[i32]) -> Vec<u8> {
    let data_bytes = (samples_i32.len() * 3) as u32;
    let block_align = ch * 3;
    let byte_rate = rate * (block_align as u32);
    let mut out = Vec::with_capacity(44 + data_bytes as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_bytes).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&ch.to_le_bytes());
    out.extend_from_slice(&rate.to_le_bytes());
    out.extend_from_slice(&byte_rate.to_le_bytes());
    out.extend_from_slice(&block_align.to_le_bytes());
    out.extend_from_slice(&24u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_bytes.to_le_bytes());
    for &s in samples_i32 {
        out.extend_from_slice(&s.to_le_bytes()[0..3]);
    }
    out
}

fn build_wav_i32(rate: u32, ch: u16, samples: &[i32]) -> Vec<u8> {
    let data_bytes = (samples.len() * 4) as u32;
    let block_align = ch * 4;
    let byte_rate = rate * (block_align as u32);
    let mut out = Vec::with_capacity(44 + data_bytes as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_bytes).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&ch.to_le_bytes());
    out.extend_from_slice(&rate.to_le_bytes());
    out.extend_from_slice(&byte_rate.to_le_bytes());
    out.extend_from_slice(&block_align.to_le_bytes());
    out.extend_from_slice(&32u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_bytes.to_le_bytes());
    for &s in samples {
        out.extend_from_slice(&s.to_le_bytes());
    }
    out
}

fn build_wav_f32(rate: u32, ch: u16, samples: &[f32]) -> Vec<u8> {
    let data_bytes = (samples.len() * 4) as u32;
    let block_align = ch * 4;
    let byte_rate = rate * (block_align as u32);
    let mut out = Vec::with_capacity(44 + data_bytes as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_bytes).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&3u16.to_le_bytes()); // IEEE_FLOAT
    out.extend_from_slice(&ch.to_le_bytes());
    out.extend_from_slice(&rate.to_le_bytes());
    out.extend_from_slice(&byte_rate.to_le_bytes());
    out.extend_from_slice(&block_align.to_le_bytes());
    out.extend_from_slice(&32u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_bytes.to_le_bytes());
    for &s in samples {
        out.extend_from_slice(&s.to_le_bytes());
    }
    out
}

fn crc8_flac(data: &[u8]) -> u8 {
    let mut crc = 0u8;
    for &b in data {
        crc ^= b;
        for _ in 0..8 {
            crc = if crc & 0x80 != 0 {
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
            crc = if crc & 0x8000 != 0 {
                (crc << 1) ^ 0x8005
            } else {
                crc << 1
            };
        }
    }
    crc
}

/// Builds a valid uncompressed VERBATIM FLAC file for testing Symphonia's exact integer path.
fn build_synthetic_flac_verbatim(rate: u32, ch: u16, bps: u8, interleaved: &[i32]) -> Vec<u8> {
    let block_frames = 256usize;
    let total_frames = interleaved.len() / (ch as usize);
    assert!(total_frames % block_frames == 0);
    let mut out = Vec::new();
    out.extend_from_slice(b"fLaC");

    // STREAMINFO last metadata block (0x80, length 34)
    out.push(0x80);
    out.extend_from_slice(&[0x00, 0x00, 34]);
    out.extend_from_slice(&(block_frames as u16).to_be_bytes());
    out.extend_from_slice(&(block_frames as u16).to_be_bytes());
    out.extend_from_slice(&[0u8; 3]); // min frame size
    out.extend_from_slice(&[0u8; 3]); // max frame size
    let packed: u64 = ((rate as u64) << 44)
        | (((ch as u64 - 1) & 0x7) << 41)
        | (((bps as u64 - 1) & 0x1F) << 36)
        | ((total_frames as u64) & 0xF_FFFF_FFFF);
    out.extend_from_slice(&packed.to_be_bytes());
    out.extend_from_slice(&[0u8; 16]); // MD5

    let mut frame_no = 0u8;
    for chunk in interleaved.chunks_exact(block_frames * (ch as usize)) {
        let mut frame = Vec::new();
        frame.extend_from_slice(&[0xFF, 0xF8]); // sync + fixed blocking
        // blocksize 0b1000 (256), sample rate 0b0000 (from STREAMINFO)
        frame.push(0x80);
        // channel assignment (ch=2 -> 0b0001 independent), sample size 0b000 (from STREAMINFO)
        let ch_code = if ch == 2 { 0x10 } else { 0x00 };
        frame.push(ch_code);
        frame.push(frame_no);
        frame_no = frame_no.wrapping_add(1);
        let h_crc = crc8_flac(&frame);
        frame.push(h_crc);

        for c in 0..(ch as usize) {
            frame.push(0x02); // VERBATIM subframe (0_000001_0)
            for f in 0..block_frames {
                let val = chunk[f * (ch as usize) + c];
                if bps <= 16 {
                    frame.extend_from_slice(&(val as i16).to_be_bytes());
                } else {
                    let be = val.to_be_bytes();
                    frame.extend_from_slice(&be[1..4]);
                }
            }
        }
        let f_crc = crc16_flac(&frame);
        frame.extend_from_slice(&f_crc.to_be_bytes());
        out.extend_from_slice(&frame);
    }
    out
}

fn build_synthetic_dsf(sample_rate: u32, dsd_l: &[u8], dsd_r: &[u8]) -> Vec<u8> {
    assert_eq!(dsd_l.len(), dsd_r.len());
    let block_size = dsd_l.len() as u32;
    let payload_size = (dsd_l.len() + dsd_r.len()) as u64;
    let total_size = 28u64 + 52u64 + 12u64 + payload_size;

    let mut out = Vec::with_capacity(total_size as usize);
    out.extend_from_slice(b"DSD ");
    out.extend_from_slice(&28u64.to_le_bytes());
    out.extend_from_slice(&total_size.to_le_bytes());
    out.extend_from_slice(&0u64.to_le_bytes());

    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&52u64.to_le_bytes());
    out.extend_from_slice(&1u32.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&2u32.to_le_bytes()); // Stereo
    out.extend_from_slice(&2u32.to_le_bytes());
    out.extend_from_slice(&sample_rate.to_le_bytes());
    out.extend_from_slice(&1u32.to_le_bytes()); // LSB-first
    out.extend_from_slice(&((dsd_l.len() as u64) * 8).to_le_bytes());
    out.extend_from_slice(&block_size.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());

    out.extend_from_slice(b"data");
    out.extend_from_slice(&(12 + payload_size).to_le_bytes());
    out.extend_from_slice(dsd_l);
    out.extend_from_slice(dsd_r);
    out
}

fn build_synthetic_dsdiff(sample_rate: u32, interleaved_dsd: &[u8]) -> Vec<u8> {
    // Minimal DSDIFF container: FRM8 -> FVER, PROP(FS, CHNL), DSD
    let mut prop_sub = Vec::new();
    prop_sub.extend_from_slice(b"SND ");
    prop_sub.extend_from_slice(b"FS  ");
    prop_sub.extend_from_slice(&4u64.to_be_bytes());
    prop_sub.extend_from_slice(&sample_rate.to_be_bytes());
    prop_sub.extend_from_slice(b"CHNL");
    prop_sub.extend_from_slice(&10u64.to_be_bytes());
    prop_sub.extend_from_slice(&2u16.to_be_bytes());
    prop_sub.extend_from_slice(b"SLFTSRGT");

    let mut body = Vec::new();
    body.extend_from_slice(b"DSD ");
    body.extend_from_slice(b"FVER");
    body.extend_from_slice(&4u64.to_be_bytes());
    body.extend_from_slice(&0x0105_0000u32.to_be_bytes());
    body.extend_from_slice(b"PROP");
    body.extend_from_slice(&(prop_sub.len() as u64).to_be_bytes());
    body.extend_from_slice(&prop_sub);
    body.extend_from_slice(b"DSD ");
    body.extend_from_slice(&(interleaved_dsd.len() as u64).to_be_bytes());
    body.extend_from_slice(interleaved_dsd);

    let mut out = Vec::new();
    out.extend_from_slice(b"FRM8");
    out.extend_from_slice(&(body.len() as u64).to_be_bytes());
    out.extend_from_slice(&body);
    out
}

fn verify_exclusive_pipeline_roundtrip(
    unified_src: UnifiedAudioFormat,
    chunks: &[AudioChunk],
    wire: WireSampleFormat,
    output_mode: OutputMode,
    expected_status: VerificationStatus,
) -> (String, String, u64) {
    let engine = AudioVerificationEngine::new(VerificationConfig {
        source_format: unified_src.clone(),
        output_mode,
        transport: DeviceTransportKind::UsbDac,
        target_rate_hz: unified_src.sample_rate,
        target_channels: unified_src.channels,
        target_valid_bits: wire.valid_bits(),
        target_container_bits: wire.container_bits(),
        buffer_size_frames: 256,
        dsp_active: false,
        software_volume_unity: true,
        resampled: false,
        exclusive_unavailable_reason: None,
    });
    let mut dop = matches!(wire, WireSampleFormat::Dop24In32MsbLe { .. }).then(DopFramer::new);

    for chunk in chunks {
        engine.record_decoder_output(chunk);
        engine.record_processed_output(chunk);
        let wire_bytes = pack_chunk_to_wire_bytes(chunk, wire, dop.as_mut());
        // Simulate arbitrary backend buffer boundary (different from decoder chunk boundary)
        let stride = (wire.bytes_per_sample() * unified_src.channels as usize) * 64;
        for slice in wire_bytes.chunks(stride.max(16)) {
            engine.record_backend_input_wire(slice, wire, unified_src.channels, unified_src.sample_rate);
        }
    }

    let snap = engine.snapshot("WASAPI Exclusive / ASIO", "Reference DAC");
    assert!(snap.verification.sample_hash_match, "Expected hash match: {snap:?}");
    assert_eq!(snap.verification.mismatched_frames, 0);
    assert_eq!(snap.verification.status, expected_status);
    assert!(snap.verification.verification_level.contains("Software"));
    (
        snap.verification.decoder_sha256,
        snap.verification.backend_input_sha256,
        snap.verification.frames_verified,
    )
}

#[test]
fn test_phase9_16bit_44k_wav_and_flac_bit_perfect_sha256() {
    // 1. Asymmetric L/R 16-bit 44.1 kHz patterns
    let mut i16_interleaved = Vec::with_capacity(2048);
    let mut i32_for_flac = Vec::with_capacity(2048);
    for i in 0..1024i32 {
        let l = ((i * 73) % 30000 - 15000) as i16;
        let r = ((-i * 41) % 30000 + 12000) as i16;
        i16_interleaved.push(l);
        i16_interleaved.push(r);
        i32_for_flac.push(l as i32);
        i32_for_flac.push(r as i32);
    }

    // Test 16/44.1 WAV through decoder + WASAPI Exclusive wire path
    let wav_path = temp_audio_path("16_44k", "wav");
    std::fs::write(&wav_path, build_wav_i16(44_100, 2, &i16_interleaved)).unwrap();
    let mut wav_dec = SymphoniaDecoder::from_file(&wav_path).unwrap();
    let mut wav_chunks = Vec::new();
    let mut recovered_wav = Vec::new();
    while let Some(chunk) = wav_dec.next_chunk().unwrap() {
        if let AudioChunk::PcmI16 { ref samples, .. } = chunk {
            recovered_wav.extend_from_slice(samples);
        } else {
            panic!("16-bit WAV must decode as PcmI16, not float! got {chunk:?}");
        }
        wav_chunks.push(chunk);
    }
    assert_eq!(recovered_wav, i16_interleaved);
    verify_exclusive_pipeline_roundtrip(
        wav_dec.unified_format(),
        &wav_chunks,
        WireSampleFormat::Int16Le,
        OutputMode::WasapiExclusive,
        VerificationStatus::BitPerfect,
    );
    let _ = std::fs::remove_file(&wav_path);

    // Test 16/44.1 FLAC lossless integer preservation (must undo Symphonia's <<16 shift)
    let flac_path = temp_audio_path("16_44k", "flac");
    std::fs::write(
        &flac_path,
        build_synthetic_flac_verbatim(44_100, 2, 16, &i32_for_flac),
    )
    .unwrap();
    let mut flac_dec = SymphoniaDecoder::from_file(&flac_path).unwrap();
    let mut flac_chunks = Vec::new();
    let mut recovered_flac = Vec::new();
    while let Some(chunk) = flac_dec.next_chunk().unwrap() {
        if let AudioChunk::PcmI16 { ref samples, .. } = chunk {
            recovered_flac.extend_from_slice(samples);
        } else {
            panic!("16-bit FLAC must decode as exact PcmI16, got {chunk:?}");
        }
        flac_chunks.push(chunk);
    }
    assert_eq!(recovered_flac, i16_interleaved);
    // Test BOTH direct 16-bit wire AND lossless 24-in-32 container promotion on DAC!
    verify_exclusive_pipeline_roundtrip(
        flac_dec.unified_format(),
        &flac_chunks,
        WireSampleFormat::Int24In32MsbLe,
        OutputMode::AsioPcm,
        VerificationStatus::BitPerfect,
    );
    let _ = std::fs::remove_file(&flac_path);

    // Also run end-to-end headless AudioPlayer Strict Bit-Perfect mode on 16/44.1 FLAC
    let flac_p2 = temp_audio_path("16_44k_live", "flac");
    std::fs::write(
        &flac_p2,
        build_synthetic_flac_verbatim(44_100, 2, 16, &i32_for_flac),
    )
    .unwrap();
    let player = AudioPlayer::new_headless();
    player.set_strict_bit_perfect(true).unwrap();
    player.play_file(&flac_p2, Some("16/44.1 FLAC".into())).unwrap();
    thread::sleep(Duration::from_millis(80));
    let info = player.output_info();
    assert!(info.verification.sample_hash_match, "Expected hash match in headless Strict Mode: {info:?}");
    assert_eq!(info.verification.decoder_sha256, info.verification.backend_input_sha256);
    assert_eq!(info.verification.status, VerificationStatus::PcmUnmodified);
    assert!(info.output.strict_mode);
    player.stop();
    player.shutdown();
    let _ = std::fs::remove_file(&flac_p2);
}

#[test]
fn test_phase9_24bit_48k_96k_192k_integer_preservation_and_container_unpack() {
    let mut i24_samples = Vec::with_capacity(2048);
    for i in 0..1024i32 {
        // Use odd LSB patterns (`& 0xFF`) that float quantization or >>8 shifts would expose immediately
        let l = (((i * 65521) % 8_000_000) - 4_000_000) | 1;
        let r = (((-i * 32749) % 8_000_000) + 3_500_000) & !1;
        i24_samples.push(l);
        i24_samples.push(r);
    }

    for rate in [48_000u32, 96_000, 192_000] {
        let wav_path = temp_audio_path(&format!("24_{rate}"), "wav");
        std::fs::write(&wav_path, build_wav_i24_packed(rate, 2, &i24_samples)).unwrap();
        let mut dec = SymphoniaDecoder::from_file(&wav_path).unwrap();
        assert_eq!(dec.unified_format().sample_rate, rate);
        assert_eq!(dec.unified_format().valid_bits, 24);

        let mut chunks = Vec::new();
        let mut recovered = Vec::new();
        while let Some(c) = dec.next_chunk().unwrap() {
            if let AudioChunk::PcmI24In32 { ref samples, .. } = c {
                recovered.extend_from_slice(samples);
            } else {
                panic!("24-bit/{rate}Hz WAV must decode as PcmI24In32, got {c:?}");
            }
            chunks.push(c);
        }
        assert_eq!(recovered, i24_samples, "24-bit WAV integer mismatch at {rate}Hz");

        // Verify both Int24PackedLe and Int24In32MsbLe container packing
        verify_exclusive_pipeline_roundtrip(
            dec.unified_format(),
            &chunks,
            WireSampleFormat::Int24PackedLe,
            OutputMode::WasapiExclusive,
            VerificationStatus::BitPerfect,
        );
        verify_exclusive_pipeline_roundtrip(
            dec.unified_format(),
            &chunks,
            WireSampleFormat::Int24In32MsbLe,
            OutputMode::AsioPcm,
            VerificationStatus::BitPerfect,
        );
        let _ = std::fs::remove_file(&wav_path);
    }

    // 24-bit / 96 kHz FLAC verbatim check (verifies >>8 unpack in SymphoniaDecoder)
    let flac_96 = temp_audio_path("24_96k", "flac");
    std::fs::write(
        &flac_96,
        build_synthetic_flac_verbatim(96_000, 2, 24, &i24_samples),
    )
    .unwrap();
    let mut dec = SymphoniaDecoder::from_file(&flac_96).unwrap();
    let mut got = Vec::new();
    let mut chunks = Vec::new();
    while let Some(c) = dec.next_chunk().unwrap() {
        if let AudioChunk::PcmI24In32 { ref samples, .. } = c {
            got.extend_from_slice(samples);
        } else {
            panic!("24-bit FLAC must decode as PcmI24In32, got {c:?}");
        }
        chunks.push(c);
    }
    assert_eq!(got, i24_samples);
    verify_exclusive_pipeline_roundtrip(
        dec.unified_format(),
        &chunks,
        WireSampleFormat::Int24In32MsbLe,
        OutputMode::WasapiExclusive,
        VerificationStatus::BitPerfect,
    );
    let _ = std::fs::remove_file(&flac_96);
}

#[test]
fn test_phase9_32bit_pcm_and_32bit_float_wav_verification() {
    let i32_samples: Vec<i32> = (0..1024i32)
        .flat_map(|i| [i.wrapping_mul(1_048_573), (-i).wrapping_mul(2_097_149)])
        .collect();
    let f32_samples: Vec<f32> = (0..1024i32)
        .flat_map(|i| [(i as f32) / 1500.0, -(i as f32) / 2100.0])
        .collect();

    let p_i32 = temp_audio_path("32_pcm", "wav");
    std::fs::write(&p_i32, build_wav_i32(192_000, 2, &i32_samples)).unwrap();
    let mut d_i32 = SymphoniaDecoder::from_file(&p_i32).unwrap();
    let mut chunks_i32 = Vec::new();
    let mut got_i32 = Vec::new();
    while let Some(c) = d_i32.next_chunk().unwrap() {
        if let AudioChunk::PcmI32 { ref samples, .. } = c {
            got_i32.extend_from_slice(samples);
        } else {
            panic!("Expected PcmI32");
        }
        chunks_i32.push(c);
    }
    assert_eq!(got_i32, i32_samples);
    verify_exclusive_pipeline_roundtrip(
        d_i32.unified_format(),
        &chunks_i32,
        WireSampleFormat::Int32Le,
        OutputMode::AsioPcm,
        VerificationStatus::BitPerfect,
    );
    let _ = std::fs::remove_file(&p_i32);

    let p_f32 = temp_audio_path("32_float", "wav");
    std::fs::write(&p_f32, build_wav_f32(96_000, 2, &f32_samples)).unwrap();
    let mut d_f32 = SymphoniaDecoder::from_file(&p_f32).unwrap();
    let mut chunks_f32 = Vec::new();
    let mut got_f32 = Vec::new();
    while let Some(c) = d_f32.next_chunk().unwrap() {
        if let AudioChunk::PcmF32 { ref samples, .. } = c {
            got_f32.extend_from_slice(samples);
        } else {
            panic!("Expected PcmF32");
        }
        chunks_f32.push(c);
    }
    assert_eq!(got_f32, f32_samples);
    verify_exclusive_pipeline_roundtrip(
        d_f32.unified_format(),
        &chunks_f32,
        WireSampleFormat::Float32Le,
        OutputMode::WasapiExclusive,
        VerificationStatus::BitPerfect,
    );
    let _ = std::fs::remove_file(&p_f32);
}

#[test]
fn test_phase9_channel_order_preservation_asymmetric_lr() {
    let chunk = AudioChunk::PcmI16 {
        samples: vec![0x1111, -0x2222, 0x3333, -0x4444, 0x5555, -0x6666, 0x7777, -0x1234],
        channels: 2,
        sample_rate: 44_100,
    };
    let wire_bytes = pack_chunk_to_wire_bytes(&chunk, WireSampleFormat::Int24In32MsbLe, None);
    let unpacked = unpack_wire_bytes_to_chunk(&wire_bytes, WireSampleFormat::Int24In32MsbLe, 2, 44_100, None).unwrap();
    let AudioChunk::PcmI24In32 { samples, .. } = unpacked else {
        panic!("Expected PcmI24In32");
    };
    assert_eq!(samples[0] >> 8, 0x1111);
    assert_eq!(samples[1] >> 8, -0x2222);
    assert_eq!(samples[2] >> 8, 0x3333);
    assert_eq!(samples[3] >> 8, -0x4444);
}

#[test]
fn test_phase9_dsd_native_dop_markers_and_dsd_to_pcm_labeling() {
    // 1. Test DSF planar-block -> interleaved fix + Native DSD + DoP v1.1 verification across DSD64/128/256/512
    let dsd_l: Vec<u8> = (0..1024u32).map(|i| ((i * 37) & 0xFF) as u8).collect();
    let dsd_r: Vec<u8> = (0..1024u32).map(|i| (((i * 91) ^ 0xA5) & 0xFF) as u8).collect();

    for (rate_hz, expected_rate) in [
        (2_822_400u32, DsdRate::Dsd64),
        (5_644_800, DsdRate::Dsd128),
        (11_289_600, DsdRate::Dsd256),
        (22_579_200, DsdRate::Dsd512),
    ] {
        let dsf_path = temp_audio_path(&format!("dsd_{rate_hz}"), "dsf");
        std::fs::write(&dsf_path, build_synthetic_dsf(rate_hz, &dsd_l, &dsd_r)).unwrap();
        let mut reader = DsfReader::new(std::fs::File::open(&dsf_path).unwrap()).unwrap();
        assert_eq!(reader.unified_format().dsd_rate, Some(expected_rate));
        let chunk = reader.next_chunk().unwrap().unwrap();
        if let AudioChunk::DsdBitstream { ref bytes, channels, is_lsb_first, .. } = chunk {
            assert_eq!(channels, 2);
            assert!(is_lsb_first);
            assert_eq!(bytes[0], dsd_l[0]);
            assert_eq!(bytes[1], dsd_r[0]);
            assert_eq!(bytes[2], dsd_l[1]);
            assert_eq!(bytes[3], dsd_r[1]);
        } else {
            panic!("Expected DsdBitstream");
        }

        // Verify Native DSD (1-bit untouched)
        verify_exclusive_pipeline_roundtrip(
            reader.unified_format(),
            &[chunk.clone()],
            WireSampleFormat::NativeDsd { channels: 2 },
            OutputMode::AsioNativeDsd,
            VerificationStatus::DsdNative,
        );

        // Verify DoP v1.1 alternating 0x05 / 0xFA markers & intact DSD payload
        verify_exclusive_pipeline_roundtrip(
            reader.unified_format(),
            &[chunk.clone()],
            WireSampleFormat::Dop24In32MsbLe {
                channels: 2,
                is_lsb_first: true,
            },
            OutputMode::DoPOverWasapiExclusive,
            VerificationStatus::DsdDop,
        );

        let _ = std::fs::remove_file(&dsf_path);
    }

    // 2. Test DSDIFF (.dff) parsing + 1-bit Native DSD preservation
    let inter_dff: Vec<u8> = dsd_l.iter().zip(&dsd_r).flat_map(|(&l, &r)| [l, r]).collect();
    let dff_path = temp_audio_path("dsd_64", "dff");
    std::fs::write(&dff_path, build_synthetic_dsdiff(2_822_400, &inter_dff)).unwrap();
    let mut dff_reader = DsdiffReader::new(std::fs::File::open(&dff_path).unwrap()).unwrap();
    let dff_chunk = dff_reader.next_chunk().unwrap().unwrap();
    verify_exclusive_pipeline_roundtrip(
        dff_reader.unified_format(),
        &[dff_chunk],
        WireSampleFormat::NativeDsd { channels: 2 },
        OutputMode::AsioNativeDsd,
        VerificationStatus::DsdNative,
    );
    let _ = std::fs::remove_file(&dff_path);

    // 3. Test DoP Marker corruption detection (modifying marker byte 0x05 -> 0x06 MUST fail verification)
    let corrupt_engine = AudioVerificationEngine::new(VerificationConfig {
        source_format: UnifiedAudioFormat {
            codec: AudioCodec::Dsf,
            sample_rate: 2_822_400,
            channels: 2,
            channel_layout: ChannelLayout::Stereo,
            sample_format: SampleFormatKind::DsdU8,
            container_bits: 8,
            valid_bits: 1,
            endianness: Endianness::Little,
            interleaving: Interleaving::Interleaved,
            dsd_rate: Some(DsdRate::Dsd64),
        },
        output_mode: OutputMode::DoPOverWasapiExclusive,
        transport: DeviceTransportKind::UsbDac,
        target_rate_hz: 176_400,
        target_channels: 2,
        target_valid_bits: 24,
        target_container_bits: 32,
        buffer_size_frames: 256,
        dsp_active: false,
        software_volume_unity: true,
        resampled: false,
        exclusive_unavailable_reason: None,
    });
    let mut dop_framer = DopFramer::new();
    let src_chunk = AudioChunk::DsdBitstream {
        bytes: inter_dff[..16].to_vec(),
        channels: 2,
        sample_rate: 2_822_400,
        is_lsb_first: true,
    };
    corrupt_engine.record_decoder_output(&src_chunk);
    corrupt_engine.record_processed_output(&src_chunk);
    let mut dop_bytes = pack_chunk_to_wire_bytes(
        &src_chunk,
        WireSampleFormat::Dop24In32MsbLe {
            channels: 2,
            is_lsb_first: true,
        },
        Some(&mut dop_framer),
    );
    dop_bytes[3] = 0x06; // Corrupt DoP marker byte!
    corrupt_engine.record_backend_input_wire(
        &dop_bytes,
        WireSampleFormat::Dop24In32MsbLe {
            channels: 2,
            is_lsb_first: true,
        },
        2,
        176_400,
    );
    let snap = corrupt_engine.snapshot("WASAPI Exclusive", "DAC");
    assert_ne!(snap.verification.status, VerificationStatus::DsdDop);
    assert!(snap.verification.mismatched_frames > 0);
    assert!(snap.verification.pcm_sample_check.contains("DoP marker corruption"));

    // 4. Headless Player: Auto -> DSD DoP vs Explicit DsdOutputMode::DsdToPcm labeling
    let dsf_live = temp_audio_path("dsf_live", "dsf");
    let dsd_block_l = vec![0x96u8; 262_144];
    let dsd_block_r = vec![0x69u8; 262_144];
    std::fs::write(&dsf_live, build_synthetic_dsf(2_822_400, &dsd_block_l, &dsd_block_r)).unwrap();
    let player = AudioPlayer::new_headless();
    player.set_strict_bit_perfect(true).unwrap();
    player.set_dsd_output_mode(DsdOutputMode::DoP).unwrap();
    player.play_file(&dsf_live, Some("DSD64 Test".into())).unwrap();
    thread::sleep(Duration::from_millis(80));
    let info_dop = player.output_info();
    assert_eq!(info_dop.verification.status, VerificationStatus::DsdDop, "{info_dop:?}");

    // Explicit DSD-to-PCM MUST report DsdToPcm and NEVER DsdNative / DsdDop
    player.set_dsd_output_mode(DsdOutputMode::DsdToPcm).unwrap();
    thread::sleep(Duration::from_millis(120));
    let info_pcm = player.output_info();
    assert_eq!(info_pcm.verification.status, VerificationStatus::DsdToPcm, "{info_pcm:?}");
    player.stop();
    player.shutdown();
    let _ = std::fs::remove_file(&dsf_live);
}

#[test]
fn test_phase9_strict_mode_blocks_dsp_volume_resampling_and_normal_restores() {
    let i16_samples: Vec<i16> = (0..144_000i32).map(|i| ((i % 4000) - 2000) as i16).collect();
    let wav_path = temp_audio_path("strict_dsp", "wav");
    std::fs::write(&wav_path, build_wav_i16(48_000, 2, &i16_samples)).unwrap();

    let player = AudioPlayer::new_headless();
    // Enable normal-mode EQ (+6 dB) and SW volume (0.45)
    player
        .set_dsp_config(DspPipelineConfig {
            bypass: false,
            peq_bands: vec![PeqBandConfig {
                filter_type: PeqFilterKind::Peaking,
                frequency_hz: 1000.0,
                gain_db: 6.0,
                q_factor: 1.0,
                enabled: true,
            }],
            crossfeed: Default::default(),
            replay_gain: ReplayGainConfig {
                mode: ReplayGainMode::Track,
                preamp_db: 0.0,
                prevent_clipping: true,
            },
        })
        .unwrap();
    player.set_volume(0.45);
    player.play_file(&wav_path, Some("DSP Test".into())).unwrap();
    thread::sleep(Duration::from_millis(80));

    let normal_info = player.output_info();
    assert_eq!(normal_info.verification.status, VerificationStatus::NotBitPerfect);
    assert!(!normal_info.verification.sample_hash_match);
    assert!(!normal_info.output.strict_mode);

    // Enable Strict Mode -> forces bypass=true, volume=1.0, integer path
    player.set_strict_bit_perfect(true).unwrap();
    thread::sleep(Duration::from_millis(80));
    assert!(player.is_dsp_bypassed());
    assert!((player.volume() - 1.0).abs() < 1e-6);

    // Attempts to un-bypass DSP or drop volume while Strict Mode is active must NOT break unity lock
    assert!(player.toggle_dsp_bypass());
    player.set_volume(0.2);
    assert!((player.volume() - 1.0).abs() < 1e-6);

    let strict_info = player.output_info();
    assert!(strict_info.output.strict_mode);
    assert!(strict_info.verification.sample_hash_match, "{strict_info:?}");
    assert_eq!(strict_info.verification.status, VerificationStatus::PcmUnmodified);

    // Disabling Strict Mode restores user's EQ & SW volume cleanly
    player.set_strict_bit_perfect(false).unwrap();
    thread::sleep(Duration::from_millis(80));
    assert!(!player.is_dsp_bypassed());
    assert!((player.volume() - 0.2).abs() < 1e-4);
    let restored_info = player.output_info();
    assert_eq!(restored_info.verification.status, VerificationStatus::NotBitPerfect);

    player.stop();
    player.shutdown();
    let _ = std::fs::remove_file(&wav_path);
}

#[test]
fn test_phase9_seek_track_switch_gapless_and_format_reinit() {
    let tone_a: Vec<i16> = (0..32_768i32).map(|i| ((i % 5000) - 2500) as i16).collect();
    let tone_b: Vec<i16> = (0..32_768i32).map(|i| (((i * 3) % 5000) - 2500) as i16).collect();
    let tone_c: Vec<i32> = (0..32_768i32).map(|i| (i * 777) % 1_000_000).collect();

    let p_a = temp_audio_path("gapless_a", "wav");
    let p_b = temp_audio_path("gapless_b", "wav");
    let p_c = temp_audio_path("switch_c_96", "wav");
    std::fs::write(&p_a, build_wav_i16(44_100, 2, &tone_a)).unwrap();
    std::fs::write(&p_b, build_wav_i16(44_100, 2, &tone_b)).unwrap();
    std::fs::write(&p_c, build_wav_i24_packed(96_000, 2, &tone_c)).unwrap();

    // 1. Seek + Track A -> Track B (same 16/44.1 format) -> Gapless transition
    let player = AudioPlayer::new_headless();
    player.set_strict_bit_perfect(true).unwrap();
    player.queue_next_file(&p_b, Some("Track B (44.1)".into()));
    player.play_file(&p_a, Some("Track A (44.1)".into())).unwrap();
    // Queue next right after play starts because play_stream clears stale pre-queue
    player.queue_next_file(&p_b, Some("Track B (44.1)".into()));

    thread::sleep(Duration::from_millis(60));
    player.seek_ms(40);
    thread::sleep(Duration::from_millis(250));

    assert!(
        player.gapless_transition_count() >= 1,
        "Identical 16/44.1 queued track must transition gaplessly without backend re-init"
    );
    assert_eq!(player.format_reinit_count(), 0);
    let gapless_info = player.output_info();
    assert_eq!(gapless_info.verification.mismatched_frames, 0, "{gapless_info:?}");
    assert!(gapless_info.verification.sample_hash_match);

    // 2. Format Switch: 16/44.1 -> 24/96kHz triggers FormatSwitchNext re-initialization cleanly!
    player.play_file(&p_a, Some("Track A (44.1)".into())).unwrap();
    player.queue_next_file(&p_c, Some("Track C (96k)".into()));
    for _ in 0..30 {
        if player.format_reinit_count() >= 1 && player.output_info().output.sample_rate_hz == 96_000 {
            break;
        }
        thread::sleep(Duration::from_millis(50));
    }
    assert!(
        player.format_reinit_count() >= 1,
        "Format change 44.1k->96k must re-initialize backend (got {})",
        player.format_reinit_count()
    );
    assert_eq!(player.output_info().output.sample_rate_hz, 96_000);
    assert_eq!(player.output_info().output.valid_bits, 24);

    player.stop();
    player.shutdown();
    let _ = std::fs::remove_file(&p_a);
    let _ = std::fs::remove_file(&p_b);
    let _ = std::fs::remove_file(&p_c);
}

#[test]
fn test_phase9_exclusive_unavailable_fallback_and_strict_rejection() {
    // Shared-only Bluetooth / Shared-mode speaker device
    let shared_only_dev = AudioDeviceCapabilities {
        device_id: "bt-speaker".into(),
        name: "Bluetooth Speaker".into(),
        backend: OutputBackendKind::WindowsWasapiShared,
        transport: DeviceTransportKind::Bluetooth,
        is_default: false,
        is_exclusive: false,
        supported_sample_rates: vec![48_000],
        supported_bit_depths: vec![16],
        supported_container_bits: vec![32],
        supported_channels: vec![2],
        supported_output_modes: vec![OutputMode::WasapiShared],
        supports_native_dsd: false,
        supports_dop: false,
        supports_float32: false,
        max_dsd_rate: None,
        asio_available: false,
        asio_driver_name: None,
        exclusive_available: false,
        probe_note: Some("Exclusive Access Failure: AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED".into()),
    };
    let src_96 = UnifiedAudioFormat {
        codec: AudioCodec::Flac,
        sample_rate: 96_000,
        channels: 2,
        channel_layout: ChannelLayout::Stereo,
        sample_format: SampleFormatKind::Int24In32,
        container_bits: 32,
        valid_bits: 24,
        endianness: Endianness::Little,
        interleaving: Interleaving::Interleaved,
        dsd_rate: None,
    };

    // Strict without fallback rejects cleanly
    let err = AudioFormatManager::negotiate(
        &src_96,
        &shared_only_dev,
        &PlaybackEnginePolicy {
            strict_bit_perfect: true,
            allow_shared_fallback: false,
            ..Default::default()
        },
    )
    .expect_err("Strict without fallback must error when exclusive unavailable");
    assert!(!err.is_empty());

    // Verification engine marks EXCLUSIVE MODE UNAVAILABLE when exclusive failed -> shared fallback
    let engine = AudioVerificationEngine::new(VerificationConfig {
        source_format: src_96,
        output_mode: OutputMode::WasapiShared,
        transport: DeviceTransportKind::UsbDac,
        target_rate_hz: 48_000,
        target_channels: 2,
        target_valid_bits: 32,
        target_container_bits: 32,
        buffer_size_frames: 480,
        dsp_active: false,
        software_volume_unity: true,
        resampled: true,
        exclusive_unavailable_reason: Some("AUDCLNT_E_DEVICE_IN_USE (0x8889000A)".into()),
    });
    let snap = engine.snapshot("WASAPI Shared", "USB DAC");
    assert_eq!(snap.verification.status, VerificationStatus::ExclusiveModeUnavailable);
    assert!(snap.output.degradation_reason.is_some());
}

#[test]
fn test_phase9_real_hardware_wasapi_exclusive_or_asio_live_probe() {
    let _guard = REAL_HW_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let caps = AudioDeviceManager::list_devices();
    let Some(usb_or_excl) = caps
        .iter()
        .find(|c| c.exclusive_available && c.transport == DeviceTransportKind::UsbDac)
        .or_else(|| caps.iter().find(|c| c.exclusive_available && c.backend == OutputBackendKind::WindowsWasapiExclusive))
    else {
        println!("No physical WASAPI Exclusive DAC active; hardware probe skipped safely");
        return;
    };

    let rate = if usb_or_excl.supported_sample_rates.contains(&48_000) {
        48_000
    } else {
        usb_or_excl.supported_sample_rates.first().copied().unwrap_or(48_000)
    };
    let silence_wav = temp_audio_path("hw_wasapi_excl", "wav");
    // Use tiny non-clipped near-silence (-60 dBFS) for real speaker safety while proving non-zero pipeline frames
    let samples: Vec<i16> = (0..rate * 2)
        .map(|i| if i % 2 == 0 { 16 } else { -16 })
        .collect();
    std::fs::write(&silence_wav, build_wav_i16(rate, 2, &samples)).unwrap();

    let player = AudioPlayer::new();
    player
        .select_output_device(Some(&usb_or_excl.device_id), Some(usb_or_excl.backend))
        .unwrap();
    player.set_strict_bit_perfect(true).unwrap();

    match player.play_file(&silence_wav, Some("HW Exclusive Verify".into())) {
        Ok(()) => {
            for _ in 0..25 {
                if player.output_info().verification.frames_verified > 0 {
                    break;
                }
                thread::sleep(Duration::from_millis(40));
            }
            let info = player.output_info();
            println!(
                "Real hardware Exclusive test result: status={:?}, mode={}, api={}, rate={}, buf={}, frames={}, sha_match={}",
                info.verification.status,
                info.output.output_mode,
                info.output.audio_api,
                info.output.sample_rate_hz,
                info.output.buffer_size_frames,
                info.verification.frames_verified,
                info.verification.sample_hash_match
            );
            // Must EITHER genuinely verify BIT-PERFECT OR honestly report EXCLUSIVE MODE UNAVAILABLE if device was busy!
            assert!(
                matches!(
                    info.verification.status,
                    VerificationStatus::BitPerfect | VerificationStatus::ExclusiveModeUnavailable
                ),
                "Unexpected hardware verification status: {info:?}"
            );
            if info.verification.status == VerificationStatus::BitPerfect {
                assert!(info.verification.frames_verified > 0);
                assert!(info.verification.sample_hash_match);
            }
            assert_ne!(player.state_code(), PlaybackLifecycleState::Error as i32);
            player.stop();
        }
        Err(e) => {
            println!("Exclusive device busy or unavailable on host: {e}");
        }
    }
    player.shutdown();
    let _ = std::fs::remove_file(&silence_wav);
}

#[test]
fn test_phase9_mp3_decoding_preserves_sample_rate_without_dsp() {
    // 5 valid MPEG-1 Layer III stereo frames at 128 kbps / 44.1 kHz (417 bytes/frame)
    let mut mp3_bytes = Vec::with_capacity(417 * 5);
    for _ in 0..5 {
        let mut frame = vec![0u8; 417];
        frame[0] = 0xFF;
        frame[1] = 0xFB;
        frame[2] = 0x90;
        frame[3] = 0x00;
        mp3_bytes.extend_from_slice(&frame);
    }
    let mp3_path = temp_audio_path("mp3_44k", "mp3");
    std::fs::write(&mp3_path, &mp3_bytes).unwrap();
    let mut dec = SymphoniaDecoder::from_file(&mp3_path).unwrap();
    let unified = dec.unified_format();
    assert_eq!(unified.codec, AudioCodec::Mp3);
    assert_eq!(unified.sample_rate, 44_100);
    assert_eq!(unified.channels, 2);

    let chunk = dec.next_chunk().unwrap().expect("MP3 must decode chunk");
    assert_eq!(chunk.sample_rate(), 44_100);
    assert_eq!(chunk.channels(), 2);

    // Ensure MP3 under Strict Mode preserves 44.1kHz with zero SRC and bypassed DSP
    let virtual_dac = AudioDeviceManager::virtual_device_capabilities();
    let neg = AudioFormatManager::negotiate(
        &unified,
        &virtual_dac,
        &PlaybackEnginePolicy {
            strict_bit_perfect: true,
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(neg.target_sample_rate, 44_100);
    assert!(!neg.requires_resampling);
    assert!(neg.requires_dsp_bypass);
    let _ = std::fs::remove_file(&mp3_path);
}

#[test]
fn test_phase9_real_asio_driver_live_probe() {
    let _guard = REAL_HW_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let caps = AudioDeviceManager::list_devices();
    let Some(asio_dev) = caps
        .iter()
        .find(|c| c.backend == OutputBackendKind::WindowsAsio && c.asio_available)
    else {
        println!("No physical initialized ASIO driver found; live ASIO test skipped safely");
        return;
    };

    let rate = if asio_dev.supported_sample_rates.contains(&48_000) {
        48_000
    } else {
        asio_dev.supported_sample_rates.first().copied().unwrap_or(44_100)
    };
    let wav_path = temp_audio_path("hw_asio", "wav");
    let samples: Vec<i32> = (0..rate * 2)
        .map(|i| if i % 2 == 0 { 1024 } else { -1024 })
        .collect();
    std::fs::write(&wav_path, build_wav_i32(rate, 2, &samples)).unwrap();

    let player = AudioPlayer::new();
    player
        .select_output_device(Some(&asio_dev.device_id), Some(OutputBackendKind::WindowsAsio))
        .unwrap();
    player.set_strict_bit_perfect(true).unwrap();

    match player.play_file(&wav_path, Some("HW ASIO Verify".into())) {
        Ok(()) => {
            for _ in 0..25 {
                if player.output_info().verification.frames_verified > 0 {
                    break;
                }
                thread::sleep(Duration::from_millis(40));
            }
            let info = player.output_info();
            println!(
                "Real hardware ASIO test result: driver={}, status={:?}, mode={}, api={}, rate={}, buf={}, frames={}, sha_match={}, reason={:?}",
                asio_dev.name,
                info.verification.status,
                info.output.output_mode,
                info.output.audio_api,
                info.output.sample_rate_hz,
                info.output.buffer_size_frames,
                info.verification.frames_verified,
                info.verification.sample_hash_match,
                info.output.degradation_reason
            );
            assert!(
                matches!(
                    info.verification.status,
                    VerificationStatus::BitPerfect | VerificationStatus::ExclusiveModeUnavailable
                ),
                "Unexpected ASIO verification status: {info:?}"
            );
            if info.verification.status == VerificationStatus::BitPerfect {
                assert!(info.verification.frames_verified > 0);
                assert!(info.verification.sample_hash_match);
            }
            player.stop();
        }
        Err(e) => {
            println!("Real ASIO driver open error (device offline/busy): {e}");
        }
    }
    player.shutdown();
    let _ = std::fs::remove_file(&wav_path);
}
