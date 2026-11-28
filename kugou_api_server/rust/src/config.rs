use std::sync::OnceLock;

/// MD3Music fixed config (from kugou_api_server/config.json / srcAppid 3116).
pub const APP_ID: &str = "3116";
pub const CLIENT_VER: &str = "11440";
pub const CLIENT_VER_NUM: i64 = 11440;
pub const CLIENT_TIME: &str = "11440";
pub const SRC_APP_ID: &str = "3116";
pub const SRC_CLIENT_VER: &str = "11440";
pub const SRC_CLIENT_TIME: &str = "11440";
pub const SRC_PID_VER: &str = "3001";
pub const SRC_PLATFORM: &str = "android";
pub const LITE_PLATFORM: &str = "android";
pub const LITE_PID: &str = "411";
pub const LITE_PID_VER: &str = "3001";

pub const VERSION: &str = "1.0.1";
pub const SUB_VERSION: &str = "1.0.1";

/// fixed dfid/mid (lite platform).
pub const DFID: &str = "-";
pub const MID: &str = "-";

pub const CLIENT_CDN: &str = "kugoucdn";
pub const CDN_PATH: &str = "kugoucdn";
pub const CDN_BASE_URL: &str = "https://imobile.sj.qq.com";

pub const DEFAULT_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

pub const ROUTE: &str = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA";
pub const APP_ID_KEY: &str = "3116";
pub const APP_ID_SIGN: &str = "3116";
pub const CLIENT_VER_SIGN: &str = "11440";

/// signatureAndroids signature params sorted by key for query building.
pub const SIGNATURE_PARAMS: &[&str] = &["appid", "clientver", "clienttime"];

pub const PLATFORM: &str = "android";
pub const PLATFORM_DEV: &str = "android";

pub const MAM: &str = "00000000000000000000000000000000";

pub static DEVICE_CONFIG: OnceLock<crate::device::DeviceConfig> = OnceLock::new();
