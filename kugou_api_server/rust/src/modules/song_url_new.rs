//! song_url_new.js → /song/url/new（获取播放地址）。

use crate::cache::now_epoch_secs;
use crate::config::APP_ID;
use crate::crypto::crypto_md5_str;
use crate::modules::{c_str, param_or_cookie_str, q_cookie, q_truthy, q_str, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use crate::util::random_string;
use serde_json::{json, Map, Value};

/// 上传给 /v6/priv_url 的音质档位，顺序即 upstream 返回 url 数组的下标顺序。
const QUALITIES: [&str; 9] = [
    "128",
    "320",
    "flac",
    "high",
    "multitrack",
    "viper_atmos",
    "viper_tape",
    "viper_clear",
    "super",
];

pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    // JS `params.quality || 128`：请求体里没有 quality 字段，这里取出来只用于
    // 从响应的 url 数组中挑出对应档位（见 apply_quality）。
    let quality = q_str(q, "quality", "128");
    let vip_token = param_or_cookie_str(q, "vip_token", "");
    let token = param_or_cookie_str(q, "token", "");
    let clienttime_ms = (now_epoch_secs() * 1000.0) as i64;
    let userid: i64 = param_or_cookie_str(q, "userid", "0").trim().parse().unwrap_or(0);
    let dfid = {
        let p = q_str(q, "dfid", "");
        if !p.is_empty() {
            p
        } else {
            let cv = c_str(q, "dfid");
            if !cv.is_empty() {
                cv
            } else {
                random_string(24)
            }
        }
    };

    // Number(params?.cookie?.vip_type || params?.vipType || 0)
    let cookie_vip_type: i64 = {
        let cv = c_str(q, "vip_type");
        if !cv.is_empty() {
            cv.trim().parse().unwrap_or(0)
        } else {
            q_str(q, "vipType", "0").trim().parse().unwrap_or(0)
        }
    };
    let vip_type = if vip_token.is_empty() {
        cookie_vip_type
    } else if cookie_vip_type != 0 {
        cookie_vip_type
    } else {
        6
    };

    let hash = q.get("hash").map(|v| crate::util::js_string(Some(v)));
    let mid = c_str(q, "KUGOU_API_MID");
    let mid = if mid.is_empty() { "undefined".to_string() } else { mid };
    let hash_key = hash.unwrap_or_else(|| "undefined".to_string());

    let mut resource = Map::new();
    if let Some(v) = q.get("album_audio_id") {
        if !v.is_null() {
            resource.insert("album_audio_id".to_string(), v.clone());
        }
    }
    resource.insert("collect_list_id".to_string(), json!("3"));
    resource.insert("collect_time".to_string(), json!(clienttime_ms));
    if let Some(v) = q.get("hash") {
        if !v.is_null() {
            resource.insert("hash".to_string(), v.clone());
        }
    }
    resource.insert("id".to_string(), json!(0));
    resource.insert("page_id".to_string(), json!(1));
    resource.insert("type".to_string(), json!("audio"));

    let data_map = json!({
        "area_code": "1",
        "behavior": "play",
        "qualities": QUALITIES.to_vec(),
        "resource": Value::Object(resource),
        "token": token,
        "tracker_param": {
            "all_m": 1,
            "auth": "",
            "is_free_part": if q_truthy(q, "free_part") { 1 } else { 0 },
            "key": crypto_md5_str(&format!(
                "{}185672dd44712f60bb1736df5a377e82{}{}{}",
                hash_key, APP_ID, mid, userid
            )),
            "module_id": 0,
            "need_climax": 1,
            "need_xcdn": 1,
            "open_time": "",
            "pid": "411",
            "pidversion": "3001",
            "priv_vip_type": "6",
            "viptoken": vip_token,
        },
        "userid": userid.to_string(),
        "vip": vip_type,
    });

    let mut cookie = q_cookie(q);
    if let Some(m) = cookie.as_object_mut() {
        m.insert("dfid".to_string(), json!(dfid.clone()));
    }

    let opts = RequestOptions::new("/v6/priv_url")
        .base_url("http://tracker.kugou.com")
        .post("/v6/priv_url")
        .json_body(data_map)
        .encrypt_type("android")
        .cookie(cookie);
    let mut res = ctx.send(&opts)?;

    if let Some(obj) = res.body.as_mut_json() {
        // 与 Dart 侧 _extractData 的取值层级保持一致：有 data 就打在 data 上，
        // 没有 data 层时 Dart 会用整个响应体，后处理也必须打在同一层。
        if obj.get("data").is_some() {
            if let Some(data) = obj.get_mut("data") {
                let mut taken = std::mem::take(data);
                match &mut taken {
                    Value::Object(_) => apply_quality(&mut taken, &quality),
                    Value::Array(a) => {
                        if let Some(first) = a.first_mut() {
                            apply_quality(first, &quality);
                        }
                    }
                    _ => {}
                }
                *data = taken;
            }
        } else {
            match obj {
                Value::Object(_) => apply_quality(obj, &quality),
                Value::Array(a) => {
                    if let Some(first) = a.first_mut() {
                        apply_quality(first, &quality);
                    }
                }
                _ => {}
            }
        }
    }
    Ok(res)
}

