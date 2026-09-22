//! scene 系列：audio_list / collection_list / lists / lists_v2 / module / module_info / music / video_list
//! 对应 JS module/{scene_*.js}

use crate::modules::{forward, q_num, q_str, Ctx};
use crate::request::ModuleResponse;
use serde_json::{json, Value};

fn userid(q: &Value) -> i64 {
    let p = q_num(q, "userid", 0);
    if p != 0 {
        p
    } else {
        crate::modules::c_num(q, "userid", 0)
    }
}

/// scene_audio_list.js → /scene/audio/list（场景歌曲列表）。
pub fn handle_audio_list(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let token = {
        let p = q_str(q, "token", "");
        if !p.is_empty() {
            p
        } else {
            crate::modules::c_str(q, "token")
        }
    };
    let data_map = json!({
        "appid": 3116,
        "clientver": 11440,
        "token": token,
        "userid": userid(q),
    });
    let params = json!({
        "scene_id": q.get("id").cloned().unwrap_or(Value::Null),
        "module_id": q.get("module_id").cloned().unwrap_or(Value::Null),
        "tag": q.get("tag").cloned().unwrap_or(Value::Null),
        "page": q_num(q, "page", 1),
        "page_size": q_num(q, "pagesize", 30),
    });
    forward(
        q, ctx, "POST", "/scene/v1/scene/audio_list", None,
        Some(params), Some(data_map), "android", &[], false, false,
    )
}

/// scene_collection_list.js → /scene/collection/list（场景合集列表）。
pub fn handle_collection_list(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let token = {
        let p = q_str(q, "token", "");
        if !p.is_empty() {
            p
        } else {
            crate::modules::c_str(q, "token")
        }
    };
    let data_map = json!({
        "appid": 3116,
        "clientver": 11440,
        "token": token,
        "userid": userid(q),
        "tag_id": q.get("tag_id").cloned().unwrap_or(Value::Null),
        "page": q_num(q, "page", 1),
        "page_size": q_num(q, "pagesize", 30),
        "exposed_data": [],
    });
    forward(
        q, ctx, "POST", "/scene/v1/distribution/collection_list", None,
        None, Some(data_map), "android", &[], false, false,
    )
}

/// scene_lists.js → /scene/lists（场景列表）。
pub fn handle_lists(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q, ctx, "GET", "/scene/v1/scene/list", None,
        None, None, "android", &[], false, false,
    )
}

/// scene_lists_v2.js → /scene/lists/v2（场景列表 v2）。
pub fn handle_lists_v2(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let kugouid = {
        let p = q_num(q, "userid", 0);
        if p != 0 {
            p
        } else {
            crate::modules::c_num(q, "userid", 0)
        }
    };
    let sort = match q_str(q, "sort", "rec").as_str() {
        "hot" => 2,
        "new" => 3,
        "rec" => 1,
        _ => 1,
    };
    let params = json!({
        "scene_id": q.get("id").cloned().unwrap_or(Value::Null),
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
        "sort_type": sort,
        "kugouid": kugouid.to_string(),
    });
    forward(
        q, ctx, "POST", "/scene/v1/scene/list_v2", None,
        Some(params), Some(json!({ "exposure": [] })), "android", &[], false, false,
    )
}

/// scene_module.js → /scene/module（场景模块）。
pub fn handle_module(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params = json!({ "scene_id": q.get("id").cloned().unwrap_or(Value::Null) });
    forward(
        q, ctx, "POST", "/scene/v1/scene/module", None,
        Some(params), None, "android", &[], false, false,
    )
}

/// scene_module_info.js → /scene/module/info（场景模块信息）。
pub fn handle_module_info(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params = json!({
        "scene_id": q.get("id").cloned().unwrap_or(Value::Null),
        "module_id": q.get("module_id").cloned().unwrap_or(Value::Null),
    });
    forward(
        q, ctx, "GET", "/scene/v1/scene/module_info", None,
        Some(params), None, "android", &[], false, false,
    )
}

/// scene_music.js → /scene/music（场景音乐推荐）。
pub fn handle_music(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params = json!({
        "scene_id": q.get("id").cloned().unwrap_or(Value::Null),
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
    });
    forward(
        q, ctx, "POST", "/genesisapi/v1/scene_music/rec_music", None,
        Some(params), Some(json!({ "exposure": [] })), "android", &[], false, false,
    )
}

/// scene_video_list.js → /scene/video/list（场景视频列表）。
pub fn handle_video_list(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let token = {
        let p = q_str(q, "token", "");
        if !p.is_empty() {
            p
        } else {
            crate::modules::c_str(q, "token")
        }
    };
    let data_map = json!({
        "appid": 3116,
        "clientver": 11440,
        "token": token,
        "userid": userid(q),
        "tag_id": q.get("tag_id").cloned().unwrap_or(Value::Null),
        "page": q_num(q, "page", 1),
        "page_size": q_num(q, "pagesize", 30),
        "exposed_data": [],
    });
    forward(
        q, ctx, "POST", "/scene/v1/distribution/video_list", None,
        None, Some(data_map), "android", &[], false, false,
    )
}
