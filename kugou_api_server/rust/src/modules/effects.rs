//! 酷狗音效目录接口，对应 KuGouMusicApi 的 effects 系列模块。
//!
//! 这些接口使用 mobilecdngz.kugou.com 的 Android 参数签名。应用层只展示
//! `sound` 可直接下载且非会员的条目；服务端保持上游原始响应，方便后续扩展。

use crate::modules::{forward, q_num, Ctx};
use crate::request::ModuleResponse;
use serde_json::{json, Value};

const CDN_BASE: &str = "http://mobilecdngz.kugou.com";
const EFFECT_VERSION: i64 = 12460;

/// GET /effects/brand：耳机品牌列表。
pub fn handle_brand(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let dm = json!({
        "sort": q_num(q, "sort", 1),
        "pagesize": q_num(q, "pagesize", 30),
        "page": q_num(q, "page", 1),
    });
    forward(q, ctx, "GET", "/api/v5/earphone/get_brand", Some(CDN_BASE), Some(dm), None, "android", &[], true, false)
}

/// GET /effects/brand/detail：指定耳机品牌的型号及音效列表。
pub fn handle_brand_detail(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let dm = json!({
        "brand_id": q_num(q, "brand_id", 0),
        "pagesize": q_num(q, "pagesize", 30),
        "page": q_num(q, "page", 1),
    });
    forward(q, ctx, "GET", "/api/v5/earphone/get_model", Some(CDN_BASE), Some(dm), None, "android", &[], true, false)
}

/// GET /effects/match：通用耳机/当前设备匹配的音效。
pub fn handle_match(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let dm = json!({
        "plat": 2,
        "version": EFFECT_VERSION,
    });
    forward(q, ctx, "GET", "/api/v5/earphone/match", Some(CDN_BASE), Some(dm), None, "android", &[], true, false)
}

/// GET /effects/artist：明星定制音效。
pub fn handle_artist(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let dm = json!({
        "plat": 2,
        "version": EFFECT_VERSION,
        "apiver": 2,
        "sort": 1,
        "pagesize": q_num(q, "pagesize", 30),
        "page": q_num(q, "page", 1),
        "classify": 1,
    });
    forward(q, ctx, "GET", "/api/v3/sound/list", Some(CDN_BASE), Some(dm), None, "android", &[], true, false)
}
