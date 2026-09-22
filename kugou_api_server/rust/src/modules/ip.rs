//! ip.js → /ip（根据 ip id 获取歌曲/专辑/视频/歌手）。

use crate::modules::{q_cookie, q_num, q_str, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use serde_json::{json, Value};

pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let data_map = json!({
        "is_publish": 1,
        "ip_id": q.get("id").cloned().unwrap_or(Value::Null),
        "sort": 3,
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
        "query": 1,
    });

    let raw_type = q_str(q, "type", "");
    let type_ = if ["audios", "albums", "videos", "author_list"].contains(&raw_type.as_str()) {
        raw_type
    } else {
        "audios".to_string()
    };

    let opts = RequestOptions::new(&format!("/openapi/v1/ip/{}", type_))
        .post(&format!("/openapi/v1/ip/{}", type_))
        .json_body(data_map)
        .encrypt_type("android")
        .cookie(q_cookie(q));
    ctx.send(&opts)
}
