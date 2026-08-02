use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

/// Cached HTTP response entry (apicache `createCacheObject`).
#[derive(Debug, Clone)]
pub struct CacheEntry {
    pub status: u16,
    /// ordered header pairs, preserving duplicate Set-Cookie headers.
    pub headers: Vec<(String, String)>,
    pub data: Vec<u8>,
    pub timestamp: f64, // seconds since epoch
    pub expire: Instant,
}

pub struct Cache {
    map: Mutex<HashMap<String, CacheEntry>>,
}

impl Cache {
    pub fn new() -> Self {
        Cache {
            map: Mutex::new(HashMap::new()),
        }
    }

    pub fn get(&self, key: &str) -> Option<CacheEntry> {
        let mut map = self.map.lock().unwrap();
        let now = Instant::now();
        match map.get(key) {
            Some(e) if e.expire > now => Some(e.clone()),
            Some(_) => {
                map.remove(key);
                None
            }
            None => None,
        }
    }

    pub fn put(&self, key: String, entry: CacheEntry) {
        let mut map = self.map.lock().unwrap();
        map.insert(key, entry);
    }

    pub fn clear(&self) {
        let mut map = self.map.lock().unwrap();
        map.clear();
    }
}

/// Global cache used by the HTTP server (2 minutes default, matching apicache('2 minutes')).
pub static CACHE: std::sync::OnceLock<Cache> = std::sync::OnceLock::new();

pub fn now_epoch_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}
