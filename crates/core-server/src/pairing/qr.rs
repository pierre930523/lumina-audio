use url::Url;

/// Generates a standard pairing URI for QR code presentation.
/// Format: `lumina://pair?pin={pin}&host={host}&port={port}`
/// Or with nonce: `lumina-pair://pair?server={host}%3A{port}&pin={pin}&nonce={nonce}`
pub fn generate_qr_pairing_uri(pin: &str, host: &str, port: u16, nonce: Option<&str>) -> String {
    if let Some(n) = nonce {
        format!(
            "lumina-pair://pair?server={}%3A{}&pin={}&nonce={}",
            host, port, pin, n
        )
    } else {
        format!("lumina://pair?pin={}&host={}&port={}", pin, host, port)
    }
}

/// Validates QR pairing URI scheme and mandatory query parameters.
pub fn validate_qr_pairing_uri(uri: &str) -> bool {
    if let Ok(parsed) = Url::parse(uri) {
        match parsed.scheme() {
            "lumina-pair" => {
                let params: Vec<(String, String)> = parsed.query_pairs().into_owned().collect();
                let has_pin = params.iter().any(|(k, _)| k == "pin");
                let has_nonce = params.iter().any(|(k, _)| k == "nonce");
                let has_server = params.iter().any(|(k, _)| k == "server");
                has_pin && has_nonce && has_server
            }
            "lumina" => {
                let params: Vec<(String, String)> = parsed.query_pairs().into_owned().collect();
                let has_pin = params.iter().any(|(k, _)| k == "pin");
                let has_host = params.iter().any(|(k, _)| k == "host");
                let has_port = params.iter().any(|(k, _)| k == "port");
                has_pin && has_host && has_port
            }
            _ => false,
        }
    } else {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_and_validate_qr_uris() {
        let uri1 = generate_qr_pairing_uri("849201", "192.168.1.100", 9888, None);
        assert_eq!(
            uri1,
            "lumina://pair?pin=849201&host=192.168.1.100&port=9888"
        );
        assert!(validate_qr_pairing_uri(&uri1));

        let uri2 = generate_qr_pairing_uri("849201", "192.168.1.100", 9888, Some("abc123nonce"));
        assert!(validate_qr_pairing_uri(&uri2));

        assert!(!validate_qr_pairing_uri("http://example.com"));
        assert!(!validate_qr_pairing_uri("lumina://pair?pin=123"));
        assert!(!validate_qr_pairing_uri("invalid_uri"));
    }
}
