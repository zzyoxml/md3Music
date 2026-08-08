//! playlist 系列：add / del / detail / effect / similar / tags /
//! track_all / track_all_new / tracks_add / tracks_del
//! 对应 JS module/playlist*.js

use crate::cache::now_epoch_secs;
use crate::config::{APP_ID, CLIENT_VER};
use crate::crypto::{playlist_aes_decrypt, playlist_aes_encrypt, rsa_encrypt2};
use crate::helper::sign_params_key;
use crate::modules::{
    cookie_or_param_str, forward, param_or_cookie_str, q_cookie, q_num, q_str, Ctx,
};
use crate::request::{BodyValue, ModuleResponse, RequestOptions};
use crate::util::json_stringify;
use serde_json::{json, Map, Value};

fn now_secs() -> i64 {
    now_epoch_secs() as i64
}

/// JS `params.x || default`（0 → default）。
fn or_num(q: &Value, key: &str, default: i64) -> i64 {
    q_num(q, key, default)
}

/// JS `params.x ?? default`（仅 null/undefined → default，0 保留）。
fn or_num_nullish(q: &Value, key: &str, default: i64) -> i64 {
    match q.get(key) {
        None | Some(Value::Null) => default,
        Some(Value::Number(n)) => n.as_i64().unwrap_or(default),
        Some(Value::String(s)) => {
            if s.trim().is_empty() {
                default
            } else {
                s.trim().parse().unwrap_or(default)
            }
        }
        Some(Value::Bool(b)) => {
            if *b {
                1
            } else {
                default
            }
        }
        _ => default,
    }
}

/// JS `params.source === 0 ? 0 : params.source || 1`。
fn source_0_or_1(q: &Value) -> i64 {
    match q.get("source") {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(1),
        Some(Value::String(s)) => {
            if s.trim().is_empty() {
                1
            } else {
                s.trim().parse().unwrap_or(1)
            }
        }
        _ => 1,
    }
}

/// 通用 playlistAES + rsaEncrypt2 加密后的 arraybuffer 请求，解密回 JSON。
fn aes_roundtrip(
    q: &Value,
    ctx: &Ctx,
    base_url: Option<&str>,
    url: &str,
    data_obj: &Value,
    params: Value,
    clear_default_params: bool,
    not_signature: bool,
    headers: &[(&str, &str)],
) -> Result<ModuleResponse, ModuleResponse> {
    let userid = param_or_cookie_str(q, "userid", "0")
        .trim()
        .parse()
        .unwrap_or(0);
    let token = param_or_cookie_str(q, "token", "");
    let (key, aes_str) = playlist_aes_encrypt(&json_stringify(data_obj));
    let p = rsa_encrypt2(&json_stringify(&json!({ "aes": key, "uid": userid, "token": token })))
        .to_uppercase();
    let clienttime = now_secs();
    let mut pm: Map<String, Value> = Map::new();
    if let Some(om) = params.as_object() {
        for (k, v) in om {
            pm.insert(k.clone(), v.clone());
        }
    }
    pm.insert("clienttime".to_string(), json!(clienttime));
    pm.insert(
        "key".to_string(),
        json!(sign_params_key(&clienttime.to_string(), APP_ID, "")),
    );
    pm.insert("clientver".to_string(), json!(CLIENT_VER));
    pm.insert("appid".to_string(), json!(APP_ID));
    pm.insert("p".to_string(), json!(p));

    let mut opts = RequestOptions::new(url);
    if let Some(b) = base_url {
        opts = opts.base_url(b);
    }
    opts = opts
        .post(url)
        .params(Value::Object(pm))
        .string_body(aes_str)
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .response_type("arraybuffer");
    // 酷狗网关 gateway.kugou.com 靠 x-router 头把请求分发到后端服务，
    // 缺失时网关无法路由直接回显 URL 拒绝（502）。与 playlist_del.js 对齐。
    for (k, v) in headers {
        opts = opts.header(k, v);
    }
    if clear_default_params {
        opts = opts.clear_default_params(true);
    }
    if not_signature {
        opts = opts.not_signature(true);
    }

    let res = ctx.send(&opts)?;
    let dec = playlist_aes_decrypt(&key, &res.body.to_base64());
    Ok(ModuleResponse {
        status: res.status,
        body: BodyValue::Json(dec),
        cookie: res.cookie,
        headers: res.headers,
    })
}

