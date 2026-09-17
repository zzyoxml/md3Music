use crate::crypto::crypto_md5_str;
use crate::util::{calculate_mid, get_guid, random_string};
use serde_json::{json, Value};
use std::sync::Mutex;

/// DeviceConfig replicates `device_config.js`.
/// Fields use interior mutability so the static OnceLock instance can be updated
/// after server startup (dfid/mid are set by /register/dev).
#[derive(Debug)]
pub struct DeviceConfig {
    inner: Mutex<DeviceInner>,
}

#[derive(Debug, Clone)]
struct DeviceInner {
    dfid: Option<String>,
    mid: Option<String>,
    uuid: Option<String>,
    guid: Option<String>,
    server_dev: Option<String>,
    mac: Option<String>,
}

impl Default for DeviceInner {
    fn default() -> Self {
        DeviceInner {
            dfid: None,
            mid: None,
            uuid: None,
            guid: None,
            server_dev: None,
            mac: None,
        }
    }
}

impl DeviceConfig {
    pub fn new() -> Self {
        DeviceConfig {
            inner: Mutex::new(DeviceInner::default()),
        }
    }

    /// Global singleton (same storage as config.rs DEVICE_CONFIG).
    pub fn instance() -> &'static DeviceConfig {
        crate::config::DEVICE_CONFIG.get_or_init(DeviceConfig::new)
    }

    pub fn init_device_info(&self) {
        let mut inner = self.inner.lock().unwrap();
        if inner.guid.is_none() {
            inner.guid = Some(get_guid());
        }
        if inner.mid.is_none() {
            let guid = inner.guid.clone().unwrap_or_default();
            inner.mid = Some(calculate_mid(&guid));
        }
        if inner.uuid.is_none() {
            inner.uuid = match (&inner.dfid, &inner.mid) {
                (Some(dfid), Some(mid)) => Some(crypto_md5_str(&format!("{}{}", dfid, mid))),
                _ => Some("-".to_string()),
            };
        }
        if inner.server_dev.is_none() {
            inner.server_dev = Some(random_string(10).to_uppercase());
        }
        if inner.mac.is_none() {
            inner.mac = Some("02:00:00:00:00:00".to_string());
        }
    }

    pub fn set_dfid(&self, new_dfid: &str) {
        let mut inner = self.inner.lock().unwrap();
        inner.dfid = Some(new_dfid.to_string());
        if let Some(mid) = &inner.mid {
            inner.uuid = Some(crypto_md5_str(&format!("{}{}", new_dfid, mid)));
        }
    }

    pub fn set_mid(&self, new_mid: &str) {
        let mut inner = self.inner.lock().unwrap();
        inner.mid = Some(new_mid.to_string());
        if let Some(dfid) = &inner.dfid {
            inner.uuid = Some(crypto_md5_str(&format!("{}{}", dfid, new_mid)));
        }
    }

    /// Restore a previously persisted guid. Since mid is derived from guid
    /// (calculate_mid), recompute it so the whole device identity stays
    /// consistent across process restarts — otherwise every launch would
    /// generate a brand-new guid and register a brand-new device upstream.
    pub fn set_guid(&self, new_guid: &str) {
        let mut inner = self.inner.lock().unwrap();
        inner.guid = Some(new_guid.to_string());
        inner.mid = Some(calculate_mid(new_guid));
        if let Some(dfid) = &inner.dfid {
            inner.uuid = Some(crypto_md5_str(&format!("{}{}", dfid, calculate_mid(new_guid))));
        }
    }

    pub fn set_server_dev(&self, new_dev: &str) {
        let mut inner = self.inner.lock().unwrap();
        inner.server_dev = Some(new_dev.to_string());
    }

    pub fn get_dfid(&self) -> String {
        self.init_device_info();
        self.inner.lock().unwrap().dfid.clone().unwrap_or_else(|| "-".to_string())
    }

    pub fn get_mid(&self) -> String {
        self.init_device_info();
        self.inner.lock().unwrap().mid.clone().unwrap_or_else(|| "-".to_string())
    }

    pub fn get_uuid(&self) -> String {
        self.init_device_info();
        self.inner.lock().unwrap().uuid.clone().unwrap_or_else(|| "-".to_string())
    }

    pub fn get_guid(&self) -> String {
        self.init_device_info();
        self.inner.lock().unwrap().guid.clone().unwrap_or_else(|| "-".to_string())
    }

    pub fn get_server_dev(&self) -> String {
        self.init_device_info();
        self.inner.lock().unwrap().server_dev.clone().unwrap_or_else(|| "-".to_string())
    }

    pub fn get_mac(&self) -> String {
        self.init_device_info();
        self.inner.lock().unwrap().mac.clone().unwrap_or_else(|| "-".to_string())
    }

    pub fn get_device_info(&self) -> Value {
        self.init_device_info();
        let inner = self.inner.lock().unwrap();
        json!({
            "dfid": inner.dfid.clone().unwrap_or_else(|| "-".to_string()),
            "mid": inner.mid.clone().unwrap_or_else(|| "-".to_string()),
            "uuid": inner.uuid.clone().unwrap_or_else(|| "-".to_string()),
            "guid": inner.guid.clone().unwrap_or_else(|| "-".to_string()),
            "serverDev": inner.server_dev.clone().unwrap_or_else(|| "-".to_string()),
            "mac": inner.mac.clone().unwrap_or_else(|| "-".to_string()),
        })
    }

    /// Load cached device_info.json (replicating server.js loadCachedDeviceInfo).
    pub fn load_cached(&self, data_dir: &str) -> bool {
        let path = format!("{}/device_info.json", data_dir);
        let text = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(_) => return false,
        };
        let data: Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(_) => return false,
        };
        let dfid = data.get("dfid").and_then(|v| v.as_str()).unwrap_or("");
        if dfid.is_empty() {
            return false;
        }
        self.set_dfid(dfid);
        if let Some(mid) = data.get("mid").and_then(|v| v.as_str()) {
            if !mid.is_empty() {
                self.set_mid(mid);
            }
        }
        if let Some(guid) = data.get("guid").and_then(|v| v.as_str()) {
            if !guid.is_empty() {
                self.set_guid(guid);
            }
        }
        if let Some(server_dev) = data.get("serverDev").and_then(|v| v.as_str()) {
            if !server_dev.is_empty() {
                self.set_server_dev(server_dev);
            }
        }
        self.init_device_info();
        true
    }

    /// Persist device_info.json (replicating server.js registerDeviceAndGetDfid write).
    pub fn save(&self, data_dir: &str, dfid: &str, mid: Option<&str>) {
        let mid = match mid {
            Some(m) if !m.is_empty() => m.to_string(),
            _ => self.get_mid(),
        };
        let info = json!({
            "dfid": dfid,
            "mid": mid,
            "uuid": self.get_uuid(),
            "guid": self.get_guid(),
            "serverDev": self.get_server_dev(),
            "mac": self.get_mac(),
        });
        let path = format!("{}/device_info.json", data_dir);
        if let Ok(text) = serde_json::to_string_pretty(&info) {
            let _ = std::fs::write(path, text);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process;

    fn tmp_dir() -> String {
        let d = std::env::temp_dir()
            .join(format!("kugou_dev_test_{}", process::id()));
        std::fs::create_dir_all(&d).unwrap();
        d.to_str().unwrap().to_string()
    }

    /// Core regression test for the device-identity bug: every app cold start
    /// (a fresh local server process) used to generate a brand-new random guid,
    /// so the account kept registering "new devices". After the fix, guid (and
    /// the mid derived from it) MUST round-trip through device_info.json across
    /// independent instances — exactly what two separate processes observe.
    #[test]
    fn guid_stable_across_instances() {
        let dir = tmp_dir();
        let f = format!("{}/device_info.json", dir);
        let _ = std::fs::remove_file(&f);

        // "launch 1": fresh instance, obtain a device identity, then persist.
        let a = DeviceConfig::new();
        let dfid = "TESTDFID1234567890";
        a.set_dfid(dfid);
        a.init_device_info();
        let guid1 = a.get_guid();
        assert_ne!(guid1, "-", "a fresh instance must own a non-empty guid");
        a.save(&dir, dfid, Some(&a.get_mid()));
        drop(a);

        // "launch 2": an independent instance reads the file back. This is the
        // cross-process contract — shared statics play no part here.
        let b = DeviceConfig::new();
        assert!(b.load_cached(&dir), "device_info.json must be loadable");
        assert_eq!(b.get_dfid(), dfid, "dfid must be restored");
        assert_eq!(
            b.get_guid(),
            guid1,
            "guid MUST be restored across instances, not regenerated"
        );
        assert_eq!(
            b.get_mid(),
            calculate_mid(&guid1),
            "mid must stay consistent with the restored guid"
        );
        let _ = std::fs::remove_file(&f);
    }
}
