use core_types::{AudioCodec, ProviderKind};
use sha2::{Digest, Sha256};
use std::fmt::Write as _;
use unicode_normalization::UnicodeNormalization;

pub fn deterministic_artist_id(name: &str) -> String {
    let normalized: String = name
        .nfc()
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase();

    let mut hasher = Sha256::new();
    hasher.update(normalized.as_bytes());
    let digest = hasher.finalize();

    let mut hex32 = String::with_capacity(32);
    for byte in &digest[..16] {
        let _ = write!(&mut hex32, "{byte:02x}");
    }
    format!("art:{hex32}")
}

pub(crate) fn normalize_local_path_for_compare(path: &str) -> String {
    let mut s = path.trim().replace('\\', "/");
    if s.get(..8)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("//?/UNC/"))
    {
        s = format!("//{}", &s[8..]);
    } else if let Some(rest) = s.strip_prefix("//?/") {
        s = rest.to_string();
    }
    while s.len() > 1 && s.ends_with('/') {
        let is_windows_drive_root = s.len() == 3 && s.as_bytes()[1] == b':';
        if is_windows_drive_root {
            break;
        }
        s.pop();
    }
    let is_windows_style =
        cfg!(windows) || s.as_bytes().get(1) == Some(&b':') || s.starts_with("//");
    if is_windows_style {
        s.to_lowercase()
    } else {
        s
    }
}

pub(crate) fn path_in_scope(track_norm: &str, scope_norm: &str) -> bool {
    if scope_norm.is_empty() {
        return true;
    }
    if scope_norm == "/" || scope_norm.ends_with(":/") {
        return track_norm.starts_with(scope_norm);
    }
    track_norm == scope_norm
        || (track_norm.starts_with(scope_norm)
            && track_norm.as_bytes().get(scope_norm.len()) == Some(&b'/'))
}

pub fn normalize_match_key(input: &str) -> String {
    let normalized: String = input.nfkc().collect();
    normalized
        .split(|c: char| !c.is_alphanumeric())
        .filter(|part| !part.is_empty())
        .map(|part| part.to_lowercase())
        .collect::<Vec<_>>()
        .join(" ")
}

pub(crate) fn parse_provider_kind(raw: &str) -> ProviderKind {
    match raw {
        "local" => ProviderKind::Local,
        "smb" => ProviderKind::Smb,
        "web_dav" | "webdav" => ProviderKind::WebDav,
        "qobuz" => ProviderKind::Qobuz,
        "tidal" => ProviderKind::Tidal,
        "deezer" => ProviderKind::Deezer,
        "apple_music" | "applemusic" => ProviderKind::AppleMusic,
        "youtube_music" | "youtubemusic" | "ytm" => ProviderKind::YouTubeMusic,
        _ => ProviderKind::Local,
    }
}

pub(crate) fn parse_audio_codec(raw: &str) -> AudioCodec {
    match raw {
        "flac" => AudioCodec::Flac,
        "alac" => AudioCodec::Alac,
        "wav" => AudioCodec::Wav,
        "aiff" => AudioCodec::Aiff,
        "dsf" => AudioCodec::Dsf,
        "dsdiff" => AudioCodec::Dsdiff,
        "aac" => AudioCodec::Aac,
        "mp3" => AudioCodec::Mp3,
        "opus" => AudioCodec::Opus,
        _ => AudioCodec::Flac,
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_local_path_for_compare;

    #[test]
    fn test_normalize_local_path_for_compare_extended_unc() {
        assert_eq!(
            normalize_local_path_for_compare(r"\\?\UNC\nas\music\01.flac"),
            normalize_local_path_for_compare(r"\\nas\music\01.flac")
        );
        assert_eq!(
            normalize_local_path_for_compare(r"\\?\unc\NAS\Music\01.flac"),
            "//nas/music/01.flac"
        );
        assert_eq!(
            normalize_local_path_for_compare(r"\\?\Unc\nas\music\"),
            "//nas/music"
        );
        assert_eq!(
            normalize_local_path_for_compare(r"\\?\D:\Music\01.flac"),
            normalize_local_path_for_compare(r"d:/music/01.flac")
        );
    }
}