/// playlist_add.js → /playlist/add（收藏歌单）。
pub fn handle_add(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = param_or_cookie_str(q, "userid", "0")
        .trim()
        .parse()
        .unwrap_or(0);
    let token = param_or_cookie_str(q, "token", "");
    let clienttime = now_secs();
    let ptype = q_num(q, "type", 0);

    let mut dm: Map<String, Value> = Map::new();
    dm.insert("userid".to_string(), json!(userid));
    dm.insert("token".to_string(), json!(token));
    dm.insert("total_ver".to_string(), json!(0));
    dm.insert("name".to_string(), json!(q_str(q, "name", "")));
    dm.insert("type".to_string(), json!(ptype));
    dm.insert("source".to_string(), json!(source_0_or_1(q)));
    dm.insert("is_pri".to_string(), json!(0));
    dm.insert(
        "list_create_userid".to_string(),
        json!(or_num(q, "list_create_userid", 0)),
    );
    dm.insert(
        "list_create_listid".to_string(),
        json!(or_num(q, "list_create_listid", 0)),
    );
    dm.insert(
        "list_create_gid".to_string(),
        json!(q_str(q, "list_create_gid", "")),
    );
    dm.insert("from_shupinmv".to_string(), json!(0));
    if ptype == 0 {
        dm.insert("is_pri".to_string(), json!(or_num(q, "is_pri", 0)));
    }

    let params = if ptype == 0 {
        json!({
            "last_time": clienttime,
            "last_area": "gztx",
            "userid": userid,
            "token": token,
        })
    } else {
        json!({})
    };

    forward(
        q, ctx, "post", "/cloudlist.service/v5/add_list", None,
        Some(params), Some(Value::Object(dm)), "android", &[], false, false,
    )
}

/// playlist_del.js → /playlist/del（取消收藏歌单）。
pub fn handle_del(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let dm = json!({
        "listid": q_num(q, "listid", 0),
        "total_ver": 0,
        "type": or_num_nullish(q, "type", 1),
    });
    let params = json!({
        "last_area": "gztx",
        "last_time": now_secs(),
    });
    aes_roundtrip(
        q,
        ctx,
        None,
        "/v2/delete_list",
        &dm,
        params,
        false,
        false,
        // 网关分发头：与 playlist_del.js 一致，缺失返回 502
        &[("x-router", "cloudlist.service.kugou.com")],
    )
}

/// playlist_detail.js → /playlist/detail（获取歌单详情）。
pub fn handle_detail(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let ids = q_str(q, "ids", "");
    let data: Vec<Value> = ids
        .split(',')
        .map(|s| json!({ "global_collection_id": s }))
        .collect();
    let dm = json!({
        "data": data,
        "userid": param_or_cookie_str(q, "userid", "0").trim().parse::<i64>().unwrap_or(0),
        "token": param_or_cookie_str(q, "token", ""),
    });
    forward(
        q, ctx, "POST", "/v3/get_list_info", None, None,
        Some(dm), "android", &[("x-router", "pubsongs.kugou.com")], false, false,
    )
}

/// playlist_effect.js → /playlist/effect（获取音效歌单）。
pub fn handle_effect(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let dm = json!({
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
    });
    forward(
        q, ctx, "POST", "/pubsongs/v1/get_sound_effect_list", None, None,
        Some(dm), "android", &[], false, false,
    )
}

/// playlist_similar.js → /playlist/similar（相似歌单）。
pub fn handle_similar(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let ids = q_str(q, "ids", "");
    let data: Vec<Value> = ids
        .split(',')
        .map(|s| json!({ "global_collection_id": s }))
        .collect();
    let clienttime_ms = (now_epoch_secs() * 1000.0) as i64;
    let dm = json!({
        "appid": APP_ID,
        "clientver": CLIENT_VER,
        "clienttime": clienttime_ms,
        "key": sign_params_key(&clienttime_ms.to_string(), "", ""),
        "userid": param_or_cookie_str(q, "userid", "0").trim().parse::<i64>().unwrap_or(0),
        "ugc": 1,
        "show_list": 1,
        "need_songs": 1,
        "data": data,
    });
    forward(
        q, ctx, "POST", "/pubsongs/v1/kmr_get_similar_lists", None, None,
        Some(dm), "android", &[], false, false,
    )
}

/// playlist_tags.js → /playlist/tags（获取歌单分类）。
pub fn handle_tags(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let dm = json!({
        "tag_type": "collection",
        "tag_id": 0,
        "source": 3,
    });
    forward(
        q, ctx, "POST", "/pubsongs/v1/get_tags_by_type", None, None,
        Some(dm), "android", &[], false, false,
    )
}

/// playlist_track_all.js → /playlist/track/all（获取歌单所有歌曲）。
pub fn handle_track_all(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let pagesize = q_num(q, "pagesize", 30);
    let gcid = {
        let v = q_str(q, "global_collection_id", "");
        if !v.is_empty() {
            v
        } else {
            q_str(q, "id", "")
        }
    };
    let mut pm: Map<String, Value> = Map::new();
    pm.insert("area_code".to_string(), json!(1));
    pm.insert(
        "begin_idx".to_string(),
        json!((q_num(q, "page", 1) - 1) * pagesize),
    );
    pm.insert("plat".to_string(), json!(1));
    pm.insert("type".to_string(), json!(1));
    pm.insert("mode".to_string(), json!(1));
    pm.insert("personal_switch".to_string(), json!(1));
    pm.insert(
        "extend_fields".to_string(),
        json!("abtags,hot_cmt,popularization"),
    );
    pm.insert("pagesize".to_string(), json!(pagesize));
    pm.insert("global_collection_id".to_string(), json!(gcid));
    forward(
        q, ctx, "GET", "/pubsongs/v2/get_other_list_file_nofilt", None,
        Some(Value::Object(pm)), None, "android", &[], false, false,
    )
}

