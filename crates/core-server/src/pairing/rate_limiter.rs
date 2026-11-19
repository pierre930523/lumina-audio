use std::collections::{HashMap, HashSet};

/// Brute-force protection: locks client IP after consecutive failed attempts.
#[derive(Debug, Clone)]
pub struct PinRateLimiter {
    pub max_failures: usize,
    pub failure_counts: HashMap<String, usize>,
    pub locked_ips: HashSet<String>,
}

impl Default for PinRateLimiter {
    fn default() -> Self {
        Self::new(5)
    }
}

impl PinRateLimiter {
    pub fn new(max_failures: usize) -> Self {
        Self {
            max_failures,
            failure_counts: HashMap::new(),
            locked_ips: HashSet::new(),
        }
    }

    pub fn is_locked(&self, ip: &str) -> bool {
        self.locked_ips.contains(ip)
    }

    pub fn record_failure(&mut self, ip: &str) -> bool {
        let count = self.failure_counts.entry(ip.to_string()).or_insert(0);
        *count += 1;
        if *count >= self.max_failures {
            self.locked_ips.insert(ip.to_string());
            true
        } else {
            false
        }
    }

    pub fn record_success(&mut self, ip: &str) {
        self.failure_counts.remove(ip);
        self.locked_ips.remove(ip);
    }

    pub fn reset(&mut self) {
        self.failure_counts.clear();
        self.locked_ips.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pin_rate_limiter_lockout() {
        let mut limiter = PinRateLimiter::new(5);
        let test_ip = "192.168.1.50";

        assert!(!limiter.is_locked(test_ip));
        for i in 1..=4 {
            let locked = limiter.record_failure(test_ip);
            assert!(!locked, "Should not be locked on attempt {i}");
            assert!(!limiter.is_locked(test_ip));
        }

        let locked = limiter.record_failure(test_ip);
        assert!(locked, "Should be locked on 5th attempt");
        assert!(limiter.is_locked(test_ip));

        // Subsequent failure keeps locked
        assert!(limiter.is_locked(test_ip));

        // Reset works
        limiter.record_success(test_ip);
        assert!(!limiter.is_locked(test_ip));
    }
}
