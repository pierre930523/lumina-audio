use std::io::{Cursor, Read, Seek, SeekFrom};

use super::Id3v2ParsedTags;
use super::id3v2::{decode_syncsafe, parse_id3v2_body_ext};

/// Parses a trailing ID3v2.4 tag identified by a 10-byte `3DI` footer (before optional ID3v1/APEv2).
pub fn parse_id3v2_footer_from_reader<R: Read + Seek>(
    reader: &mut R,
    collect_raw: bool,
) -> Option<Id3v2ParsedTags> {
    parse_id3v2_footer_from_reader_ext(reader, collect_raw, true)
}

pub fn parse_id3v2_footer_from_reader_ext<R: Read + Seek>(
    reader: &mut R,
    collect_raw: bool,
    include_pictures: bool,
) -> Option<Id3v2ParsedTags> {
    let file_len = reader.seek(SeekFrom::End(0)).ok()?;
    let mut end = file_len;

    if end >= 128 && reader.seek(SeekFrom::Start(end - 128)).is_ok() {
        let mut m = [0u8; 3];
        if reader.read_exact(&mut m).is_ok() && &m == b"TAG" {
            end -= 128;
        }
    }

    if end >= 32 && reader.seek(SeekFrom::Start(end - 32)).is_ok() {
        let mut ape = [0u8; 32];
        if reader.read_exact(&mut ape).is_ok() && &ape[0..8] == b"APETAGEX" {
            let tag_size = u64::from(u32::from_le_bytes(ape[12..16].try_into().unwrap()));
            let flags = u32::from_le_bytes(ape[20..24].try_into().unwrap());
            let has_header = (flags & (1 << 31)) != 0;
            let total = tag_size.saturating_add(if has_header { 32 } else { 0 });
            if total >= 32 && end >= total {
                end -= total;
            }
        }
    }

    if end < 20 {
        return None;
    }

    reader.seek(SeekFrom::Start(end - 10)).ok()?;
    let mut footer = [0u8; 10];
    reader.read_exact(&mut footer).ok()?;
    if &footer[0..3] != b"3DI" {
        return None;
    }

    let major = footer[3];
    if major != 4 {
        return None;
    }
    let flags = footer[5];
    let tag_size = decode_syncsafe(&footer[6..10]) as usize;
    if tag_size == 0 || tag_size > 16 * 1024 * 1024 {
        return None;
    }

    let body_start = end.checked_sub(10 + tag_size as u64)?;
    reader.seek(SeekFrom::Start(body_start)).ok()?;
    let mut body = vec![0u8; tag_size];
    reader.read_exact(&mut body).ok()?;
    Some(parse_id3v2_body_ext(
        &body,
        major,
        flags,
        collect_raw,
        include_pictures,
    ))
}

/// Parses a trailing ID3v2.4 `3DI` footer tag from an in-memory buffer.
pub fn parse_id3v2_footer_from_slice(data: &[u8], collect_raw: bool) -> Option<Id3v2ParsedTags> {
    parse_id3v2_footer_from_slice_ext(data, collect_raw, true)
}

pub fn parse_id3v2_footer_from_slice_ext(
    data: &[u8],
    collect_raw: bool,
    include_pictures: bool,
) -> Option<Id3v2ParsedTags> {
    let mut cursor = Cursor::new(data);
    parse_id3v2_footer_from_reader_ext(&mut cursor, collect_raw, include_pictures)
}

