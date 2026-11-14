//! audio 扩展系列：audio_related / audio_accompany_matching / audio_ktv_total / kmr_audio_mv / krm_audio
//! 对应 JS module/{audio_related,audio_accompany_matching,audio_ktv_total,kmr_audio_mv,krm_audio}.js

use crate::crypto::{crypto_md5_str, md5_hex};
use crate::modules::{forward, q_num, q_str, sorted_kv_joined, Ctx};
use crate::request::ModuleResponse;
use serde_json::{json, Map, Value};

/// audio_related.js → /audio/related（相关歌曲 / 高潮合辑）。
pub fn handle_related(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let show_detail = q_num(q, "show_detail", 0) == 0;
    let album_audio_id: i64 = q_num(q, "album_audio_id", 0);

    let mut data_map = Map::new();
    data_map.insert("album_audio_id".to_string(), json!(album_audio_id));
    data_map.insert("appid".to_string(), json!(1005));
    data_map.insert("area_code".to_string(), json!(1));
    data_map.insert("clientver".to_string(), json!(12329));

    let sort = match q_str(q, "sort", "").as_str() {
        "hot" => 2,
        "new" => 3,
        _ => 1,
    };
    if !show_detail {
        data_map.insert("page".to_string(), json!(q_num(q, "page", 1)));
        data_map.insert("pagesize".to_string(), json!(q_num(q, "pagesize", 30)));
        data_map.insert("show_input".to_string(), json!(1));
        data_map.insert("show_type".to_string(), json!(q_num(q, "show_type", 0)));
        data_map.insert("sort".to_string(), json!(sort));
        data_map.insert("type".to_string(), json!(q_num(q, "type", 0)));
    }
    data_map.insert("version".to_string(), json!(1));

    let str_const = "OIlwieks28dk2k092lksi2UIkp";
    let params_string = sorted_kv_joined(&json!(data_map), "");
    let signature = crypto_md5_str(&format!("{}{}{}", str_const, params_string, str_const));
    data_map.insert("signature".to_string(), json!(signature));

    let url = if show_detail {
        "/v2/audio_related/total"
    } else {
        "/v3/album_audio/related"
    };
    forward(
        q, ctx, "GET", url, Some("https://listkmrp3cdnretry.kugou.com"),
        Some(json!(data_map)), None, "android", &[], true, false,
    )
}

/// audio_accompany_matching.js → /audio/accompany/matching（伴奏匹配）。
pub fn handle_accompany_matching(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let mut data_map = Map::new();
    data_map.insert("isteen".to_string(), json!(0));
    data_map.insert("mixId".to_string(), json!(q_num(q, "mixId", 0)));
    data_map.insert("usemkv".to_string(), json!(1));
    data_map.insert("platform".to_string(), json!(2));
    data_map.insert("fileName".to_string(), json!(q_str(q, "fileName", "")));
    data_map.insert("hash".to_string(), q.get("hash").cloned().unwrap_or(Value::Null));
    data_map.insert("version".to_string(), json!(12375));
    data_map.insert("appid".to_string(), json!(3116));

    let str_const = "*s&iN#G70*";
    let params_string = sorted_kv_joined(&json!(data_map), "&");
    let sign = md5_hex(format!("{}{}", params_string, str_const).as_bytes());
    let sign = sign[8..24].to_string();
    data_map.insert("sign".to_string(), json!(sign));

    forward(
        q, ctx, "GET", "/sing7/accompanywan/json/v2/cdn/optimal_matching_accompany_2_listen.do",
        Some("https://nsongacsing.kugou.com"),
        Some(json!(data_map)), None, "android", &[], true, true,
    )
}

/// audio_ktv_total.js → /audio/ktv/total（KTV 曲库数量）。
pub fn handle_ktv_total(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let mut data_map = Map::new();
    data_map.insert("isteen".to_string(), json!(0));
    data_map.insert("songId".to_string(), json!(q_num(q, "songId", 0)));
    data_map.insert("usemkv".to_string(), json!(1));
    data_map.insert("platform".to_string(), json!(2));
    data_map.insert("singerName".to_string(), q.get("singerName").cloned().unwrap_or(Value::Null));
    data_map.insert("songHash".to_string(), q.get("songHash").cloned().unwrap_or(Value::Null));
    data_map.insert("version".to_string(), json!(12375));
    data_map.insert("appid".to_string(), json!(3116));

    let str_const = "*s&iN#G70*";
    let params_string = sorted_kv_joined(&json!(data_map), "&");
    let sign = md5_hex(format!("{}{}", params_string, str_const).as_bytes());
    let sign = sign[8..24].to_string();
    data_map.insert("sign".to_string(), json!(sign));

    forward(
        q, ctx, "GET", "/sing7/listenguide/json/v2/cdn/listenguide/get_total_opus_num_v02.do",
        Some("https://acsing.service.kugou.com"),
        Some(json!(data_map)), None, "android", &[], true, true,
    )
}

/// kmr_audio_mv.js → /kmr/audio/mv（歌曲 MV）。
pub fn handle_kmr_audio_mv(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let resource: Vec<Value> = q_str(q, "album_audio_id", "")
        .split(',')
        .map(|s| json!({ "album_audio_id": s }))
        .collect();
    let data_map = json!({
        "data": resource,
        "fields": q_str(q, "fields", ""),
    });
    forward(
        q, ctx, "POST", "/kmr/v1/audio/mv", None,
        None, Some(data_map), "android",
        &[("x-router", "openapi.kugou.com"), ("KG-TID", "38")],
        false, false,
    )
}

/// krm_audio.js → /krm/audio（歌手/专辑/歌曲信息）。
pub fn handle_krm_audio(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let resource: Vec<Value> = q_str(q, "album_audio_id", "")
        .split(',')
        .map(|s| {
            let n: i64 = s.trim().parse().unwrap_or(0);
            json!({ "entity_id": n })
        })
        .collect();
    let data_map = json!({
        "data": resource,
        "fields": q_str(q, "fields", "base"),
    });
    forward(
        q, ctx, "POST", "/kmr/v2/audio", None,
        None, Some(data_map), "android",
        &[("x-router", "openapi.kugou.com"), ("KG-TID", "238")],
        false, false,
    )
}
