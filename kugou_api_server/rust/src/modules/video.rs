//! video 系列：detail / privilege / url
//! 对应 JS module/{video_detail,video_privilege,video_url}.js

use crate::cache::now_epoch_secs;
use crate::crypto::md5_hex_str;
use crate::helper::sign_params_key;
use crate::modules::{
    cookie_or_param_str, c_num, c_str, forward, q_cookie, q_str, Ctx,
};
use crate::request::{ModuleResponse, RequestOptions};
use serde_json::{json, Map, Value};

/// video_detail.js → /video/detail（视频详情）。
pub fn handle_detail(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let dfid = cookie_or_param_str(q, "dfid", "-");
    let mid = c_str(q, "KUGOU_API_MID");
    let mid_js = if mid.is_empty() { "undefined".to_string() } else { mid.clone() };
    let uuid = md5_hex_str(&format!("{}{}", dfid, mid_js));
    let token = {
        let p = q_str(q, "token", "");
        if !p.is_empty() {
            p
        } else {
            c_str(q, "token")
        }
    };
    let clienttime = now_epoch_secs().floor() as i64;
    let resource: Value = q_str(q, "id", "")
        .split(',')
        .map(|s| json!({ "video_id": s }))
        .collect::<Vec<_>>()
        .into();
    let mut m = Map::new();
    m.insert("appid".into(), json!(3116));
    m.insert("clientver".into(), json!(11440));
    m.insert("clienttime".into(), json!(clienttime));
    if !mid.is_empty() {
        m.insert("mid".into(), json!(mid));
    }
    m.insert("uuid".into(), json!(uuid));
    m.insert("dfid".into(), json!(dfid));
    m.insert("token".into(), json!(token));
    m.insert("key".into(), json!(sign_params_key(&clienttime.to_string(), "", "")));
    m.insert("show_resolution".into(), json!(1));
    m.insert("data".into(), resource);
    forward(
        q, ctx, "POST", "/v1/video", None, None, Some(Value::Object(m)), "android",
        &[("x-router", "kmr.service.kugou.com")], true, false,
    )
}

/// video_privilege.js → /video/privilege（视频特权）。
pub fn handle_privilege(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let dfid = c_str(q, "dfid");
    let dfid = if dfid.is_empty() { "-".to_string() } else { dfid };
    let mid = c_str(q, "KUGOU_API_MID");
    let resource: Value = q_str(q, "hash", "")
        .split(',')
        .map(|s| json!({ "hash": s, "id": 0, "name": "" }))
        .collect::<Vec<_>>()
        .into();
    let mut m = Map::new();
    m.insert("appid".into(), json!(3116));
    m.insert("area_code".into(), json!(1));
    m.insert("behavior".into(), json!("play"));
    m.insert("clientver".into(), json!(11440));
    m.insert("dfid".into(), json!(dfid));
    if !mid.is_empty() {
        m.insert("mid".into(), json!(mid));
    }
    m.insert("resource".into(), resource);
    m.insert("token".into(), json!(c_str(q, "token")));
    m.insert("userid".into(), json!(c_num(q, "userid", 0)));
    m.insert("vip".into(), json!(c_num(q, "vip_type", 0)));
    forward(
        q, ctx, "POST", "/v1/get_video_privilege", None, None, Some(Value::Object(m)), "android",
        &[("x-router", "media.store.kugou.com")], false, false,
    )
}

/// video_url.js → /video/url（视频 url）。
pub fn handle_url(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params = json!({
        "backupdomain": 1,
        "cmd": 123,
        "ext": "mp4",
        "ismp3": 0,
        "hash": q.get("hash").cloned().unwrap_or(Value::Null),
        "pid": 1,
        "type": 1,
    });
    let opts = RequestOptions::new("/v2/interface/index")
        .get("/v2/interface/index")
        .params(params)
        .encrypt_type("android")
        .encrypt_key(true)
        .cookie(q_cookie(q))
        .header("x-router", "trackermv.kugou.com");
    ctx.send(&opts)
}
