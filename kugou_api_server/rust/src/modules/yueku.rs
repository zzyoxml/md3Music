//! yueku 系列：yueku / yueku/banner
//! 对应 JS module/{yueku,yueku_banner}.js

use crate::modules::{forward, param_or_cookie_num, Ctx};
use crate::request::ModuleResponse;
use serde_json::{json, Value};

/// yueku.js → /yueku（安卓乐库内容）。
pub fn handle_yueku(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q, ctx, "GET", "/v1/yueku/recommend_v2", None,
        Some(json!({ "operator": 7, "plat": 0, "type": 11, "area_code": 1, "req_multi": 1 })),
        None, "android", &[("x-router", "service.mobile.kugou.com")], false, false,
    )
}

/// yueku_banner.js → /yueku/banner（乐库 banner）。
pub fn handle_banner(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = param_or_cookie_num(q, "userid", 0);
    let data_map = json!({
        "plat": 0,
        "channel": 201,
        "operator": 7,
        "networktype": 2,
        "userid": userid,
        "vip_type": 0,
        "m_type": 0,
        "tags": [],
        "apiver": 5,
        "ability": 2,
        "mode": "normal",
    });
    forward(q, ctx, "POST", "/ads.gateway/v3/listen_banner", None, None, Some(data_map), "android", &[], false, false)
}
