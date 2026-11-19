use std::fs;
use tempfile::tempdir;

use core_db::open_test_database;
use core_providers::local::lyrics::{
    decode_text_cjk, LyricsFormat, LyricsKind, LyricsManager, LyricsSource,
    LyricsTarget,
};

#[tokio::test]
async fn test_empty_state_when_no_lyrics() {
    let pool = open_test_database().await.unwrap();
    let dir = tempdir().unwrap();
    let audio_path = dir.path().join("instrumental.flac");
    fs::write(&audio_path, b"fake flac content").unwrap();

    let target = LyricsTarget {
        track_id: None,
        file_path: Some(audio_path.to_str().unwrap().to_string()),
    };

    let result = LyricsManager::get_lyrics(&target, Some(&pool)).await;
    assert!(!result.found);
    assert_eq!(result.kind, LyricsKind::None);
    assert_eq!(result.source, LyricsSource::None);
    assert!(result.lines.is_empty());
}

#[tokio::test]
async fn test_standard_lrc_parsing_and_offset() {
    let lrc = r#"
[ti:Test Title]
[ar:Test Artist]
[offset:+500]
[00:01.00]Line 1
[00:03.50]Line 2
[00:06.00]Line 3
"#;
    let res = LyricsManager::parse_lrc(lrc, LyricsSource::SidecarLrc).unwrap();
    assert!(res.found);
    assert_eq!(res.kind, LyricsKind::Synced);
    assert_eq!(res.source, LyricsSource::SidecarLrc);
    assert_eq!(res.format, LyricsFormat::Lrc);
    assert_eq!(res.offset_ms, 500);
    assert_eq!(res.lines.len(), 3);

    // 1000 + 500 = 1500
    assert_eq!(res.lines[0].start_ms, Some(1500));
    assert_eq!(res.lines[0].end_ms, Some(4000));
    assert_eq!(res.lines[0].text, "Line 1");

    // 3500 + 500 = 4000
    assert_eq!(res.lines[1].start_ms, Some(4000));
    assert_eq!(res.lines[1].end_ms, Some(6500));
    assert_eq!(res.lines[1].text, "Line 2");

    // 6000 + 500 = 6500
    assert_eq!(res.lines[2].start_ms, Some(6500));
    assert_eq!(res.lines[2].end_ms, None);
    assert_eq!(res.lines[2].text, "Line 3");
}

#[tokio::test]
async fn test_negative_offset_clamping() {
    let lrc = r#"
[offset:-2000]
[00:01.00]Clamped to zero
[00:05.00]Shifted line
"#;
    let res = LyricsManager::parse_lrc(lrc, LyricsSource::SidecarLrc).unwrap();
    assert!(res.found);
    assert_eq!(res.offset_ms, -2000);
    // (1000 - 2000).max(0) = 0
    assert_eq!(res.lines[0].start_ms, Some(0));
    // (5000 - 2000).max(0) = 3000
    assert_eq!(res.lines[1].start_ms, Some(3000));
}

#[tokio::test]
async fn test_duplicate_timestamps_expansion() {
    let lrc = r#"
[00:01.00]Verse 1
[00:05.00][00:15.00]Repeated Chorus
"#;
    let res = LyricsManager::parse_lrc(lrc, LyricsSource::SidecarLrc).unwrap();
    assert!(res.found);
    assert_eq!(res.lines.len(), 3);
    assert_eq!(res.lines[0].start_ms, Some(1000));
    assert_eq!(res.lines[0].text, "Verse 1");
    assert_eq!(res.lines[1].start_ms, Some(5000));
    assert_eq!(res.lines[1].text, "Repeated Chorus");
    assert_eq!(res.lines[2].start_ms, Some(15000));
    assert_eq!(res.lines[2].text, "Repeated Chorus");
}

#[tokio::test]
async fn test_enhanced_lrc_word_timings() {
    let lrc = r#"
[00:01.00]<00:01.00>Hello <00:01.50>World <00:02.00>Today
[00:03.00]<00:03.00>繁體<00:03.50>歌詞<00:04.00>測試
"#;
    let res = LyricsManager::parse_lrc(lrc, LyricsSource::SidecarLrc).unwrap();
    assert!(res.found);
    assert_eq!(res.format, LyricsFormat::EnhancedLrc);
    assert_eq!(res.lines.len(), 2);
    assert!(!res.lines[0].words.is_empty());
    assert_eq!(res.lines[0].words[0].text, "Hello");
    assert_eq!(res.lines[0].words[0].start_ms, 1000);
    assert_eq!(res.lines[0].words[1].text, "World");
    assert_eq!(res.lines[0].words[1].start_ms, 1500);
}