/// 从响应的 data.url 中挑出与请求音质对应的链接，并把真实音质写回 data.quality。
///
/// 上游请求体只有固定的 qualities 数组、没有 quality 字段，所以响应有两种语义：
///   a) url 数组与 qualities 一一对应 → 按下标取，取不到就往下退到第一个非空；
///   b) 只返回一个"当前账号可用的最高音质" → 只能用 bitRate 反推档位。
///
/// 两种情况都写成 data.url(String) + data.quality，Dart 侧据此如实标记，
/// 不再把请求值当成实际音质（原先会让 UI 在没有 Hi-Res 音源时也显示 Hi-Res）。
pub fn apply_quality(data: &mut Value, quality: &str) {
    let urls: Vec<String> = match data.get("url") {
        Some(Value::Array(a)) => a
            .iter()
            .map(|v| v.as_str().unwrap_or("").to_string())
            .collect(),
        Some(Value::String(s)) => vec![s.clone()],
        _ => return,
    };
    if urls.is_empty() {
        return;
    }

    let desired = QUALITIES.iter().position(|q| *q == quality);
    let indexed = urls.len() > 1;
    let idx = if indexed {
        let mut i = desired.unwrap_or(0).min(urls.len() - 1);
        while i > 0 && urls[i].is_empty() {
            i -= 1;
        }
        i
    } else {
        0
    };
    if urls[idx].is_empty() {
        return;
    }

    let actual = if indexed && desired == Some(idx) {
        QUALITIES[idx].to_string()
    } else {
        quality_from_bitrate(data).to_string()
    };

    if let Some(m) = data.as_object_mut() {
        m.insert("url".to_string(), json!(&urls[idx]));
        m.insert("quality".to_string(), json!(actual));
        m.insert("url_list".to_string(), json!(urls));
    }
}

/// 由码率反推音质档位：上游静默降质（请求音质不可用时直接给更低音质的链接，
/// 不在 fail_process 里标记）或只返回单一链接时使用。
///
/// 码率优先用 `fileSize * 8 / timeLength` 反算：这两个字段一定存在，且单位恒为 bps，
/// 不受上游 `bitRate` 字段口径（bps / kbps 混用）影响。真机实测两者高度吻合：
/// 3194531B/259s ≈ 98.6kbps 对 `bitRate=98337`；49649577B/233s ≈ 1704kbps 对 `bitRate=1702271`。
/// 拿不到时长才退回 `bitRate`，并用 extName 做容器格式的交叉校验。
pub fn quality_from_bitrate(data: &Value) -> &'static str {
    let file_size = data
        .get("fileSize")
        .or_else(|| data.get("file_size"))
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);
    let time_length = data
        .get("timeLength")
        .or_else(|| data.get("time_length"))
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);

    // 反算优先；其次 bitRate 字段（口径不统一，<1000 视为已经是 kbps）
    let mut bps = if file_size > 0.0 && time_length > 0.0 {
        file_size * 8.0 / time_length
    } else {
        0.0
    };
    if bps <= 0.0 {
        bps = data
            .get("bitRate")
            .or_else(|| data.get("bit_rate"))
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0);
        if bps > 0.0 && bps < 1000.0 {
            bps *= 1000.0;
        }
    }
    let kbps = bps / 1000.0;

    // 有损容器不可能是无损档位，用它兜住码率异常（如 96kbps 的 ogg 被算成高码率）
    let ext = data
        .get("extName")
        .or_else(|| data.get("extname"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if matches!(ext.as_str(), "ogg" | "mp3" | "aac" | "m4a" | "wma") {
        return if kbps <= 200.0 { "128" } else { "320" };
    }

    if kbps <= 200.0 {
        return "128";
    }
    if kbps <= 500.0 {
        return "320";
    }
    // CD 规格 FLAC（16bit/44.1k）约 1411kbps；24bit/96k Hi-Res 约 4600kbps
    if kbps > 1500.0 {
        return "high";
    }
    "flac"
}
