use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};

use core_db::open_test_database;
use core_providers::local::artwork::ArtworkManager;
use core_providers::local::dsd_meta::{parse_dff, parse_dsf};
use core_providers::local::metadata::derive_title_and_track_from_filename;
use core_providers::local::riff_meta::parse_wav;
use core_providers::local::scanner::{find_folder_cover_in_files, normalize_path};
use core_providers::LibrarySyncService;
use core_types::{ArtworkSourceKind, AudioCodec};
use image::{ImageBuffer, Rgb};
use tempfile::tempdir;

fn create_test_image(path: &Path, width: u32, height: u32, rgb: (u8, u8, u8)) {
    let img: ImageBuffer<Rgb<u8>, Vec<u8>> =
        ImageBuffer::from_pixel(width, height, Rgb([rgb.0, rgb.1, rgb.2]));
    img.save(path).expect("failed to save test image");
}

fn create_test_image_bytes(width: u32, height: u32, rgb: (u8, u8, u8)) -> Vec<u8> {
    let img: ImageBuffer<Rgb<u8>, Vec<u8>> =
        ImageBuffer::from_pixel(width, height, Rgb([rgb.0, rgb.1, rgb.2]));
    let mut buf = std::io::Cursor::new(Vec::new());
    img.write_to(&mut buf, image::ImageFormat::Jpeg)
        .expect("failed to encode jpeg");
    buf.into_inner()
}

fn encode_syncsafe(val: u32) -> [u8; 4] {
    [
        ((val >> 21) & 0x7F) as u8,
        ((val >> 14) & 0x7F) as u8,
        ((val >> 7) & 0x7F) as u8,
        (val & 0x7F) as u8,
    ]
}

#[allow(clippy::too_many_arguments)]
fn build_id3v2_tag(
    title: Option<&str>,
    artist: Option<&str>,
    album: Option<&str>,
    album_artist: Option<&str>,
    genre: Option<&str>,
    composer: Option<&str>,
    year: Option<&str>,
    picture: Option<(&[u8], &str, u8)>, // (bytes, mime, type)
) -> Vec<u8> {
    let mut frames = Vec::new();

    let mut add_text_frame = |id: &[u8; 4], text: &str| {
        let mut payload = vec![3u8]; // UTF-8 encoding
        payload.extend_from_slice(text.as_bytes());
        payload.push(0); // null terminator

        frames.extend_from_slice(id);
        frames.extend_from_slice(&encode_syncsafe(payload.len() as u32));
        frames.extend_from_slice(&[0, 0]); // flags
        frames.extend_from_slice(&payload);
    };

    if let Some(t) = title {
        add_text_frame(b"TIT2", t);
    }
    if let Some(a) = artist {
        add_text_frame(b"TPE1", a);
    }
    if let Some(al) = album {
        add_text_frame(b"TALB", al);
    }
    if let Some(aa) = album_artist {
        add_text_frame(b"TPE2", aa);
    }
    if let Some(g) = genre {
        add_text_frame(b"TCON", g);
    }
    if let Some(c) = composer {
        add_text_frame(b"TCOM", c);
    }
    if let Some(y) = year {
        add_text_frame(b"TDRC", y);
    }

    if let Some((pic_bytes, mime, pic_type)) = picture {
        let mut payload = vec![0u8]; // ISO-8859-1 encoding for mime/desc
        payload.extend_from_slice(mime.as_bytes());
        payload.push(0); // null terminator for mime
        payload.push(pic_type);
        payload.push(0); // empty description null terminator
        payload.extend_from_slice(pic_bytes);

        frames.extend_from_slice(b"APIC");
        frames.extend_from_slice(&encode_syncsafe(payload.len() as u32));
        frames.extend_from_slice(&[0, 0]); // flags
        frames.extend_from_slice(&payload);
    }

    let mut tag = Vec::new();
    tag.extend_from_slice(b"ID3");
    tag.extend_from_slice(&[4, 0, 0]); // version 2.4.0
    tag.extend_from_slice(&encode_syncsafe(frames.len() as u32));
    tag.extend_from_slice(&frames);
    tag
}

