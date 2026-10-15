//! comment_music.js → /comment/music（歌曲评论）。

use crate::modules::{param_or_cookie_str, q_cookie, q_num, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use serde_json::{json, Value};

pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let mixsongid = {
        let v = q_str_param(q, "mixsongid");
        if !v.is_empty() {
            v
        } else {
            q_str_param(q, "album_audio_id")
        }
    };

    let r = json!({
        "mixsongid": mixsongid,
        "need_show_image": 1,
        "p": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
        "show_classify": q_num(q, "show_classify", 1),
        "show_hotword_list": q_num(q, "show_hotword_list", 1),
        "extdata": "0",
        "code": "fc4be23b4e972707f36b8a828a93ba8a",
    });

    let opts = RequestOptions::new("/mcomment/v1/cmtlist")
        .post("/mcomment/v1/cmtlist")
        .params(r)
        .encrypt_type("android")
        .cookie(q_cookie(q));
    ctx.send(&opts)
}

fn q_str_param(q: &Value, key: &str) -> String {
    param_or_cookie_str(q, key, "")
}
