//! search.js → /search（歌曲搜索）。

use crate::modules::{forward, q_cookie, q_num, q_str, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use serde_json::{json, Value};

pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let keyword = {
        let kw = q_str(q, "keywords", "");
        if !kw.is_empty() {
            kw
        } else {
            q_str(q, "keyword", "")
        }
    };
    let page = q_num(q, "page", 1);
    let pagesize = q_num(q, "pagesize", 30);

    // 按歌词搜索歌曲：/search?type=lyric → complexsearch.kugou.com/v1/search/lyric
    // 返回的每条结果带 `Lyric` 字段（匹配的歌词片段）。
    if q_str(q, "type", "song") == "lyric" {
        let data_map = json!({
            "keyword": keyword,
            "page": page,
            "pagesize": pagesize,
            "platform": "WebFilter",
            "iscorrection": 1,
        });
        return forward(
            q, ctx, "GET", "/v1/search/lyric", None,
            Some(data_map), None, "android",
            &[("x-router", "complexsearch.kugou.com")],
            false, false,
        );
    }

    let data_map = json!({
        "keyword": keyword,
        "page": page,
        "pagesize": pagesize,
        "platform": "WebFilter",
        "iscorrection": 1,
        "albumhide": 0,
        "nocollect": 0,
    });

    let opts = RequestOptions::new("/song_search_v2")
        .get("/song_search_v2")
        .params(data_map)
        .encrypt_type("android")
        .header("x-router", "songsearch.kugou.com")
        .cookie(q_cookie(q));
    ctx.send(&opts)
}
