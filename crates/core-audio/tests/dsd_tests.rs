use core_audio::dsd::{
    DSD_SILENCE_BYTE, DopFramer, DsdChannelDecimator, DsdStereoDecimator, DsdiffParser,
    DsdiffReader, DsfParser, DsfReader,
};
use core_audio::pcm::{AudioChunk, AudioDecoder};
use std::io::Cursor;
use std::time::Duration;

fn build_synthetic_dsf() -> Vec<u8> {
    let mut buf = Vec::new();

    // 1. 'DSD ' chunk (28 bytes)
    buf.extend_from_slice(b"DSD ");
    buf.extend_from_slice(&28u64.to_le_bytes()); // chunk_size
    buf.extend_from_slice(&1024u64.to_le_bytes()); // total file_size
    buf.extend_from_slice(&0u64.to_le_bytes()); // metadata_offset

    // 2. 'fmt ' chunk (52 bytes)
    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&52u64.to_le_bytes()); // chunk_size
    buf.extend_from_slice(&1u32.to_le_bytes()); // format_version = 1
    buf.extend_from_slice(&0u32.to_le_bytes()); // format_id = 0 (raw DSD)
    buf.extend_from_slice(&2u32.to_le_bytes()); // channel_type = 2 (stereo)
    buf.extend_from_slice(&2u32.to_le_bytes()); // channel_num = 2
    buf.extend_from_slice(&2822400u32.to_le_bytes()); // sample_rate = 2.8224 MHz (DSD64)
    buf.extend_from_slice(&1u32.to_le_bytes()); // bits_per_sample = 1
    buf.extend_from_slice(&2822400u64.to_le_bytes()); // sample_count = 1 sec
    buf.extend_from_slice(&4096u32.to_le_bytes()); // block_size_per_channel = 4096
    buf.extend_from_slice(&0u32.to_le_bytes()); // reserved = 0

    // 3. 'data' chunk (12 bytes header + 8192 bytes silence)
    buf.extend_from_slice(b"data");
    let data_len = 8192u64;
    buf.extend_from_slice(&(12 + data_len).to_le_bytes());
    buf.resize(buf.len() + data_len as usize, DSD_SILENCE_BYTE);

    buf
}

fn build_synthetic_dsdiff() -> Vec<u8> {
    let mut buf = Vec::new();

    // PROP SND chunk contents:
    let mut prop_snd = Vec::new();
    // FS subchunk
    prop_snd.extend_from_slice(b"FS  ");
    prop_snd.extend_from_slice(&4u64.to_be_bytes());
    prop_snd.extend_from_slice(&2822400u32.to_be_bytes());
    // CHNL subchunk (2 channels)
    prop_snd.extend_from_slice(b"CHNL");
    prop_snd.extend_from_slice(&2u64.to_be_bytes());
    prop_snd.extend_from_slice(&2u16.to_be_bytes());
    // CMPR subchunk ("DSD ")
    prop_snd.extend_from_slice(b"CMPR");
    prop_snd.extend_from_slice(&4u64.to_be_bytes());
    prop_snd.extend_from_slice(b"DSD ");

    // PROP chunk wrapper
    let mut prop_chunk = Vec::new();
    prop_chunk.extend_from_slice(b"PROP");
    let prop_size = 4 + prop_snd.len() as u64;
    prop_chunk.extend_from_slice(&prop_size.to_be_bytes());
    prop_chunk.extend_from_slice(b"SND ");
    prop_chunk.extend_from_slice(&prop_snd);

    // DSD chunk (raw audio)
    let audio_payload = vec![DSD_SILENCE_BYTE; 4096];
    let mut dsd_chunk = Vec::new();
    dsd_chunk.extend_from_slice(b"DSD ");
    dsd_chunk.extend_from_slice(&(audio_payload.len() as u64).to_be_bytes());
    dsd_chunk.extend_from_slice(&audio_payload);

    // Root FRM8
    let frm8_payload_len = 4 + prop_chunk.len() + dsd_chunk.len();
    buf.extend_from_slice(b"FRM8");
    buf.extend_from_slice(&(frm8_payload_len as u64).to_be_bytes());
    buf.extend_from_slice(b"DSD ");
    buf.extend_from_slice(&prop_chunk);
    buf.extend_from_slice(&dsd_chunk);

    buf
}

