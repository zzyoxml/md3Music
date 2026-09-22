//! sheet 系列：collection / detail / explore / rank / song / tags
//! 对应 JS module/{sheet_*.js}

use crate::modules::{forward, q_num, Ctx};
use crate::request::ModuleResponse;
use serde_json::{json, Value};

/// sheet_collection.js → /sheet/collection（乐谱首页模块配置）。
pub fn handle_collection(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let position = match q.get("position") {
        Some(v) if !v.is_null() => crate::util::js_string(Some(v)),
        _ => "2".to_string(),
    };
    let params_map = json!({
        "srcappid": 3116,
        "position": position,
    });
    forward(
        q, ctx, "GET", "/miniyueku/v1/opern_square/get_home_module_config", None,
        Some(params_map), None, "web", &[], false, false,
    )
}

/// sheet_detail.js → /sheet/detail（乐谱详情）。
pub fn handle_detail(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params_map = json!({ "opern_id": q.get("id").cloned().unwrap_or(Value::Null) });
    forward(
        q, ctx, "GET", "/opern/v1/detail/info", None,
        Some(params_map), None, "android", &[], false, false,
    )
}

/// sheet_explore.js → /sheet/explore（乐谱推荐）。
pub fn handle_explore(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params = json!({
        "pagesize": q_num(q, "pagesize", 30),
        "page": q_num(q, "page", 1),
        "opern_level": q_num(q, "level", 0),
        "instruments": q_num(q, "instruments", 1),
        "tagid": q_num(q, "tagid", 0),
    });
    forward(
        q, ctx, "POST", "/opern/v1/home/get_rec_opern", None,
        Some(params), Some(json!({ "exposure_mixids": "" })), "android", &[], false, false,
    )
}

/// sheet_rank.js → /sheet/rank（乐谱排行榜）。
pub fn handle_rank(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params = json!({
        "pagesize": q_num(q, "pagesize", 30),
        "page": q_num(q, "page", 1),
        "opern_level": q_num(q, "level", 0),
        "instruments": q_num(q, "instruments", 1),
        "tagid": q_num(q, "tagid", 0),
    });
    forward(
        q, ctx, "POST", "/opern/v1/home/get_rank_opern", None,
        Some(params), None, "android", &[], false, false,
    )
}

/// sheet_song.js → /sheet/song（乐谱列表）。
pub fn handle_song(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let instruments = match q.get("instruments") {
        Some(v) if !v.is_null() => crate::util::js_string(Some(v)),
        _ => "1".to_string(),
    };
    let opern_level = match q.get("level") {
        Some(v) if !v.is_null() => crate::util::js_string(Some(v)),
        _ => "0".to_string(),
    };
    let params_map = json!({
        "mixsongid": q.get("album_audio_id").cloned().unwrap_or(Value::Null),
        "instruments": instruments,
        "opern_level": opern_level,
    });
    forward(
        q, ctx, "GET", "/opern/v1/detail/song_info", None,
        Some(params_map), None, "android", &[], false, false,
    )
}

/// sheet_tags.js → /sheet/tags（乐谱 tag）。
pub fn handle_tags(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q, ctx, "GET", "/opern/v1/home/get_tags", None,
        None, None, "android", &[], false, false,
    )
}
