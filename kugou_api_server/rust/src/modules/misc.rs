//! misc 系列：song_climax / song_ranking / song_ranking_filter / songlist_add / privilege_lite /
//! favorite_count / lastest_songs_listen / captcha_sent / singer_list
//! 对应 JS module/{song_climax,song_ranking,song_ranking_filter,songlist_add,privilege_lite,favorite_count,lastest_songs_listen,captcha_sent,singer_list}.js

use crate::modules::{forward, q_cookie, q_num, q_str, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use crate::util::js_string;
use serde_json::{json, Value};

/// song_climax.js → /song/climax（音频高潮部分）。
pub fn handle_song_climax(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let data = q_str(q, "hash", "")
        .split(',')
        .map(|s| json!({ "hash": s }))
        .collect::<Vec<_>>();
    let params = json!({ "data": crate::util::json_stringify(&json!(data)) });
    forward(
        q, ctx, "GET", "/v1/audio_climax/audio", Some("https://expendablekmrcdn.kugou.com"),
        Some(params), None, "android", &[], false, false,
    )
}

/// song_ranking.js → /song/ranking（歌曲成绩单）。
pub fn handle_song_ranking(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params = json!({ "album_audio_id": q.get("album_audio_id").cloned().unwrap_or(Value::Null) });
    forward(
        q, ctx, "GET", "/grow/v1/song_ranking/play_page/ranking_info", None,
        Some(params), None, "android", &[], false, false,
    )
}

/// song_ranking_filter.js → /song/ranking/filter（成绩单筛选）。
pub fn handle_song_ranking_filter(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params = json!({
        "album_audio_id": q.get("album_audio_id").cloned().unwrap_or(Value::Null),
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
    });
    forward(
        q, ctx, "GET", "/grow/v1/song_ranking/unlock/v2/ranking_filter", None,
        Some(params), None, "android", &[], false, false,
    )
}

/// songlist_add.js → /songlist/add（收藏专辑）。
pub fn handle_songlist_add(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid: i64 = q_num(q, "userid", 0);
    let token = q_str(q, "token", "");
    let data_map = json!({
        "userid": userid,
        "token": token,
        "name": q_str(q, "name", ""),
        "type": q_num(q, "type", 1),
        "source": q_num(q, "source", 2),
        "is_pri": 0,
        "list_create_userid": q_num(q, "list_create_userid", 0),
        "list_create_listid": q_num(q, "list_create_listid", 0),
        "list_create_gid": q_str(q, "list_create_gid", ""),
        "total_ver": 0,
        "from_shupinmv": 0,
    });
    forward(
        q, ctx, "POST", "/v2/songlist/add", None,
        None, Some(data_map), "android", &[], false, false,
    )
}

/// privilege_lite.js → /privilege/lite（歌曲权限信息）。
pub fn handle_privilege_lite(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let mut resource = q_str(q, "hash", "")
        .split(',')
        .map(|s| json!({ "type": "audio", "page_id": 0, "hash": s, "album_id": 0 }))
        .collect::<Vec<_>>();
    let album_ids = q_str(q, "album_id", "");
    for (i, s) in album_ids.split(',').enumerate() {
        if let Some(item) = resource.get_mut(i) {
            if let Some(m) = item.as_object_mut() {
                m.insert("album_id".to_string(), json!(s));
            }
        }
    }
    let data_map = json!({
        "appid": 3116,
        "area_code": 1,
        "behavior": "play",
        "clientver": 11440,
        "need_hash_offset": 1,
        "relate": 1,
        "support_verify": 1,
        "resource": json!(resource),
        "qualities": ["128", "320", "flac", "high", "viper_atmos", "viper_tape", "viper_clear", "super", "multitrack"],
    });
    forward(
        q, ctx, "POST", "/v2/get_res_privilege/lite", None,
        None, Some(data_map), "android",
        &[("x-router", "media.store.kugou.com"), ("Content-Type", "application/json")],
        false, false,
    )
}

/// favorite_count.js → /favorite/count（收藏数）。
pub fn handle_favorite_count(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params = json!({ "mixsongids": q.get("mixsongids").cloned().unwrap_or(Value::Null) });
    forward(
        q, ctx, "GET", "/count/v1/audio/mget_collect", None,
        Some(params), None, "android", &[], false, false,
    )
}

/// lastest_songs_listen.js → /lastest/songs/listen（继续播放信息）。
pub fn handle_lastest_songs_listen(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let token = {
        let p = q_str(q, "token", "");
        if !p.is_empty() {
            p
        } else {
            crate::modules::c_str(q, "token")
        }
    };
    let userid: i64 = q_num(q, "userid", 0);
    let data_map = json!({
        "area_code": "1",
        "sources": ["pc", "mobile", "tv", "car"],
        "userid": userid,
        "ret_info": 1,
        "token": token,
        "pagesize": q_num(q, "pagesize", 30),
    });
    forward(
        q, ctx, "POST", "/playque/devque/v1/get_latest_songs", None,
        None, Some(data_map), "android", &[], false, false,
    )
}

/// captcha_sent.js → /captcha/sent（手机验证码发送）。
pub fn handle_captcha_sent(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let data_map = json!({
        "businessid": 5,
        "mobile": q_str(q, "mobile", "undefined"),
        "plat": 3,
    });
    let mut cookie = q_cookie(q);
    let mid = crate::modules::c_str(q, "KUGOU_API_MID");
    if let Some(m) = cookie.as_object_mut() {
        m.clear();
        m.insert("mid".to_string(), json!(mid));
    }
    let opts = RequestOptions::new("/v7/send_mobile_code")
        .post("/v7/send_mobile_code")
        .base_url("http://login.user.kugou.com")
        .json_body(data_map)
        .encrypt_type("android")
        .cookie(cookie);
    ctx.send(&opts)
}

/// singer_list.js → /singer/list（歌手列表，nullish 默认）。
pub fn handle_singer_list(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let hotsize = q.get("hotsize").filter(|v| !v.is_null()).map(|v| js_string(Some(v))).unwrap_or_else(|| "200".to_string());
    let sextype = q.get("sextype").filter(|v| !v.is_null()).map(|v| js_string(Some(v))).unwrap_or_else(|| "0".to_string());
    let type_ = q.get("type").filter(|v| !v.is_null()).map(|v| js_string(Some(v))).unwrap_or_else(|| "0".to_string());
    let params = json!({
        "hotsize": hotsize,
        "musician": 0,
        "sextype": sextype,
        "showtype": 2,
        "type": type_,
    });
    forward(
        q, ctx, "GET", "/ocean/v6/singer/list", None,
        Some(params), None, "android", &[], false, false,
    )
}