#[test]
fn test_dsf_parser_valid_stream() {
    let bytes = build_synthetic_dsf();
    let mut cursor = Cursor::new(bytes);
    let header = DsfParser::parse(&mut cursor).expect("DSF parse failed");

    assert_eq!(header.channel_num, 2);
    assert_eq!(header.sample_rate, 2822400);
    assert_eq!(header.sample_count, 2822400);
    assert_eq!(header.block_size, 4096);
    assert_eq!(header.data_length, 8192);
}

#[test]
fn test_dsf_parser_corrupt_magic_and_channel() {
    let mut bytes = build_synthetic_dsf();
    bytes[0..4].copy_from_slice(b"NOPE");
    let mut cursor = Cursor::new(bytes);
    assert!(DsfParser::parse(&mut cursor).is_err());
}

#[test]
fn test_dsdiff_parser_valid_stream() {
    let bytes = build_synthetic_dsdiff();
    let mut cursor = Cursor::new(bytes);
    let header = DsdiffParser::parse(&mut cursor).expect("DSDIFF parse failed");

    assert_eq!(header.channel_num, 2);
    assert_eq!(header.sample_rate, 2822400);
    assert_eq!(header.data_length, 4096);
}

#[test]
fn test_dop_framing_and_unframing_roundtrip() {
    let mut framer = DopFramer::new();

    // 1. Alternating marker test
    let dsd_l = (0xAB, 0xCD);
    let dsd_r = (0x12, 0x34);

    let (pcm_l0, pcm_r0) = framer.frame_stereo_i32(dsd_l, dsd_r, false);
    let marker0_l = ((pcm_l0 >> 24) & 0xFF) as u8;
    let marker0_r = ((pcm_r0 >> 24) & 0xFF) as u8;
    assert_eq!(marker0_l, DopFramer::MARKER_EVEN);
    assert_eq!(marker0_r, DopFramer::MARKER_EVEN);

    let (pcm_l1, pcm_r1) = framer.frame_stereo_i32(dsd_l, dsd_r, false);
    let marker1_l = ((pcm_l1 >> 24) & 0xFF) as u8;
    let marker1_r = ((pcm_r1 >> 24) & 0xFF) as u8;
    assert_eq!(marker1_l, DopFramer::MARKER_ODD);
    assert_eq!(marker1_r, DopFramer::MARKER_ODD);

    // 2. Unframing roundtrip test
    let mut unframer = DopFramer::new();
    let (recovered_l0, recovered_r0) = unframer.unframe_stereo_i32(pcm_l0, pcm_r0).unwrap();
    assert_eq!(recovered_l0, 0xABCD);
    assert_eq!(recovered_r0, 0x1234);

    let (recovered_l1, recovered_r1) = unframer.unframe_stereo_i32(pcm_l1, pcm_r1).unwrap();
    assert_eq!(recovered_l1, 0xABCD);
    assert_eq!(recovered_r1, 0x1234);

    // 3. Silence preroll test
    let preroll = DopFramer::generate_silence_preroll(16);
    assert_eq!(preroll.len(), 32); // 16 frames * 2 channels
}