fn create_wav_fixture(
    path: &Path,
    sample_rate: u32,
    channels: u16,
    bit_depth: u16,
    info_tags: Option<(&str, &str, &str, &str)>, // (title, artist, album, genre)
    id3_tag: Option<&[u8]>,
) {
    let mut file = File::create(path).unwrap();

    let bytes_per_sec = sample_rate * channels as u32 * (bit_depth as u32 / 8);
    let block_align = channels * (bit_depth / 8);
    let data_len = bytes_per_sec; // 1 second

    // Write dummy RIFF header (length will be patched or arbitrary valid length)
    file.write_all(b"RIFF\x00\x00\x00\x00WAVE").unwrap();

    // fmt chunk
    file.write_all(b"fmt \x10\x00\x00\x00").unwrap(); // 16 bytes
    file.write_all(&1u16.to_le_bytes()).unwrap(); // PCM
    file.write_all(&channels.to_le_bytes()).unwrap();
    file.write_all(&sample_rate.to_le_bytes()).unwrap();
    file.write_all(&bytes_per_sec.to_le_bytes()).unwrap();
    file.write_all(&block_align.to_le_bytes()).unwrap();
    file.write_all(&bit_depth.to_le_bytes()).unwrap();

    // bext chunk
    let mut bext = vec![0u8; 346];
    let desc = b"BWF Description";
    bext[..desc.len()].copy_from_slice(desc);
    let orig = b"BWF Originator";
    bext[256..256 + orig.len()].copy_from_slice(orig);
    let date = b"2025-01-01";
    bext[320..320 + date.len()].copy_from_slice(date);
    file.write_all(b"bext").unwrap();
    file.write_all(&(bext.len() as u32).to_le_bytes()).unwrap();
    file.write_all(&bext).unwrap();

    // LIST INFO chunk
    if let Some((t, a, al, g)) = info_tags {
        let mut list_body = Vec::new();
        list_body.extend_from_slice(b"INFO");

        let mut add_info_sub = |id: &[u8; 4], val: &str| {
            let mut val_bytes = val.as_bytes().to_vec();
            val_bytes.push(0); // null terminator
            let len = val_bytes.len() as u32;
            list_body.extend_from_slice(id);
            list_body.extend_from_slice(&len.to_le_bytes());
            list_body.extend_from_slice(&val_bytes);
            if len % 2 == 1 {
                list_body.push(0); // 2-byte pad
            }
        };

        add_info_sub(b"INAM", t);
        add_info_sub(b"IART", a);
        add_info_sub(b"IPRD", al);
        add_info_sub(b"IGNR", g);

        file.write_all(b"LIST").unwrap();
        file.write_all(&(list_body.len() as u32).to_le_bytes())
            .unwrap();
        file.write_all(&list_body).unwrap();
        if list_body.len() % 2 == 1 {
            file.write_all(&[0]).unwrap();
        }
    }

    // ID3 chunk
    if let Some(id3) = id3_tag {
        file.write_all(b"id3 ").unwrap();
        file.write_all(&(id3.len() as u32).to_le_bytes()).unwrap();
        file.write_all(id3).unwrap();
        if id3.len() % 2 == 1 {
            file.write_all(&[0]).unwrap();
        }
    }

    // data chunk
    file.write_all(b"data").unwrap();
    file.write_all(&data_len.to_le_bytes()).unwrap();
    file.write_all(&vec![0u8; data_len as usize]).unwrap();

    let total_len = file.metadata().unwrap().len() as u32;
    file.flush().unwrap();
    // Fix RIFF size
    let riff_size = total_len - 8;
    file.sync_all().unwrap();
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .open(path)
        .unwrap();
    std::io::Seek::seek(&mut f, std::io::SeekFrom::Start(4)).unwrap();
    f.write_all(&riff_size.to_le_bytes()).unwrap();
}

fn create_dsf_fixture(path: &Path, id3: &[u8]) {
    let mut file = File::create(path).unwrap();

    // DSD chunk (28 bytes)
    file.write_all(b"DSD ").unwrap();
    file.write_all(&28u64.to_le_bytes()).unwrap();
    file.write_all(&0u64.to_le_bytes()).unwrap(); // file_size (patch later)
    file.write_all(&0u64.to_le_bytes()).unwrap(); // metadata_offset (patch later)

    // fmt chunk (52 bytes)
    file.write_all(b"fmt ").unwrap();
    file.write_all(&52u64.to_le_bytes()).unwrap();
    file.write_all(&1u32.to_le_bytes()).unwrap(); // format version
    file.write_all(&0u32.to_le_bytes()).unwrap(); // format id 0 = DSD raw
    file.write_all(&2u32.to_le_bytes()).unwrap(); // channel type 2 = stereo
    file.write_all(&2u32.to_le_bytes()).unwrap(); // channel num
    file.write_all(&2822400u32.to_le_bytes()).unwrap(); // sampling freq
    file.write_all(&1u32.to_le_bytes()).unwrap(); // bits per sample
    file.write_all(&2822400u64.to_le_bytes()).unwrap(); // sample count (1 sec)
    file.write_all(&4096u32.to_le_bytes()).unwrap(); // block size
    file.write_all(&0u32.to_le_bytes()).unwrap(); // reserved

    // data chunk
    file.write_all(b"data").unwrap();
    let data_bytes = 4096 * 2u64;
    file.write_all(&(data_bytes + 12).to_le_bytes()).unwrap();
    file.write_all(&vec![0xAA; data_bytes as usize]).unwrap();

    // metadata chunk
    let metadata_pos = file.metadata().unwrap().len();
    file.write_all(id3).unwrap();
    let total_file_size = file.metadata().unwrap().len();

    // Patch file size and metadata offset in header
    drop(file);
    let mut f = std::fs::OpenOptions::new().write(true).open(path).unwrap();
    std::io::Seek::seek(&mut f, std::io::SeekFrom::Start(12)).unwrap();
    f.write_all(&total_file_size.to_le_bytes()).unwrap();
    f.write_all(&metadata_pos.to_le_bytes()).unwrap();
}

