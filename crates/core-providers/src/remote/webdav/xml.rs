use quick_xml::Reader;
use quick_xml::events::Event;

use crate::error::ProviderError;

#[derive(Debug, Clone)]
pub(super) struct DavEntry {
    pub(super) href_path: String,
    pub(super) is_collection: bool,
    pub(super) display_name: Option<String>,
    pub(super) last_modified: Option<String>,
    pub(super) content_length: Option<u64>,
}

pub(super) fn parse_propfind_xml(xml: &str) -> Result<Vec<DavEntry>, ProviderError> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);

    let mut entries = Vec::new();
    let mut element_depth: usize = 0;
    let mut saw_root = false;

    let mut in_response = false;
    let mut in_propstat = false;
    let mut in_resourcetype = false;
    let mut current_tag: Option<String> = None;

    let mut cur_href = String::new();
    let mut cur_is_col = false;
    let mut cur_display: Option<String> = None;
    let mut cur_last_modified: Option<String> = None;
    let mut cur_content_length: Option<u64> = None;
    let mut resp_status_text = String::new();
    let mut has_any_propstat = false;
    let mut has_ok_propstat = false;

    let mut ps_is_col = false;
    let mut ps_display: Option<String> = None;
    let mut ps_last_modified: Option<String> = None;
    let mut ps_content_length_str = String::new();
    let mut ps_status_text = String::new();

    let mut buf = Vec::new();
    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(ref e)) => {
                element_depth += 1;
                saw_root = true;
                let name = String::from_utf8_lossy(e.local_name().as_ref()).to_ascii_lowercase();
                match name.as_str() {
                    "response" => {
                        in_response = true;
                        in_propstat = false;
                        in_resourcetype = false;
                        cur_href.clear();
                        cur_is_col = false;
                        cur_display = None;
                        cur_last_modified = None;
                        cur_content_length = None;
                        resp_status_text.clear();
                        has_any_propstat = false;
                        has_ok_propstat = false;
                    }
                    "propstat" if in_response => {
                        in_propstat = true;
                        has_any_propstat = true;
                        ps_is_col = false;
                        ps_display = None;
                        ps_last_modified = None;
                        ps_content_length_str.clear();
                        ps_status_text.clear();
                    }
                    "resourcetype" if in_response => {
                        in_resourcetype = true;
                    }
                    "collection" if in_response && in_resourcetype => {
                        if in_propstat {
                            ps_is_col = true;
                        } else {
                            cur_is_col = true;
                        }
                    }
                    "href" | "displayname" | "status" | "getlastmodified" | "getcontentlength"
                        if in_response =>
                    {
                        current_tag = Some(name);
                    }
                    _ => {}
                }
            }
            Ok(Event::Empty(ref e)) => {
                saw_root = true;
                let name = String::from_utf8_lossy(e.local_name().as_ref()).to_ascii_lowercase();
                if in_response && in_resourcetype && name == "collection" {
                    if in_propstat {
                        ps_is_col = true;
                    } else {
                        cur_is_col = true;
                    }
                }
            }
            Ok(Event::Text(ref e)) => {
                if in_response {
                    if let Some(ref tag) = current_tag {
                        let text = e.unescape().unwrap_or_default().into_owned();
                        match tag.as_str() {
                            "href" => cur_href.push_str(&text),
                            "displayname" => {
                                if in_propstat {
                                    let entry = ps_display.get_or_insert_with(String::new);
                                    entry.push_str(&text);
                                } else {
                                    let entry = cur_display.get_or_insert_with(String::new);
                                    entry.push_str(&text);
                                }
                            }
                            "getlastmodified" => {
                                if in_propstat {
                                    let entry = ps_last_modified.get_or_insert_with(String::new);
                                    entry.push_str(&text);
                                } else {
                                    let entry = cur_last_modified.get_or_insert_with(String::new);
                                    entry.push_str(&text);
                                }
                            }
                            "getcontentlength" => {
                                if in_propstat {
                                    ps_content_length_str.push_str(&text);
                                } else if let Ok(len) = text.trim().parse::<u64>() {
                                    cur_content_length = Some(len);
                                }
                            }
                            "status" => {
                                if in_propstat {
                                    ps_status_text.push_str(&text);
                                } else {
                                    resp_status_text.push_str(&text);
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
            Ok(Event::End(ref e)) => {
                element_depth = element_depth.saturating_sub(1);
                let name = String::from_utf8_lossy(e.local_name().as_ref()).to_ascii_lowercase();
                match name.as_str() {
                    "response" => {
                        let resp_status_ok = parse_dav_status_is_ok(&resp_status_text);
                        let propstat_ok = !has_any_propstat || has_ok_propstat;
                        if !cur_href.trim().is_empty() && resp_status_ok && propstat_ok {
                            entries.push(DavEntry {
                                href_path: extract_path_from_href(&cur_href),
                                is_collection: cur_is_col,
                                display_name: cur_display.take(),
                                last_modified: cur_last_modified
                                    .take()
                                    .map(|s| s.trim().to_string())
                                    .filter(|s| !s.is_empty()),
                                content_length: cur_content_length.take(),
                            });
                        }
                        in_response = false;
                        in_propstat = false;
                        in_resourcetype = false;
                        current_tag = None;
                    }
                    "propstat" if in_response => {
                        if parse_dav_status_is_ok(&ps_status_text) {
                            has_ok_propstat = true;
                            if ps_is_col {
                                cur_is_col = true;
                            }
                            if cur_display.is_none() {
                                cur_display = ps_display.take();
                            }
                            if cur_last_modified.is_none() {
                                cur_last_modified = ps_last_modified.take();
                            }
                            if cur_content_length.is_none() {
                                cur_content_length =
                                    ps_content_length_str.trim().parse::<u64>().ok();
                            }
                        }
                        in_propstat = false;
                        in_resourcetype = false;
                        current_tag = None;
                    }
                    "resourcetype" => {
                        in_resourcetype = false;
                    }
                    "href" | "displayname" | "status" | "getlastmodified" | "getcontentlength" => {
                        current_tag = None;
                    }
                    _ => {}
                }
            }
            Ok(Event::Eof) => break,
            Err(e) => {
                return Err(ProviderError::ScanError(format!(
                    "Failed to parse WebDAV PROPFIND XML: {e}"
                )));
            }
            _ => {}
        }
        buf.clear();
    }

    if !saw_root || in_response || in_propstat || element_depth != 0 {
        return Err(ProviderError::ScanError(
            "Truncated or incomplete WebDAV PROPFIND XML".to_string(),
        ));
    }

    Ok(entries)
}

fn parse_dav_status_is_ok(status_text: &str) -> bool {
    let trimmed = status_text.trim();
    if trimmed.is_empty() {
        return true;
    }
    for tok in trimmed.split_whitespace() {
        if tok.len() == 3 && tok.bytes().all(|b| b.is_ascii_digit()) {
            if let Ok(code) = tok.parse::<u16>() {
                return (200..=299).contains(&code);
            }
        }
    }
    false
}

fn extract_path_from_href(href: &str) -> String {
    let trimmed = href.trim();
    if let Ok(parsed) = url::Url::parse(trimmed) {
        parsed.path().to_string()
    } else {
        trimmed.to_string()
    }
}
