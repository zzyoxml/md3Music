//! audio.js → /audio（歌曲信息）。

use crate::cache::now_epoch_secs;
use crate::helper::sign_params_key;
use crate::modules::{cookie_or_param_num, cookie_or_param_str, c_str, q_cookie, q_str, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use serde_json::{json, Map, Value};

pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let date_time = (now_epoch_secs() * 1000.0) as i64;
    let data: Value = q_str(q, "hash", "")
        .split(',')
        .map(|s| json!({ "hash": s, "audio_id": 0 }))
        .collect::<Vec<_>>()
        .into();
    let dfid = cookie_or_param_str(q, "dfid", "-");
    let userid = cookie_or_param_num(q, "userid", 0);
    let token = cookie_or_param_str(q, "token", "");
    let mid = c_str(q, "KUGOU_API_MID");

    let mut data_map = Map::new();
    data_map.insert("appid".to_string(), json!(3116));
    data_map.insert("clienttime".to_string(), json!(date_time));
    data_map.insert("clientver".to_string(), json!(11440));
    data_map.insert("data".to_string(), data);
    data_map.insert("dfid".to_string(), json!(dfid));
    data_map.insert("key".to_string(), json!(sign_params_key(&date_time.to_string(), "", "")));
    if !mid.is_empty() {
        data_map.insert("mid".to_string(), json!(mid));
    }
    if !token.is_empty() {
        data_map.insert("token".to_string(), json!(token));
    }
    if userid != 0 {
        data_map.insert("userid".to_string(), json!(userid));
    }

    let opts = RequestOptions::new("/v1/audio/audio")
        .base_url("http://kmr.service.kugou.com")
        .post("/v1/audio/audio")
        .json_body(Value::Object(data_map))
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .header("x-router", "kmr.service.kugou.com")
        .header("Content-Type", "application/json");
    ctx.send(&opts)
}
