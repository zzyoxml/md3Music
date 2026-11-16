//! images 系列：images / images/audio
//! 对应 JS module/{images,images_audio}.js

use crate::helper::signature_android_params;
use crate::modules::{q_cookie, q_num, q_str, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use crate::util::{encode_uri_component, json_stringify};
use serde_json::{json, Value};

/// 构造 paramsMap 序列化查询串（JS `Object.keys(pm).sort().map(k=>`${k}=${encodeURIComponent(...)}`).join('&')`）。
fn build_query(pm: &Value) -> String {
    let mut keys: Vec<&String> = match pm.as_object() {
        Some(m) => m.keys().collect(),
        None => return String::new(),
    };
    keys.sort();
    keys.iter()
        .map(|k| {
            let v = pm.get(*k).unwrap_or(&Value::Null);
            let vs = match v {
                Value::Object(_) | Value::Array(_) => json_stringify(v),
                Value::String(s) => s.clone(),
                Value::Number(n) => n.to_string(),
                Value::Bool(b) => b.to_string(),
                Value::Null => "null".to_string(),
            };
            format!("{}={}", k, encode_uri_component(&vs))
        })
        .collect::<Vec<_>>()
        .join("&")
}

/// images.js → /images
pub fn handle_images(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let mut data: Vec<Value> = q_str(q, "hash", "")
        .split(',')
        .map(|s| json!({ "album_id": 0, "hash": s, "album_audio_id": 0 }))
        .collect();
    let album_ids: Vec<String> = q_str(q, "album_id", "").split(',').map(String::from).collect();
    for (i, s) in album_ids.iter().enumerate() {
        if i < data.len() {
            data[i]["album_id"] = if s.is_empty() { json!(0) } else { json!(s) };
        }
    }
    let album_audio_ids: Vec<String> = q_str(q, "album_audio_id", "").split(',').map(String::from).collect();
    for (i, s) in album_audio_ids.iter().enumerate() {
        if i < data.len() {
            data[i]["album_audio_id"] = if s.is_empty() { json!(0) } else { json!(s) };
        }
    }
    let pm = json!({
        "album_image_type": "-3",
        "appid": 3116,
        "clientver": 11440,
        "author_image_type": "3,4,5",
        "count": q_num(q, "count", 5),
        "data": data,
        "isCdn": 1,
        "publish_time": 1,
    });
    let query = build_query(&pm);
    let signature = signature_android_params(&pm, &[], false);
    let url = format!("/container/v2/image?{}", query);
    let opts = RequestOptions::new(&url)
        .get(&url)
        .base_url("https://expendablekmr.kugou.com")
        .params(json!({ "signature": signature }))
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .clear_default_params(true)
        .not_sign(true);
    ctx.send(&opts)
}

/// images_audio.js → /images/audio
pub fn handle_images_audio(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let mut data: Vec<Value> = q_str(q, "hash", "")
        .split(',')
        .map(|s| json!({ "audio_id": 0, "hash": s, "album_audio_id": 0, "filename": "" }))
        .collect();
    let audio_ids: Vec<String> = q_str(q, "audio_id", "").split(',').map(String::from).collect();
    for (i, s) in audio_ids.iter().enumerate() {
        if i < data.len() {
            data[i]["audio_id"] = if s.is_empty() { json!(0) } else { json!(s) };
        }
    }
    let album_audio_ids: Vec<String> = q_str(q, "album_audio_id", "").split(',').map(String::from).collect();
    for (i, s) in album_audio_ids.iter().enumerate() {
        if i < data.len() {
            data[i]["album_audio_id"] = if s.is_empty() { json!(0) } else { json!(s) };
        }
    }
    let filenames: Vec<String> = q_str(q, "filename", "").split(',').map(String::from).collect();
    for (i, s) in filenames.iter().enumerate() {
        if i < data.len() {
            data[i]["filename"] = json!(s);
        }
    }
    let pm = json!({
        "appid": 3116,
        "clientver": 11440,
        "count": q_num(q, "count", 5),
        "data": data,
        "isCdn": 1,
        "publish_time": 1,
        "show_authors": 1,
    });
    let query = build_query(&pm);
    let signature = signature_android_params(&pm, &[], false);
    let url = format!("/v2/author_image/audio?{}", query);
    let opts = RequestOptions::new(&url)
        .get(&url)
        .base_url("https://expendablekmr.kugou.com")
        .params(json!({ "signature": signature }))
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .clear_default_params(true)
        .not_sign(true);
    ctx.send(&opts)
}
