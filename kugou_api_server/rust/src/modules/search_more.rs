//! search 扩展系列：album / artist / hot / special / complex / default / lyric
//! 对应 JS module/{search_album,search_artist,search_hot,search_special,search_complex,search_default,search_lyric}.js

use crate::modules::{forward, q_num, q_str, Ctx};
use crate::request::ModuleResponse;
use serde_json::{json, Value};

fn keyword(q: &Value) -> String {
    let kw = q_str(q, "keyword", "");
    if !kw.is_empty() {
        kw
    } else {
        q_str(q, "keywords", "")
    }
}

/// search_album.js → /search/album（搜索专辑）。
pub fn handle_album(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let data_map = json!({
        "keyword": keyword(q),
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 20),
        "iscorrection": 1,
        "highlight": "em",
        "plat": 0,
    });
    forward(
        q, ctx, "GET", "/api/v3/search/album", None,
        Some(data_map), None, "android", &[("x-router", "msearch.kugou.com")], false, false,
    )
}

/// search_artist.js → /search/artist（搜索歌手）。
pub fn handle_artist(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let data_map = json!({
        "keyword": keyword(q),
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 20),
        "showtype": 14,
        "highlight": "em",
        "plat": 0,
        "sver": 5,
    });
    forward(
        q, ctx, "GET", "/api/v3/search/singer", None,
        Some(data_map), None, "android", &[("x-router", "msearchcdn.kugou.com")], false, false,
    )
}

/// search_hot.js → /search/hot（热搜词）。
pub fn handle_hot(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let data_map = json!({
        "navid": 1,
        "plat": 2,
    });
    forward(
        q, ctx, "GET", "/api/v3/search/hot_tab", None,
        Some(data_map), None, "android", &[("x-router", "msearch.kugou.com")], false, false,
    )
}

/// search_special.js → /search/special（搜索歌单）。
pub fn handle_special(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let data_map = json!({
        "keyword": keyword(q),
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 20),
        "filter": 0,
        "highlight": "em",
    });
    forward(
        q, ctx, "GET", "/api/v3/search/special", None,
        Some(data_map), None, "android", &[("x-router", "mobilecdnbj.kugou.com")], false, false,
    )
}

/// search_complex.js → /search/complex（综合搜索）。
pub fn handle_complex(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let data_map = json!({
        "platform": "AndroidFilter",
        "keyword": q.get("keywords").cloned().unwrap_or(Value::Null),
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
        "cursor": 0,
    });
    forward(
        q, ctx, "GET", "/v6/search/complex", Some("https://complexsearch.kugou.com"),
        Some(data_map), None, "android", &[], false, false,
    )
}

/// search_default.js → /search/default（默认搜索词）。
pub fn handle_default(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid: i64 = {
        let p = q_num(q, "userid", 0);
        if p != 0 {
            p
        } else {
            crate::modules::c_num(q, "userid", 0)
        }
    };
    let vip_type: i64 = {
        let p = q_num(q, "vip_type", 0);
        if p != 0 {
            p
        } else {
            crate::modules::c_num(q, "vip_type", 65530)
        }
    };
    let data_map = json!({
        "plat": 0,
        "userid": userid,
        "tags": "{}",
        "vip_type": vip_type,
        "m_type": 0,
        "own_ads": {},
        "ability": "3",
        "sources": [],
        "bitmap": 2,
        "mode": "normal",
    });
    forward(
        q, ctx, "POST", "/searchnofocus/v1/search_no_focus_word", None,
        Some(json!({ "clientver": 12329 })), Some(data_map), "android", &[], false, false,
    )
}

/// search_lyric.js → /search/lyric（歌词搜索，lyrics.kugou.com）。
/// 注：JS 中 `notSign` 不被 createRequest 识别，仍会计算 signature。
pub fn handle_lyric(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let man = match q.get("man") {
        Some(v) if !v.is_null() => crate::util::js_string(Some(v)),
        _ => "no".to_string(),
    };
    let data_map = json!({
        "album_audio_id": q_num(q, "album_audio_id", 0),
        "appid": 3116,
        "clientver": 11440,
        "duration": q_num(q, "duration", 0),
        "hash": q_str(q, "hash", ""),
        "keyword": q_str(q, "keywords", ""),
        "lrctxt": 1,
        "man": man,
    });
    forward(
        q, ctx, "GET", "/v1/search", Some("https://lyrics.kugou.com"),
        Some(data_map), None, "android", &[], true, false,
    )
}
