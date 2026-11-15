//! top 系列：album / card / card_youth / ip / playlist / song
//! 对应 JS module/{top_album,top_card,top_card_youth,top_ip,top_playlist,top_song}.js

use crate::cache::now_epoch_secs;
use crate::helper::sign_params_key;
use crate::modules::{c_str, forward, q_num, q_str, Ctx};
use crate::request::{BodyValue, ModuleResponse};
use serde_json::{json, Map, Value};

/// top_album.js → /top/album（推荐专辑）。
pub fn handle_album(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let token = {
        let p = q_str(q, "token", "");
        if !p.is_empty() {
            p
        } else {
            c_str(q, "token")
        }
    };
    let data_map = json!({
        "apiver": 20,
        "token": token,
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
        "withpriv": 1,
    });
    forward(
        q, ctx, "POST", "/musicadservice/v1/mobile_newalbum_sp", None,
        None, Some(data_map), "android", &[], false, false,
    )
}

/// top_card.js → /top/card（热门好歌精选）。
pub fn handle_card(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let fakem = "60f7ebf1f812edbac3c63a7310001701760f";
    let mid = c_str(q, "KUGOU_API_MID");
    let date_time = (now_epoch_secs() * 1000.0) as i64;
    let userid: i64 = q_num(q, "userid", 0);

    let mut data_map = Map::new();
    data_map.insert("appid".to_string(), json!(3116));
    data_map.insert("clientver".to_string(), json!(11440));
    data_map.insert("platform".to_string(), json!("android"));
    data_map.insert("clienttime".to_string(), json!(date_time));
    data_map.insert("userid".to_string(), json!(userid));
    data_map.insert("key".to_string(), json!(sign_params_key(&date_time.to_string(), "", "")));
    data_map.insert("fakem".to_string(), json!(fakem));
    data_map.insert("area_code".to_string(), json!(1));
    if !mid.is_empty() {
        data_map.insert("mid".to_string(), json!(mid));
    }
    data_map.insert("uuid".to_string(), json!("-"));
    data_map.insert("client_playlist".to_string(), json!([]));
    data_map.insert("u_info".to_string(), json!("a0c35cd40af564444b5584c2754dedec"));

    let params = json!({
        "card_id": q_num(q, "card_id", 1),
        "fakem": fakem,
        "area_code": 1,
        "platform": "ios",
    });
    forward(
        q, ctx, "POST", "/singlecardrec.service/v1/single_card_recommend", None,
        Some(params), Some(json!(data_map)), "android", &[], false, false,
    )
}

/// top_card_youth.js → /top/card/youth（概念版卡片推荐）。
pub fn handle_card_youth(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let tagid = match q.get("tagid") {
        Some(v) if !v.is_null() => v.clone(),
        _ => json!(""),
    };
    let data_map = json!({
        "tagid": tagid,
        "u_info": "",
        "source_mixsong": "",
    });
    let pagesize = match q.get("pagesize") {
        Some(v) if !v.is_null() => crate::util::js_string(Some(v)),
        _ => "30".to_string(),
    };
    let params = json!({
        "card_id": q_num(q, "card_id", 3005),
        "area_code": 1,
        "platform": "ops",
        "module_id": 1,
        "ver": "v2",
        "pagesize": pagesize,
    });
    forward(
        q, ctx, "POST", "youth/v1/song/single_card_recommend", None,
        Some(params), Some(data_map), "android", &[], false, false,
    )
}

/// top_ip.js → /top/ip（每日推荐，含 inner_url 的 ip_id 提取）。
pub fn handle_ip(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let data_map = json!({ "tags": {} });
    let params = json!({
        "clientver": 12349,
        "area_code": 1,
    });
    let mut res = forward(
        q, ctx, "POST", "/v1/daily_recommend", Some("http://musicadservice.kugou.com"),
        Some(params), Some(data_map), "android", &[], false, false,
    )?;

    let mut body = res.body.to_json();
    let status_ok = match body.get("status") {
        Some(Value::Number(n)) => n.as_i64() == Some(1),
        Some(Value::String(s)) => s == "1",
        _ => false,
    };
    if status_ok {
        if let Some(data) = body.get_mut("data") {
            if let Some(list) = data.get_mut("list") {
                if let Some(arr) = list.as_array_mut() {
                    for s in arr.iter_mut() {
                        if let Some(extra) = s.get_mut("extra") {
                            if let Some(inner_url) = extra.get("inner_url").and_then(Value::as_str) {
                                if let Some(idx) = inner_url.rfind("ip_id") {
                                    // JS: Number(inner_url.substring(findIndex + 6))
                                    let substr = &inner_url[idx + 6..];
                                    let n = substr.trim().parse::<i64>().unwrap_or(0);
                                    if let Some(m) = extra.as_object_mut() {
                                        m.insert("ip_id".to_string(), json!(n));
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    res.body = BodyValue::Json(body);
    Ok(res)
}

/// top_playlist.js → /top/playlist（歌单推荐）。
pub fn handle_playlist(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let date_time = now_epoch_secs() as i64;
    let mid = c_str(q, "KUGOU_API_MID");
    let userid: i64 = q_num(q, "userid", 0);

    let mut data_map = Map::new();
    data_map.insert("appid".to_string(), json!(3116));
    if !mid.is_empty() {
        data_map.insert("mid".to_string(), json!(mid));
    }
    data_map.insert("clientver".to_string(), json!(11440));
    data_map.insert("platform".to_string(), json!("android"));
    data_map.insert("clienttime".to_string(), json!(date_time));
    data_map.insert("userid".to_string(), json!(userid));
    data_map.insert("module_id".to_string(), json!(q_num(q, "module_id", 1)));
    data_map.insert("page".to_string(), json!(q_num(q, "page", 1)));
    data_map.insert("pagesize".to_string(), json!(q_num(q, "pagesize", 30)));
    data_map.insert("key".to_string(), json!(sign_params_key(&date_time.to_string(), "", "")));
    data_map.insert("special_recommend".to_string(), json!({
        "withtag": q_num(q, "withtag", 1),
        "withsong": q_num(q, "withsong", 1),
        "sort": q_num(q, "sort", 1),
        "ugc": 1,
        "is_selected": 0,
        "withrecommend": 1,
        "area_code": 1,
        "categoryid": q_num(q, "category_id", 0),
    }));
    data_map.insert("req_multi".to_string(), json!(1));
    data_map.insert("retrun_min".to_string(), json!(5));
    data_map.insert("return_special_falg".to_string(), json!(1));

    forward(
        q, ctx, "POST", "/v2/special_recommend", None,
        None, Some(json!(data_map)), "android",
        &[("x-router", "specialrec.service.kugou.com")], false, false,
    )
}

/// top_song.js → /top/song（新歌速递）。
pub fn handle_song(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid: i64 = q_num(q, "userid", 0);
    let data_map = json!({
        "rank_id": q_num(q, "type", 21608),
        "userid": userid,
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
        "tags": [],
    });
    forward(
        q, ctx, "POST", "/musicadservice/container/v1/newsong_publish", None,
        None, Some(data_map), "android", &[], false, false,
    )
}
