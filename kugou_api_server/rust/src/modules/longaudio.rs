//! longaudio 系列：album/audios、album/detail、daily/rank/vip/week recommend
//! 对应 JS module/longaudio_*.js

use crate::modules::{forward, q_cookie, q_num, q_str, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use serde_json::{json, Value};

/// longaudio_album_audios.js → /longaudio/album/audios
pub fn handle_album_audios(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let mut m = serde_json::Map::new();
    if let Some(v) = q.get("album_id").cloned() {
        m.insert("album_id".into(), v);
    }
    m.insert("area_code".into(), json!(1));
    m.insert("tagid".into(), json!(0));
    m.insert("page".into(), json!(q_num(q, "page", 1)));
    m.insert("pagesize".into(), json!(q_num(q, "pagesize", 30)));
    let opts = RequestOptions::new("/longaudio/v2/album_audios")
        .post("/longaudio/v2/album_audios")
        .json_body(Value::Object(m))
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .header("x-router", "openapi.kugou.com")
        .header("KG-TID", "78");
    ctx.send(&opts)
}

/// longaudio_album_detail.js → /longaudio/album/detail
pub fn handle_album_detail(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let data: Value = q_str(q, "album_id", "")
        .split(',')
        .map(|s| json!({ "album_id": s }))
        .collect::<Vec<_>>()
        .into();
    let body = json!({
        "data": data,
        "show_album_tag": 1,
        "fields": "album_name,album_id,category,authors,sizable_cover,intro,author_name,trans_param,album_tag,mix_intro,full_intro,is_publish",
    });
    let opts = RequestOptions::new("/openapi/v2/broadcast")
        .post("/openapi/v2/broadcast")
        .json_body(body)
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .header("KG-TID", "78");
    ctx.send(&opts)
}

/// longaudio_daily_recommend.js → /longaudio/daily/recommend
pub fn handle_daily_recommend(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q, ctx, "POST", "/longaudio/v1/home_new/daily_recommend", None,
        Some(json!({ "module_id": 1, "size": q_num(q, "pagesize", 30), "page": q_num(q, "page", 1) })),
        None, "android", &[], false, false,
    )
}

/// longaudio_rank_recommend.js → /longaudio/rank/recommend
pub fn handle_rank_recommend(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q, ctx, "GET", "/longaudio/v1/home_new/rank_card_recommend", None,
        Some(json!({ "platform": "ios" })), None, "android", &[], false, false,
    )
}

/// longaudio_vip_recommend.js → /longaudio/vip/recommend
pub fn handle_vip_recommend(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q, ctx, "POST", "/longaudio/v1/home_new/vip_select_recommend", None,
        Some(json!({ "position": "2", "clientver": 12329 })),
        Some(json!({ "album_playlist": [] })), "android", &[], false, false,
    )
}

/// longaudio_week_recommend.js → /longaudio/week/recommend
pub fn handle_week_recommend(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q, ctx, "POST", "/longaudio/v1/home_new/week_new_albums_recommend", None,
        Some(json!({ "clientver": 12329 })),
        Some(json!({ "album_playlist": [] })), "android", &[], false, false,
    )
}

/// /longaudio/album/list → 免费听书库/分类榜单专辑列表。
///
/// 抓包自酷狗 ListenBookCategoryMainFragment（gateway.kugou.com，appid=1005 标准盐）：
/// - tag_id：分类（906=有声小说、1097=玄幻异界…）；free=1 免费过滤
/// - gender：0=不限 / 1=男频 / 2=女频；status：0=全部 / 1=连载 / 2=完结；sort：0=默认 / 1=播放量 / 2=更新时间
/// - 分页：page / page_size（响应 data.data_list，data.is_end=1 表示到底）
pub fn handle_album_list(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let opts = RequestOptions::new("/longaudio/v1/album/list")
        .get("/longaudio/v1/album/list")
        .params(json!({
            "appid": 1005,
            "clientver": 20789,
            "api_ver": 2,
            "gender": q_num(q, "gender", 0),
            "sort": q_num(q, "sort", 0),
            "tag_id": q_num(q, "tag_id", 906),
            "free": q_num(q, "free", 1),
            "status": q_num(q, "status", 0),
            "page": q_num(q, "page", 1),
            "page_size": q_num(q, "page_size", 20),
        }))
        .encrypt_type("android")
        .standard_signature(true)
        .cookie(q_cookie(q));
    ctx.send(&opts)
}

/// /longaudio/tag/list → 听书分类标签树。
///
/// 抓包：GET gateway.kugou.com/v3/list_audiobook_tags（x-router: longaudio.kugou.com，
/// appid=1005 + 标准盐），返回 data[0]=有声小说(906)、其 son[] 为 24 个子分类。
pub fn handle_tag_list(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let opts = RequestOptions::new("/v3/list_audiobook_tags")
        .get("/v3/list_audiobook_tags")
        .params(json!({
            "appid": 1005,
            "clientver": 20789,
            "platform": "android",
        }))
        .encrypt_type("android")
        .standard_signature(true)
        .cookie(q_cookie(q))
        .header("x-router", "longaudio.kugou.com");
    ctx.send(&opts)
}
