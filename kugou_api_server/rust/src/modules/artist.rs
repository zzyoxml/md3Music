//! artist 系列：detail / albums / audios / videos / lists / follow / unfollow / follow_newsongs / honour
//! 对应 JS module/{artist_*.js}

use crate::cache::now_epoch_secs;
use crate::crypto::{crypto_aes_encrypt, rsa_encrypt2};
use crate::helper::sign_params_key;
use crate::modules::{forward, q_cookie, q_num, q_str, c_str, param_or_cookie_num, Ctx};
use crate::request::ModuleResponse;
use crate::util::json_stringify;
use serde_json::{json, Map, Value};

/// artist_detail.js → /artist/detail（歌手详情）。
pub fn handle_detail(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q, ctx, "POST", "/kmr/v3/author", None,
        None, Some(json!({ "author_id": q.get("id").cloned().unwrap_or(Value::Null) })), "android",
        &[("x-router", "openapi.kugou.com"), ("kg-tid", "36")],
        false, false,
    )
}

/// artist_albums.js → /artist/albums（歌手专辑）。
pub fn handle_albums(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let data_map = json!({
        "author_id": q.get("id").cloned().unwrap_or(Value::Null),
        "pagesize": q_num(q, "pagesize", 30),
        "page": q_num(q, "page", 1),
        "sort": if q_str(q, "sort", "") == "hot" { 3 } else { 1 },
        "category": 1,
        "area_code": "all",
    });
    forward(
        q, ctx, "POST", "/kmr/v1/author/albums", None,
        None, Some(data_map), "android",
        &[("x-router", "openapi.kugou.com"), ("kg-tid", "36")],
        false, false,
    )
}

/// artist_audios.js → /artist/audios（歌手单曲）。
pub fn handle_audios(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let clienttime = now_epoch_secs() as i64;
    let mid = c_str(q, "KUGOU_API_MID");
    let mut data_map = Map::new();
    data_map.insert("appid".to_string(), json!(3116));
    data_map.insert("clientver".to_string(), json!(11440));
    if !mid.is_empty() {
        data_map.insert("mid".to_string(), json!(mid));
    }
    data_map.insert("clienttime".to_string(), json!(clienttime));
    data_map.insert("key".to_string(), json!(sign_params_key(&clienttime.to_string(), "", "")));
    data_map.insert("author_id".to_string(), q.get("id").cloned().unwrap_or(Value::Null));
    data_map.insert("pagesize".to_string(), json!(q_num(q, "pagesize", 30)));
    data_map.insert("page".to_string(), json!(q_num(q, "page", 1)));
    data_map.insert("sort".to_string(), json!(if q_str(q, "sort", "") == "hot" { 1 } else { 2 }));
    data_map.insert("area_code".to_string(), json!("all"));
    forward(
        q, ctx, "POST", "/kmr/v1/audio_group/author", Some("https://openapi.kugou.com"),
        None, Some(json!(data_map)), "android",
        &[("x-router", "openapi.kugou.com"), ("kg-tid", "220")],
        false, false,
    )
}

/// artist_videos.js → /artist/videos（歌手 MV，openapicdn 明文 query）。
fn tag_idx(tag: &str) -> String {
    match tag {
        "official" => "18".to_string(),
        "live" => "20".to_string(),
        "fan" => "23".to_string(),
        "artist" => "42419".to_string(),
        _ => String::new(),
    }
}

pub fn handle_videos(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params_map = json!({
        "author_id": q.get("id").cloned().unwrap_or(Value::Null),
        "is_fanmade": "",
        "tag_idx": tag_idx(&q_str(q, "tag", "all")),
        "pagesize": q_num(q, "pagesize", 30),
        "page": q_num(q, "page", 1),
    });
    forward(
        q, ctx, "GET", "/kmr/v1/author/videos", Some("https://openapicdn.kugou.com"),
        Some(params_map), None, "android", &[], false, false,
    )
}