#[test]
fn test_gesemann_decimation_fir_filter_accuracy() {
    let mut decimator = DsdChannelDecimator::new();

    // Feed 32 bytes of silence (0x69 pattern)
    let mut silence_pcm = 0.0;
    for _ in 0..32 {
        silence_pcm = decimator.translate_byte(DSD_SILENCE_BYTE, false);
    }
    assert!(
        silence_pcm.abs() < 1e-6,
        "Silence pattern 0x69 must decimate to 0.000000, got {silence_pcm}"
    );

    // Feed 32 bytes of all ones (0xFF)
    let mut pos_pcm = 0.0;
    for _ in 0..32 {
        pos_pcm = decimator.translate_byte(0xFF, false);
    }
    assert!(
        (pos_pcm - 1.0).abs() < 1e-4,
        "Full positive pattern 0xFF must decimate to +1.0, got {pos_pcm}"
    );

    // Feed 32 bytes of all zeros (0x00)
    let mut neg_pcm = 0.0;
    for _ in 0..32 {
        neg_pcm = decimator.translate_byte(0x00, false);
    }
    assert!(
        (neg_pcm - (-1.0)).abs() < 1e-4,
        "Full negative pattern 0x00 must decimate to -1.0, got {neg_pcm}"
    );

    // Test stereo decimator
    let mut stereo_dec = DsdStereoDecimator::new();
    let stereo_bytes = vec![DSD_SILENCE_BYTE; 64];
    let pcm = stereo_dec.decimate_interleaved(&stereo_bytes, false);
    assert_eq!(pcm.len(), 64);
}

// ============================================================================
// M2.1 DSD Seek Clamping, Multi-Block DSF, Odd-Byte DSDIFF & DoP Framing Tests
// ============================================================================

#[inline]
fn dsf_block_marker_bytes(block_idx: usize) -> (u8, u8) {
    let l = (block_idx as u8).wrapping_mul(3).wrapping_add(1);
    let r = (block_idx as u8).wrapping_mul(7).wrapping_add(5);
    (l, r)
}

fn build_multiblock_dsf_with_id3(num_blocks: usize, block_size: usize) -> Vec<u8> {
    let sample_rate = 2_822_400u32;
    let channels = 2u32;
    let sample_count = (num_blocks as u64) * (block_size as u64) * 8;
    let data_payload_len = (num_blocks * block_size * channels as usize) as u64;
    let metadata_offset = 28 + 52 + 12 + data_payload_len;
    let trailing_id3 = b"ID3 \x03\x00\x00\x00\x00\x04TEST";
    let total_file_size = metadata_offset + (trailing_id3.len() as u64);

    let mut buf = Vec::with_capacity(total_file_size as usize);

    // 1. 'DSD ' chunk (28 bytes)
    buf.extend_from_slice(b"DSD ");
    buf.extend_from_slice(&28u64.to_le_bytes());
    buf.extend_from_slice(&total_file_size.to_le_bytes());
    buf.extend_from_slice(&metadata_offset.to_le_bytes());

    // 2. 'fmt ' chunk (52 bytes)
    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&52u64.to_le_bytes());
    buf.extend_from_slice(&1u32.to_le_bytes());
    buf.extend_from_slice(&0u32.to_le_bytes());
    buf.extend_from_slice(&2u32.to_le_bytes());
    buf.extend_from_slice(&channels.to_le_bytes());
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&1u32.to_le_bytes());
    buf.extend_from_slice(&sample_count.to_le_bytes());
    buf.extend_from_slice(&(block_size as u32).to_le_bytes());
    buf.extend_from_slice(&0u32.to_le_bytes());

    // 3. 'data' chunk (12 bytes + planar blocks)
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&(12 + data_payload_len).to_le_bytes());
    for b in 0..num_blocks {
        let (l, r) = dsf_block_marker_bytes(b);
        buf.extend(std::iter::repeat_n(l, block_size));
        buf.extend(std::iter::repeat_n(r, block_size));
    }

    // 4. Trailing ID3 chunk (must never be read by next_chunk even after 100% seek)
    buf.extend_from_slice(trailing_id3);
    buf
}

