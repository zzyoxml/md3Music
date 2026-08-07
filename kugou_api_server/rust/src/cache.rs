use std::collections::HashMap;
use std::sync::RwLock;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

/// 缓存最大条目数。P0: 原实现无上限，客户端请求大量不同 URL 时
/// 过期 entry 仅在 get 命中时惰性删除，内存持续增长；改为有界缓存。
const MAX_ENTRIES: usize = 512;

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

/// P0: 全局 Mutex → RwLock。缓存读多写少（get 远多于 put），
/// 读读并发不再互斥，高并发下不再把缓存读写完全串行化。
pub struct Cache {
    map: RwLock<HashMap<String, CacheEntry>>,
}

impl Cache {
    pub fn new() -> Self {
        Cache {
            map: RwLock::new(HashMap::new()),
        }
    }

    pub fn get(&self, key: &str) -> Option<CacheEntry> {
        let map = self.map.read().unwrap();
        let now = Instant::now();
        match map.get(key) {
            Some(e) if e.expire > now => Some(e.clone()),
            // 过期项延迟到 put 路径统一清理（读锁内不可修改）
            _ => None,
        }
    }

    pub fn put(&self, key: String, entry: CacheEntry) {
        let mut map = self.map.write().unwrap();
        map.insert(key, entry);
        // P0: 容量上限 + 顺带清理过期项，避免缓存无界增长
        if map.len() > MAX_ENTRIES {
            let now = Instant::now();
            map.retain(|_, e| e.expire > now);
            if map.len() > MAX_ENTRIES {
                // 清理过期项后仍超限：驱逐时间戳最旧的多余条目
                let mut oldest: Vec<(String, f64)> = map
                    .iter()
                    .map(|(k, e)| (k.clone(), e.timestamp))
                    .collect();
                oldest.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
                let excess = map.len() - MAX_ENTRIES;
                for (k, _) in oldest.into_iter().take(excess) {
                    map.remove(&k);
                }
            }
        }
    }

    pub fn clear(&self) {
        let mut map = self.map.write().unwrap();
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
