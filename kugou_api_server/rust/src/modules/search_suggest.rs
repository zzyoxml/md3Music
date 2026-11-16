//! search_suggest.js → /search/suggest（搜索建议）。

use crate::modules::{q_cookie, q_num, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use serde_json::{json, Value};

pub fn handle(q: &serde_json::Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let opts = RequestOptions::new("/v2/getSearchTip")
        .get("/v2/getSearchTip")
        .params(json!({
            "keyword": q.get("keywords").cloned().unwrap_or(Value::Null),
            "AlbumTipCount": q_num(q, "albumTipCount", 10),
            "CorrectTipCount": q_num(q, "correctTipCount", 10),
            "MVTipCount": q_num(q, "mvTipCount", 10),
            "MusicTipCount": q_num(q, "musicTipCount", 10),
            "radiotip": 1,
        }))
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .header("x-router", "searchtip.kugou.com");
    ctx.send(&opts)
}