fn build_indexed_dsdiff(bytes_per_channel: usize) -> Vec<u8> {
    let mut prop_snd = Vec::new();
    prop_snd.extend_from_slice(b"FS  ");
    prop_snd.extend_from_slice(&4u64.to_be_bytes());
    prop_snd.extend_from_slice(&2_822_400u32.to_be_bytes());
    prop_snd.extend_from_slice(b"CHNL");
    prop_snd.extend_from_slice(&2u64.to_be_bytes());
    prop_snd.extend_from_slice(&2u16.to_be_bytes());
    prop_snd.extend_from_slice(b"CMPR");
    prop_snd.extend_from_slice(&4u64.to_be_bytes());
    prop_snd.extend_from_slice(b"DSD ");

    let mut prop_chunk = Vec::new();
    prop_chunk.extend_from_slice(b"PROP");
    prop_chunk.extend_from_slice(&((4 + prop_snd.len()) as u64).to_be_bytes());
    prop_chunk.extend_from_slice(b"SND ");
    prop_chunk.extend_from_slice(&prop_snd);

    let mut audio_payload = Vec::with_capacity(bytes_per_channel * 2);
    for i in 0..bytes_per_channel {
        audio_payload.push((i & 0xFF) as u8);
        audio_payload.push(((i >> 8) & 0xFF) as u8);
    }

    let mut dsd_chunk = Vec::new();
    dsd_chunk.extend_from_slice(b"DSD ");
    dsd_chunk.extend_from_slice(&(audio_payload.len() as u64).to_be_bytes());
    dsd_chunk.extend_from_slice(&audio_payload);

    // Trailing COMT chunk after DSD audio (must never be read into on EOF seek)
    let mut comt_chunk = Vec::new();
    comt_chunk.extend_from_slice(b"COMT");
    comt_chunk.extend_from_slice(&4u64.to_be_bytes());
    comt_chunk.extend_from_slice(&[0xAA, 0xBB, 0xCC, 0xDD]);

    let frm8_payload_len = 4 + prop_chunk.len() + dsd_chunk.len() + comt_chunk.len();
    let mut buf = Vec::with_capacity(12 + frm8_payload_len);
    buf.extend_from_slice(b"FRM8");
    buf.extend_from_slice(&(frm8_payload_len as u64).to_be_bytes());
    buf.extend_from_slice(b"DSD ");
    buf.extend_from_slice(&prop_chunk);
    buf.extend_from_slice(&dsd_chunk);
    buf.extend_from_slice(&comt_chunk);
    buf
}

