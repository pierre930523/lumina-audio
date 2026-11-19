//! Strict SQLite FTS5 Query Sanitizer.
//!
//! Neutralizes dangerous operators and formats user tokens for safe prefix matching.

/// Sanitizes raw user input string for safe SQLite FTS5 query matching.
///
/// 1. Strips dangerous operators: `"`, `*`, `(`, `)`, `:`, `^`, `+`, `-`, `~`, `/`, `\`, `{`, `}`, `[`, `]`.
/// 2. Splits input into whitespace-delimited tokens.
/// 3. Filters out standalone FTS5 reserved keywords (AND, OR, NOT, NEAR).
/// 4. Wraps each remaining token in quotes and appends `*` for prefix search: `"{token}"*`.
/// 5. Joins tokens with spaces (implicit AND in FTS5).
pub fn sanitize_fts5_query(query: &str) -> String {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    // Step 1: Replace control characters and dangerous punctuation with spaces
    let cleaned: String = trimmed
        .chars()
        .map(|c| {
            if c.is_ascii_control() {
                ' '
            } else {
                match c {
                    '"' | '*' | '(' | ')' | ':' | '^' | '+' | '-' | '~' | '\\' | '/' | '{'
                    | '}' | '[' | ']' => ' ',
                    _ => c,
                }
            }
        })
        .collect();

    // Step 2: Extract tokens and filter out standalone boolean keywords
    let tokens: Vec<&str> = cleaned
        .split_whitespace()
        .filter(|tok| {
            let upper = tok.to_ascii_uppercase();
            !matches!(upper.as_str(), "AND" | "OR" | "NOT" | "NEAR")
        })
        .collect();

    if tokens.is_empty() {
        return String::new();
    }

    // Step 3 & 4: Quote each token and append * for prefix search, joined by space
    tokens
        .into_iter()
        .map(|tok| format!("\"{}\"*", tok))
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_empty_and_whitespace_returns_empty() {
        assert_eq!(sanitize_fts5_query(""), "");
        assert_eq!(sanitize_fts5_query("   "), "");
        assert_eq!(sanitize_fts5_query("::: --- ***"), "");
    }

    #[test]
    fn test_single_character_prefix() {
        assert_eq!(sanitize_fts5_query("P"), "\"P\"*");
    }

    #[test]
    fn test_multi_token_conjunction() {
        assert_eq!(sanitize_fts5_query("Pink Floyd"), "\"Pink\"* \"Floyd\"*");
    }

    #[test]
    fn test_neutralizes_dangerous_operators() {
        let toxic = "Pink (Floyd) \"Dark*Side: AND OR NOT ^test";
        let sanitized = sanitize_fts5_query(toxic);
        assert!(!sanitized.contains('('));
        assert!(!sanitized.contains(')'));
        assert!(!sanitized.contains(':'));
        assert_eq!(
            sanitized,
            "\"Pink\"* \"Floyd\"* \"Dark\"* \"Side\"* \"test\"*"
        );
    }

    #[test]
    fn test_cjk_characters_preserved() {
        assert_eq!(sanitize_fts5_query("坂本龍一"), "\"坂本龍一\"*");
    }
}
