use std::io::{Read, Seek, SeekFrom};

use super::Id3v1ParsedTags;
use crate::local::dsd_meta::parse_year;
use crate::local::encoding::{
    decode_bytes_with_encoding, detect_tag_block_encoding, sanitize_tag_text,
};

const ID3V1_GENRES: &[&str] = &[
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
];

pub(crate) fn parse_id3v1_from_reader<R: Read + Seek>(
    reader: &mut R,
    collect_raw: bool,
) -> Option<Id3v1ParsedTags> {
    let len = reader.seek(SeekFrom::End(0)).ok()?;
    if len < 128 {
        return None;
    }
    reader.seek(SeekFrom::End(-128)).ok()?;
    let mut v1_buf = [0u8; 128];
    reader.read_exact(&mut v1_buf).ok()?;
    parse_id3v1_buf(&v1_buf, collect_raw)
}

pub(crate) fn parse_id3v1_from_slice(bytes: &[u8], collect_raw: bool) -> Option<Id3v1ParsedTags> {
    if bytes.len() < 128 {
        return None;
    }
    let tail: [u8; 128] = bytes[bytes.len() - 128..].try_into().ok()?;
    parse_id3v1_buf(&tail, collect_raw)
}

fn trim_id3v1_slice(raw: &[u8]) -> &[u8] {
    let end = raw.iter().position(|&b| b == 0).unwrap_or(raw.len());
    let mut s = &raw[..end];
    while let Some(&last) = s.last() {
        if last == b' ' {
            s = &s[..s.len() - 1];
        } else {
            break;
        }
    }
    s
}

fn parse_id3v1_buf(v1_buf: &[u8; 128], collect_raw: bool) -> Option<Id3v1ParsedTags> {
    if &v1_buf[0..3] != b"TAG" {
        return None;
    }

    let raw_title = trim_id3v1_slice(&v1_buf[3..33]);
    let raw_artist = trim_id3v1_slice(&v1_buf[33..63]);
    let raw_album = trim_id3v1_slice(&v1_buf[63..93]);
    let raw_year = trim_id3v1_slice(&v1_buf[93..97]);
    let (raw_comment, track_number) = if v1_buf[125] == 0 && v1_buf[126] != 0 {
        (trim_id3v1_slice(&v1_buf[97..125]), Some(v1_buf[126] as u16))
    } else {
        (trim_id3v1_slice(&v1_buf[97..127]), None)
    };
    let genre_idx = v1_buf[127] as usize;
    let genre = ID3V1_GENRES.get(genre_idx).map(|g| (*g).to_string());

    let enc = detect_tag_block_encoding(&[raw_title, raw_artist, raw_album, raw_comment]);

    let dec_title = sanitize_tag_text(&decode_bytes_with_encoding(raw_title, enc));
    let dec_artist = sanitize_tag_text(&decode_bytes_with_encoding(raw_artist, enc));
    let dec_album = sanitize_tag_text(&decode_bytes_with_encoding(raw_album, enc));
    let dec_year = sanitize_tag_text(&decode_bytes_with_encoding(raw_year, enc));
    let dec_comment = sanitize_tag_text(&decode_bytes_with_encoding(raw_comment, enc));

    let mut raw_fields = Vec::new();
    if collect_raw {
        for (k, b, v) in [
            ("TITLE", raw_title, &dec_title),
            ("ARTIST", raw_artist, &dec_artist),
            ("ALBUM", raw_album, &dec_album),
            ("YEAR", raw_year, &dec_year),
            ("COMMENT", raw_comment, &dec_comment),
        ] {
            if !b.is_empty() {
                raw_fields.push((k.to_string(), b.to_vec(), v.clone()));
            }
        }
        if let Some(trk) = track_number {
            raw_fields.push(("TRACK".to_string(), vec![v1_buf[126]], trk.to_string()));
        }
        if let Some(ref g) = genre {
            raw_fields.push(("GENRE".to_string(), vec![v1_buf[127]], g.clone()));
        }
    }

    Some(Id3v1ParsedTags {
        detected_encoding: enc,
        raw_fields,
        title: (!dec_title.is_empty()).then_some(dec_title),
        artist: (!dec_artist.is_empty()).then_some(dec_artist),
        album: (!dec_album.is_empty()).then_some(dec_album),
        release_year: parse_year(&dec_year),
        track_number,
        genre,
    })
}
