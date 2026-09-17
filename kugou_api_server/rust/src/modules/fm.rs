//! fm 系列：class / image / recommend / songs / yueku_fm / personal_fm / pc_diantai
//! 对应 JS module/{fm_class,fm_image,fm_recommend,fm_songs,yueku_fm,personal_fm,pc_diantai}.js

use crate::cache::now_epoch_secs;
use crate::helper::sign_params_key;
use crate::modules::{
    cookie_or_param_num, cookie_or_param_str, c_num, c_str, forward, q_num, q_str, q_truthy, Ctx,
};
use crate::request::ModuleResponse;
use serde_json::{json, Map, Value};

fn now_ms() -> i64 {
    (now_epoch_secs() * 1000.0) as i64
}

/// fm_class.js → /fm/class
pub fn handle_class(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let date_time = now_ms();
    let userid = cookie_or_param_num(q, "userid", 0);
    let mid = c_str(q, "KUGOU_API_MID");
    let mut m = Map::new();
    m.insert("kguid".into(), json!(userid));
    m.insert("clienttime".into(), json!(date_time));
    if !mid.is_empty() {
        m.insert("mid".into(), json!(mid));
    }
    m.insert("platform".into(), json!("android"));
    m.insert("clientver".into(), json!(11440));
    m.insert("uid".into(), json!(userid));
    m.insert("get_tracker".into(), json!(1));
    m.insert("key".into(), json!(sign_params_key(&date_time.to_string(), "", "")));
    m.insert("appid".into(), json!(3116));
    forward(
        q, ctx, "POST", "/v1/class_fm_song", None, None, Some(Value::Object(m)), "android",
        &[("x-router", "fm.service.kugou.com")], false, false,
    )
}

/// fm_image.js → /fm/image
pub fn handle_image(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let date_time = now_ms();
    let dfid = cookie_or_param_str(q, "dfid", "-");
    let userid = cookie_or_param_num(q, "userid", 0);
    let token = cookie_or_param_str(q, "token", "");
    let mid = c_str(q, "KUGOU_API_MID");
    let fm_data: Value = q_str(q, "fmid", "")
        .split(',')
        .map(|s| json!({ "fields": "imgUrl100,imgUrl50", "fmid": s, "fmtype": 2 }))
        .collect::<Vec<_>>()
        .into();
    let mut m = Map::new();
    m.insert("appid".into(), json!(3116));
    m.insert("clienttime".into(), json!(date_time));
    m.insert("clientver".into(), json!(11440));
    m.insert("data".into(), fm_data);
    m.insert("dfid".into(), json!(dfid));
    m.insert("key".into(), json!(sign_params_key(&date_time.to_string(), "", "")));
    if !mid.is_empty() {
        m.insert("mid".into(), json!(mid));
    }
    if userid != 0 {
        m.insert("userid".into(), json!(userid));
    }
    if !token.is_empty() {
        m.insert("token".into(), json!(token));
    }
    forward(
        q, ctx, "POST", "/v1/fm_info", None, None, Some(Value::Object(m)), "android",
        &[("x-router", "fm.service.kugou.com"), ("Content-Type", "application/json")], false, false,
    )
}

/// fm_recommend.js → /fm/recommend
pub fn handle_recommend(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let date_time = now_ms();
    let dfid = cookie_or_param_str(q, "dfid", "-");
    let mid = c_str(q, "KUGOU_API_MID");
    let mut m = Map::new();
    m.insert("appid".into(), json!(3116));
    m.insert("clientver".into(), json!(11440));
    m.insert("clienttime".into(), json!(date_time));
    if !mid.is_empty() {
        m.insert("mid".into(), json!(mid));
    }
    m.insert("key".into(), json!(sign_params_key(&date_time.to_string(), "", "")));
    m.insert("rcmdsongcount".into(), json!(1));
    m.insert("level".into(), json!(0));
    m.insert("area_code".into(), json!(1));
    m.insert("get_tracker".into(), json!(1));
    m.insert("uid".into(), json!(0));
    m.insert("dfid".into(), json!(dfid));
    forward(
        q, ctx, "POST", "/v1/rcmd_list", None, None, Some(Value::Object(m)), "android",
        &[("x-router", "fm.service.kugou.com")], false, false,
    )
}

