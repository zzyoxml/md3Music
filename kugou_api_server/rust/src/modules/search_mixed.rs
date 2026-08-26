//! search_mixed.js → /search/mixed（综合搜索）。

use crate::cache::now_epoch_secs;
use crate::crypto::crypto_md5_str;
use crate::modules::{q_cookie, q_num, Ctx};
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

/// /search/audiobook → 听书/有声书关键词搜索。
///
/// 走标准版综合搜索 `/complexsearch/v4/search/song`（host gateway.kugou.com，
/// appid=1005 + 标准签名盐 OIlwieks28dk2k092lksi2UIkp），返回 data.lists 章节列表。
pub fn handle_audiobook(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let keyword = q.get("keyword").cloned().unwrap_or(Value::Null);
    let page = q_num(q, "page", 1);
    let pagesize = q_num(q, "pagesize", 10);
    let m = json!({
        "appid": 1005,
        "clientver": 20789,
        "area_code": 1,
        "albumhide": 1,
        "com_user_type": 0,
        "privilegefilter": 0,
        "dopicfull": 1,
        "filter": 12,
        "platform": "AndroidFilter",
        "tag": "em",
        "recver": 2,
        "iscorrection": 1,
        "search_ability": 223,
        "sec_aggre": 1,
        "sec_aggre_bitmap": 0,
        "mode_ability": 1,
        "nocollect": 1,
        "user_type": 0,
        "keyword": keyword,
        "page": page,
        "pagesize": pagesize,
    });
    let opts = RequestOptions::new("/complexsearch/v4/search/song")
        .get("/complexsearch/v4/search/song")
        .params(m)
        .encrypt_type("android")
        .standard_signature(true)
        .cookie(q_cookie(q));
    ctx.send(&opts)
}
