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