const ID3V1_GENRE_NAMES: &[&str] = &[
    "Blues",
    "Classic Rock",
    "Country",
    "Dance",
    "Disco",
    "Funk",
    "Grunge",
    "Hip-Hop",
    "Jazz",
    "Metal",
    "New Age",
    "Oldies",
    "Other",
    "Pop",
    "R&B",
    "Rap",
    "Reggae",
    "Rock",
    "Techno",
    "Industrial",
    "Alternative",
    "Ska",
    "Death Metal",
    "Pranks",
    "Soundtrack",
    "Euro-Techno",
    "Ambient",
    "Trip-Hop",
    "Vocal",
    "Jazz+Funk",
    "Fusion",
    "Trance",
    "Classical",
    "Instrumental",
    "Acid",
    "House",
    "Game",
    "Sound Clip",
    "Gospel",
    "Noise",
    "AlternRock",
    "Bass",
    "Soul",
    "Punk",
    "Space",
    "Meditative",
    "Instrumental Pop",
    "Instrumental Rock",
    "Ethnic",
    "Gothic",
    "Darkwave",
    "Techno-Industrial",
    "Electronic",
    "Pop-Folk",
    "Eurodance",
    "Dream",
    "Southern Rock",
    "Comedy",
    "Cult",
    "Gangsta",
    "Top 40",
    "Christian Rap",
    "Pop/Funk",
    "Jungle",
    "Native American",
    "Cabaret",
    "New Wave",
    "Psychedelic",
    "Rave",
    "Showtunes",
    "Trailer",
    "Lo-Fi",
    "Tribal",
    "Acid Punk",
    "Acid Jazz",
    "Polka",
    "Retro",
    "Musical",
    "Rock & Roll",
    "Hard Rock",
    "Folk",
    "Folk-Rock",
    "National Folk",
    "Swing",
    "Fast Fusion",
    "Bebop",
    "Latin",
    "Revival",
    "Celtic",
    "Bluegrass",
    "Avantgarde",
    "Gothic Rock",
    "Progressive Rock",
    "Psychedelic Rock",
    "Symphonic Rock",
    "Slow Rock",
    "Big Band",
    "Chorus",
    "Easy Listening",
    "Acoustic",
    "Humour",
    "Speech",
    "Chanson",
    "Opera",
    "Chamber Music",
    "Sonata",
    "Symphony",
    "Booty Bass",
    "Primus",
    "Porn Groove",
    "Satire",
    "Slow Jam",
    "Club",
    "Tango",
    "Samba",
    "Folklore",
    "Ballad",
    "Power Ballad",
    "Rhythmic Soul",
    "Freestyle",
    "Duet",
    "Punk Rock",
    "Drum Solo",
    "A Cappella",
    "Euro-House",
    "Dance Hall",
    "Goa",
    "Drum & Bass",
    "Club-House",
    "Hardcore",
    "Terror",
    "Indie",
    "BritPop",
    "Afro-Punk",
    "Polsk Punk",
    "Beat",
    "Christian Gangsta Rap",
    "Heavy Metal",
    "Black Metal",
    "Crossover",
    "Contemporary Christian",
    "Christian Rock",
    "Merengue",
    "Salsa",
    "Thrash Metal",
    "Anime",
    "JPop",
    "Synthpop",
    "Abstract",
    "Art Rock",
    "Baroque",
    "Bhangra",
    "Big Beat",
    "Breakbeat",
    "Chillout",
    "Downtempo",
    "Dub",
    "EBM",
    "Eclectic",
    "Electro",
    "Electroclash",
    "Emo",
    "Experimental",
    "Garage",
    "Global",
    "IDM",
    "Illbient",
    "Industro-Goth",
    "Jam Band",
    "Krautrock",
    "Leftfield",
    "Lounge",
    "Math Rock",
    "New Romantic",
    "Nu-Breakz",
    "Post-Punk",
    "Post-Rock",
    "Psytrance",
    "Shoegaze",
    "Space Rock",
    "Trop Rock",
    "World Music",
    "Neoclassical",
    "Audiobook",
    "Audio Theatre",
    "Neue Deutsche Welle",
    "Podcast",
    "Indie Rock",
    "G-Funk",
    "Dubstep",
    "Garage Rock",
    "Psybient",
];

