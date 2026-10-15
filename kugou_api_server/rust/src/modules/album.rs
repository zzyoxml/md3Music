//! album 系列：album / album_detail / album_songs / album_shop
//! 对应 JS module/{album,album_detail,album_songs,album_shop}.js

use crate::cache::now_epoch_secs;
use crate::helper::sign_params_key;
use crate::modules::{c_str, forward, or_num, or_str, q_num, q_str, Ctx};
use crate::request::{BodyValue, ModuleResponse};
use serde_json::{json, Value};

/// album.js → /album（批量专辑信息）。
pub fn handle_album(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let date_time = (now_epoch_secs() * 1000.0) as i64;
    let data = q_str(q, "album_id", "")
        .split(',')
        .map(|s| json!({ "album_id": s, "album_name": "", "author_name": "" }))
        .collect::<Vec<_>>()
        .into();
    let dfid = {
        let p = q_str(q, "dfid", "");
        let c = c_str(q, "dfid");
        if !p.is_empty() {
            p
        } else if !c.is_empty() {
            c
        } else {
            "-".to_string()
        }
    };
    let userid: i64 = q_num(q, "userid", 0);
    let token = q_str(q, "token", "");

    let mut data_map = serde_json::Map::new();
    data_map.insert("appid".to_string(), json!(3116));
    data_map.insert("clienttime".to_string(), json!(date_time));
    data_map.insert("clientver".to_string(), json!(11440));
    data_map.insert("data".to_string(), data);
    data_map.insert("dfid".to_string(), json!(dfid));
    data_map.insert("fields".to_string(), json!(q_str(q, "fields", "")));
    data_map.insert("key".to_string(), json!(sign_params_key(&date_time.to_string(), "", "")));
    let mid = c_str(q, "KUGOU_API_MID");
    data_map.insert("mid".to_string(), json!(mid));
    if !token.is_empty() {
        data_map.insert("token".to_string(), json!(token));
    }
    if userid != 0 {
        data_map.insert("userid".to_string(), json!(userid));
    }

    forward(
        q, ctx, "POST", "/v1/album", Some("http://kmr.service.kugou.com"),
        None, Some(json!(data_map)), "android",
        &[("x-router", "kmr.service.kugou.com"), ("Content-Type", "application/json")],
        false, false,
    )
}

/// album_detail.js → /album/detail（专辑详情）。
pub fn handle_album_detail(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let album_id = {
        let v = q.get("album_id");
        if v.is_some() {
            v.unwrap().clone()
        } else {
            q.get("id").cloned().unwrap_or(Value::Null)
        }
    };
    let data = json!({
        "data": [{ "album_id": album_id }],
        "is_buy": q_num(q, "is_buy", 0),
        "fields": "album_id,album_name,publish_date,sizable_cover,intro,language,is_publish,heat,type,quality,authors,exclusive,author_name,trans_param,gid",
    });
    forward(
        q, ctx, "POST", "/kmr/v2/albums", None,
        None, Some(data), "android",
        &[("x-router", "openapi.kugou.com"), ("kg-tid", "255")],
        false, false,
    )
}

/// album_songs.js → /album/songs（专辑音乐列表，响应重塑为扁平结构）。
pub fn handle_album_songs(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let album_id = {
        let v = q.get("album_id");
        if v.is_some() {
            v.unwrap().clone()
        } else {
            q.get("id").cloned().unwrap_or(Value::Null)
        }
    };
    let data_map = json!({
        "album_id": album_id,
        "is_buy": q_str(q, "is_buy", ""),
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
    });
    let mut res = forward(
        q, ctx, "POST", "/v1/album_audio/lite", None,
        None, Some(data_map), "android",
        &[("x-router", "openapi.kugou.com"), ("kg-tid", "255")],
        false, false,
    )?;

    let mut body = res.body.to_json();
    if let Some(data) = body.get_mut("data") {
        if let Some(songs) = data.get_mut("songs") {
            if let Some(arr) = songs.as_array_mut() {
                *arr = arr
                    .iter()
                    .map(|s| {
                        let ai = s.get("audio_info").cloned().unwrap_or(json!({}));
                        let base = s.get("base").cloned().unwrap_or(json!({}));
                        let authors = s.get("authors").cloned().unwrap_or(json!([]));
                        let album_info = s.get("album_info").cloned().unwrap_or(json!({}));
                        let author_name = authors
                            .as_array()
                            .map(|a| {
                                a.iter()
                                    .map(|x| or_str(x, "author_name", ""))
                                    .collect::<Vec<_>>()
                                    .join(",")
                            })
                            .unwrap_or_default();
                        let singerinfo = authors
                            .as_array()
                            .map(|a| {
                                a.iter()
                                    .map(|x| json!({ "name": or_str(x, "author_name", ""), "id": or_num(x, "author_id", 0) }))
                                    .collect::<Vec<_>>()
                            })
                            .unwrap_or_default();
                        let hash = or_str(&ai, "hash", "");
                        let hash_128 = {
                            let h = or_str(&ai, "hash_128", "");
                            if h.is_empty() {
                                hash.clone()
                            } else {
                                h
                            }
                        };
                        json!({
                            "hash": hash,
                            "songname": or_str(&base, "audio_name", ""),
                            "author_name": author_name,
                            "singerinfo": singerinfo,
                            "album_id": or_str(&base, "album_id", ""),
                            "album_name": or_str(&album_info, "album_name", ""),
                            "album_audio_id": or_str(&base, "album_audio_id", ""),
                            "duration": or_num(&ai, "duration", 0),
                            "filesize": or_num(&ai, "filesize", 0),
                            "bitrate": or_num(&ai, "bitrate", 128),
                            "hash_128": hash_128,
                            "hash_320": or_str(&ai, "hash_320", ""),
                            "hash_flac": or_str(&ai, "hash_flac", ""),
                            "cover": or_str(&album_info, "cover", ""),
                            "audio_id": or_num(&base, "audio_id", 0),
                            "privilege": s.get("copyright").and_then(|c| c.get("privilege")).and_then(Value::as_i64).unwrap_or(0),
                        })
                    })
                    .collect();
            }
        }
    }
    res.body = BodyValue::Json(body);
    Ok(res)
}

/// album_shop.js → /album/shop（唱片店分类）。
pub fn handle_album_shop(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q, ctx, "GET", "/zhuanjidata/v3/album_shop_v2/get_classify_data", None,
        None, None, "android", &[], false, false,
    )
}
