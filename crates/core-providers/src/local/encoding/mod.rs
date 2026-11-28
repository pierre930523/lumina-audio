mod detect;
mod sanitize;
#[cfg(test)]
mod tests;

use std::fmt;

use encoding_rs::{BIG5, EUC_KR, GBK, SHIFT_JIS, UTF_8, UTF_16BE, UTF_16LE, WINDOWS_1252};
use serde::{Deserialize, Serialize};

pub use detect::detect_tag_block_encoding;
pub use sanitize::{
    decode_bytes_with_encoding, decode_text_cjk, decode_with_detected_encoding,
    recover_latin1_mojibake, recover_latin1_mojibake_block, sanitize_multiline_tag_text,
    sanitize_tag_text,
};

/// Detected or resolved text encoding for an audio tag block or field.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DetectedEncoding {
    #[default]
    Ascii,
    Utf8,
    Utf8Bom,
    Utf16Le,
    Utf16Be,
    ShiftJis,
    Gbk,
    Big5,
    EucKr,
    Windows1252,
}

impl DetectedEncoding {
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Ascii => "ascii",
            Self::Utf8 => "utf-8",
            Self::Utf8Bom => "utf-8-bom",
            Self::Utf16Le => "utf-16le",
            Self::Utf16Be => "utf-16be",
            Self::ShiftJis => "shift_jis",
            Self::Gbk => "gbk",
            Self::Big5 => "big5",
            Self::EucKr => "euc-kr",
            Self::Windows1252 => "windows-1252",
        }
    }

    pub const fn is_cjk(&self) -> bool {
        matches!(self, Self::ShiftJis | Self::Gbk | Self::Big5 | Self::EucKr)
    }

    pub(super) fn to_encoding_rs(self) -> &'static encoding_rs::Encoding {
        match self {
            Self::Ascii | Self::Utf8 | Self::Utf8Bom => UTF_8,
            Self::Utf16Le => UTF_16LE,
            Self::Utf16Be => UTF_16BE,
            Self::ShiftJis => SHIFT_JIS,
            Self::Gbk => GBK,
            Self::Big5 => BIG5,
            Self::EucKr => EUC_KR,
            Self::Windows1252 => WINDOWS_1252,
        }
    }
}

impl fmt::Display for DetectedEncoding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}