#[test]
fn test_dsf_reader_multiblock_seek_matrix() {
    let num_blocks = 40usize;
    let block_size = 4096usize;
    let sr = 2_822_400u32;
    let samples_per_block = (block_size as u64) * 8;
    let block_interleaved_bytes = block_size * 2;
    let total_frames = (num_blocks as u64) * samples_per_block;

    let dsf_bytes = build_multiblock_dsf_with_id3(num_blocks, block_size);
    let mut reader = DsfReader::new(Cursor::new(dsf_bytes)).expect("DsfReader::new failed");

    assert_eq!(reader.total_frames(), Some(total_frames));
    assert_eq!(reader.seek_precision_frames(), samples_per_block);
    let dur = reader.duration().expect("DSF duration missing");
    let dur_ns = dur.as_nanos();

    let verify_seek = |r: &mut DsfReader<Cursor<Vec<u8>>>, t: Duration, label: &str| {
        r.seek(t)
            .unwrap_or_else(|e| panic!("{label}: DsfReader::seek({t:?}) failed: {e}"));
        let target_frame = ((t.as_nanos().saturating_mul(sr as u128)) / 1_000_000_000) as u64;
        let expected_block = if t >= dur || target_frame >= total_frames {
            num_blocks
        } else {
            (target_frame / samples_per_block) as usize
        };

        let mut remaining_blocks = 0usize;
        let mut total_bytes = 0usize;
        while let Some(chunk) = r.next_chunk().expect("DSF next_chunk failed") {
            match chunk {
                AudioChunk::DsdBitstream {
                    bytes,
                    channels,
                    sample_rate,
                    is_lsb_first,
                } => {
                    assert_eq!(channels, 2);
                    assert_eq!(sample_rate, sr);
                    assert!(is_lsb_first);
                    assert_eq!(bytes.len(), block_interleaved_bytes);
                    let blk_idx = expected_block + remaining_blocks;
                    let (exp_l, exp_r) = dsf_block_marker_bytes(blk_idx);
                    assert_eq!(bytes[0], exp_l, "{label}: block {blk_idx} L mismatch");
                    assert_eq!(bytes[1], exp_r, "{label}: block {blk_idx} R mismatch");
                    assert_eq!(
                        bytes[bytes.len() - 2],
                        exp_l,
                        "{label}: block {blk_idx} tail L mismatch"
                    );
                    assert_eq!(
                        bytes[bytes.len() - 1],
                        exp_r,
                        "{label}: block {blk_idx} tail R mismatch"
                    );
                    remaining_blocks += 1;
                    total_bytes += bytes.len();
                }
                other => panic!("Expected DsdBitstream, got {other:?}"),
            }
        }
        assert_eq!(
            remaining_blocks,
            num_blocks - expected_block,
            "{label}: remaining block count mismatch"
        );
        assert_eq!(
            total_bytes,
            (num_blocks - expected_block) * block_interleaved_bytes,
            "{label}: remaining byte count mismatch"
        );
    };

    // 1. Percentages: 0%, 10%, 25%, 50%, 75%, 90%, 100%, >100%
    for pct in [0u128, 10, 25, 50, 75, 90, 100, 130] {
        let t_ns = (dur_ns * pct) / 100;
        let t = Duration::from_nanos(t_ns as u64);
        verify_seek(&mut reader, t, &format!("dsf-{pct}%"));
    }

    // 2. Backward seek after 100% / >100% EOF resumes cleanly
    verify_seek(&mut reader, Duration::ZERO, "dsf-after-eof-zero");
    verify_seek(
        &mut reader,
        dur + Duration::from_secs(5),
        "dsf-far-past-eof",
    );
    verify_seek(&mut reader, Duration::from_millis(120), "dsf-after-eof-mid");

    // 3. Consecutive repeated seeks without intermediate next_chunk()
    for ms in [50u64, 380, 120, 410, 15] {
        reader.seek(Duration::from_millis(ms)).unwrap();
    }
    verify_seek(&mut reader, Duration::from_millis(15), "dsf-repeated");

    // 4. 24 seeded random seeks (forward & backward)
    let mut prng: u64 = 0xDEAD_BEEF_CAFE_BABEu64;
    for step in 0..24 {
        prng = prng
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let rand_ns = (prng as u128) % dur_ns;
        verify_seek(
            &mut reader,
            Duration::from_nanos(rand_ns as u64),
            &format!("dsf-rand-{step}"),
        );
    }
}

