//! get_model: 获取社区音效列表。对应 JS module/get_model.js → GET /get/model
//! 上游: GET gateway.kugou.com/ocean/v6/sound/list（默认 gateway，android 签名，注入默认参数）。
//! 响应 `{ status: 1, data: [ { id, name, classify, tag_name, sound, intro, ... } ] }`，
//! classify=2 为官方蝰蛇音效，classify=3 为社区音效。

use crate::modules::{forward, q_num, Ctx};
use crate::request::ModuleResponse;
use serde_json::{json, Value};

/// GET /get/model?sort=&page=&pagesize=
///
/// sort: 排序，不传默认 2（3=最热，4=最新）；page: 页数；pagesize: 每页数量，默认 30。
pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let dm = json!({
        "super_vip": 1,
        "sound_ver": 2,
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
        "apiver": 3,
        "classify": "2,3",
        "plat": 2,
        "privilege": 1,
        "sort": q_num(q, "sort", 2),
    });
    forward(
        q, ctx, "GET", "/ocean/v6/sound/list", None,
        Some(dm), None, "android", &[], false, false,
    )
}
