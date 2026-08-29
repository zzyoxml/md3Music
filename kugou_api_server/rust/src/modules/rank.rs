//! rank 系列：audio / info / list / top / vol
//! 对应 JS module/{rank_audio,rank_info,rank_list,rank_top,rank_vol}.js

use crate::modules::{forward, or_num, or_str, q_num, q_str, Ctx};
use crate::request::{BodyValue, ModuleResponse};
use serde_json::{json, Value};

/// rank_audio.js → /rank/audio（排行榜音乐列表，响应重塑为扁平结构）。
pub fn handle_audio(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let data_map = json!({
        "show_portrait_mv": 1,
        "show_type_total": 1,
        "filter_original_remarks": 1,
        "area_code": 1,
        "pagesize": q_num(q, "pagesize", 30),
        "rank_cid": q_num(q, "rank_cid", 0),
        "type": 1,
        "page": q_num(q, "page", 1),
        "rank_id": q.get("rankid").cloned().unwrap_or(Value::Null),
    });
    let mut res = forward(
        q, ctx, "POST", "/openapi/kmr/v2/rank/audio", None,
        None, Some(data_map), "android", &[("kg-tid", "369")], false, false,
    )?;

    let mut body = res.body.to_json();
    if let Some(data) = body.get_mut("data") {
        let songs_key = if data.get("songlist").is_some() {
            Some("songlist".to_string())
        } else if data.get("list").is_some() {
            Some("list".to_string())
        } else if data.get("songs").is_some() {
            Some("songs".to_string())
        } else {
            None
        };
        if let Some(k) = songs_key {
            if let Some(arr) = data.get_mut(&k).and_then(|v| v.as_array_mut()) {
                if !arr.is_empty() {
                    *arr = arr.iter().map(transform_rank_song).collect();
                }
            }
        }
    }
    res.body = BodyValue::Json(body);
    Ok(res)
}

fn transform_rank_song(s: &Value) -> Value {
    // 已经是扁平格式（songname/SongName/filename）则原样返回
    if s.get("songname").is_some() || s.get("SongName").is_some() || s.get("filename").is_some() {
        return s.clone();
    }
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
    let hash = {
        let h = or_str(&ai, "hash", "");
        if h.is_empty() {
            or_str(s, "hash", "")
        } else {
            h
        }
    };
    let hash_128 = {
        let h = or_str(&ai, "hash_128", "");
        if h.is_empty() {
            if hash.is_empty() {
                or_str(s, "hash_128", "")
            } else {
                hash.clone()
            }
        } else {
            h
        }
    };
    let songname = {
        let n = or_str(&base, "audio_name", "");
        if n.is_empty() {
            or_str(s, "songname", "")
        } else {
            n
        }
    };
    let author_name = if author_name.is_empty() {
        or_str(s, "author_name", "")
    } else {
        author_name
    };
    let album_id = {
        let v = or_str(&base, "album_id", "");
        if v.is_empty() {
            or_str(s, "album_id", "")
        } else {
            v
        }
    };
    let album_name = {
        let v = or_str(&album_info, "album_name", "");
        if v.is_empty() {
            or_str(s, "album_name", "")
        } else {
            v
        }
    };
    let album_audio_id = {
        let v = or_str(&base, "album_audio_id", "");
        if v.is_empty() {
            or_str(s, "album_audio_id", "")
        } else {
            v
        }
    };
    let duration = {
        let v = or_num(&ai, "duration", 0);
        if v == 0 {
            or_num(s, "duration", 0)
        } else {
            v
        }
    };
    let filesize = {
        let v = or_num(&ai, "filesize", 0);
        if v == 0 {
            or_num(s, "filesize", 0)
        } else {
            v
        }
    };
    let bitrate = {
        let v = or_num(&ai, "bitrate", 0);
        if v == 0 {
            or_num(s, "bitrate", 128)
        } else {
            v
        }
    };
    let hash_320 = {
        let v = or_str(&ai, "hash_320", "");
        if v.is_empty() {
            or_str(s, "hash_320", "")
        } else {
            v
        }
    };
    let hash_flac = {
        let v = or_str(&ai, "hash_flac", "");
        if v.is_empty() {
            or_str(s, "hash_flac", "")
        } else {
            v
        }
    };
    let cover = {
        let v = or_str(&album_info, "cover", "");
        if v.is_empty() {
            or_str(s, "cover", "")
        } else {
            v
        }
    };
    let sizable_cover = {
        let v = or_str(&album_info, "sizable_cover", "");
        if v.is_empty() {
            or_str(s, "sizable_cover", "")
        } else {
            v
        }
    };
    let audio_id = {
        let v = or_num(&base, "audio_id", 0);
        if v == 0 {
            or_num(s, "audio_id", 0)
        } else {
            v
        }
    };
    let privilege = {
        let p = s.get("copyright").and_then(|c| c.get("privilege")).and_then(Value::as_i64).unwrap_or(0);
        if p == 0 {
            or_num(s, "privilege", 0)
        } else {
            p
        }
    };
    json!({
        "hash": hash,
        "songname": songname,
        "author_name": author_name,
        "singerinfo": singerinfo,
        "album_id": album_id,
        "album_name": album_name,
        "album_audio_id": album_audio_id,
        "duration": duration,
        "filesize": filesize,
        "bitrate": bitrate,
        "hash_128": hash_128,
        "hash_320": hash_320,
        "hash_flac": hash_flac,
        "cover": cover,
        "sizable_cover": sizable_cover,
        "audio_id": audio_id,
        "privilege": privilege,
    })
}

/// rank_info.js → /rank/info（排行榜详情）。
pub fn handle_info(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let parmas_map = json!({
        "rank_cid": q_num(q, "rank_cid", 0),
        "rankid": q.get("rankid").cloned().unwrap_or(Value::Null),
        "with_album_img": q_num(q, "album_img", 1),
        "zone": q_str(q, "zone", ""),
    });
    forward(
        q, ctx, "GET", "/ocean/v6/rank/info", None,
        Some(parmas_map), None, "android", &[], false, false,
    )
}

/// rank_list.js → /rank/list（排行榜列表）。
pub fn handle_list(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let parmas_map = json!({
        "plat": 2,
        "withsong": q_num(q, "withsong", 1),
        "parentid": 0,
    });
    forward(
        q, ctx, "GET", "/ocean/v6/rank/list", None,
        Some(parmas_map), None, "android", &[], false, false,
    )
}

/// rank_top.js → /rank/top（排行榜推荐）。
pub fn handle_top(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q, ctx, "GET", "/mobileservice/api/v5/rank/rec_rank_list", None,
        None, None, "android", &[], false, false,
    )
}

/// rank_vol.js → /rank/vol（排行榜往期）。
pub fn handle_vol(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let parmas_map = json!({
        "rank_cid": q_num(q, "rank_cid", 0),
        "rankid": q.get("rankid").cloned().unwrap_or(Value::Null),
        "ranktype": 1,
        "type": 0,
        "plat": 2,
    });
    forward(
        q, ctx, "GET", "/ocean/v6/rank/vol", None,
        Some(parmas_map), None, "android", &[], false, false,
    )
}