#[test]
fn test_dsdiff_reader_odd_byte_seek_and_dop_aligned() {
    let bytes_per_ch = 20_001usize; // intentionally odd and not multiple of 4096
    let sr = 2_822_400u32;
    let total_frames = (bytes_per_ch as u64) * 8;

    let dff_bytes = build_indexed_dsdiff(bytes_per_ch);
    let mut reader = DsdiffReader::new(Cursor::new(dff_bytes)).expect("DsdiffReader::new failed");
    assert_eq!(reader.total_frames(), Some(total_frames));
    assert_eq!(reader.seek_precision_frames(), 8);

    let dur = reader.duration().expect("DSDIFF duration missing");
    let dur_ns = dur.as_nanos();

    let verify_dsdiff_seek =
        |r: &mut DsdiffReader<Cursor<Vec<u8>>>, t: Duration, force_dop: bool, label: &str| {
            if force_dop {
                r.seek_dop_aligned(t).unwrap();
            } else {
                r.seek(t).unwrap();
            }

            let target_frame = ((t.as_nanos().saturating_mul(sr as u128)) / 1_000_000_000) as u64;
            let expected_byte_per_ch = if t >= dur || target_frame >= total_frames {
                bytes_per_ch
            } else {
                let raw = (target_frame / 8) as usize;
                if force_dop || r.seek_precision_frames() == 16 {
                    raw & !1
                } else {
                    raw
                }
            };

            if force_dop && expected_byte_per_ch < bytes_per_ch {
                assert_eq!(
                    expected_byte_per_ch % 2,
                    0,
                    "{label}: DoP-aligned seek must land on even byte per channel"
                );
            }

            let mut total_bytes = 0usize;
            let mut pair_idx = expected_byte_per_ch;
            while let Some(chunk) = r.next_chunk().expect("DSDIFF next_chunk failed") {
                match chunk {
                    AudioChunk::DsdBitstream {
                        bytes,
                        channels,
                        sample_rate,
                        is_lsb_first,
                    } => {
                        assert_eq!(channels, 2);
                        assert_eq!(sample_rate, sr);
                        assert!(!is_lsb_first);
                        assert_eq!(bytes.len() % 2, 0);
                        for lr in bytes.as_chunks::<2>().0 {
                            assert_eq!(
                                lr[0],
                                (pair_idx & 0xFF) as u8,
                                "{label}: L mismatch @ {pair_idx}"
                            );
                            assert_eq!(
                                lr[1],
                                ((pair_idx >> 8) & 0xFF) as u8,
                                "{label}: R mismatch @ {pair_idx}"
                            );
                            pair_idx += 1;
                        }
                        total_bytes += bytes.len();
                    }
                    other => panic!("Expected DsdBitstream, got {other:?}"),
                }
            }
            assert_eq!(
                total_bytes,
                (bytes_per_ch - expected_byte_per_ch) * 2,
                "{label}: remaining byte count mismatch"
            );
        };

    // 1. Explicitly hit an odd byte boundary (pair index 1001 = 8008 DSD frames)
    let odd_time_ns = (8008u128 * 1_000_000_000) / (sr as u128) + 1;
    let odd_time = Duration::from_nanos(odd_time_ns as u64);
    verify_dsdiff_seek(&mut reader, odd_time, false, "dsdiff-odd-byte-native");
    verify_dsdiff_seek(&mut reader, odd_time, true, "dsdiff-odd-byte-dop-aligned");

    // 2. Percentages: 0%, 10%, 25%, 50%, 75%, 90%, 100%, >100%
    for pct in [0u128, 10, 25, 50, 75, 90, 100, 125] {
        let t = Duration::from_nanos(((dur_ns * pct) / 100) as u64);
        verify_dsdiff_seek(&mut reader, t, false, &format!("dsdiff-native-{pct}%"));
        verify_dsdiff_seek(&mut reader, t, true, &format!("dsdiff-dop-{pct}%"));
    }

    // 3. set_dop_aligned(true) updates seek_precision_frames() and aligns AudioDecoder::seek
    reader.set_dop_aligned(true);
    assert_eq!(reader.seek_precision_frames(), 16);
    verify_dsdiff_seek(&mut reader, odd_time, false, "dsdiff-set-dop-aligned");
    reader.set_dop_aligned(false);
    assert_eq!(reader.seek_precision_frames(), 8);

    // 4. Consecutive repeated seeks & backward seek after EOF
    reader.seek(dur + Duration::from_secs(1)).unwrap();
    assert!(reader.next_chunk().unwrap().is_none());
    for ns in [500_000u64, 4_000_000, 1_200_000, 2_500_000] {
        reader.seek(Duration::from_nanos(ns)).unwrap();
    }
    verify_dsdiff_seek(
        &mut reader,
        Duration::from_nanos(2_500_000),
        false,
        "dsdiff-repeated",
    );

    // 5. 24 seeded random seeks
    let mut prng: u64 = 0xCAFE_BABE_1234_5678u64;
    for step in 0..24 {
        prng = prng
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let rand_ns = (prng as u128) % dur_ns;
        verify_dsdiff_seek(
            &mut reader,
            Duration::from_nanos(rand_ns as u64),
            step % 2 == 0,
            &format!("dsdiff-rand-{step}"),
        );
    }
}