fn create_dff_fixture(path: &Path, title: &str, artist: &str, id3: Option<&[u8]>) {
    let mut file = File::create(path).unwrap();

    // FRM8 header (12 bytes)
    file.write_all(b"FRM8\x00\x00\x00\x00\x00\x00\x00\x00DSD ").unwrap();

    // FVER chunk
    file.write_all(b"FVER\x00\x00\x00\x00\x00\x00\x00\x04\x01\x05\x00\x00").unwrap();

    // PROP chunk
    let mut prop = Vec::new();
    prop.extend_from_slice(b"SND ");
    // FS subchunk
    prop.extend_from_slice(b"FS  \x00\x00\x00\x00\x00\x00\x00\x04");
    prop.extend_from_slice(&2822400u32.to_be_bytes());
    // CHNL subchunk
    prop.extend_from_slice(b"CHNL\x00\x00\x00\x00\x00\x00\x00\x02");
    prop.extend_from_slice(&2u16.to_be_bytes());

    file.write_all(b"PROP").unwrap();
    file.write_all(&(prop.len() as u64).to_be_bytes()).unwrap();
    file.write_all(&prop).unwrap();

    // DIIN chunk
    let mut diin = Vec::new();
    // DITI
    let tb = title.as_bytes();
    diin.extend_from_slice(b"DITI");
    diin.extend_from_slice(&(4 + tb.len() as u64).to_be_bytes());
    diin.extend_from_slice(&(tb.len() as u32).to_be_bytes());
    diin.extend_from_slice(tb);
    if tb.len() % 2 == 1 {
        diin.push(0);
    }
    // DIAR
    let ab = artist.as_bytes();
    diin.extend_from_slice(b"DIAR");
    diin.extend_from_slice(&(4 + ab.len() as u64).to_be_bytes());
    diin.extend_from_slice(&(ab.len() as u32).to_be_bytes());
    diin.extend_from_slice(ab);
    if ab.len() % 2 == 1 {
        diin.push(0);
    }

    file.write_all(b"DIIN").unwrap();
    file.write_all(&(diin.len() as u64).to_be_bytes()).unwrap();
    file.write_all(&diin).unwrap();

    // DSD chunk
    let dsd_data = vec![0x69; 4096];
    file.write_all(b"DSD ").unwrap();
    file.write_all(&(dsd_data.len() as u64).to_be_bytes()).unwrap();
    file.write_all(&dsd_data).unwrap();

    // ID3 chunk
    if let Some(id3_data) = id3 {
        file.write_all(b"ID3 ").unwrap();
        file.write_all(&(id3_data.len() as u64).to_be_bytes()).unwrap();
        file.write_all(id3_data).unwrap();
        if id3_data.len() % 2 == 1 {
            file.write_all(&[0]).unwrap();
        }
    }

    let total = file.metadata().unwrap().len();
    drop(file);
    let mut f = std::fs::OpenOptions::new().write(true).open(path).unwrap();
    std::io::Seek::seek(&mut f, std::io::SeekFrom::Start(4)).unwrap();
    f.write_all(&(total - 12).to_be_bytes()).unwrap();
}

#[tokio::test]
async fn test_artwork_priority_chain() {
    let pool = open_test_database().await.unwrap();
    let tmp = tempdir().unwrap();
    let music_dir = tmp.path().join("music");
    let cache_dir = tmp.path().join("cache");
    fs::create_dir_all(&music_dir).unwrap();

    let emb_bytes = create_test_image_bytes(200, 200, (200, 50, 50));
    let id3 = build_id3v2_tag(
        Some("Emb Track"),
        Some("Artist"),
        Some("Album"),
        None,
        None,
        None,
        None,
        Some((&emb_bytes, "image/jpeg", 3)), // Type 3 = FrontCover
    );

    let track_path = music_dir.join("01_embedded.wav");
    create_wav_fixture(&track_path, 44100, 2, 16, None, Some(&id3));

    // Also put cover.jpg and folder.jpg in the directory
    create_test_image(&music_dir.join("cover.jpg"), 300, 300, (50, 200, 50));
    create_test_image(&music_dir.join("folder.jpg"), 400, 400, (50, 50, 200));

    // 1. Embedded front cover beats cover.jpg
    let res = ArtworkManager::resolve_artwork(
        &pool,
        &track_path.to_string_lossy(),
        0,
        &cache_dir,
    )
    .await
    .unwrap();
    assert!(res.found);
    assert_eq!(res.source_kind, ArtworkSourceKind::Embedded);

    // 2. Directory with only cover.jpg beats folder.jpg
    let sub1 = tmp.path().join("sub1");
    fs::create_dir_all(&sub1).unwrap();
    create_test_image(&sub1.join("cover.jpg"), 300, 300, (50, 200, 50));
    create_test_image(&sub1.join("folder.jpg"), 400, 400, (50, 50, 200));
    create_test_image(&sub1.join("front.jpg"), 500, 500, (200, 200, 50));
    let plain_wav = sub1.join("plain.wav");
    create_wav_fixture(&plain_wav, 44100, 2, 16, None, None);

    let res1 = ArtworkManager::resolve_artwork(
        &pool,
        &plain_wav.to_string_lossy(),
        0,
        &cache_dir,
    )
    .await
    .unwrap();
    assert!(res1.found);
    assert_eq!(res1.source_kind, ArtworkSourceKind::Cover);

    // 3. Directory with only folder.png beats front.jpg
    let sub2 = tmp.path().join("sub2");
    fs::create_dir_all(&sub2).unwrap();
    create_test_image(&sub2.join("folder.png"), 400, 400, (50, 50, 200));
    create_test_image(&sub2.join("front.jpg"), 500, 500, (200, 200, 50));
    let plain_wav2 = sub2.join("plain2.wav");
    create_wav_fixture(&plain_wav2, 44100, 2, 16, None, None);

    let res2 = ArtworkManager::resolve_artwork(
        &pool,
        &plain_wav2.to_string_lossy(),
        0,
        &cache_dir,
    )
    .await
    .unwrap();
    assert!(res2.found);
    assert_eq!(res2.source_kind, ArtworkSourceKind::Folder);

    // 4. Directory with only front.webp
    let sub3 = tmp.path().join("sub3");
    fs::create_dir_all(&sub3).unwrap();
    create_test_image(&sub3.join("front.png"), 500, 500, (200, 200, 50));
    let plain_wav3 = sub3.join("plain3.wav");
    create_wav_fixture(&plain_wav3, 44100, 2, 16, None, None);

    let res3 = ArtworkManager::resolve_artwork(
        &pool,
        &plain_wav3.to_string_lossy(),
        0,
        &cache_dir,
    )
    .await
    .unwrap();
    assert!(res3.found);
    assert_eq!(res3.source_kind, ArtworkSourceKind::Front);

    // 5. Placeholder when no images exist
    let sub4 = tmp.path().join("sub4");
    fs::create_dir_all(&sub4).unwrap();
    let plain_wav4 = sub4.join("plain4.wav");
    create_wav_fixture(&plain_wav4, 44100, 2, 16, None, None);

    let res4 = ArtworkManager::resolve_artwork(
        &pool,
        &plain_wav4.to_string_lossy(),
        0,
        &cache_dir,
    )
    .await
    .unwrap();
    assert!(!res4.found);
    assert_eq!(res4.source_kind, ArtworkSourceKind::Placeholder);
}