/// playlist_track_all_new.js → /playlist/track/all/new（获取自己歌单所有歌曲）。
pub fn handle_track_all_new(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = cookie_or_param_str(q, "userid", "0");
    let token = cookie_or_param_str(q, "token", "0");
    let mut dm: Map<String, Value> = Map::new();
    if let Some(v) = q.get("listid") {
        if !v.is_null() {
            dm.insert("listid".to_string(), v.clone());
        }
    }
    dm.insert("userid".to_string(), json!(userid));
    dm.insert("area_code".to_string(), json!(1));
    dm.insert("show_relate_goods".to_string(), json!(0));
    dm.insert("pagesize".to_string(), json!(q_num(q, "pagesize", 30)));
    dm.insert("allplatform".to_string(), json!(1));
    dm.insert("show_cover".to_string(), json!(1));
    dm.insert("type".to_string(), json!(0));
    dm.insert("token".to_string(), json!(token));
    dm.insert("page".to_string(), json!(q_num(q, "page", 1)));
    forward(
        q, ctx, "post", "/v4/get_list_all_file", None, None,
        Some(Value::Object(dm)), "android", &[("x-router", "cloudlist.service.kugou.com")], false, false,
    )
}

/// playlist_tracks_add.js → /playlist/tracks/add（对歌单添加歌曲）。
pub fn handle_tracks_add(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = param_or_cookie_str(q, "userid", "0")
        .trim()
        .parse()
        .unwrap_or(0);
    let token = param_or_cookie_str(q, "token", "");
    let clienttime = now_secs();
    let resource: Vec<Value> = q_str(q, "data", "")
        .split(',')
        .map(|s| {
            let parts: Vec<&str> = s.split('|').collect();
            json!({
                "number": 1,
                "name": parts.get(0).copied().unwrap_or(""),
                "hash": parts.get(1).copied().unwrap_or(""),
                "size": 0,
                "sort": 0,
                "timelen": 0,
                "bitrate": 0,
                "album_id": parts.get(2).and_then(|v| v.parse::<i64>().ok()).unwrap_or(0),
                "mixsongid": parts.get(3).and_then(|v| v.parse::<i64>().ok()).unwrap_or(0),
            })
        })
        .collect();
    let mut dm: Map<String, Value> = Map::new();
    if let Some(v) = q.get("listid") {
        if !v.is_null() {
            dm.insert("listid".to_string(), v.clone());
        }
    }
    dm.insert("userid".to_string(), json!(userid));
    dm.insert("token".to_string(), json!(token));
    dm.insert("list_ver".to_string(), json!(0));
    dm.insert("type".to_string(), json!(0));
    dm.insert("slow_upload".to_string(), json!(1));
    dm.insert("scene".to_string(), json!("false;null"));
    dm.insert("data".to_string(), Value::Array(resource));
    let params = json!({
        "last_time": clienttime,
        "last_area": "gztx",
        "userid": userid,
        "token": token,
    });
    forward(
        q, ctx, "post", "/cloudlist.service/v6/add_song", None,
        Some(params), Some(Value::Object(dm)), "android", &[], false, false,
    )
}

/// playlist_tracks_del.js → /playlist/tracks/del（对歌单删除歌曲）。
pub fn handle_tracks_del(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = param_or_cookie_str(q, "userid", "0")
        .trim()
        .parse()
        .unwrap_or(0);
    let token = param_or_cookie_str(q, "token", "");
    let clienttime = now_secs();
    let resource: Vec<Value> = q_str(q, "fileids", "")
        .split(',')
        .filter(|s| !s.is_empty())
        .map(|s| {
            match s.trim().parse::<i64>() {
                Ok(n) if n > 0 => json!({ "fileid": n }),
                _ => json!({ "fileid": 0, "hash": s }),
            }
        })
        .collect();
    let mut dm: Map<String, Value> = Map::new();
    if let Some(v) = q.get("listid") {
        if !v.is_null() {
            dm.insert("listid".to_string(), v.clone());
        }
    }
    dm.insert("userid".to_string(), json!(userid));
    dm.insert("data".to_string(), Value::Array(resource));
    dm.insert("type".to_string(), json!(0));
    dm.insert("token".to_string(), json!(token));
    dm.insert("list_ver".to_string(), json!(0));
    let params = json!({
        "last_time": clienttime,
        "last_area": "gztx",
        "userid": userid,
        "token": token,
    });
    forward(
        q, ctx, "post", "/cloudlist.service/v4/delete_songs", None,
        Some(params), Some(Value::Object(dm)), "android", &[], false, false,
    )
}
