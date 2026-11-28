use encoding_rs::{BIG5, GBK, SHIFT_JIS, WINDOWS_1252};

use super::{
    DetectedEncoding, detect_tag_block_encoding, recover_latin1_mojibake_block, sanitize_tag_text,
};

#[test]
fn test_western_accented_adjacent_chars_not_misclassified_as_cjk() {
    for word in ["créée", "Ação", "«Été»", "Café", "Björk", "Tiësto", "Naïve"] {
        let (bytes, _, had_err) = WINDOWS_1252.encode(word);
        assert!(!had_err, "failed to encode {word}");
        let enc = detect_tag_block_encoding(&[bytes.as_ref()]);
        assert_eq!(
            enc,
            DetectedEncoding::Windows1252,
            "Western Latin-1 '{word}' was misclassified as {enc:?}"
        );
    }
}

#[test]
fn test_cjk_tag_wide_detection_shift_jis_gbk_big5() {
    let (sjis_title, _, _) = SHIFT_JIS.encode("あの夏へ");
    let (sjis_artist, _, _) = SHIFT_JIS.encode("久石譲");
    assert_eq!(
        detect_tag_block_encoding(&[sjis_title.as_ref(), sjis_artist.as_ref()]),
        DetectedEncoding::ShiftJis
    );

    let (gbk_title, _, _) = GBK.encode("简体中文测试歌曲");
    let (gbk_artist, _, _) = GBK.encode("周杰伦");
    assert_eq!(
        detect_tag_block_encoding(&[gbk_title.as_ref(), gbk_artist.as_ref()]),
        DetectedEncoding::Gbk
    );

    let (big5_title, _, _) = BIG5.encode("繁體中文專輯測試");
    let (big5_artist, _, _) = BIG5.encode("周杰倫");
    assert_eq!(
        detect_tag_block_encoding(&[big5_title.as_ref(), big5_artist.as_ref()]),
        DetectedEncoding::Big5
    );
}

#[test]
fn test_bom_detection_scans_all_samples_not_just_first() {
    let mut utf8_bom = vec![0xEF, 0xBB, 0xBF];
    utf8_bom.extend_from_slice("久石譲".as_bytes());
    let enc = detect_tag_block_encoding(&[b"01", utf8_bom.as_slice()]);
    assert_eq!(enc, DetectedEncoding::Utf8Bom);
}

#[test]
fn test_recover_latin1_mojibake_block_consistent_across_fields() {
    let (sjis_title, _, _) = SHIFT_JIS.encode("千と千尋の神隠し");
    let (sjis_artist, _, _) = SHIFT_JIS.encode("久石譲");
    let latin1_title: String = sjis_title.iter().map(|&b| b as char).collect();
    let latin1_artist: String = sjis_artist.iter().map(|&b| b as char).collect();

    let (recovered, enc) =
        recover_latin1_mojibake_block(&[latin1_title.as_str(), latin1_artist.as_str()]);
    assert_eq!(enc, Some(DetectedEncoding::ShiftJis));
    assert_eq!(recovered[0], "千と千尋の神隠し");
    assert_eq!(recovered[1], "久石譲");
}

#[test]
fn test_sanitize_tag_text_unicode_nfc_and_trim() {
    // Decomposed NFD "Cafe\u{0301}" -> NFC "Café"
    let nfd = "  Cafe\u{0301}\0\t ";
    assert_eq!(sanitize_tag_text(nfd), "Café");
}
