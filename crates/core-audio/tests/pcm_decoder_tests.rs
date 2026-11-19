use core_audio::pcm::{AudioChunk, AudioDecoder, SymphoniaDecoder};
use core_types::{AudioCodec, SampleFormatKind};
use std::io::{Cursor, Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

static TEMP_FILE_COUNTER: AtomicU64 = AtomicU64::new(0);

struct TempAudioFile {
    path: PathBuf,
}

impl TempAudioFile {
    fn new(name: &str, ext: &str, bytes: &[u8]) -> Self {
        let id = TEMP_FILE_COUNTER.fetch_add(1, Ordering::Relaxed);
        let pid = std::process::id();
        let path = std::env::temp_dir().join(format!("lumina_m21_{name}_{pid}_{id}.{ext}"));
        std::fs::write(&path, bytes).expect("failed to write temp audio fixture");
        Self { path }
    }
}

impl Drop for TempAudioFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

struct CustomSeekableReader {
    inner: Cursor<Vec<u8>>,
}

impl Read for CustomSeekableReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.inner.read(buf)
    }
}

impl Seek for CustomSeekableReader {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        self.inner.seek(pos)
    }
}

fn build_synthetic_wav(sample_rate: u32, channels: u16, num_frames: u32) -> Vec<u8> {
    let mut buf = Vec::new();
    let bytes_per_sample = 2u16; // 16-bit PCM
    let block_align = channels * bytes_per_sample;
    let byte_rate = sample_rate * (block_align as u32);
    let data_len = num_frames * (block_align as u32);

    // 1. RIFF header
    buf.extend_from_slice(b"RIFF");
    let riff_len = 36 + data_len;
    buf.extend_from_slice(&riff_len.to_le_bytes());
    buf.extend_from_slice(b"WAVE");

    // 2. 'fmt ' chunk (16 bytes)
    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&16u32.to_le_bytes()); // Subchunk1Size
    buf.extend_from_slice(&1u16.to_le_bytes()); // AudioFormat 1 = PCM
    buf.extend_from_slice(&channels.to_le_bytes());
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&byte_rate.to_le_bytes());
    buf.extend_from_slice(&block_align.to_le_bytes());
    buf.extend_from_slice(&16u16.to_le_bytes()); // bits_per_sample = 16

    // 3. 'data' chunk
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_len.to_le_bytes());

    // Generate 440 Hz sine wave in 16-bit signed PCM
    use std::f64::consts::PI;
    for n in 0..num_frames {
        let t = n as f64 / sample_rate as f64;
        let s = (2.0 * PI * 440.0 * t).sin();
        let sample_i16 = (s * 30000.0) as i16;
        for _ in 0..channels {
            buf.extend_from_slice(&sample_i16.to_le_bytes());
        }
    }

    buf
}

#[test]
fn test_symphonia_decoder_synthetic_wav() {
    let wav_bytes = build_synthetic_wav(48000, 2, 4800); // 0.1 sec of audio
    let mut decoder = SymphoniaDecoder::from_bytes(wav_bytes, Some("wav"))
        .expect("Failed to initialize SymphoniaDecoder on synthetic WAV");

    assert_eq!(decoder.format().codec, AudioCodec::Wav);
    assert_eq!(decoder.format().sample_rate_hz, 48000);
    assert_eq!(decoder.format().channels, 2);
    assert_eq!(decoder.format().bit_depth, 16);

    // Decode chunks
    let mut total_samples_decoded = 0;
    while let Some(chunk) = decoder.next_chunk().expect("Error decoding next chunk") {
        match chunk {
            AudioChunk::PcmI16 {
                ref samples,
                channels,
                sample_rate,
            } => {
                assert_eq!(channels, 2);
                assert_eq!(sample_rate, 48000);
                total_samples_decoded += samples.len();

                // Lossless integer preservation converts cleanly to normalized [-1.0, 1.0]
                for &s in &chunk.to_f64_interleaved() {
                    assert!((-1.0..=1.0).contains(&s), "Sample out of bounds: {s}");
                }
            }
            other => panic!("Expected PcmI16 chunk, got {other:?}"),
        }
    }

    assert!(total_samples_decoded > 0, "Expected decoded samples");

    // Seek back to start
    decoder.seek(Duration::ZERO).expect("Seek failed");
    let first_chunk = decoder.next_chunk().expect("Error decoding after seek");
    assert!(first_chunk.is_some(), "Expected chunk after seek");
}

// ============================================================================
// Pure-Rust Deterministic Index-Encoded Fixtures & Seek Verification Matrix
// ============================================================================

#[inline]
fn indexed_i16_pair(frame_idx: usize) -> (i16, i16) {
    let l = (frame_idx & 0x7FFF) as i16;
    let r = (((frame_idx >> 15) & 0x3FFF) as i16) + 1;
    (l, r)
}

#[inline]
fn indexed_i24_pair(frame_idx: usize) -> (i32, i32) {
    let l = (frame_idx as i32) + 1;
    let r = -((frame_idx as i32) + 1);
    (l, r)
}

fn build_wav_i16_indexed(sample_rate: u32, num_frames: usize) -> Vec<u8> {
    let channels = 2u16;
    let block_align = channels * 2;
    let byte_rate = sample_rate * (block_align as u32);
    let data_len = (num_frames as u32) * (block_align as u32);

    let mut buf = Vec::with_capacity(44 + data_len as usize);
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&(36 + data_len).to_le_bytes());
    buf.extend_from_slice(b"WAVE");
    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&16u32.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes());
    buf.extend_from_slice(&channels.to_le_bytes());
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&byte_rate.to_le_bytes());
    buf.extend_from_slice(&block_align.to_le_bytes());
    buf.extend_from_slice(&16u16.to_le_bytes());
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_len.to_le_bytes());

    for i in 0..num_frames {
        let (l, r) = indexed_i16_pair(i);
        buf.extend_from_slice(&l.to_le_bytes());
        buf.extend_from_slice(&r.to_le_bytes());
    }
    buf
}

