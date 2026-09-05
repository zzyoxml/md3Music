//! audio_match.js（bundle 内联）→ /audio/match（听歌识曲，PCM 指纹）。

use crate::cache::now_epoch_secs;
use crate::modules::{param_or_cookie_num, q_cookie, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use serde_json::{json, Value};

pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = param_or_cookie_num(q, "userid", 0);
    let params = json!({
        "fpid": (now_epoch_secs() * 1000.0) as i64,
        "area_code": 1,
        "include_unpublish": 1,
        "useid": userid,
        "multi_result": 1,
    });
    let body = ctx.body_bytes.clone().unwrap_or_default();

    let opts = RequestOptions::new("/fingerprint.service/v1/music_trackid_mulit")
        .post("/fingerprint.service/v1/music_trackid_mulit")
        .params(params)
        .bytes_body(body)
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .header("content-type", "application/octet-stream")
        .header("user-agent", "KuGou/11490 (Android)");
    ctx.send(&opts)
}
