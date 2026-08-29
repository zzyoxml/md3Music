//! theme 系列：music / music_detail / playlist / playlist_track
//! 对应 JS module/{theme_music,theme_music_detail,theme_playlist,theme_playlist_track}.js

use crate::cache::now_epoch_secs;
use crate::modules::{forward, q_num, Ctx};
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

/// theme_music.js → /theme/music（主题音乐）。
pub fn handle_music(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let clienttime = now_epoch_secs() as i64;
    let data_map = json!({
        "platform": "android",
        "clienttime": clienttime,
        "show_theme_category_ids": q.get("ids").cloned().unwrap_or(Value::Null),
        "userid": userid(q),
        "module_id": 508,
    });
    forward(
        q, ctx, "POST", "/everydayrec.service/v1/mul_theme_category_recommend", None,
        None, Some(data_map), "android", &[], false, false,
    )
}

/// theme_music_detail.js → /theme/music/detail（主题音乐详情）。
pub fn handle_music_detail(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let clienttime = now_epoch_secs() as i64;
    let data_map = json!({
        "platform": "android",
        "clienttime": clienttime,
        "theme_category_id": q.get("id").cloned().unwrap_or(Value::Null),
        "show_theme_category_id": 0,
        "userid": userid(q),
        "module_id": 508,
    });
    forward(
        q, ctx, "POST", "/everydayrec.service/v1/theme_category_recommend", None,
        None, Some(data_map), "android", &[], false, false,
    )
}

/// theme_playlist.js → /theme/playlist（主题歌单）。
pub fn handle_playlist(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let clienttime = (now_epoch_secs() * 1000.0) as i64;
    let data_map = json!({
        "platform": "android",
        "clientver": 11440,
        "clienttime": clienttime,
        "area_code": 1,
        "module_id": 1,
        "userid": userid(q),
    });
    forward(
        q, ctx, "POST", "/v2/getthemelist", None,
        None, Some(data_map), "android",
        &[("x-router", "everydayrec.service.kugou.com")], false, false,
    )
}

/// theme_playlist_track.js → /theme/playlist/track（主题歌单歌曲）。
pub fn handle_playlist_track(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let clienttime = (now_epoch_secs() * 1000.0) as i64;
    let data_map = json!({
        "platform": "android",
        "clientver": 11440,
        "clienttime": clienttime,
        "area_code": 1,
        "module_id": 1,
        "userid": userid(q),
        "theme_id": q.get("theme_id").cloned().unwrap_or(Value::Null),
    });
    forward(
        q, ctx, "POST", "/v2/gettheme_songidlist", None,
        None, Some(data_map), "android",
        &[("x-router", "everydayrec.service.kugou.com")], false, false,
    )
}