/// artist_lists.js → /artist/lists（歌手列表）。
pub fn handle_lists(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params_map = json!({
        "musician": q_num(q, "musician", 0),
        "sextype": q_num(q, "sextypes", 0),
        "showtype": 2,
        "type": q_num(q, "type", 0),
        "hotsize": q_num(q, "hotsize", 30),
    });
    forward(
        q, ctx, "GET", "/ocean/v6/singer/list", None,
        Some(params_map), None, "android", &[], false, false,
    )
}

/// artist_follow.js → /artist/follow（关注歌手）。
pub fn handle_follow(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let singerid: i64 = q_str(q, "id", "0").trim().parse().unwrap_or(0);
    let token = {
        let p = q_str(q, "token", "");
        if !p.is_empty() { p } else { c_str(q, "token") }
    };
    let userid = param_or_cookie_num(q, "userid", 0);
    let clienttime = now_epoch_secs() as i64;

    let encrypt = crypto_aes_encrypt(
        &json_stringify(&json!({ "singerid": singerid, "token": token })),
        None,
        None,
    );
    let key = encrypt.1.unwrap_or_default();
    let p = rsa_encrypt2(&json_stringify(&json!({ "clienttime": clienttime, "key": key })));

    let data = json!({
        "plat": 0,
        "userid": userid,
        "singerid": singerid,
        "source": 7,
        "p": p,
        "params": encrypt.0,
    });

    forward(
        q, ctx, "POST", "/followservice/v3/follow_singer", None,
        Some(json!({ "clienttime": clienttime })), Some(data), "android", &[], false, false,
    )
}

/// artist_unfollow.js → /artist/unfollow（取消关注歌手）。
pub fn handle_unfollow(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let singerid = q.get("id").cloned().unwrap_or(Value::Null);
    let token = {
        let p = q_str(q, "token", "");
        if !p.is_empty() { p } else { c_str(q, "token") }
    };
    let userid = q.get("userid").cloned().unwrap_or_else(|| {
        q_cookie(q).get("userid").cloned().unwrap_or(json!(0))
    });
    let clienttime = now_epoch_secs() as i64;

    let mut aes_obj = Map::new();
    aes_obj.insert("singerid".to_string(), singerid.clone());
    aes_obj.insert("token".to_string(), json!(token));
    let encrypt = crypto_aes_encrypt(&json_stringify(&Value::Object(aes_obj)), None, None);
    let key = encrypt.1.unwrap_or_default();
    let p = rsa_encrypt2(&json_stringify(&json!({ "clienttime": clienttime, "key": key })));

    let mut data = Map::new();
    data.insert("plat".to_string(), json!(0));
    data.insert("userid".to_string(), userid);
    data.insert("singerid".to_string(), singerid);
    data.insert("source".to_string(), json!(7));
    data.insert("p".to_string(), json!(p));
    data.insert("params".to_string(), json!(encrypt.0));

    forward(
        q, ctx, "POST", "/followservice/v3/unfollow_singer", None,
        None, Some(json!(data)), "android", &[], false, false,
    )
}

/// artist_follow_newsongs.js → /artist/follow/newsongs（关注歌手新歌）。
pub fn handle_follow_newsongs(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let last_album_id: i64 = q_num(q, "last_album_id", 0);
    let page_size = q_num(q, "pagesize", 30);
    let opt_sort = if q_num(q, "opt_sort", 1) == 2 { 2 } else { 1 };

    let params_map = json!({
        "last_album_id": last_album_id,
        "page_size": page_size,
        "opt_sort": opt_sort,
    });
    forward(
        q, ctx, "POST", "/feed/v1/follow/newsong_album_list", None,
        Some(params_map), Some(json!({ "last_album_id": last_album_id })), "android", &[], false, false,
    )
}

/// artist_honour.js → /artist/honour（歌手荣誉详情）。
pub fn handle_honour(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params = json!({
        "singer_id": q.get("id").cloned().unwrap_or(Value::Null),
        "pagesize": q_num(q, "pagesize", 30),
        "page": q_num(q, "page", 1),
    });
    forward(
        q, ctx, "POST", "/v1/query_singer_honour_detail", Some("http://h5activity.kugou.com"),
        Some(params), None, "android", &[], false, false,
    )
}
