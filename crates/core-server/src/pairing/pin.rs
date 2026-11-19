use rand::Rng;
use std::time::Instant;

/// Generates a random 6-digit numeric PIN matching `^[0-9]{6}$`.
pub fn generate_six_digit_pin() -> String {
    let mut rng = rand::thread_rng();
    let num: u32 = rng.gen_range(0..1_000_000);
    format!("{:06}", num)
}

/// Validates that a string consists of exactly 6 numeric digits.
pub fn validate_pin_format(pin: &str) -> bool {
    let trimmed = pin.trim();
    trimmed.len() == 6 && trimmed.chars().all(|c| c.is_ascii_digit())
}

#[derive(Debug, Clone)]
pub struct ActivePin {
    pub pin: String,
    pub created_at: Instant,
    pub ttl_secs: f64,
    pub device_name: String,
}

impl ActivePin {
    pub fn new(pin: String, device_name: String, ttl_secs: f64) -> Self {
        Self {
            pin,
            created_at: Instant::now(),
            ttl_secs,
            device_name,
        }
    }

    pub fn is_valid(&self, now: Instant) -> bool {
        now.duration_since(self.created_at).as_secs_f64() <= self.ttl_secs
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn test_generate_and_validate_pin() {
        for _ in 0..100 {
            let pin = generate_six_digit_pin();
            assert_eq!(pin.len(), 6);
            assert!(validate_pin_format(&pin));
        }
    }

    #[test]
    fn test_validate_pin_format_boundaries() {
        assert!(validate_pin_format("123456"));
        assert!(validate_pin_format("000000"));
        assert!(validate_pin_format("999999"));
        assert!(!validate_pin_format("12345"));
        assert!(!validate_pin_format("1234567"));
        assert!(!validate_pin_format("12a456"));
        assert!(!validate_pin_format(""));
        assert!(!validate_pin_format("-12345"));
    }

    #[test]
    fn test_pin_ttl_expiry() {
        let pin = ActivePin::new("123456".to_string(), "test".to_string(), 60.0);
        let t0 = pin.created_at;
        assert!(pin.is_valid(t0));
        assert!(pin.is_valid(t0 + Duration::from_secs(59)));
        assert!(pin.is_valid(t0 + Duration::from_secs(60)));
        assert!(!pin.is_valid(t0 + Duration::from_millis(60_100)));
    }
}
