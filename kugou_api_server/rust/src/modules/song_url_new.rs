//! song_url_new.js → /song/url/new（获取播放地址）。

use crate::cache::now_epoch_secs;
use crate::config::APP_ID;
use crate::crypto::crypto_md5_str;
use crate::modules::{c_str, param_or_cookie_str, q_cookie, q_truthy, q_str, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use crate::util::random_string;
use serde_json::{json, Map, Value};

pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
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
        "qualities": ["128", "320", "flac", "high", "multitrack", "viper_atmos", "viper_tape", "viper_clear", "super"],
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
    ctx.send(&opts)
}