#[tokio::test]
async fn test_artwork_user_override_lifecycle() {
    let pool = open_test_database().await.unwrap();
    let tmp = tempdir().unwrap();
    let cache_dir = tmp.path().join("cache");
    let track_path = tmp.path().join("song.wav");
    create_wav_fixture(&track_path, 44100, 2, 16, None, None);

    create_test_image(&tmp.path().join("cover.jpg"), 300, 300, (50, 200, 50));
    let user_img = tmp.path().join("custom.png");
    create_test_image(&user_img, 600, 600, (255, 100, 100));

    // Initially resolves to cover.jpg
    let initial = ArtworkManager::resolve_artwork(
        &pool,
        &track_path.to_string_lossy(),
        0,
        &cache_dir,
    )
    .await
    .unwrap();
    assert!(initial.found);
    assert_eq!(initial.source_kind, ArtworkSourceKind::Cover);

    // Set user override
    let target = format!(r#"{{"file_path":"{}"}}"#, normalize_path(&track_path));
    ArtworkManager::set_user_cover(&pool, &target, &user_img.to_string_lossy())
        .await
        .unwrap();

    let over = ArtworkManager::resolve_artwork(
        &pool,
        &track_path.to_string_lossy(),
        0,
        &cache_dir,
    )
    .await
    .unwrap();
    assert!(over.found);
    assert_eq!(over.source_kind, ArtworkSourceKind::User);

    // Clear user override restores cover.jpg
    ArtworkManager::clear_user_cover(&pool, &target)
        .await
        .unwrap();

    let restored = ArtworkManager::resolve_artwork(
        &pool,
        &track_path.to_string_lossy(),
        0,
        &cache_dir,
    )
    .await
    .unwrap();
    assert!(restored.found);
    assert_eq!(restored.source_kind, ArtworkSourceKind::Cover);
}

#[tokio::test]
async fn test_artwork_oversized_downscaling() {
    let pool = open_test_database().await.unwrap();
    let tmp = tempdir().unwrap();
    let cache_dir = tmp.path().join("cache");
    let track_path = tmp.path().join("big.wav");
    create_wav_fixture(&track_path, 44100, 2, 16, None, None);

    let big_img = tmp.path().join("cover.jpg");
    create_test_image(&big_img, 2400, 1800, (10, 10, 200));

    // Resolve with max_dim = 512
    let res = ArtworkManager::resolve_artwork(
        &pool,
        &track_path.to_string_lossy(),
        512,
        &cache_dir,
    )
    .await
    .unwrap();

    assert!(res.found);
    assert!(res.width.unwrap() <= 512);
    assert!(res.height.unwrap() <= 512);

    // Verify cache file on disk
    let cp = PathBuf::from(res.cache_path.unwrap());
    assert!(cp.exists());
    let loaded = image::open(&cp).unwrap();
    assert!(loaded.width() <= 512);
    assert!(loaded.height() <= 512);
}

#[tokio::test]
async fn test_wav_riff_info_bext_and_id3_extraction() {
    let tmp = tempdir().unwrap();
    let wav_path = tmp.path().join("master.wav");

    let id3 = build_id3v2_tag(
        Some("ID3 Title"),
        Some("ID3 Artist"),
        Some("ID3 Album"),
        Some("ID3 AlbumArtist"),
        Some("ID3 Genre"),
        Some("ID3 Composer"),
        Some("2024"),
        None,
    );

    create_wav_fixture(
        &wav_path,
        48000,
        2,
        24,
        Some(("INFO Title", "INFO Artist", "INFO Album", "INFO Genre")),
        Some(&id3),
    );

    let parsed = parse_wav(&wav_path).unwrap();
    assert_eq!(parsed.format.sample_rate_hz, 48000);
    assert_eq!(parsed.format.bit_depth, 24);
    assert_eq!(parsed.format.channels, 2);
    assert_eq!(parsed.format.codec, AudioCodec::Wav);

    // ID3 values take precedence over INFO
    assert_eq!(parsed.title.as_deref(), Some("ID3 Title"));
    assert_eq!(parsed.artist.as_deref(), Some("ID3 Artist"));
    assert_eq!(parsed.album.as_deref(), Some("ID3 Album"));
    assert_eq!(parsed.album_artist.as_deref(), Some("ID3 AlbumArtist"));
    assert_eq!(parsed.composer.as_deref(), Some("ID3 Composer"));
    assert_eq!(parsed.release_year, Some(2024));
}

#[tokio::test]
async fn test_dsf_and_dff_parsing() {
    let tmp = tempdir().unwrap();

    // 1. DSF
    let dsf_path = tmp.path().join("test.dsf");
    let id3 = build_id3v2_tag(
        Some("DSF Title"),
        Some("DSF Artist"),
        Some("DSF Album"),
        Some("DSF AlbArtist"),
        Some("DSD Genre"),
        Some("DSD Composer"),
        Some("2023"),
        None,
    );
    create_dsf_fixture(&dsf_path, &id3);

    let dsf = parse_dsf(&dsf_path).unwrap();
    assert_eq!(dsf.format.codec, AudioCodec::Dsf);
    assert_eq!(dsf.format.sample_rate_hz, 2822400);
    assert!(dsf.format.is_dsd);
    assert_eq!(dsf.tags.title.as_deref(), Some("DSF Title"));
    assert_eq!(dsf.tags.artist.as_deref(), Some("DSF Artist"));
    assert_eq!(dsf.tags.album_artist.as_deref(), Some("DSF AlbArtist"));
    assert_eq!(dsf.tags.genre.as_deref(), Some("DSD Genre"));
    assert_eq!(dsf.tags.composer.as_deref(), Some("DSD Composer"));

    // 2. DFF
    let dff_path = tmp.path().join("test.dff");
    create_dff_fixture(&dff_path, "DFF DIIN Title", "DFF DIIN Artist", Some(&id3));

    let dff = parse_dff(&dff_path).unwrap();
    assert_eq!(dff.format.codec, AudioCodec::Dsdiff);
    assert_eq!(dff.format.sample_rate_hz, 2822400);
    assert!(dff.format.is_dsd);
    // ID3 title/artist overrides DIIN
    assert_eq!(dff.tags.title.as_deref(), Some("DSF Title"));
    assert_eq!(dff.tags.artist.as_deref(), Some("DSF Artist"));
    assert_eq!(dff.tags.album_artist.as_deref(), Some("DSF AlbArtist"));
}

#[test]
fn test_numeric_filename_handling() {
    let p1 = Path::new("C:/Music/1999.flac");
    let (t1, n1) = derive_title_and_track_from_filename(p1);
    assert_eq!(t1, "1999");
    assert_eq!(n1, 1);

    let p2 = Path::new("C:/Music/2001.flac");
    let (t2, n2) = derive_title_and_track_from_filename(p2);
    assert_eq!(t2, "2001");
    assert_eq!(n2, 1);

    let p3 = Path::new("C:/Music/01 - 2001.flac");
    let (t3, n3) = derive_title_and_track_from_filename(p3);
    assert_eq!(t3, "2001");
    assert_eq!(n3, 1);

    let p4 = Path::new("C:/Music/05 - Prince.flac");
    let (t4, n4) = derive_title_and_track_from_filename(p4);
    assert_eq!(t4, "Prince");
    assert_eq!(n4, 5);
}

#[test]
fn test_non_cover_rejection() {
    let files = ["back.jpg", "artist.png", "booklet.jpeg", "other.webp"];
    assert!(find_folder_cover_in_files(&files).is_none());

    let files_with_cover = ["back.jpg", "cover.png", "artist.png"];
    assert_eq!(
        find_folder_cover_in_files(&files_with_cover),
        Some("cover.png".to_string())
    );
}

#[tokio::test]
async fn test_incremental_and_forced_tag_rescan() {
    let pool = open_test_database().await.unwrap();
    let tmp = tempdir().unwrap();
    let music_dir = tmp.path().join("music");
    fs::create_dir_all(&music_dir).unwrap();

    let track1 = music_dir.join("01_song.wav");
    create_wav_fixture(
        &track1,
        44100,
        2,
        16,
        Some(("Song One", "Artist", "Album", "Rock")),
        None,
    );

    // Initial rescan
    let rep1 = LibrarySyncService::rescan_tags(
        &pool,
        Some(&music_dir.to_string_lossy()),
        false,
    )
    .await
    .unwrap();

    assert_eq!(rep1.scanned, 1);
    assert_eq!(rep1.updated, 1);
    assert_eq!(rep1.pruned, 0);

    // Second rescan without force -> unchanged_cached
    let rep2 = LibrarySyncService::rescan_tags(
        &pool,
        Some(&music_dir.to_string_lossy()),
        false,
    )
    .await
    .unwrap();

    assert_eq!(rep2.scanned, 1);
    assert_eq!(rep2.updated, 0);
    assert_eq!(rep2.unchanged_cached, 1);

    // Third rescan with force = true -> updated = 1
    let rep3 = LibrarySyncService::rescan_tags(
        &pool,
        Some(&music_dir.to_string_lossy()),
        true,
    )
    .await
    .unwrap();

    assert_eq!(rep3.scanned, 1);
    assert_eq!(rep3.updated, 1);

    // Delete track and rescan -> pruned = 1
    fs::remove_file(&track1).unwrap();
    let rep4 = LibrarySyncService::rescan_tags(
        &pool,
        Some(&music_dir.to_string_lossy()),
        false,
    )
    .await
    .unwrap();

    assert_eq!(rep4.scanned, 0);
    assert_eq!(rep4.pruned, 1);
}

#[tokio::test]
async fn test_album_level_artwork_resolution_and_full_res_preservation() {
    use core_providers::{LocalProvider, MusicProvider};

    let pool = open_test_database().await.unwrap();
    let tmp = tempdir().unwrap();
    let music_dir = tmp.path().join("Artist").join("FullResAlbum");
    let cache_dir = tmp.path().join("cache");
    fs::create_dir_all(&music_dir).unwrap();

    // Track 1 has NO embedded cover; Track 2 has a 1200x1200 embedded FrontCover JPEG.
    let no_art_id3 = build_id3v2_tag(
        Some("Track One"),
        Some("Test Artist"),
        Some("Full Res Album"),
        Some("Test Artist"),
        None,
        None,
        Some("2024"),
        None,
    );
    create_wav_fixture(
        &music_dir.join("01 - Track One.wav"),
        44100,
        2,
        16,
        None,
        Some(&no_art_id3),
    );

    let big_emb_bytes = create_test_image_bytes(1200, 1200, (12, 140, 220));
    let with_art_id3 = build_id3v2_tag(
        Some("Track Two"),
        Some("Test Artist"),
        Some("Full Res Album"),
        Some("Test Artist"),
        None,
        None,
        Some("2024"),
        Some((&big_emb_bytes, "image/jpeg", 3)),
    );
    create_wav_fixture(
        &music_dir.join("02 - Track Two.wav"),
        44100,
        2,
        16,
        None,
        Some(&with_art_id3),
    );

    let provider = LocalProvider::from_root(&music_dir);
    let sync = provider.sync_library().await.unwrap();
    LibrarySyncService::persist_sync_result(&pool, &sync)
        .await
        .unwrap();

    let albums = LibrarySyncService::list_canonical_albums(&pool, 10, 0)
        .await
        .unwrap();
    assert_eq!(albums.len(), 1);
    let album_id = &albums[0].id;

    // 1. Resolve with max_dim = 0 via FFI-style {"track_id": album_id} AND plain album_id
    for target in [
        album_id.clone(),
        serde_json::json!({ "track_id": album_id }).to_string(),
        serde_json::json!({ "album_id": album_id }).to_string(),
    ] {
        let res = ArtworkManager::resolve_artwork(&pool, &target, 0, &cache_dir)
            .await
            .unwrap();
        assert!(res.found, "expected artwork found for target {target}");
        assert_eq!(res.source_kind, ArtworkSourceKind::Embedded);
        assert_eq!(res.width, Some(1200));
        assert_eq!(res.height, Some(1200));
        let cached_bytes = fs::read(res.cache_path.as_ref().unwrap()).unwrap();
        assert_eq!(
            cached_bytes, big_emb_bytes,
            "max_dim=0 must preserve original raw embedded bytes verbatim"
        );
    }

    // 2. Track 1 (without its own embedded art) falls back to sibling track's album embedded cover
    let detail = LibrarySyncService::get_album_detail(&pool, album_id)
        .await
        .unwrap()
        .unwrap();
    let trk1_id = &detail.versions[0].tracks[0].id;
    let trk1_res = ArtworkManager::resolve_artwork(&pool, trk1_id, 0, &cache_dir)
        .await
        .unwrap();
    assert!(trk1_res.found);
    assert_eq!(trk1_res.source_kind, ArtworkSourceKind::Embedded);
    assert_eq!(trk1_res.width, Some(1200));

    // 3. Album user cover override via {"track_id": album_id} applies to both album and tracks
    let custom_cover = tmp.path().join("custom_album.png");
    create_test_image(&custom_cover, 900, 900, (250, 40, 80));
    let custom_bytes = fs::read(&custom_cover).unwrap();
    let album_target = serde_json::json!({ "track_id": album_id }).to_string();

    ArtworkManager::set_user_cover(&pool, &album_target, &custom_cover.to_string_lossy())
        .await
        .unwrap();

    let over_album = ArtworkManager::resolve_artwork(&pool, &album_target, 0, &cache_dir)
        .await
        .unwrap();
    assert!(over_album.found);
    assert_eq!(over_album.source_kind, ArtworkSourceKind::User);
    assert_eq!(over_album.width, Some(900));
    assert_eq!(
        fs::read(over_album.cache_path.as_ref().unwrap()).unwrap(),
        custom_bytes
    );

    let over_trk1 = ArtworkManager::resolve_artwork(&pool, trk1_id, 0, &cache_dir)
        .await
        .unwrap();
    assert_eq!(over_trk1.source_kind, ArtworkSourceKind::User);

    // 4. Clear user cover restores original full-res embedded cover
    ArtworkManager::clear_user_cover(&pool, &album_target)
        .await
        .unwrap();
    let restored = ArtworkManager::resolve_artwork(&pool, &album_target, 0, &cache_dir)
        .await
        .unwrap();
    assert!(restored.found);
    assert_eq!(restored.source_kind, ArtworkSourceKind::Embedded);
    assert_eq!(restored.width, Some(1200));
}

#[tokio::test]
async fn test_single_track_album_and_track1_only_artwork_resolution() {
    use core_providers::{LocalProvider, MusicProvider};

    let pool = open_test_database().await.unwrap();
    let tmp = tempdir().unwrap();
    let single_dir = tmp.path().join("Artist").join("SingleEP");
    let cache_dir = tmp.path().join("cache");
    fs::create_dir_all(&single_dir).unwrap();

    // 1-track album where Track 1 holds the embedded FrontCover JPEG.
    let emb_bytes = create_test_image_bytes(1024, 1024, (40, 180, 90));
    let id3 = build_id3v2_tag(
        Some("Only Track"),
        Some("Single Artist"),
        Some("Single EP"),
        Some("Single Artist"),
        None,
        None,
        Some("2025"),
        Some((&emb_bytes, "image/jpeg", 3)),
    );
    create_wav_fixture(
        &single_dir.join("01 - Only Track.wav"),
        44100,
        2,
        16,
        None,
        Some(&id3),
    );

    let provider = LocalProvider::from_root(&single_dir);
    let sync = provider.sync_library().await.unwrap();
    LibrarySyncService::persist_sync_result(&pool, &sync)
        .await
        .unwrap();

    let albums = LibrarySyncService::list_canonical_albums(&pool, 10, 0)
        .await
        .unwrap();
    assert_eq!(albums.len(), 1);
    let album_id = &albums[0].id;

    // Querying by album_id (plain, {"track_id": album_id}, {"album_id": album_id}) MUST resolve Track 1!
    for target in [
        album_id.clone(),
        serde_json::json!({ "track_id": album_id }).to_string(),
        serde_json::json!({ "album_id": album_id }).to_string(),
    ] {
        let res = ArtworkManager::resolve_artwork(&pool, &target, 0, &cache_dir)
            .await
            .unwrap();
        assert!(res.found, "single-track album query {target} must find Track 1 artwork");
        assert_eq!(res.source_kind, ArtworkSourceKind::Embedded);
        assert_eq!(res.width, Some(1024));
        assert_eq!(res.height, Some(1024));
        assert_eq!(
            fs::read(res.cache_path.as_ref().unwrap()).unwrap(),
            emb_bytes
        );
    }
}

#[tokio::test]
async fn test_corrupt_artwork_rejected_at_max_dim_zero() {
    let pool = open_test_database().await.unwrap();
    let tmp = tempdir().unwrap();
    let cache_dir = tmp.path().join("cache");
    let track_path = tmp.path().join("track.wav");
    create_wav_fixture(&track_path, 44100, 2, 16, None, None);

    // Corrupt JPEG with valid FF D8 FF magic header followed by garbage bytes
    fs::write(tmp.path().join("cover.jpg"), [0xFF, 0xD8, 0xFF, 0x00, 0x01, 0x02]).unwrap();

    let res = ArtworkManager::resolve_artwork(&pool, &track_path.to_string_lossy(), 0, &cache_dir)
        .await
        .unwrap();
    assert!(!res.found);
    assert_eq!(res.source_kind, ArtworkSourceKind::Placeholder);
}

#[tokio::test]
async fn test_same_directory_distinct_albums_do_not_collide_and_multidisc_stays_grouped() {
    use core_providers::local::mapper::AlbumMapper;
    use core_providers::local::metadata::ExtractedMetadata;
    use core_types::{AudioFormat, ProviderKind};

    let fmt = AudioFormat::pcm(AudioCodec::Flac, 44100, 16, 2).unwrap();
    let shared_dir = PathBuf::from("C:/Music/FlatFolder");

    let items = vec![
        (
            shared_dir.join("v23.flac"),
            ExtractedMetadata {
                title: "Tag v2.3".to_string(),
                artist: "Artist23".to_string(),
                album: "Album23".to_string(),
                album_artist: Some("AlbArt23".to_string()),
                release_year: Some(1998),
                track_number: 4,
                disc_number: 1,
                format: fmt.clone(),
                ..Default::default()
            },
        ),
        (
            shared_dir.join("v24.flac"),
            ExtractedMetadata {
                title: "Tag v2.4".to_string(),
                artist: "Artist24".to_string(),
                album: "Album24".to_string(),
                album_artist: Some("AlbArt24".to_string()),
                release_year: Some(2023),
                track_number: 7,
                disc_number: 1,
                format: fmt.clone(),
                ..Default::default()
            },
        ),
        (
            shared_dir.join("d1t1.flac"),
            ExtractedMetadata {
                title: "Disc 1 Song".to_string(),
                artist: "MultiBand".to_string(),
                album: "Double Album".to_string(),
                album_artist: Some("MultiBand".to_string()),
                release_year: Some(2020),
                track_number: 1,
                disc_number: 1,
                format: fmt.clone(),
                ..Default::default()
            },
        ),
        (
            shared_dir.join("d2t1.flac"),
            ExtractedMetadata {
                title: "Disc 2 Song".to_string(),
                artist: "MultiBand".to_string(),
                album: "Double Album".to_string(),
                album_artist: Some("MultiBand".to_string()),
                release_year: Some(2020),
                track_number: 1,
                disc_number: 2,
                format: fmt,
                ..Default::default()
            },
        ),
    ];

    let (albums, tracks, meta) =
        AlbumMapper::map_scanned_items_with_metadata(items, ProviderKind::Local).unwrap();
    assert_eq!(albums.len(), 3);
    assert_eq!(tracks.len(), 4);

    let ext_ids: std::collections::HashSet<&str> = albums
        .iter()
        .flat_map(|a| a.versions.iter().map(|v| v.external_album_id.as_str()))
        .collect();
    assert_eq!(
        ext_ids.len(),
        3,
        "distinct albums in same dir must have distinct external_album_id"
    );

    let pool = open_test_database().await.unwrap();
    LibrarySyncService::persist_provider_albums(&pool, &albums, &tracks, &meta)
        .await
        .unwrap();

    let db_albums = LibrarySyncService::list_canonical_albums(&pool, 20, 0)
        .await
        .unwrap();
    assert_eq!(db_albums.len(), 3);

    let a23 = db_albums.iter().find(|a| a.title == "Album23").unwrap();
    let a24 = db_albums.iter().find(|a| a.title == "Album24").unwrap();
    let dbl = db_albums.iter().find(|a| a.title == "Double Album").unwrap();
    assert_eq!(a23.release_year, Some(1998));
    assert_eq!(a24.release_year, Some(2023));

    let dbl_detail = LibrarySyncService::get_album_detail(&pool, &dbl.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(dbl_detail.versions.len(), 1);
    assert_eq!(dbl_detail.versions[0].tracks.len(), 2);
}

#[test]
fn test_flac_native_metadata_and_track_disc_parsing() {
    use core_providers::local::dsd_meta::{parse_slash_number, parse_track_and_disc_number};
    use core_providers::local::metadata::MetadataExtractor;

    // 1. Verify track & disc number parsing
    assert_eq!(parse_track_and_disc_number("1-02"), (Some(2), Some(1)));
    assert_eq!(parse_track_and_disc_number("2-14"), (Some(14), Some(2)));
    assert_eq!(parse_track_and_disc_number("01-05"), (Some(5), Some(1)));
    assert_eq!(parse_track_and_disc_number("1.02"), (Some(2), Some(1)));
    assert_eq!(parse_track_and_disc_number("03/12"), (Some(3), None));
    assert_eq!(parse_track_and_disc_number("4"), (Some(4), None));
    assert_eq!(parse_slash_number("1-02"), Some(2));
    assert_eq!(parse_slash_number("03/12"), Some(3));

    // 2. Build mock FLAC bytes with STREAMINFO and VORBIS_COMMENT
    let mut flac_bytes = Vec::new();
    flac_bytes.extend_from_slice(b"fLaC");

    // STREAMINFO block (34 bytes), not last (header: type 0, len 34)
    let mut streaminfo = vec![0u8; 34];
    streaminfo[10] = 0x0A;
    streaminfo[11] = 0xC4;
    streaminfo[12] = 0x42;
    streaminfo[13] = 0xF0;
    flac_bytes.push(0x00);
    flac_bytes.extend_from_slice(&[0x00, 0x00, 0x22]);
    flac_bytes.extend_from_slice(&streaminfo);

    // VORBIS_COMMENT block, is_last = true (header: 0x80 | 4 = 0x84)
    let mut comments_data = Vec::new();
    let vendor = b"reference libFLAC 1.4.2";
    comments_data.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
    comments_data.extend_from_slice(vendor);

    let comments = [
        "TITLE=空から降ってきた少女",
        "ARTIST=久石譲",
        "ALBUM=天空の城ラピュタ ハイテックシリーズ",
        "ALBUM ARTIST=久石譲",
        "TRACKNUMBER=1-02",
        "DATE=1986",
    ];
    comments_data.extend_from_slice(&(comments.len() as u32).to_le_bytes());
    for c in &comments {
        comments_data.extend_from_slice(&(c.len() as u32).to_le_bytes());
        comments_data.extend_from_slice(c.as_bytes());
    }

    flac_bytes.push(0x84);
    let clen = comments_data.len() as u32;
    flac_bytes.push(((clen >> 16) & 0xFF) as u8);
    flac_bytes.push(((clen >> 8) & 0xFF) as u8);
    flac_bytes.push((clen & 0xFF) as u8);
    flac_bytes.extend_from_slice(&comments_data);

    let meta = MetadataExtractor::extract_from_bytes(flac_bytes, "flac", None).unwrap();
    assert_eq!(meta.title, "空から降ってきた少女");
    assert_eq!(meta.artist, "久石譲");
    assert_eq!(meta.album, "天空の城ラピュタ ハイテックシリーズ");
    assert_eq!(meta.album_artist.as_deref(), Some("久石譲"));
    assert_eq!(meta.track_number, 2);
    assert_eq!(meta.disc_number, 1);
    assert_eq!(meta.release_year, Some(1986));
}