#[test]
fn test_dop_framer_cross_chunk_buffering_and_reset() {
    // 1. Stereo DSDIFF (MSB-first) split across odd-byte chunk boundaries: 6 + 2 + 5 + 3 = 16 bytes (4 DoP frames)
    let source_msb: [u8; 16] = [
        0x11, 0x21, 0x12, 0x22, 0x13, 0x23, 0x14, 0x24, 0x15, 0x25, 0x16, 0x26, 0x17, 0x27, 0x18,
        0x28,
    ];
    let mut framer = DopFramer::new();
    let mut wire = Vec::new();

    framer.pack_dsd_to_wire_le(&source_msb[0..6], 2, false, &mut wire);
    assert_eq!(wire.len(), 8); // 1 stereo DoP frame emitted (4 DSD bytes consumed)
    assert_eq!(framer.pending_byte_count(), 2); // 2 odd bytes buffered

    framer.pack_dsd_to_wire_le(&source_msb[6..8], 2, false, &mut wire);
    assert_eq!(wire.len(), 16); // buffered 2 + new 2 completed frame #2
    assert_eq!(framer.pending_byte_count(), 0);

    framer.pack_dsd_to_wire_le(&source_msb[8..13], 2, false, &mut wire);
    assert_eq!(wire.len(), 24); // frame #3 emitted, 1 byte buffered
    assert_eq!(framer.pending_byte_count(), 1);

    framer.pack_dsd_to_wire_le(&source_msb[13..16], 2, false, &mut wire);
    assert_eq!(wire.len(), 32); // all 4 DoP frames emitted, zero bytes lost!
    assert_eq!(framer.pending_byte_count(), 0);

    // Unframe all 4 stereo DoP frames and verify exact alternating 0x05/0xFA markers & DSD words
    let mut unframer = DopFramer::new();
    for g in 0..4 {
        let base = g * 8;
        let l_pcm = i32::from_le_bytes(wire[base..base + 4].try_into().unwrap());
        let r_pcm = i32::from_le_bytes(wire[base + 4..base + 8].try_into().unwrap());
        let (l_word, r_word) = unframer
            .unframe_stereo_i32(l_pcm, r_pcm)
            .expect("DoP marker sequence broke across odd-byte chunk boundary");
        let s_base = g * 4;
        assert_eq!(
            l_word,
            ((source_msb[s_base] as u16) << 8) | (source_msb[s_base + 2] as u16)
        );
        assert_eq!(
            r_word,
            ((source_msb[s_base + 1] as u16) << 8) | (source_msb[s_base + 3] as u16)
        );
    }

    // 2. LSB-first (DSF) odd-byte buffering + reset() clears pending_bytes and marker_phase
    framer.pack_dsd_to_wire_le(&[0x80, 0x40], 2, true, &mut wire);
    assert_eq!(framer.pending_byte_count(), 2);
    let _ = framer.next_marker(); // flip marker_phase
    framer.reset();
    assert_eq!(framer.pending_byte_count(), 0);
    assert_eq!(framer.next_marker(), DopFramer::MARKER_EVEN);

    // 3. Silence preroll bytes advance marker_phase continuously
    framer.reset();
    let preroll_bytes = framer.generate_silence_preroll_bytes(2, 3);
    assert_eq!(preroll_bytes.len(), 3 * 2 * 4);
    assert_eq!(framer.next_marker(), DopFramer::MARKER_ODD);
}
