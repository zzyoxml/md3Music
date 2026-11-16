use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

/// 缓存条数、单项和总字节上限。大响应保留在响应路径，但不进入缓存。
const MAX_ENTRIES: usize = 512;
const MAX_ENTRY_BYTES: usize = 1024 * 1024;
const MAX_CACHE_BYTES: usize = 16 * 1024 * 1024;

/// Cached HTTP response entry (apicache `createCacheObject`).
///
/// 以 `Arc<CacheEntry>` 形式存于缓存：命中路径只做 O(1) 引用计数克隆，
/// 避免整块深拷贝 body（列表/歌单 JSON 可达数十~数百 KB）。
#[derive(Debug)]
pub struct CacheEntry {
    pub status: u16,
    /// ordered header pairs, preserving duplicate Set-Cookie headers.
    pub headers: Vec<(String, String)>,
    pub data: Vec<u8>,
    pub timestamp: f64, // seconds since epoch
    pub expire: Instant,
}

/// P0: 全局 Mutex → RwLock。缓存读多写少（get 远多于 put），
/// 读读并发不再互斥，高并发下不再把缓存读写完全串行化。
/// P0: entry 以 Arc 存储，get 返回 Arc 克隆（O(1)），零深拷贝。
pub struct Cache {
    state: RwLock<CacheState>,
    max_entries: usize,
    max_entry_bytes: usize,
    max_cache_bytes: usize,
}

struct CacheState {
    map: HashMap<String, Arc<CacheEntry>>,
    resident_bytes: usize,
}

fn entry_size(key: &str, entry: &CacheEntry) -> usize {
    key.len()
        .saturating_add(entry.data.len())
        .saturating_add(entry.headers.iter().fold(0usize, |total, (name, value)| {
            total.saturating_add(name.len()).saturating_add(value.len())
        }))
}

impl Cache {
    pub fn new() -> Self {
        Cache {
            state: RwLock::new(CacheState {
                map: HashMap::new(),
                resident_bytes: 0,
            }),
            max_entries: MAX_ENTRIES,
            max_entry_bytes: MAX_ENTRY_BYTES,
            max_cache_bytes: MAX_CACHE_BYTES,
        }
    }

    #[cfg(test)]
    fn with_limits(max_entries: usize, max_entry_bytes: usize, max_cache_bytes: usize) -> Self {
        Cache {
            state: RwLock::new(CacheState {
                map: HashMap::new(),
                resident_bytes: 0,
            }),
            max_entries,
            max_entry_bytes,
            max_cache_bytes,
        }
    }

    pub fn get(&self, key: &str) -> Option<Arc<CacheEntry>> {
        let state = self.state.read().unwrap();
        let now = Instant::now();
        match state.map.get(key) {
            Some(e) if e.expire > now => Some(Arc::clone(e)),
            // 过期项延迟到 put 路径统一清理（读锁内不可修改）
            _ => None,
        }
    }

    pub fn put(&self, key: String, entry: CacheEntry) {
        let size = entry_size(&key, &entry);
        // 单项过大时保留旧缓存条目，不因一次超限响应使热键缓存失效。
        if size > self.max_entry_bytes || size > self.max_cache_bytes || self.max_entries == 0 {
            return;
        }
        let mut state = self.state.write().unwrap();
        if let Some(old) = state.map.remove(&key) {
            state.resident_bytes = state.resident_bytes.saturating_sub(entry_size(&key, &old));
        }
        let now = Instant::now();
        let expired: Vec<String> = state
            .map
            .iter()
            .filter(|(_, value)| value.expire <= now)
            .map(|(key, _)| key.clone())
            .collect();
        for expired_key in expired {
            if let Some(old) = state.map.remove(&expired_key) {
                state.resident_bytes =
                    state.resident_bytes.saturating_sub(entry_size(&expired_key, &old));
            }
        }

        while state.map.len() >= self.max_entries
            || state.resident_bytes.saturating_add(size) > self.max_cache_bytes
        {
            let oldest = state
                .map
                .iter()
                .min_by(|a, b| {
                    a.1.timestamp
                        .partial_cmp(&b.1.timestamp)
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
                .map(|(key, _)| key.clone());
            let Some(oldest_key) = oldest else { break };
            if let Some(old) = state.map.remove(&oldest_key) {
                state.resident_bytes =
                    state.resident_bytes.saturating_sub(entry_size(&oldest_key, &old));
            }
        }
        state.resident_bytes = state.resident_bytes.saturating_add(size);
        state.map.insert(key, Arc::new(entry));
    }

    pub fn clear(&self) {
        let mut state = self.state.write().unwrap();
        state.map.clear();
        state.resident_bytes = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn entry(data_len: usize, timestamp: f64) -> CacheEntry {
        CacheEntry {
            status: 200,
            headers: Vec::new(),
            data: vec![0; data_len],
            timestamp,
            expire: Instant::now() + Duration::from_secs(60),
        }
    }

    #[test]
    fn cache_enforces_single_entry_total_bytes_and_count() {
        let cache = Cache::with_limits(2, 8, 10);
        cache.put("large".into(), entry(9, 1.0));
        assert!(cache.get("large").is_none());

        cache.put("a".into(), entry(4, 1.0));
        cache.put("b".into(), entry(4, 2.0));
        cache.put("c".into(), entry(4, 3.0));
        assert!(cache.get("a").is_none());
        assert!(cache.get("b").is_some());
        assert!(cache.get("c").is_some());

        cache.put("d".into(), entry(1, 4.0));
        assert_eq!(cache.state.read().unwrap().map.len(), 2);
        assert!(cache.state.read().unwrap().resident_bytes <= 10);
    }

    #[test]
    fn replacement_and_clear_keep_byte_accounting_consistent() {
        let cache = Cache::with_limits(2, 8, 10);
        cache.put("same".into(), entry(4, 1.0));
        cache.put("same".into(), entry(2, 2.0));
        assert_eq!(cache.state.read().unwrap().resident_bytes, 6);
        cache.clear();
        assert_eq!(cache.state.read().unwrap().resident_bytes, 0);
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
