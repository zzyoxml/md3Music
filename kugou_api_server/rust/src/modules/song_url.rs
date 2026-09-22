//! song_url.js → /song/url（获取播放地址，v5/url，encryptKey）。
//! 与 song_url_new.js（/song/url/new）不同：走 trackercdn v5/url。

use crate::device::DeviceConfig;
use crate::modules::song_url_new::quality_from_bitrate;
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
    let mut res = ctx.send(&opts)?;

    // /v5/url 是按 quality 请求的：上游要么给该音质的链接、要么在 fail_process
    // 里标记 buy（由 Dart 侧拦掉）。链接到手即代表请求音质成立，把 quality 写回
    // data，供 Dart 侧如实标记实际音质。
    if let Some(obj) = res.body.as_mut_json() {
        // 与 Dart 侧 _extractData 的取值层级保持一致：有 data 就打在 data 上，
        // 没有 data 层时 Dart 会用整个响应体，后处理也必须打在同一层，
        // 否则 quality 字段丢失、实际音质被 fromJson 的默认值恒标成 128。
        if obj.get("data").is_some() {
            if let Some(data) = obj.get_mut("data") {
                let mut taken = std::mem::take(data);
                match &mut taken {
                    Value::Object(_) => stamp_quality(&mut taken, &quality),
                    Value::Array(a) => {
                        if let Some(first) = a.first_mut() {
                            stamp_quality(first, &quality);
                        }
                    }
                    _ => {}
                }
                *data = taken;
            }
        } else {
            match obj {
                Value::Object(_) => stamp_quality(obj, &quality),
                Value::Array(a) => {
                    if let Some(first) = a.first_mut() {
                        stamp_quality(first, &quality);
                    }
                }
                _ => {}
            }
        }
    }
    Ok(res)
}

/// 请求音质不可用时，上游常常**静默**给出一个更低音质的链接（而不是在
/// fail_process 里标 buy），所以不能盲信请求值——用 bitRate 反推真实档位。
/// 只有拿不到码率时才沿用请求值。
fn stamp_quality(data: &mut Value, quality: &str) {
    if data.get("url").is_none() {
        return;
    }
    let has_bitrate = data
        .get("bitRate")
        .or_else(|| data.get("bit_rate"))
        .and_then(|v| v.as_f64())
        .map(|br| br > 0.0)
        .unwrap_or(false);
    let actual = if has_bitrate {
        quality_from_bitrate(data).to_string()
    } else {
        quality.to_string()
    };
    if let Some(m) = data.as_object_mut() {
        m.insert("quality".to_string(), json!(actual));
    }
}
