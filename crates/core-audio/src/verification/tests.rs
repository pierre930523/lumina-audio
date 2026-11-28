use super::*;
use crate::dsd::DopFramer;
use crate::pcm::AudioChunk;

#[test]
fn dop_wire_packer_carries_odd_boundary_bytes_without_dropping() {
    let mut packer = WirePacker::new();
    let wire = WireSampleFormat::Dop24In32MsbLe {
        channels: 2,
        is_lsb_first: false,
    };
    // 6 bytes = 1 stereo DoP frame (4 bytes) + 2 trailing bytes [0xAA, 0xBB]
    let chunk1 = AudioChunk::DsdBitstream {
        bytes: vec![0x11, 0x22, 0x33, 0x44, 0xAA, 0xBB],
        channels: 2,
        sample_rate: 2_822_400,
        is_lsb_first: false,
    };
    let out1 = packer.pack(&chunk1, wire).to_vec();
    assert_eq!(out1.len(), 8);
    assert_eq!(packer.pending_dop_bytes(), 2);

    // Next 2 bytes [0xCC, 0xDD] complete the carried stereo DoP frame
    let chunk2 = AudioChunk::DsdBitstream {
        bytes: vec![0xCC, 0xDD],
        channels: 2,
        sample_rate: 2_822_400,
        is_lsb_first: false,
    };
    let out2 = packer.pack(&chunk2, wire).to_vec();
    assert_eq!(out2.len(), 8);
    assert_eq!(packer.pending_dop_bytes(), 0);

    let mut combined = Vec::new();
    combined.extend_from_slice(&out1);
    combined.extend_from_slice(&out2);

    let mut unframer = DopFramer::new();
    let unpacked = unpack_wire_bytes_to_chunk(&combined, wire, 2, 2_822_400, Some(&mut unframer))
        .expect("valid DoP unpack");
    assert_eq!(
        unpacked,
        AudioChunk::DsdBitstream {
            bytes: vec![0x11, 0x22, 0x33, 0x44, 0xAA, 0xBB, 0xCC, 0xDD],
            channels: 2,
            sample_rate: 2_822_400,
            is_lsb_first: false,
        }
    );
}

#[test]
fn native_dsd_bit_order_lut_reverses_only_when_order_differs() {
    let dsf_lsb = AudioChunk::DsdBitstream {
        bytes: vec![0x01, 0x80, 0x69, 0xA5],
        channels: 2,
        sample_rate: 2_822_400,
        is_lsb_first: true,
    };
    let wire = WireSampleFormat::NativeDsd { channels: 2 };

    // Same order (LSB -> LSB): verbatim
    let mut lsb_packer = WirePacker::new().with_native_dsd_target_lsb_first(Some(true));
    assert_eq!(lsb_packer.pack(&dsf_lsb, wire), &[0x01, 0x80, 0x69, 0xA5]);

    // Different order (LSB -> MSB): exact bit reversal via LUT
    let mut msb_packer = WirePacker::new().with_native_dsd_target_lsb_first(Some(false));
    assert_eq!(msb_packer.pack(&dsf_lsb, wire), &[0x80, 0x01, 0x96, 0xA5]);
}

#[test]
fn wire_packer_reuses_buffer_for_pcm_chunks() {
    let mut packer = WirePacker::with_capacity(1024);
    let chunk = AudioChunk::PcmI16 {
        samples: vec![100, -200, 300, -400],
        channels: 2,
        sample_rate: 44_100,
    };
    let p1 = packer.pack(&chunk, WireSampleFormat::Int16Le).as_ptr();
    let p2 = packer.pack(&chunk, WireSampleFormat::Int16Le).as_ptr();
    assert_eq!(p1, p2);
}
