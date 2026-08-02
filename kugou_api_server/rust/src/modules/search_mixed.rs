//! search_mixed.js → /search/mixed（综合搜索）。

use crate::cache::now_epoch_secs;
use crate::crypto::crypto_md5_str;
use crate::modules::{q_cookie, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use serde_json::{json, Value};

pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let time = (now_epoch_secs() * 1000.0) as i64;
    let requestid = format!("{}_0", crypto_md5_str(&format!("bdaa53d04e7475feb9024164a47032f9{}", time)));

    let data_map = json!({
        "ab_tag": 0,
        "ability": 511,
        "albumhide": 0,
        "apiver": 22,
        "area_code": 1,
        "clientver": 20125,
        "cursor": 0,
        "is_gpay": 0,
        "iscorrection": 1,
        "keyword": q.get("keyword").cloned().unwrap_or(Value::Null),
        "nocollect": 0,
        "osversion": 16.5,
        "platform": "IOSFilter",
        "recver": 2,
        "req_ai": 1,
        "requestid": requestid,
        "search_ability": 3,
        "sec_aggre": 1,
        "sec_aggre_bitmap": 0,
        "style_type": 3,
        "tag": "em",
    });

    let opts = RequestOptions::new("/v3/search/mixed")
        .get("/v3/search/mixed")
        .params(data_map)
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .header("x-router", "complexsearch.kugou.com")
        .header("kg-clienttimems", &time.to_string());
    ctx.send(&opts)
}
