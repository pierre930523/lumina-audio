mod embedded;
mod embedded_id3;
mod fetcher;
mod lrc_parser;
mod models;
mod ttml_parser;

pub use lrc_parser::decode_text_cjk;
pub use models::{
    LyricLine, LyricWord, LyricsFormat, LyricsKind, LyricsManager, LyricsResult, LyricsSource,
    LyricsTarget,
};
