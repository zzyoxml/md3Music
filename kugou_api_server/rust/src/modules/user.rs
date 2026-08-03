//! user 系列：cloud / cloud_url / detail / follow / follow_message /
//! history / listen / playlist / video_collect / video_love / vip_detail
//! 对应 JS module/user*.js

use crate::cache::now_epoch_secs;
use crate::config::{APP_ID, CLIENT_VER};
use crate::crypto::{
    base64_decode, crypto_rsa_encrypt, playlist_aes_decrypt, playlist_aes_encrypt, rsa_encrypt2,
};
use crate::helper::{sign_cloud_key, sign_params_key};
use crate::modules::{
    c_str, cookie_or_param_str, forward, param_or_cookie_str, q_cookie, q_num, q_raw_or, q_str,
    Ctx,
};
use crate::request::{BodyValue, ModuleResponse, RequestOptions};
use crate::util::json_stringify;
use serde_json::{json, Map, Value};

fn now_secs() -> i64 {
    now_epoch_secs() as i64
}

/// JS `cryptoRSAEncrypt({...}).toUpperCase()`。
fn rsa_pk_upper(obj: &Value) -> String {
    crypto_rsa_encrypt(&json_stringify(obj), None).to_uppercase()
}

/// user_cloud.js → /user/cloud（云盘歌曲列表，playlistAES + arraybuffer）。
pub fn handle_cloud(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    // JS `params?.userid || params?.cookie?.userid || 0`：保留字符串原值，
    // 全部缺失时才用数字 0。强转 i64 会让 RSA/AES 明文与 JS 版不一致，鉴权失败。
    let userid_raw = param_or_cookie_str(q, "userid", "");
    let userid: Value = if userid_raw.is_empty() { json!(0) } else { json!(userid_raw) };
    let token = param_or_cookie_str(q, "token", "");
    let mid = c_str(q, "KUGOU_API_MID");
    let clienttime = now_secs();

    // dataMap：JS `params.page ?? 1` / `params.pagesize ?? 30` 保留原始字符串，
    // 缺失时才用数字默认值（与 JSON.stringify 明文逐字节一致）。
    let dm = json!({
        "page": q_raw_or(q, "page", json!(1)),
        "pagesize": q_raw_or(q, "pagesize", json!(30)),
        "getkmr": 1,
    });
    let (key, aes_str) = playlist_aes_encrypt(&json_stringify(&dm));
    let p = rsa_encrypt2(&json_stringify(&json!({ "aes": key, "uid": userid, "token": token })))
        .to_uppercase();

    let mut pm: Map<String, Value> = Map::new();
    pm.insert("clienttime".to_string(), json!(clienttime));
    if !mid.is_empty() {
        pm.insert("mid".to_string(), json!(mid));
    }
    pm.insert(
        "key".to_string(),
        json!(sign_params_key(&clienttime.to_string(), APP_ID, "")),
    );
    pm.insert("clientver".to_string(), json!(CLIENT_VER));
    pm.insert("appid".to_string(), json!(APP_ID));
    pm.insert("p".to_string(), json!(p));

    let opts = RequestOptions::new("/v1/get_list")
        .base_url("https://mcloudservice.kugou.com")
        .post("/v1/get_list")
        .params(Value::Object(pm.clone()))
        .bytes_body(base64_decode(&aes_str))
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .response_type("arraybuffer")
        .clear_default_params(true)
        .not_signature(true);
    let res = ctx.send(&opts)?;
    let dec = playlist_aes_decrypt(&key, &res.body.to_base64());
    eprintln!(
        "[CLOUD-DEBUG] status={} params={} p_len={} dec={}",
        res.status,
        json_stringify(&Value::Object(pm)),
        p.len(),
        json_stringify(&dec)
    );
    Ok(ModuleResponse {
        status: res.status,
        body: BodyValue::Json(dec),
        cookie: res.cookie,
        headers: res.headers,
    })
}

/// user_cloud_url.js → /user/cloud/url（获取云盘音乐 URL）。
pub fn handle_cloud_url(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let hash = q_str(q, "hash", "").to_ascii_lowercase();
    let pm = json!({
        "hash": hash,
        "ssa_flag": "is_fromtrack",
        "version": "20102",
        "ssl": 0,
        // JS `params.album_audio_id ?? 0` / `params.audio_id ?? 0`：
        // 保留原始字符串（云盘上传歌曲依赖该字段），缺失才用数字 0。
        "album_audio_id": q_raw_or(q, "album_audio_id", json!(0)),
        "pid": 20026,
        "audio_id": q_raw_or(q, "audio_id", json!(0)),
        // 云盘文件各自有 kv_id（列表接口返回），请求音质需与文件匹配，
        // 支持前端透传 kv_id，默认 2（JS 版历史默认值）。
        "kv_id": q_raw_or(q, "kv_id", json!(2)),
        "key": sign_cloud_key(&hash, "20026"),
        "bucket": "musicclound",
        "name": q_str(q, "name", ""),
        "with_res_tag": 0,
    });
    forward(
        q, ctx, "GET", "/bsstrackercdngz/v2/query_musicclound_url", None,
        Some(pm), None, "android", &[], false, false,
    )
}