/// Resolves ID3v2 `TCON` numeric/parenthesized ID3v1 genre references such as `"(17)"`,
/// `"(17)Rock"`, `"17"`, `"(17)(28)"`, `"(RX)"`, `"(CR)"` into human-readable names.
pub(super) fn normalize_id3_genre(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    // Pure numeric ID3v2.4 genre code e.g. "17"
    if trimmed.chars().all(|c| c.is_ascii_digit()) {
        if let Ok(idx) = trimmed.parse::<usize>() {
            if let Some(&name) = ID3V1_GENRE_NAMES.get(idx) {
                return name.to_string();
            }
        }
        return trimmed.to_string();
    }

    if !trimmed.starts_with('(') {
        return trimmed.to_string();
    }

    let mut genres: Vec<String> = Vec::new();
    let mut rest = trimmed;
    let mut matched_any_ref = false;

    while rest.starts_with('(') {
        // Escaped literal "((" in ID3v2.3 TCON
        if rest.starts_with("((") {
            let literal = &rest[1..];
            if !literal.is_empty() {
                genres.push(literal.trim().to_string());
            }
            rest = "";
            break;
        }
        let Some(close_pos) = rest.find(')') else {
            break;
        };
        let inside = &rest[1..close_pos];
        let mapped = match inside {
            "RX" => Some("Remix"),
            "CR" => Some("Cover"),
            code if !code.is_empty() && code.chars().all(|c| c.is_ascii_digit()) => code
                .parse::<usize>()
                .ok()
                .and_then(|idx| ID3V1_GENRE_NAMES.get(idx).copied()),
            _ => None,
        };
        if let Some(name) = mapped {
            matched_any_ref = true;
            if !genres.iter().any(|g| g.eq_ignore_ascii_case(name)) {
                genres.push(name.to_string());
            }
            rest = rest[close_pos + 1..].trim_start();
        } else {
            break;
        }
    }

    if !matched_any_ref {
        return trimmed.to_string();
    }

    let tail = rest.trim();
    if !tail.is_empty() {
        // E.g. "(17)Classic Rock" -> prefer refinement if it overrides, or avoid "(17)Rock" duplicate
        if genres.len() == 1 && tail.eq_ignore_ascii_case(&genres[0]) {
            return genres.remove(0);
        }
        if genres.len() == 1 {
            return tail.to_string();
        }
        if !genres.iter().any(|g| g.eq_ignore_ascii_case(tail)) {
            genres.push(tail.to_string());
        }
    }

    genres.join(" / ")
}

pub(super) fn parse_rva2_frame(payload: &[u8], tags: &mut Id3v2ParsedTags) {
    let Some(nul_pos) = payload.iter().position(|&b| b == 0) else {
        return;
    };
    let ident = payload[..nul_pos]
        .iter()
        .map(|&b| b as char)
        .collect::<String>()
        .trim()
        .to_ascii_lowercase();

    let mut pos = nul_pos + 1;
    let mut master_gain: Option<f64> = None;
    let mut master_peak: Option<f64> = None;
    let mut first_gain: Option<f64> = None;
    let mut max_peak: Option<f64> = None;

    while pos + 4 <= payload.len() {
        let channel_type = payload[pos];
        let vol_adj = i16::from_be_bytes([payload[pos + 1], payload[pos + 2]]);
        let gain_db = (vol_adj as f64) / 512.0;
        let peak_bits = payload[pos + 3] as usize;
        pos += 4;

        let peak_bytes = peak_bits.div_ceil(8);
        if pos + peak_bytes > payload.len() {
            break;
        }

        let peak = if peak_bits > 0 && peak_bits <= 64 {
            let mut raw_peak: u64 = 0;
            for &b in &payload[pos..pos + peak_bytes] {
                raw_peak = (raw_peak << 8) | (b as u64);
            }
            let denom = (1u64 << (peak_bits - 1)) as f64;
            let val = (raw_peak as f64) / denom;
            (val.is_finite() && val >= 0.0).then_some(val)
        } else {
            None
        };
        pos += peak_bytes;

        if first_gain.is_none() {
            first_gain = Some(gain_db);
        }
        if let Some(p) = peak {
            max_peak = Some(max_peak.map_or(p, |cur| cur.max(p)));
        }
        if channel_type == 0x01 {
            master_gain = Some(gain_db);
            master_peak = peak;
        }
    }

    let chosen_gain = master_gain.or(first_gain);
    let chosen_peak = master_peak.or(max_peak);

    match ident.as_str() {
        "album" => {
            if tags.rva2_rg_album_db.is_none() {
                tags.rva2_rg_album_db = chosen_gain;
            }
            if tags.rva2_rg_album_peak.is_none() {
                tags.rva2_rg_album_peak = chosen_peak;
            }
        }
        "track" | "" => {
            if tags.rva2_rg_track_db.is_none() {
                tags.rva2_rg_track_db = chosen_gain;
            }
            if tags.rva2_rg_track_peak.is_none() {
                tags.rva2_rg_track_peak = chosen_peak;
            }
        }
        _ => {}
    }
}
