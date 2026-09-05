//! everyday 系列：friend / history / recommend / style_recommend / recommend_songs
//! 对应 JS module/{everyday_friend,everyday_history,everyday_recommend,everyday_style_recommend,recommend_songs}.js

use crate::modules::{forward, q_cookie, q_str, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use serde_json::{json, Value};

/// everyday_friend.js → /everyday/friend
pub fn handle_friend(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let body = json!({
        "list": [{
            "user_id": 853927886,
            "mixsong_ids": [290083753,251724346,571554587,250126644,208831644,40328518,250504076,581706850,318347675,585258401,288481998,407414475,28239430,280584633,291957521,64556644,243149863,488725103,32114153,39951172,29019580,40397606,327507651,32029382,32218359,340353127,276448762,177071956,100031397,249251602],
        }],
    });
    let params = json!({ "channel": 130, "isteen": 0, "platform": 2, "usemkv": 1 });
    forward(
        q, ctx, "POST", "/sing7/relation/json/v3/friend_rec_by_using_song_list",
        Some("https://acsing.service.kugou.com"), Some(params), Some(body), "android",
        &[("pid", "126556797")], false, false,
    )
}

/// everyday_history.js → /everyday/history
pub fn handle_history(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let mut m = serde_json::Map::new();
    m.insert("mode".into(), json!(q_str(q, "mode", "list")));
    m.insert("platform".into(), json!(q_str(q, "platform", "ios")));
    if !q_str(q, "history_name", "").is_empty() {
        m.insert("history_name".into(), json!(q_str(q, "history_name", "")));
    }
    if !q_str(q, "date", "").is_empty() {
        m.insert("date".into(), json!(q_str(q, "date", "")));
    }
    forward(
        q, ctx, "POST", "/everyday/api/v1/get_history", None,
        Some(Value::Object(m)), None, "android",
        &[("x-router", "everydayrec.service.kugou.com")], false, false,
    )
}

/// everyday_recommend.js → /everyday/recommend
pub fn handle_recommend(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q, ctx, "POST", "/everyday_song_recommend", None,
        Some(json!({ "platform": q_str(q, "platform", "ios") })), None, "android",
        &[("x-router", "everydayrec.service.kugou.com")], false, false,
    )
}

/// everyday_style_recommend.js → /everyday/style/recommend
pub fn handle_style_recommend(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q, ctx, "POST", "/everydayrec.service/everyday_style_recommend", None,
        Some(json!({ "tagids": q_str(q, "tagids", "") })), Some(json!({})), "android",
        &[], false, false,
    )
}

/// recommend_songs.js → /recommend/songs（每日推荐歌曲）。
pub fn handle_recommend_songs(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = {
        let p = q_str(q, "userid", "");
        if !p.is_empty() {
            p
        } else {
            crate::modules::c_str(q, "userid")
        }
    };
    let userid = if userid.is_empty() { "0".to_string() } else { userid };
    let body = json!({
        "platform": q_str(q, "platform", "android"),
        "userid": userid,
    });
    let opts = RequestOptions::new("/everyday_song_recommend")
        .post("/everyday_song_recommend")
        .json_body(body)
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .header("x-router", "everydayrec.service.kugou.com");
    ctx.send(&opts)
}
