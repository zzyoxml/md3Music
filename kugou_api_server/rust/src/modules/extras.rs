//! 独立推荐/工具模块：ai_recommend / brush / playhistory_upload
//! 对应 JS module/{ai_recommend,brush,playhistory_upload}.js

use crate::cache::now_epoch_secs;
use crate::helper::sign_params_key;
use crate::modules::{
    cookie_or_param_num, c_num, c_str, forward, param_or_cookie_num, q_cookie, q_num, q_str, Ctx,
};
use crate::request::{ModuleResponse, RequestOptions};
use serde_json::{json, Map, Value};

/// ai_recommend.js → /ai/recommend
pub fn handle_ai_recommend(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = param_or_cookie_num(q, "userid", 0);
    let mid = c_str(q, "KUGOU_API_MID");
    let clienttime = (now_epoch_secs() * 1000.0) as i64;
    let recommend_source: Value = q_str(q, "album_audio_id", "")
        .split(',')
        .map(|s| json!({ "ID": s.parse::<i64>().unwrap_or(0) }))
        .collect::<Vec<_>>()
        .into();
    let mut m = Map::new();
    m.insert("platform".into(), json!("ios"));
    m.insert("clientver".into(), json!(11440));
    m.insert("clienttime".into(), json!(clienttime));
    m.insert("userid".into(), json!(userid));
    m.insert("client_playlist".into(), json!([]));
    m.insert("source_type".into(), json!(2));
    m.insert("playlist_ver".into(), json!(2));
    m.insert("area_code".into(), json!(1));
    m.insert("appid".into(), json!(3116));
    m.insert("key".into(), json!(sign_params_key(&clienttime.to_string(), "", "")));
    if !mid.is_empty() {
        m.insert("mid".into(), json!(mid));
    }
    m.insert("recommend_source".into(), recommend_source);
    forward(
        q, ctx, "POST", "/recommend", None, None, Some(Value::Object(m)), "android",
        &[("x-router", "songlistairec.kugou.com")], true, false,
    )
}

/// brush.js → /brush（刷一刷）。
pub fn handle_brush(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = cookie_or_param_num(q, "userid", 0);
    let vip_type = {
        let c = c_num(q, "vip_type", 0);
        if c != 0 {
            c
        } else {
            q_num(q, "vipType", 0)
        }
    };
    let date_time = (now_epoch_secs() * 1000.0) as i64;
    let mid = c_str(q, "KUGOU_API_MID");
    let song_pool_id = q_num(q, "song_pool_id", 0);
    let mut pr = Map::new();
    pr.insert("userid".into(), json!(userid));
    pr.insert("appid".into(), json!(3116));
    pr.insert("playlist_ver".into(), json!(2));
    pr.insert("clienttime".into(), json!(date_time));
    if !mid.is_empty() {
        pr.insert("mid".into(), json!(mid));
    }
    pr.insert("new_sync_point".into(), json!(date_time));
    pr.insert("module_id".into(), json!(1));
    pr.insert("action".into(), json!("login"));
    pr.insert("vip_type".into(), json!(vip_type));
    pr.insert("vip_flags".into(), json!(3));
    pr.insert("recommend_source_locked".into(), json!(0));
    pr.insert("song_pool_id".into(), json!(song_pool_id));
    pr.insert("callerid".into(), json!(0));
    pr.insert("m_type".into(), json!(1));
    pr.insert("kguid".into(), json!(userid));
    pr.insert("platform".into(), json!("ios"));
    pr.insert("area_code".into(), json!(1));
    pr.insert("fakem".into(), json!("ca981cfc583a4c37f28d2d49000013c16a0a"));
    pr.insert("clientver".into(), json!(11850));
    pr.insert("mode".into(), json!(q_str(q, "mode", "normal")));
    pr.insert("active_swtich".into(), json!("on"));
    pr.insert("key".into(), json!(sign_params_key(&date_time.to_string(), "", "")));
    let body = json!({
        "behaviors": [],
        "abtest": { "abtest": { "shuashua": { "commentcard": 2 } } },
        "personal_recommend_params": Value::Object(pr),
    });
    let params = json!({ "sort_type": 1, "platform": "ios", "page": 1, "content_ver": 4, "clientver": 11850 });
    forward(
        q, ctx, "POST", "/genesisapi/v1/newepoch_song_rec/feed", None,
        Some(params), Some(body), "android", &[], false, false,
    )
}

/// playhistory_upload.js → /playhistory/upload（提交听歌历史）。
pub fn handle_playhistory_upload(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = param_or_cookie_num(q, "userid", 0);
    let token = {
        let p = q_str(q, "token", "");
        if !p.is_empty() {
            p
        } else {
            c_str(q, "token")
        }
    };
    let mxid: Value = match q.get("mxid") {
        Some(Value::Number(n)) => json!(n.as_i64().unwrap_or(0)),
        Some(Value::String(s)) => match s.parse::<i64>() {
            Ok(v) => json!(v),
            Err(_) => Value::Null,
        },
        _ => Value::Null,
    };
    let ot = {
        let p = q_str(q, "time", "");
        if !p.is_empty() {
            p.parse::<i64>().unwrap_or(now_epoch_secs().floor() as i64)
        } else {
            now_epoch_secs().floor() as i64
        }
    };
    let pc = q_num(q, "pc", 1);
    let songs = json!([{ "mxid": mxid, "op": 1, "ot": ot, "pc": pc }]);
    let body = json!({ "songs": songs, "token": token, "userid": userid });
    let opts = RequestOptions::new("/playhistory/v1/upload_songs")
        .post("/playhistory/v1/upload_songs")
        .json_body(body)
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .params(json!({ "plat": 3 }));
    ctx.send(&opts)
}