#[tokio::test]
async fn test_cjk_legacy_encodings_gbk_big5_shiftjis() {
    use encoding_rs::{BIG5, GBK, SHIFT_JIS};

    // GBK
    let gbk_txt = "简体中文歌词测试";
    let (gbk_bytes, _, _) = GBK.encode(gbk_txt);
    let decoded_gbk = decode_text_cjk(&gbk_bytes);
    assert_eq!(decoded_gbk, gbk_txt);

    // Big5
    let big5_txt = "繁體中文歌詞測試";
    let (big5_bytes, _, _) = BIG5.encode(big5_txt);
    let decoded_big5 = decode_text_cjk(&big5_bytes);
    assert_eq!(decoded_big5, big5_txt);

    // Shift-JIS
    let sjis_txt = "日本語歌詞テスト";
    let (sjis_bytes, _, _) = SHIFT_JIS.encode(sjis_txt);
    let decoded_sjis = decode_text_cjk(&sjis_bytes);
    assert_eq!(decoded_sjis, sjis_txt);
}

#[tokio::test]
async fn test_priority_chain_and_user_override() {
    let pool = open_test_database().await.unwrap();
    let dir = tempdir().unwrap();

    let song_path = dir.path().join("song.flac");
    fs::write(&song_path, b"dummy audio").unwrap();

    let lrc_path = dir.path().join("song.lrc");
    fs::write(&lrc_path, "[00:01.00]Sidecar LRC Lyric").unwrap();

    let txt_path = dir.path().join("song.txt");
    fs::write(&txt_path, "Sidecar TXT Lyric").unwrap();

    let user_override_path = dir.path().join("user_override.lrc");
    fs::write(&user_override_path, "[00:00.50]User Override Lyric").unwrap();

    let target = LyricsTarget {
        track_id: None,
        file_path: Some(song_path.to_str().unwrap().to_string()),
    };

    // 1. Initially, Sidecar LRC should win over Sidecar TXT
    let res1 = LyricsManager::get_lyrics(&target, Some(&pool)).await;
    assert!(res1.found);
    assert_eq!(res1.source, LyricsSource::SidecarLrc);
    assert_eq!(res1.lines[0].text, "Sidecar LRC Lyric");

    // 2. Set user file override
    LyricsManager::set_user_override(&target, user_override_path.to_str().unwrap(), &pool)
        .await
        .unwrap();

    let res2 = LyricsManager::get_lyrics(&target, Some(&pool)).await;
    assert!(res2.found);
    assert_eq!(res2.source, LyricsSource::UserFile);
    assert_eq!(res2.lines[0].text, "User Override Lyric");

    // 3. Clear user file override
    let cleared = LyricsManager::clear_user_override(&target, &pool)
        .await
        .unwrap();
    assert!(cleared);

    let res3 = LyricsManager::get_lyrics(&target, Some(&pool)).await;
    assert!(res3.found);
    assert_eq!(res3.source, LyricsSource::SidecarLrc);
    assert_eq!(res3.lines[0].text, "Sidecar LRC Lyric");

    // 4. Remove sidecar .lrc; sidecar .txt should be picked up
    fs::remove_file(&lrc_path).unwrap();
    let res4 = LyricsManager::get_lyrics(&target, Some(&pool)).await;
    assert!(res4.found);
    assert_eq!(res4.source, LyricsSource::SidecarTxt);
    assert_eq!(res4.format, LyricsFormat::Plain);
    assert_eq!(res4.lines[0].text, "Sidecar TXT Lyric");
}

#[tokio::test]
async fn test_json_serialization_contract() {
    let lrc = "[00:01.00]<00:01.00>Contract <00:01.50>Test";
    let res = LyricsManager::parse_lrc(lrc, LyricsSource::EmbeddedSynced).unwrap();
    let json_val = serde_json::to_value(&res).unwrap();

    assert_eq!(json_val["found"], true);
    assert_eq!(json_val["kind"], "synced");
    assert_eq!(json_val["source"], "embedded_synced");
    assert_eq!(json_val["format"], "enhanced_lrc");
    assert_eq!(json_val["offset_ms"], 0);
    assert!(json_val["lines"].is_array());
    assert_eq!(json_val["lines"][0]["start_ms"], 1000);
    assert_eq!(json_val["lines"][0]["words"][0]["text"], "Contract");
}