fn build_wav_i24_indexed(sample_rate: u32, num_frames: usize) -> Vec<u8> {
    let channels = 2u16;
    let block_align = channels * 3;
    let byte_rate = sample_rate * (block_align as u32);
    let data_len = (num_frames as u32) * (block_align as u32);

    let mut buf = Vec::with_capacity(44 + data_len as usize);
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&(36 + data_len).to_le_bytes());
    buf.extend_from_slice(b"WAVE");
    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&16u32.to_le_bytes());
    buf.extend_from_slice(&1u16.to_le_bytes());
    buf.extend_from_slice(&channels.to_le_bytes());
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&byte_rate.to_le_bytes());
    buf.extend_from_slice(&block_align.to_le_bytes());
    buf.extend_from_slice(&24u16.to_le_bytes());
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_len.to_le_bytes());

    for i in 0..num_frames {
        let (l, r) = indexed_i24_pair(i);
        buf.extend_from_slice(&l.to_le_bytes()[0..3]);
        buf.extend_from_slice(&r.to_le_bytes()[0..3]);
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

fn build_flac_verbatim_indexed(
    sample_rate: u32,
    bits_per_sample: u8,
    block_frames: usize,
    num_blocks: usize,
    with_seektable: bool,
) -> Vec<u8> {
    assert_eq!(sample_rate, 48_000);
    assert_eq!(block_frames, 256);
    let channels = 2u8;
    let total_frames = (block_frames * num_blocks) as u64;

    // Encode all frames first so SEEKTABLE offsets relative to first_frame_offset are exact.
    let mut frame_offsets = Vec::with_capacity(num_blocks);
    let mut frames_blob = Vec::new();
    let sample_rate_code = 0x0Au8; // 48 kHz
    let bps_code = match bits_per_sample {
        16 => 0x04u8,
        24 => 0x06u8,
        _ => panic!("unsupported bits_per_sample {bits_per_sample}"),
    };

    for block_idx in 0..num_blocks {
        frame_offsets.push(frames_blob.len() as u64);
        let mut frame = vec![
            // Sync code + fixed block size strategy (0)
            0xFF,
            0xF8,
            // Block size = 256 -> code 0b1000 (8); sample rate = 48 kHz -> 0x0A
            (0x08 << 4) | sample_rate_code,
            // Stereo L/R (1) + sample size code
            ((channels - 1) << 4) | (bps_code << 1),
        ];
        push_flac_utf8_u64(&mut frame, block_idx as u64);
        let hdr_crc = crc8_flac(&frame);
        frame.push(hdr_crc);

        for c in 0..channels as usize {
            // Subframe header: 0 (pad) | 000001 (VERBATIM) | 0 (no wasted bits) = 0x02
            frame.push(0x02);
            for f in 0..block_frames {
                let global_f = block_idx * block_frames + f;
                if bits_per_sample == 16 {
                    let (l, r) = indexed_i16_pair(global_f);
                    let s = if c == 0 { l } else { r };
                    frame.extend_from_slice(&s.to_be_bytes());
                } else {
                    let (l, r) = indexed_i24_pair(global_f);
                    let s = if c == 0 { l } else { r };
                    let be = s.to_be_bytes();
                    frame.extend_from_slice(&be[1..4]);
                }
            }
        }

        let crc16 = crc16_flac(&frame);
        frame.extend_from_slice(&crc16.to_be_bytes());
        frames_blob.extend_from_slice(&frame);
    }

    let mut out = Vec::with_capacity(128 + frames_blob.len());
    out.extend_from_slice(b"fLaC");

    // STREAMINFO metadata block (34 bytes)
    let streaminfo_hdr: u8 = if with_seektable { 0x00 } else { 0x80 };
    out.push(streaminfo_hdr);
    out.extend_from_slice(&[0x00, 0x00, 34]);
    out.extend_from_slice(&(block_frames as u16).to_be_bytes());
    out.extend_from_slice(&(block_frames as u16).to_be_bytes());
    out.extend_from_slice(&[0, 0, 0]); // min_frame_size unknown
    out.extend_from_slice(&[0, 0, 0]); // max_frame_size unknown
    let packed_hi: u32 =
        (sample_rate << 12) | (((channels as u32 - 1) & 7) << 9) | (((bits_per_sample as u32 - 1) & 31) << 4);
    let packed_total: u64 = ((packed_hi as u64) << 32) | (total_frames & 0x0F_FFFF_FFFF);
    out.extend_from_slice(&packed_total.to_be_bytes());
    out.extend_from_slice(&[0u8; 16]); // MD5

    if with_seektable {
        // Place a seekpoint every 16 blocks (4096 samples)
        let mut points = Vec::new();
        for b in (0..num_blocks).step_by(16) {
            let sample_no = (b * block_frames) as u64;
            let offset = frame_offsets[b];
            points.push((sample_no, offset, block_frames as u16));
        }
        let table_len = (points.len() * 18) as u32;
        out.push(0x83); // is_last = 1, type = 3 (SEEKTABLE)
        out.push(((table_len >> 16) & 0xFF) as u8);
        out.push(((table_len >> 8) & 0xFF) as u8);
        out.push((table_len & 0xFF) as u8);
        for (sample_no, offset, n_samples) in points {
            out.extend_from_slice(&sample_no.to_be_bytes());
            out.extend_from_slice(&offset.to_be_bytes());
            out.extend_from_slice(&n_samples.to_be_bytes());
        }
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

fn mp3_frame_len(bitrate_kbps: usize) -> usize {
    (144 * bitrate_kbps * 1000) / 44_100
}

fn build_mp3_layer3_frame(
    bitrate_idx: u8,
    bitrate_kbps: usize,
    main_data_begin: u16,
    active_global_gain: Option<u8>,
    prefix_main_bytes: &[u8],
    suffix_main_bytes: &[u8],
) -> Vec<u8> {
    let total_len = mp3_frame_len(bitrate_kbps);
    let mut frame = vec![0u8; total_len];
    // MPEG-1 Layer III, no CRC, 44.1 kHz (sr_idx=0), padding=0, stereo (mode=0)
    frame[0] = 0xFF;
    frame[1] = 0xFB;
    frame[2] = bitrate_idx << 4;
    frame[3] = 0x00;

    let mut side = MsbBitWriter::new(32);
    side.write_bits(main_data_begin as u32, 9);
    side.write_bits(0, 3); // private_bits
    side.write_bits(0, 8); // scfsi

    for _gr in 0..2 {
        for _ch in 0..2 {
            if let Some(gain) = active_global_gain {
                side.write_bits(5, 12); // part2_3_length = 5 bits
                side.write_bits(1, 9); // big_values = 1 pair
                side.write_bits(gain as u32, 8); // global_gain
                side.write_bits(0, 4); // scalefac_compress
                side.write_bits(0, 1); // window_switching_flag
                side.write_bits(1, 5); // table_select[0] = 1
                side.write_bits(0, 5); // table_select[1]
                side.write_bits(0, 5); // table_select[2]
                side.write_bits(0, 4); // region0_count
                side.write_bits(0, 3); // region1_count
                side.write_bits(0, 1); // preflag
                side.write_bits(0, 1); // scalefac_scale
                side.write_bits(0, 1); // count1table_select
            } else {
                side.write_bits(0, 59);
            }
        }
    }
    assert_eq!(side.bit_pos, 256);
    frame[4..36].copy_from_slice(&side.bytes);

    let md = &mut frame[36..];
    if !prefix_main_bytes.is_empty() {
        md[..prefix_main_bytes.len()].copy_from_slice(prefix_main_bytes);
    }
    if !suffix_main_bytes.is_empty() {
        let start = md.len() - suffix_main_bytes.len();
        md[start..].copy_from_slice(suffix_main_bytes);
    }
    frame
}

fn build_mp3_cbr_fixture(num_frames: usize) -> Vec<u8> {
    let mut out = Vec::new();
    for f in 0..num_frames {
        let gain = if f < num_frames / 2 { None } else { Some(180) };
        out.extend_from_slice(&build_mp3_layer3_frame(9, 128, 0, gain, &[], &[]));
    }
    out
}

enum Mp3VbrHeaderKind {
    Xing,
    Vbri,
}

fn build_mp3_vbr_fixture(num_frames: usize, kind: Mp3VbrHeaderKind) -> Vec<u8> {
    // Bitrate cycle: 128(9), 192(11), 256(13), 320(14)
    const RATES: [(u8, usize); 4] = [(9, 128), (11, 192), (13, 256), (14, 320)];

    let mut audio_frames = Vec::with_capacity(num_frames);
    let mut audio_bytes_len = 0usize;
    let mut frame_starts = Vec::with_capacity(num_frames);

    for f in 0..num_frames {
        frame_starts.push(audio_bytes_len);
        let (idx, kbps) = RATES[f % RATES.len()];
        // Trigger bit-reservoir lookback (`main_data_begin > 0`) on frames 20 and 40:
        // frames 19 and 39 are silent (consuming 0 reservoir bytes) and carry the
        // tail byte(s) in their main_data; frames 20 and 40 reference them via
        // main_data_begin = 2 and 1 respectively.
        let (mdb, suffix): (u16, &[u8]) = match f {
            19 => (0, &[0x00, 0x00]),
            20 => (2, &[]),
            39 => (0, &[0x00]),
            40 => (1, &[]),
            _ => (0, &[]),
        };
        let gain = if f < num_frames / 2 { None } else { Some(185) };
        let fr = build_mp3_layer3_frame(idx, kbps, mdb, gain, &[], suffix);
        audio_bytes_len += fr.len();
        audio_frames.push(fr);
    }

    // Build Frame 0 info/header frame (128 kbps = 417 bytes, zeroed side_info)
    let hdr_len = mp3_frame_len(128);
    let mut hdr_frame = vec![0u8; hdr_len];
    hdr_frame[0] = 0xFF;
    hdr_frame[1] = 0xFB;
    hdr_frame[2] = 9 << 4;
    hdr_frame[3] = 0x00;

    let total_stream_bytes = (hdr_len + audio_bytes_len) as u32;
    match kind {
        Mp3VbrHeaderKind::Xing => {
            let x = &mut hdr_frame[36..];
            x[0..4].copy_from_slice(b"Xing");
            x[4..8].copy_from_slice(&0x0000_000Fu32.to_be_bytes()); // frames + bytes + toc + quality
            x[8..12].copy_from_slice(&(num_frames as u32).to_be_bytes());
            x[12..16].copy_from_slice(&total_stream_bytes.to_be_bytes());
            for (i, slot) in x[16..116].iter_mut().enumerate() {
                let f_idx = ((i * num_frames) / 100).min(num_frames - 1);
                let byte_pos = hdr_len + frame_starts[f_idx];
                *slot = ((byte_pos * 256) / (total_stream_bytes as usize)).min(255) as u8;
            }
            x[116..120].copy_from_slice(&50u32.to_be_bytes());
        }
        Mp3VbrHeaderKind::Vbri => {
            let v = &mut hdr_frame[36..];
            v[0..4].copy_from_slice(b"VBRI");
            v[4..6].copy_from_slice(&1u16.to_be_bytes()); // version
            v[6..8].copy_from_slice(&0u16.to_be_bytes()); // delay
            v[8..10].copy_from_slice(&50u16.to_be_bytes()); // quality
            v[10..14].copy_from_slice(&total_stream_bytes.to_be_bytes());
            v[14..18].copy_from_slice(&(num_frames as u32).to_be_bytes());
            v[18..20].copy_from_slice(&0u16.to_be_bytes()); // toc_entries
            v[20..22].copy_from_slice(&1u16.to_be_bytes()); // toc_scale
            v[22..24].copy_from_slice(&2u16.to_be_bytes()); // toc_entry_size
            v[24..26].copy_from_slice(&1u16.to_be_bytes()); // toc_frames
        }
    }

    let mut out = Vec::with_capacity(total_stream_bytes as usize);
    out.extend_from_slice(&hdr_frame);
    for fr in audio_frames {
        out.extend_from_slice(&fr);
    }
    out
}

fn mp4_box(fourcc: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let size = (8 + payload.len()) as u32;
    let mut out = Vec::with_capacity(size as usize);
    out.extend_from_slice(&size.to_be_bytes());
    out.extend_from_slice(fourcc);
    out.extend_from_slice(payload);
    out
}

fn mp4_full_box(fourcc: &[u8; 4], version: u8, flags: u32, payload: &[u8]) -> Vec<u8> {
    let mut inner = Vec::with_capacity(4 + payload.len());
    inner.push(version);
    inner.push(((flags >> 16) & 0xFF) as u8);
    inner.push(((flags >> 8) & 0xFF) as u8);
    inner.push((flags & 0xFF) as u8);
    inner.extend_from_slice(payload);
    mp4_box(fourcc, &inner)
}

fn build_m4a_alac_indexed(
    sample_rate: u32,
    bit_depth: u8,
    frame_length: usize,
    num_packets: usize,
) -> Vec<u8> {
    let total_frames = (frame_length * num_packets) as u32;
    let channels = 2u8;

    // 1. ftyp
    let mut ftyp_payload = Vec::new();
    ftyp_payload.extend_from_slice(b"M4A ");
    ftyp_payload.extend_from_slice(&0u32.to_be_bytes());
    ftyp_payload.extend_from_slice(b"M4A ");
    ftyp_payload.extend_from_slice(b"mp42");
    ftyp_payload.extend_from_slice(b"isom");
    let ftyp = mp4_box(b"ftyp", &ftyp_payload);

    // 2. Encode uncompressed verbatim ALAC CPE packets
    let mut packets = Vec::with_capacity(num_packets);
    for pkt_idx in 0..num_packets {
        let bit_cap = 23 + frame_length * 2 * (bit_depth as usize) + 3;
        let byte_len = bit_cap.div_ceil(8);
        let mut bw = MsbBitWriter::new(byte_len);
        bw.write_bits(1, 3); // ALAC_ELEM_TAG_CPE
        bw.write_bits(0, 4); // elem_instance_tag
        bw.write_bits(0, 12); // unused header bits = 0
        bw.write_bits(0, 1); // is_partial_frame = 0
        bw.write_bits(0, 2); // shift = 0
        bw.write_bits(1, 1); // is_uncompressed = 1

        let mask = if bit_depth == 16 { 0xFFFFu32 } else { 0x00FF_FFFFu32 };
        for f in 0..frame_length {
            let global_f = pkt_idx * frame_length + f;
            let (l, r) = if bit_depth == 16 {
                let (li, ri) = indexed_i16_pair(global_f);
                (li as i32, ri as i32)
            } else {
                indexed_i24_pair(global_f)
            };
            bw.write_bits((l as u32) & mask, bit_depth as usize);
            bw.write_bits((r as u32) & mask, bit_depth as usize);
        }
        bw.write_bits(7, 3); // ALAC_ELEM_TAG_END
        packets.push(bw.bytes);
    }
    let packet_bytes = packets[0].len() as u32;

    // 3. Magic cookie (24 bytes) inside nested 'alac' atom
    let mut magic_cookie = Vec::with_capacity(24);
    magic_cookie.extend_from_slice(&(frame_length as u32).to_be_bytes());
    magic_cookie.push(0); // compatible_version
    magic_cookie.push(bit_depth);
    magic_cookie.push(40); // pb
    magic_cookie.push(10); // mb
    magic_cookie.push(14); // kb
    magic_cookie.push(channels);
    magic_cookie.extend_from_slice(&255u16.to_be_bytes()); // max_run
    magic_cookie.extend_from_slice(&packet_bytes.to_be_bytes()); // max_frame_bytes
    magic_cookie.extend_from_slice(&(sample_rate * (channels as u32) * (bit_depth as u32)).to_be_bytes());
    magic_cookie.extend_from_slice(&sample_rate.to_be_bytes());
    let inner_alac = mp4_full_box(b"alac", 0, 0, &magic_cookie);

    // 'alac' AudioSampleEntry v0
    let mut entry_payload = Vec::new();
    entry_payload.extend_from_slice(&[0u8; 6]); // reserved
    entry_payload.extend_from_slice(&1u16.to_be_bytes()); // data_reference_index
    entry_payload.extend_from_slice(&0u16.to_be_bytes()); // version = 0
    entry_payload.extend_from_slice(&0u16.to_be_bytes()); // revision
    entry_payload.extend_from_slice(&0u32.to_be_bytes()); // vendor
    entry_payload.extend_from_slice(&(channels as u16).to_be_bytes());
    entry_payload.extend_from_slice(&(bit_depth as u16).to_be_bytes());
    entry_payload.extend_from_slice(&0u16.to_be_bytes()); // compression_id
    entry_payload.extend_from_slice(&0u16.to_be_bytes()); // packet_size
    entry_payload.extend_from_slice(&(sample_rate << 16).to_be_bytes()); // 16.16 fixed point
    entry_payload.extend_from_slice(&inner_alac);
    let alac_sample_entry = mp4_box(b"alac", &entry_payload);

    let mut stsd_payload = Vec::new();
    stsd_payload.extend_from_slice(&1u32.to_be_bytes()); // entry_count = 1
    stsd_payload.extend_from_slice(&alac_sample_entry);
    let stsd = mp4_full_box(b"stsd", 0, 0, &stsd_payload);

    // stts: 1 entry (sample_count = num_packets, sample_delta = frame_length)
    let mut stts_payload = Vec::new();
    stts_payload.extend_from_slice(&1u32.to_be_bytes());
    stts_payload.extend_from_slice(&(num_packets as u32).to_be_bytes());
    stts_payload.extend_from_slice(&(frame_length as u32).to_be_bytes());
    let stts = mp4_full_box(b"stts", 0, 0, &stts_payload);

    // stsc: 1 chunk holding all num_packets samples
    let mut stsc_payload = Vec::new();
    stsc_payload.extend_from_slice(&1u32.to_be_bytes());
    stsc_payload.extend_from_slice(&1u32.to_be_bytes()); // first_chunk
    stsc_payload.extend_from_slice(&(num_packets as u32).to_be_bytes()); // samples_per_chunk
    stsc_payload.extend_from_slice(&1u32.to_be_bytes()); // sample_description_index
    let stsc = mp4_full_box(b"stsc", 0, 0, &stsc_payload);

    // stsz: constant sample_size = packet_bytes
    let mut stsz_payload = Vec::new();
    stsz_payload.extend_from_slice(&packet_bytes.to_be_bytes());
    stsz_payload.extend_from_slice(&(num_packets as u32).to_be_bytes());
    let stsz = mp4_full_box(b"stsz", 0, 0, &stsz_payload);

    // Build stbl helper with configurable chunk_offset so we can compute exact mdat offset
    let make_moov = |chunk_offset: u32| -> Vec<u8> {
        let mut stco_payload = Vec::new();
        stco_payload.extend_from_slice(&1u32.to_be_bytes());
        stco_payload.extend_from_slice(&chunk_offset.to_be_bytes());
        let stco = mp4_full_box(b"stco", 0, 0, &stco_payload);

        let mut stbl_payload = Vec::new();
        stbl_payload.extend_from_slice(&stsd);
        stbl_payload.extend_from_slice(&stts);
        stbl_payload.extend_from_slice(&stsc);
        stbl_payload.extend_from_slice(&stsz);
        stbl_payload.extend_from_slice(&stco);
        let stbl = mp4_box(b"stbl", &stbl_payload);

        let mut smhd_payload = Vec::new();
        smhd_payload.extend_from_slice(&[0u8; 4]); // balance + reserved
        let smhd = mp4_full_box(b"smhd", 0, 0, &smhd_payload);

        let url = mp4_full_box(b"url ", 0, 1, &[]);
        let mut dref_payload = Vec::new();
        dref_payload.extend_from_slice(&1u32.to_be_bytes());
        dref_payload.extend_from_slice(&url);
        let dref = mp4_full_box(b"dref", 0, 0, &dref_payload);
        let dinf = mp4_box(b"dinf", &dref);

        let mut minf_payload = Vec::new();
        minf_payload.extend_from_slice(&smhd);
        minf_payload.extend_from_slice(&dinf);
        minf_payload.extend_from_slice(&stbl);
        let minf = mp4_box(b"minf", &minf_payload);

        // mdhd v0
        let mut mdhd_payload = Vec::new();
        mdhd_payload.extend_from_slice(&0u32.to_be_bytes()); // creation_time
        mdhd_payload.extend_from_slice(&0u32.to_be_bytes()); // mod_time
        mdhd_payload.extend_from_slice(&sample_rate.to_be_bytes());
        mdhd_payload.extend_from_slice(&total_frames.to_be_bytes());
        mdhd_payload.extend_from_slice(&0x55C4u16.to_be_bytes()); // und
        mdhd_payload.extend_from_slice(&0u16.to_be_bytes());
        let mdhd = mp4_full_box(b"mdhd", 0, 0, &mdhd_payload);

        // hdlr
        let mut hdlr_payload = Vec::new();
        hdlr_payload.extend_from_slice(&0u32.to_be_bytes()); // pre_defined
        hdlr_payload.extend_from_slice(b"soun");
        hdlr_payload.extend_from_slice(&[0u8; 12]); // reserved
        hdlr_payload.extend_from_slice(b"SoundHandler\0");
        let hdlr = mp4_full_box(b"hdlr", 0, 0, &hdlr_payload);

        let mut mdia_payload = Vec::new();
        mdia_payload.extend_from_slice(&mdhd);
        mdia_payload.extend_from_slice(&hdlr);
        mdia_payload.extend_from_slice(&minf);
        let mdia = mp4_box(b"mdia", &mdia_payload);

        // tkhd v0
        let mut tkhd_payload = Vec::new();
        tkhd_payload.extend_from_slice(&0u32.to_be_bytes()); // creation_time
        tkhd_payload.extend_from_slice(&0u32.to_be_bytes()); // mod_time
        tkhd_payload.extend_from_slice(&1u32.to_be_bytes()); // track_id
        tkhd_payload.extend_from_slice(&0u32.to_be_bytes()); // reserved
        tkhd_payload.extend_from_slice(&total_frames.to_be_bytes());
        tkhd_payload.extend_from_slice(&[0u8; 8]); // reserved
        tkhd_payload.extend_from_slice(&0u16.to_be_bytes()); // layer
        tkhd_payload.extend_from_slice(&0u16.to_be_bytes()); // alternate_group
        tkhd_payload.extend_from_slice(&0x0100u16.to_be_bytes()); // volume
        tkhd_payload.extend_from_slice(&0u16.to_be_bytes()); // reserved
        let identity_matrix: [u32; 9] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000];
        for m in identity_matrix {
            tkhd_payload.extend_from_slice(&m.to_be_bytes());
        }
        tkhd_payload.extend_from_slice(&0u32.to_be_bytes()); // width
        tkhd_payload.extend_from_slice(&0u32.to_be_bytes()); // height
        let tkhd = mp4_full_box(b"tkhd", 0, 7, &tkhd_payload);

        let mut trak_payload = Vec::new();
        trak_payload.extend_from_slice(&tkhd);
        trak_payload.extend_from_slice(&mdia);
        let trak = mp4_box(b"trak", &trak_payload);

        // mvhd v0
        let mut mvhd_payload = Vec::new();
        mvhd_payload.extend_from_slice(&0u32.to_be_bytes());
        mvhd_payload.extend_from_slice(&0u32.to_be_bytes());
        mvhd_payload.extend_from_slice(&sample_rate.to_be_bytes());
        mvhd_payload.extend_from_slice(&total_frames.to_be_bytes());
        mvhd_payload.extend_from_slice(&0x0001_0000u32.to_be_bytes()); // rate 1.0
        mvhd_payload.extend_from_slice(&0x0100u16.to_be_bytes()); // volume 1.0
        mvhd_payload.extend_from_slice(&[0u8; 10]);
        for m in identity_matrix {
            mvhd_payload.extend_from_slice(&m.to_be_bytes());
        }
        mvhd_payload.extend_from_slice(&[0u8; 24]); // pre_defined
        mvhd_payload.extend_from_slice(&2u32.to_be_bytes()); // next_track_id
        let mvhd = mp4_full_box(b"mvhd", 0, 0, &mvhd_payload);

        let mut moov_payload = Vec::new();
        moov_payload.extend_from_slice(&mvhd);
        moov_payload.extend_from_slice(&trak);
        mp4_box(b"moov", &moov_payload)
    };

    let moov_placeholder = make_moov(0);
    let mdat_payload_offset = (ftyp.len() + moov_placeholder.len() + 8) as u32;
    let moov = make_moov(mdat_payload_offset);
    assert_eq!(moov.len(), moov_placeholder.len());

    let mut mdat_payload = Vec::with_capacity(packets.len() * (packet_bytes as usize));
    for p in packets {
        mdat_payload.extend_from_slice(&p);
    }
    let mdat = mp4_box(b"mdat", &mdat_payload);

    let mut out = Vec::with_capacity(ftyp.len() + moov.len() + mdat.len());
    out.extend_from_slice(&ftyp);
    out.extend_from_slice(&moov);
    out.extend_from_slice(&mdat);
    out
}

fn decode_remaining_frames_and_first_pair(
    dec: &mut SymphoniaDecoder,
) -> (usize, Option<(i32, i32)>) {
    let mut total_frames = 0usize;
    let mut first_pair = None;
    while let Some(chunk) = dec.next_chunk().expect("next_chunk failed") {
        let frames = chunk.frames();
        assert!(frames > 0, "next_chunk should never yield empty chunk");
        if first_pair.is_none() {
            first_pair = match &chunk {
                AudioChunk::PcmI16 { samples, .. } => Some((samples[0] as i32, samples[1] as i32)),
                AudioChunk::PcmI24In32 { samples, .. } => Some((samples[0], samples[1])),
                AudioChunk::PcmI32 { samples, .. } => Some((samples[0], samples[1])),
                _ => None,
            };
        }
        total_frames += frames;
    }
    (total_frames, first_pair)
}

fn assert_exact_lossless_seek_matrix(
    label: &str,
    dec: &mut SymphoniaDecoder,
    sample_rate: u32,
    total_frames: usize,
    is_24bit: bool,
) {
    assert_eq!(dec.total_frames(), Some(total_frames as u64), "{label}: total_frames");
    let dur = dec.duration().expect("duration should be Some");
    let dur_ms = dur.as_millis() as u64;

    let expected_pair = |frame_idx: usize| -> (i32, i32) {
        if is_24bit {
            indexed_i24_pair(frame_idx)
        } else {
            let (l, r) = indexed_i16_pair(frame_idx);
            (l as i32, r as i32)
        }
    };

    // 1. Percentage seeks: 0%, 10%, 25%, 50%, 75%, 90%
    for pct in [0u64, 10, 25, 50, 75, 90] {
        // Offset by +3ms on non-zero percentages to guarantee mid-packet / non-aligned landing
        let seek_ms = if pct == 0 {
            0
        } else {
            ((dur_ms * pct) / 100).saturating_add(3).min(dur_ms.saturating_sub(5))
        };
        let target_time = Duration::from_millis(seek_ms);
        let outcome = dec
            .seek_with_outcome(target_time)
            .unwrap_or_else(|e| panic!("{label}: seek {pct}% ({seek_ms}ms) failed: {e}"));
        assert_eq!(dec.last_seek_outcome(), Some(outcome));

        let expected_frame = ((seek_ms as u128 * sample_rate as u128) / 1000) as usize;
        let (rem_frames, first_pair) = decode_remaining_frames_and_first_pair(dec);
        assert_eq!(
            rem_frames,
            total_frames - expected_frame,
            "{label}: {pct}% ({seek_ms}ms, outcome={outcome:?}, first_pair={first_pair:?}) post-seek frame count mismatch"
        );
        assert_eq!(
            first_pair,
            Some(expected_pair(expected_frame)),
            "{label}: {pct}% ({seek_ms}ms) first sample mismatch at frame {expected_frame}"
        );
    }

    // 2. 100% and >100% EOF clamping + backward seek recovery
    for eof_time in [dur, dur + Duration::from_millis(250)] {
        dec.seek(eof_time)
            .unwrap_or_else(|e| panic!("{label}: EOF seek {eof_time:?} failed: {e}"));
        assert!(
            dec.next_chunk().expect("next_chunk at EOF").is_none(),
            "{label}: expected Ok(None) after EOF seek {eof_time:?}"
        );
    }
    dec.seek(Duration::from_millis(123))
        .expect("backward seek after EOF failed");
    let expected_after_eof = ((123u128 * sample_rate as u128) / 1000) as usize;
    let (rem_after_eof, first_after_eof) = decode_remaining_frames_and_first_pair(dec);
    assert_eq!(rem_after_eof, total_frames - expected_after_eof);
    assert_eq!(first_after_eof, Some(expected_pair(expected_after_eof)));

    // 3. Consecutive repeated seeks without intermediate next_chunk()
    for ms in [100u64, 800, 250, 900, 7] {
        dec.seek(Duration::from_millis(ms))
            .expect("repeated seek failed");
    }
    let final_ms = 7u64;
    let expected_rep = ((final_ms as u128 * sample_rate as u128) / 1000) as usize;
    let (rem_rep, first_rep) = decode_remaining_frames_and_first_pair(dec);
    assert_eq!(rem_rep, total_frames - expected_rep);
    assert_eq!(first_rep, Some(expected_pair(expected_rep)));

    // 4. 24 seeded deterministic random seeks (forward & backward)
    let mut prng: u64 = 0x9E37_79B9_7F4A_7C15;
    for step in 0..24 {
        prng = prng
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let rand_ms = (prng >> 32) % (dur_ms.saturating_sub(2).max(1));
        dec.seek(Duration::from_millis(rand_ms))
            .unwrap_or_else(|e| panic!("{label}: random seek #{step} ({rand_ms}ms) failed: {e}"));
        let expected_frame = ((rand_ms as u128 * sample_rate as u128) / 1000) as usize;
        let (rem_frames, first_pair) = decode_remaining_frames_and_first_pair(dec);
        assert_eq!(
            rem_frames,
            total_frames - expected_frame,
            "{label}: random seek #{step} ({rand_ms}ms) remaining frame mismatch"
        );
        assert_eq!(
            first_pair,
            Some(expected_pair(expected_frame)),
            "{label}: random seek #{step} ({rand_ms}ms) first sample mismatch"
        );
    }
}

#[test]
fn test_wav_16bit_and_24bit_s24le_seek_and_classification() {
    let total_frames = 48_000usize;
    let sr = 48_000u32;

    // 16-bit WAV (from_bytes + from_file)
    let wav16 = build_wav_i16_indexed(sr, total_frames);
    let mut dec16_bytes = SymphoniaDecoder::from_bytes(wav16.clone(), Some("wav")).unwrap();
    assert_eq!(
        dec16_bytes.unified_format().sample_format,
        SampleFormatKind::Int16
    );
    assert_exact_lossless_seek_matrix("wav16-bytes", &mut dec16_bytes, sr, total_frames, false);

    let f16 = TempAudioFile::new("wav16", "wav", &wav16);
    let mut dec16_file = SymphoniaDecoder::from_file(&f16.path).unwrap();
    assert_exact_lossless_seek_matrix("wav16-file", &mut dec16_file, sr, total_frames, false);

    // 24-bit S24LE WAV: verify SampleFormatKind::Int24In32 classification & exact 24-bit seeking
    let wav24 = build_wav_i24_indexed(sr, total_frames);
    let mut dec24_bytes = SymphoniaDecoder::from_bytes(wav24.clone(), Some("wav")).unwrap();
    let uf24 = dec24_bytes.unified_format();
    assert_eq!(uf24.codec, AudioCodec::Wav);
    assert_eq!(uf24.sample_format, SampleFormatKind::Int24In32);
    assert_eq!(uf24.container_bits, 32);
    assert_eq!(uf24.valid_bits, 24);
    assert_exact_lossless_seek_matrix("wav24-bytes", &mut dec24_bytes, sr, total_frames, true);

    let f24 = TempAudioFile::new("wav24", "wav", &wav24);
    let mut dec24_file = SymphoniaDecoder::from_file(&f24.path).unwrap();
    assert_eq!(
        dec24_file.unified_format().sample_format,
        SampleFormatKind::Int24In32
    );
    assert_exact_lossless_seek_matrix("wav24-file", &mut dec24_file, sr, total_frames, true);
}

#[test]
fn test_flac_16bit_and_24bit_with_and_without_seektable_and_try_new() {
    let sr = 48_000u32;
    let block_frames = 256usize;
    let num_blocks = 192usize; // 49,152 frames = 1.024 s, > 16,192 bytes so binary search triggers
    let total_frames = block_frames * num_blocks;

    for (bits, is_24bit) in [(16u8, false), (24u8, true)] {
        for with_seektable in [false, true] {
            let flac_bytes =
                build_flac_verbatim_indexed(sr, bits, block_frames, num_blocks, with_seektable);
            assert!(
                flac_bytes.len() > 20_000,
                "FLAC fixture must exceed 16,192 bytes to exercise Symphonia binary search"
            );

            let tag = format!(
                "flac{bits}-{}",
                if with_seektable { "seektable" } else { "noseektable" }
            );

            let mut dec_bytes = SymphoniaDecoder::from_bytes(flac_bytes.clone(), Some("flac"))
                .unwrap_or_else(|e| panic!("{tag} from_bytes failed: {e}"));
            assert_eq!(dec_bytes.format().codec, AudioCodec::Flac);
            assert_exact_lossless_seek_matrix(
                &format!("{tag}-bytes"),
                &mut dec_bytes,
                sr,
                total_frames,
                is_24bit,
            );

            let f = TempAudioFile::new(&tag, "flac", &flac_bytes);
            let mut dec_file = SymphoniaDecoder::from_file(&f.path)
                .unwrap_or_else(|e| panic!("{tag} from_file failed: {e}"));
            assert_exact_lossless_seek_matrix(
                &format!("{tag}-file"),
                &mut dec_file,
                sr,
                total_frames,
                is_24bit,
            );

            if !with_seektable && bits == 16 {
                // Also verify GenericSource::byte_len() via SymphoniaDecoder::try_new
                let custom = CustomSeekableReader {
                    inner: Cursor::new(flac_bytes),
                };
                let mut dec_generic =
                    SymphoniaDecoder::try_new(custom, Some("flac"), None).unwrap();
                assert_exact_lossless_seek_matrix(
                    "flac16-generic-try-new",
                    &mut dec_generic,
                    sr,
                    total_frames,
                    false,
                );
            }
        }
    }
}

fn assert_mp3_seek_matrix(label: &str, dec: &mut SymphoniaDecoder, expected_total_frames: usize) {
    assert_eq!(dec.format().codec, AudioCodec::Mp3);
    assert_eq!(dec.total_frames(), Some(expected_total_frames as u64));
    let sr = 44_100u32;
    let dur = dec.duration().expect("MP3 duration missing");
    let dur_ms = dur.as_millis() as u64;

    // 1. Percentage seeks landing mid-frame (1152 samples/frame)
    for pct in [0u64, 10, 25, 50, 75, 90] {
        let seek_ms = if pct == 0 {
            0
        } else {
            ((dur_ms * pct) / 100).saturating_add(7).min(dur_ms.saturating_sub(10))
        };
        let outcome = dec
            .seek_with_outcome(Duration::from_millis(seek_ms))
            .unwrap_or_else(|e| panic!("{label}: seek {pct}% ({seek_ms}ms) failed: {e}"));
        let target_frame = ((seek_ms as u128 * sr as u128) / 1000) as usize;

        let mut decoded_frames = 0usize;
        let mut energy_sum = 0.0f64;
        while let Some(chunk) = dec.next_chunk().expect("MP3 next_chunk failed") {
            match chunk {
                AudioChunk::PcmF32 { ref samples, .. } => {
                    for &s in samples {
                        assert!(s.is_finite(), "{label}: non-finite sample after seek");
                        energy_sum += (s as f64) * (s as f64);
                    }
                    decoded_frames += chunk.frames();
                }
                other => panic!("{label}: expected PcmF32, got {other:?}"),
            }
        }

        assert_eq!(
            decoded_frames,
            expected_total_frames - target_frame,
            "{label}: {pct}% ({seek_ms}ms, outcome={outcome:?}) exact post-seek frame count mismatch"
        );
        if pct < 50 {
            assert!(
                energy_sum > 0.0,
                "{label}: expected non-zero active region energy after seek at {pct}%"
            );
        }
    }

    // 2. 100% & >100% EOF clamp + backward seek recovery
    for eof_time in [dur, dur + Duration::from_millis(500)] {
        dec.seek(eof_time).expect("MP3 EOF seek failed");
        assert!(dec.next_chunk().unwrap().is_none());
    }
    dec.seek(Duration::from_millis(530)).expect("MP3 backward seek after EOF failed");
    let frame_530 = ((530u128 * sr as u128) / 1000) as usize;
    let mut after_eof_frames = 0usize;
    while let Some(chunk) = dec.next_chunk().unwrap() {
        after_eof_frames += chunk.frames();
    }
    assert_eq!(after_eof_frames, expected_total_frames - frame_530);

    // 3. Consecutive repeated seeks
    for ms in [200u64, 1500, 522, 1800, 17] {
        dec.seek(Duration::from_millis(ms)).unwrap();
    }
    let frame_17 = ((17u128 * sr as u128) / 1000) as usize;
    let mut rep_frames = 0usize;
    while let Some(chunk) = dec.next_chunk().unwrap() {
        rep_frames += chunk.frames();
    }
    assert_eq!(rep_frames, expected_total_frames - frame_17);

    // 4. 20+ seeded random seeks (including frame 20 / 40 bit-reservoir boundaries)
    let mut prng: u64 = 0x1234_5678_9ABC_DEF0;
    for step in 0..22 {
        prng = prng
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let rand_ms = (prng >> 32) % (dur_ms.saturating_sub(5).max(1));
        dec.seek(Duration::from_millis(rand_ms)).unwrap();
        let target_frame = ((rand_ms as u128 * sr as u128) / 1000) as usize;
        let mut count = 0usize;
        while let Some(chunk) = dec.next_chunk().unwrap() {
            count += chunk.frames();
        }
        assert_eq!(
            count,
            expected_total_frames - target_frame,
            "{label}: random seek #{step} ({rand_ms}ms) frame count mismatch"
        );
    }
}

#[test]
fn test_mp3_cbr_and_vbr_xing_vbri_bit_reservoir_seek() {
    let num_frames = 80usize;
    let expected_total_frames = num_frames * 1152; // 92,160 frames

    // 1. CBR
    let cbr = build_mp3_cbr_fixture(num_frames);
    let mut dec_cbr_b = SymphoniaDecoder::from_bytes(cbr.clone(), Some("mp3")).unwrap();
    assert_mp3_seek_matrix("mp3-cbr-bytes", &mut dec_cbr_b, expected_total_frames);
    let f_cbr = TempAudioFile::new("mp3_cbr", "mp3", &cbr);
    let mut dec_cbr_f = SymphoniaDecoder::from_file(&f_cbr.path).unwrap();
    assert_mp3_seek_matrix("mp3-cbr-file", &mut dec_cbr_f, expected_total_frames);

    // 2. VBR Xing with main_data_begin > 0 at frames 20 and 40
    let xing = build_mp3_vbr_fixture(num_frames, Mp3VbrHeaderKind::Xing);
    let mut dec_xing_b = SymphoniaDecoder::from_bytes(xing.clone(), Some("mp3")).unwrap();
    // Explicitly target inside frame 20 (frame 20 starts at 20 * 1152 / 44.1 = 522.45 ms)
    let bit_reservoir_seek = Duration::from_millis(530);
    let outcome = dec_xing_b.seek_with_outcome(bit_reservoir_seek).unwrap();
    assert!(
        outcome.trimmed_frames > 0,
        "Expected pre-target trimming across bit-reservoir ref_frame, got {outcome:?}"
    );
    let mut post_res_frames = 0usize;
    while let Some(chunk) = dec_xing_b.next_chunk().unwrap() {
        post_res_frames += chunk.frames();
    }
    let expected_530 = ((530u128 * 44_100u128) / 1000) as usize;
    assert_eq!(post_res_frames, expected_total_frames - expected_530);
    assert_mp3_seek_matrix("mp3-xing-bytes", &mut dec_xing_b, expected_total_frames);

    let f_xing = TempAudioFile::new("mp3_xing", "mp3", &xing);
    let mut dec_xing_f = SymphoniaDecoder::from_file(&f_xing.path).unwrap();
    assert_mp3_seek_matrix("mp3-xing-file", &mut dec_xing_f, expected_total_frames);

    // 3. VBR VBRI
    let vbri = build_mp3_vbr_fixture(num_frames, Mp3VbrHeaderKind::Vbri);
    let mut dec_vbri_b = SymphoniaDecoder::from_bytes(vbri.clone(), Some("mp3")).unwrap();
    assert_mp3_seek_matrix("mp3-vbri-bytes", &mut dec_vbri_b, expected_total_frames);
    let f_vbri = TempAudioFile::new("mp3_vbri", "mp3", &vbri);
    let mut dec_vbri_f = SymphoniaDecoder::from_file(&f_vbri.path).unwrap();
    assert_mp3_seek_matrix("mp3-vbri-file", &mut dec_vbri_f, expected_total_frames);
}

#[test]
fn test_m4a_alac_16bit_and_24bit_seek_matrix() {
    let sr = 48_000u32;
    let frame_length = 256usize;
    let num_packets = 192usize;
    let total_frames = frame_length * num_packets; // 49,152 frames = 1.024 s

    for (bit_depth, is_24bit) in [(16u8, false), (24u8, true)] {
        let m4a_bytes = build_m4a_alac_indexed(sr, bit_depth, frame_length, num_packets);
        let tag = format!("m4a-alac-{bit_depth}");

        let mut dec_b = SymphoniaDecoder::from_bytes(m4a_bytes.clone(), Some("m4a"))
            .unwrap_or_else(|e| panic!("{tag} from_bytes failed: {e}"));
        assert_eq!(dec_b.format().codec, AudioCodec::Alac);
        assert_eq!(dec_b.unified_format().valid_bits, bit_depth);
        assert_exact_lossless_seek_matrix(&format!("{tag}-bytes"), &mut dec_b, sr, total_frames, is_24bit);

        let f = TempAudioFile::new(&tag, "m4a", &m4a_bytes);
        let mut dec_f = SymphoniaDecoder::from_file(&f.path)
            .unwrap_or_else(|e| panic!("{tag} from_file failed: {e}"));
        assert_exact_lossless_seek_matrix(&format!("{tag}-file"), &mut dec_f, sr, total_frames, is_24bit);
    }
}
