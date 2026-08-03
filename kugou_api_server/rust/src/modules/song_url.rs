//! song_url.js → /song/url（获取播放地址，v5/url，encryptKey）。
//! 与 song_url_new.js（/song/url/new）不同：走 trackercdn v5/url。

use crate::device::DeviceConfig;
use crate::modules::{c_str, q_cookie, q_num, q_str, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use serde_json::{json, Value};

pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let hash = q_str(q, "hash", "").to_ascii_lowercase();
    let ppage_id = q_str(q, "ppage_id", "356753938,823673182,967485191");
    // JS `params.quality || 128` 保留字符串（'128'/'320'/'flac'/'high'）。
    // 不能用 q_num：'flac'/'high' 解析失败会回落 128，导致始终最低音质。
    let quality = q_str(q, "quality", "128");

    let dev = DeviceConfig::instance();
    let dev_info = dev.get_device_info();

    // 设备信息优先，其次 params/cookie，最后 '-'
    let dfid = {
        let d = dev_info.get("dfid").and_then(|v| v.as_str()).unwrap_or("-");
        if !d.is_empty() && d != "-" {
            d.to_string()
        } else {
            let p = q_str(q, "dfid", "");
            if !p.is_empty() {
                p
            } else {
                let cv = c_str(q, "dfid");
                if !cv.is_empty() {
                    cv
                } else {
                    "-".to_string()
                }
            }
        }
    };
    let mid = {
        let d = dev_info.get("mid").and_then(|v| v.as_str()).unwrap_or("-");
        if !d.is_empty() && d != "-" {
            d.to_string()
        } else {
            let p = q_str(q, "mid", "");
            if !p.is_empty() {
                p
            } else {
                let cv = c_str(q, "KUGOU_API_MID");
                if !cv.is_empty() {
                    cv
                } else {
                    "-".to_string()
                }
            }
        }
    };
    let uuid = {
        let d = dev_info.get("uuid").and_then(|v| v.as_str()).unwrap_or("-");
        if !d.is_empty() && d != "-" {
            d.to_string()
        } else {
            let p = q_str(q, "uuid", "");
            if !p.is_empty() {
                p
            } else {
                let cv = c_str(q, "uuid");
                if !cv.is_empty() {
                    cv
                } else {
                    "-".to_string()
                }
            }
        }
    };
    let guid = {
        let d = dev_info.get("guid").and_then(|v| v.as_str()).unwrap_or("-");
        if !d.is_empty() && d != "-" {
            d.to_string()
        } else {
            let p = q_str(q, "guid", "");
            if !p.is_empty() {
                p
            } else {
                let cv = c_str(q, "KUGOU_API_GUID");
                if !cv.is_empty() {
                    cv
                } else {
                    "-".to_string()
                }
            }
        }
    };
    let server_dev = {
        let d = dev_info.get("serverDev").and_then(|v| v.as_str()).unwrap_or("-");
        if !d.is_empty() && d != "-" {
            d.to_string()
        } else {
            let cv = c_str(q, "KUGOU_API_DEV");
            if !cv.is_empty() {
                cv
            } else {
                "-".to_string()
            }
        }
    };
    let mac = {
        let d = dev_info.get("mac").and_then(|v| v.as_str()).unwrap_or("-");
        if !d.is_empty() && d != "-" {
            d.to_string()
        } else {
            let cv = c_str(q, "KUGOU_API_MAC");
            if !cv.is_empty() {
                cv
            } else {
                "-".to_string()
            }
        }
    };

    let pm = json!({
        "album_id": q_num(q, "album_id", 0),
        "area_code": 1,
        "hash": hash,
        "ssa_flag": "is_fromtrack",
        "version": 11430,
        "page_id": 967177915,
        "quality": quality,
        "album_audio_id": q_num(q, "album_audio_id", 0),
        "behavior": "play",
        "pid": 411,
        "cmd": 26,
        "pidversion": 3001,
        "IsFreePart": if q.get("free_part").is_some() { 1 } else { 0 },
        "ppage_id": ppage_id,
        "cdnBackup": 1,
        "module": "",
        "clientver": 11430,
    });

    // cookie merge: Object.assign({devices...}, params.cookie)
    let mut cookie = q_cookie(q);
    if let Some(m) = cookie.as_object_mut() {
        m.insert("dfid".to_string(), json!(dfid));
        m.insert("KUGOU_API_MID".to_string(), json!(mid));
        m.insert("uuid".to_string(), json!(uuid));
        m.insert("KUGOU_API_GUID".to_string(), json!(guid));
        m.insert("KUGOU_API_DEV".to_string(), json!(server_dev));
        m.insert("KUGOU_API_MAC".to_string(), json!(mac));
    }

    let opts = RequestOptions::new("/v5/url")
        .get("/v5/url")
        .params(pm)
        .encrypt_type("android")
        .encrypt_key(true)
        .header("x-router", "trackercdn.kugou.com")
        .cookie(cookie);
    ctx.send(&opts)
}
