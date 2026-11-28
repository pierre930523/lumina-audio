mod analyzer;
mod tap;
#[cfg(test)]
mod tests;
mod wire_format;
mod wire_unpack;

pub use analyzer::{AudioVerificationEngine, VerificationConfig};
pub use tap::VerificationTapProducer;
pub use wire_format::{
    BIT_REVERSE_LUT, WireFormatStamp, WirePacker, WireSampleFormat, pack_chunk_to_wire_bytes,
    pack_chunk_to_wire_bytes_into, pack_chunk_to_wire_bytes_with_dsd_order_into,
    pack_native_dsd_bytes_into,
};
pub use wire_unpack::unpack_wire_bytes_to_chunk;
