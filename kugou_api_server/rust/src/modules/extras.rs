//! 独立推荐/工具模块：ai_recommend / brush / playhistory_upload
//! 对应 JS module/{ai_recommend,brush,playhistory_upload}.js

use crate::cache::now_epoch_secs;
use crate::helper::{sign_params_key, sign_params_key_standard};
use crate::modules::{
    cookie_or_param_str, c_num, c_str, forward, param_or_cookie_num, q_cookie, q_num, q_str, Ctx,
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
    // 对齐 JS brush.js：userid 取自 cookie 时是字符串，酷狗 feed 接口对类型敏感，
    // 用数字会返回空 feed。非零时保留字符串原值，回退数用数字 0。
    let userid_raw = cookie_or_param_str(q, "userid", "0");
    let userid: Value = if userid_raw.is_empty() || userid_raw == "0" {
        json!(0)
    } else {
        json!(userid_raw)
    };
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
    pr.insert("userid".into(), userid.clone());
    // 刷刷 feed 接口只认标准版 appid(1005)，用概念版 appid(3116) 会返回空 list。
    // 实测：/brush 用 appid=1005 有数据，appid=3116 返回 data.list=[]。
    pr.insert("appid".into(), json!(1005));
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
    pr.insert("kguid".into(), userid.clone());
    pr.insert("platform".into(), json!("ios"));
    pr.insert("area_code".into(), json!(1));
    pr.insert("fakem".into(), json!("ca981cfc583a4c37f28d2d49000013c16a0a"));
    pr.insert("clientver".into(), json!(11850));
    pr.insert("mode".into(), json!(q_str(q, "mode", "normal")));
    pr.insert("active_swtich".into(), json!("on"));
    // key 用标准版签名（appid=1005 + 标准盐 + clientver=20489），否则上游报 20006 签名错误。
    pr.insert("key".into(), json!(sign_params_key_standard(&date_time.to_string())));
    let body = json!({
        "behaviors": [],
        "abtest": { "abtest": { "shuashua": { "commentcard": 2 } } },
        "personal_recommend_params": Value::Object(pr),
    });
    // 刷刷 feed 不是标准分页，而是 page 作为批次游标（每次随机返回 0~3 条）。
    // 前端可递增 page 连续请求，合并去重来积累多条。
    let page = q_num(q, "page", 1);
    let params = json!({ "sort_type": 1, "platform": "ios", "page": page, "content_ver": 4, "clientver": 11850, "appid": 1005 });
    // 刷刷 feed 用 appid=1005（标准版），query signature 与 body key 都必须用标准盐，
    // 因此不用 forward（其默认用概念版签名），手动构建 RequestOptions 并开启 standard_signature。
    let opts = RequestOptions::new("/genesisapi/v1/newepoch_song_rec/feed")
        .post("/genesisapi/v1/newepoch_song_rec/feed")
        .params(params)
        .json_body(body)
        .encrypt_type("android")
        .standard_signature(true)
        .cookie(q_cookie(q));
    ctx.send(&opts)
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