/// user_detail.js → /user/detail（获取用户信息）。
pub fn handle_detail(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let token = param_or_cookie_str(q, "token", "");
    let userid = param_or_cookie_str(q, "userid", "0")
        .trim()
        .parse::<i64>()
        .unwrap_or(0);
    let clienttime = now_secs();
    let pk = rsa_pk_upper(&json!({ "token": token, "clienttime": clienttime }));
    let dm = json!({
        "visit_time": clienttime,
        "usertype": 1,
        "p": pk,
        "userid": userid,
    });
    forward(
        q, ctx, "POST", "/v3/get_my_info", None,
        Some(json!({ "plat": 1 })), Some(dm), "android", &[("x-router", "usercenter.kugou.com")], false, false,
    )
}

/// user_follow.js → /user/follow（获取用户关注的歌手）。
pub fn handle_follow(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let token = param_or_cookie_str(q, "token", "");
    let userid = param_or_cookie_str(q, "userid", "0");
    let clienttime = now_secs();
    let dm = json!({
        "merge": 2,
        "need_iden_type": 1,
        "ext_params": "k_pic,jumptype,singerid,score",
        "userid": userid,
        "type": 0,
        "id_type": 0,
        "p": rsa_pk_upper(&json!({ "clienttime": clienttime, "token": token })),
    });
    forward(
        q, ctx, "POST", "/v4/follow_list", None,
        Some(json!({ "plat": 1 })), Some(dm), "android", &[("x-router", "relationuser.kugou.com")], false, false,
    )
}

/// user_follow_message.js → /user/follow/message（关注歌手的消息）。
pub fn handle_follow_message(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = param_or_cookie_str(q, "userid", "0");
    let id = q_str(q, "id", "");
    let pm = json!({
        "filter": 1,
        "maxid": 0,
        "pagesize": q_num(q, "pagesize", 30),
        "tag": format!("chat:{}_{}", userid, id),
    });
    forward(
        q, ctx, "GET", "/msg.mobile/v3/msgtag/history", None,
        Some(pm), None, "android", &[], false, false,
    )
}

/// user_history.js → /user/history（用户听歌排行）。
pub fn handle_history(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = param_or_cookie_str(q, "userid", "0")
        .trim()
        .parse()
        .unwrap_or(0);
    let token = param_or_cookie_str(q, "token", "");
    let mut dm: Map<String, Value> = Map::new();
    dm.insert("token".to_string(), json!(token));
    dm.insert("userid".to_string(), json!(userid));
    dm.insert("source_classify".to_string(), json!("app"));
    dm.insert("to_subdivide_sr".to_string(), json!(1));
    if let Some(v) = q.get("bp") {
        if !v.is_null() {
            dm.insert("bp".to_string(), v.clone());
        }
    }
    forward(
        q, ctx, "POST", "/playhistory/v1/get_songs", None, None,
        Some(Value::Object(dm)), "android", &[], false, false,
    )
}

/// user_listen.js → /user/listen（用户听歌列表）。
pub fn handle_listen(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let token = param_or_cookie_str(q, "token", "");
    let userid = param_or_cookie_str(q, "userid", "0");
    let clienttime = now_secs();
    let p = rsa_pk_upper(&json!({ "clienttime": clienttime, "token": token }));
    let dm = json!({
        "t_userid": userid,
        "userid": userid,
        "list_type": q_num(q, "type", 0),
        "area_code": 1,
        "cover": 2,
        "p": p,
    });
    forward(
        q, ctx, "POST", "/v2/get_list", Some("https://listenservice.kugou.com"),
        Some(json!({ "clienttime": clienttime, "plat": 0 })), Some(dm), "android", &[], false, false,
    )
}

/// user_playlist.js → /user/playlist（获取用户歌单）。
pub fn handle_playlist(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = cookie_or_param_str(q, "userid", "0");
    let token = cookie_or_param_str(q, "token", "");
    let dm = json!({
        "userid": userid,
        "token": token,
        "total_ver": 979,
        "type": q_num(q, "type", 2),
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
    });
    forward(
        q, ctx, "post", "/v7/get_all_list", None,
        Some(json!({ "plat": 1, "userid": userid.trim().parse::<i64>().unwrap_or(0), "token": token })),
        Some(dm), "android", &[("x-router", "cloudlist.service.kugou.com")], false, false,
    )
}

/// user_video_collect.js → /user/video/collect（收藏的视频）。
pub fn handle_video_collect(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = param_or_cookie_str(q, "userid", "0");
    let token = param_or_cookie_str(q, "token", "");
    let dm = json!({
        "userid": userid,
        "token": token,
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
    });
    forward(
        q, ctx, "POST", "/collectservice/v2/collect_list_mixvideo", None,
        Some(json!({ "plat": 1 })), Some(dm), "android", &[], false, false,
    )
}

/// user_video_love.js → /user/video/love（点赞的视频）。
pub fn handle_video_love(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = param_or_cookie_str(q, "userid", "0");
    let pm = json!({
        "kugouid": userid,
        "pagesize": q_num(q, "pagesize", 30),
        "load_video_info": 1,
        "p": 1,
        "plat": 1,
    });
    forward(
        q, ctx, "get", "/m.comment.service/v1/get_user_like_video", None,
        Some(pm), None, "android", &[], false, false,
    )
}

/// user_vip_detail.js → /user/vip/detail（联合 VIP 信息）。
pub fn handle_vip_detail(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q, ctx, "GET", "/v1/get_union_vip", Some("https://kugouvip.kugou.com"),
        Some(json!({ "busi_type": "concept" })), None, "android", &[], false, false,
    )
}