/// fm_songs.js → /fm/songs
pub fn handle_songs(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let date_time = now_ms();
    let userid = cookie_or_param_num(q, "userid", 0);
    let mid = c_str(q, "KUGOU_API_MID");
    let fmids: Vec<String> = q_str(q, "fmid", "").split(',').map(String::from).collect();
    let default_type = q_num(q, "type", 2);
    let default_offset = q_num(q, "offset", -1);
    let default_size = q_num(q, "size", 20);
    let mut fm_data: Vec<Value> = fmids
        .iter()
        .map(|s| {
            json!({
                "fmid": s,
                "fmtype": default_type,
                "offset": default_offset,
                "size": default_size,
                "singername": "",
            })
        })
        .collect();
    let fmtypes: Vec<String> = q_str(q, "fmtype", "").split(',').map(String::from).collect();
    for (i, s) in fmtypes.iter().enumerate() {
        if i < fm_data.len() && !s.is_empty() {
            fm_data[i]["fmtype"] = json!(s);
        }
    }
    let fmoffsets: Vec<String> = q_str(q, "fmoffset", "").split(',').map(String::from).collect();
    for (i, s) in fmoffsets.iter().enumerate() {
        if i < fm_data.len() && !s.is_empty() {
            if let Ok(n) = s.parse::<i64>() {
                fm_data[i]["offset"] = json!(n);
            }
        }
    }
    let fmsizes: Vec<String> = q_str(q, "fmsize", "").split(',').map(String::from).collect();
    for (i, s) in fmsizes.iter().enumerate() {
        if i < fm_data.len() && !s.is_empty() {
            if let Ok(n) = s.parse::<i64>() {
                fm_data[i]["size"] = json!(n);
            }
        }
    }
    let mut m = Map::new();
    m.insert("appid".into(), json!(3116));
    m.insert("area_code".into(), json!(1));
    m.insert("clienttime".into(), json!(date_time));
    m.insert("clientver".into(), json!(11440));
    m.insert("data".into(), json!(fm_data));
    m.insert("get_tracker".into(), json!(1));
    m.insert("key".into(), json!(sign_params_key(&date_time.to_string(), "", "")));
    if !mid.is_empty() {
        m.insert("mid".into(), json!(mid));
    }
    if userid != 0 {
        m.insert("uid".into(), json!(userid));
    }
    forward(
        q, ctx, "POST", "/v1/app_song_list_offset", None, None, Some(Value::Object(m)), "android",
        &[("x-router", "fm.service.kugou.com"), ("Content-Type", "application/json")], false, false,
    )
}

/// yueku_fm.js → /yueku/fm（乐库下的 fm）。
pub fn handle_yueku_fm(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q, ctx, "GET", "/v1/time_fm_info", None,
        Some(json!({ "operator": 7, "plat": 0, "type": 11, "area_code": 1, "req_multi": 1 })),
        None, "android", &[("x-router", "fm.service.kugou.com")], false, false,
    )
}

/// personal_fm.js → /personal/fm
pub fn handle_personal_fm(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let date_time = now_ms();
    let userid = cookie_or_param_num(q, "userid", 0);
    let token = cookie_or_param_str(q, "token", "");
    let vip_type = {
        let c = c_num(q, "vip_type", 0);
        if c != 0 {
            c
        } else {
            q_num(q, "vipType", 0)
        }
    };
    let mid = c_str(q, "KUGOU_API_MID");
    let song_pool_id = q_num(q, "song_pool_id", 0);
    let remain_songcnt = q_num(q, "remain_songcnt", 0);
    let mut m = Map::new();
    m.insert("appid".into(), json!(3116));
    m.insert("clienttime".into(), json!(date_time));
    if !mid.is_empty() {
        m.insert("mid".into(), json!(mid));
    }
    m.insert("action".into(), json!(q_str(q, "action", "play")));
    m.insert("recommend_source_locked".into(), json!(0));
    m.insert("song_pool_id".into(), json!(song_pool_id));
    m.insert("callerid".into(), json!(0));
    m.insert("m_type".into(), json!(1));
    m.insert("platform".into(), json!(q_str(q, "platform", "ios")));
    m.insert("area_code".into(), json!(1));
    m.insert("remain_songcnt".into(), json!(remain_songcnt));
    m.insert("clientver".into(), json!(11440));
    m.insert("is_overplay".into(), json!(if q_truthy(q, "is_overplay") { 1 } else { 0 }));
    m.insert("mode".into(), json!(q_str(q, "mode", "normal")));
    m.insert("fakem".into(), json!("ca981cfc583a4c37f28d2d49000013c16a0a"));
    m.insert("key".into(), json!(sign_params_key(&date_time.to_string(), "", "")));
    if userid != 0 {
        m.insert("userid".into(), json!(userid));
        m.insert("kguid".into(), json!(userid));
    }
    if !token.is_empty() {
        m.insert("token".into(), json!(token));
    }
    if vip_type != 0 {
        m.insert("vip_type".into(), json!(vip_type));
    }
    if !q_str(q, "hash", "").is_empty() {
        m.insert("hash".into(), json!(q_str(q, "hash", "")));
    }
    if !q_str(q, "songid", "").is_empty() {
        m.insert("songid".into(), json!(q_str(q, "songid", "")));
    }
    if !q_str(q, "playtime", "").is_empty() {
        m.insert("playtime".into(), json!(q_str(q, "playtime", "")));
    }
    forward(
        q, ctx, "POST", "/v2/personal_recommend", None, None, Some(Value::Object(m)), "android",
        &[("x-router", "persnfm.service.kugou.com")], false, false,
    )
}

/// pc_diantai.js → /pc/diantai（电台 banner）。
pub fn handle_pc_diantai(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = cookie_or_param_num(q, "userid", 0);
    let data_map = json!({ "isvip": 0, "userid": userid, "vipType": 0 });
    forward(
        q, ctx, "POST", "/v3/pc_diantai", Some("https://adservice.kugou.com"),
        None, Some(data_map), "android", &[], false, false,
    )
}
