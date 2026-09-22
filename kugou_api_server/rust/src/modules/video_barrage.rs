//! MV 视频弹幕列表（底层复用 MV 评论池，只读）。
//!
//! 对照 KuGouMusicApi：
//! - `module/_comment.js` 的 `getListAuthParams` / `commentRequestConfig` /
//!   `buildVideoBarrageListConfig`
//! - `module/video_barrage.js`（入参校验：video_id 与 hash 至少其一）
//!
//! 与评论写接口（`comment_send.rs`）同走评论服务 `/index.php` +
//! `x-router: m.comment.service.kugou.com`，**跳过签名**（JS `notSignature`）且
//! **清空默认参数**（JS `clearDefaultParams`），设备/账号参数全部显式传入。
//!
//! 文件下半部分（`handle_send` / `build_send_params`）实现 `/video/barrage/send`，
//! 该发送接口形态与评论写接口**完全不同**：method = GET、无请求体、无签名（`key`）、
//! 且 query 不带 `clienttime` / `dfid` / `uuid`。逐字节对齐 `module/_comment.js`
//! 的 `buildVideoBarrageSendConfig` 与 `module/video_barrage_send.js`，**不得自创口径**。
//!
//! 安全边界：`handle_send` 不做任何自动重试（弹幕发布成功即产生真实公开内容），
//! 日志只记录 op/code/childrenid/status/error_code，**不得记录弹幕正文 / token / cookie**
//! （`comment_send::log_send` 已满足，直接复用，勿在此新增日志）。

use crate::modules::comment_send::{bad_request, compact_map, first_param, identity, list_auth_params};
use crate::modules::{q_cookie, q_str, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use serde_json::{json, Map, Value};

/// MV 弹幕池（与歌曲弹幕池 `SONG_BARRAGE_CODE` 不是同一个池子）。
pub const VIDEO_BARRAGE_CODE: &str = "db3664c219a6e350b00ab08d7f723a79";
/// 评论服务 router 头（JS `COMMENT_HOST`）。
const VIDEO_BARRAGE_ROUTER: &str = "m.comment.service.kugou.com";
/// 评论列表统一入口（JS `url: '/index.php'`）。
const VIDEO_BARRAGE_URL: &str = "/index.php";

/// JS `buildVideoBarrageListConfig`：纯参数构造（含鉴权），不触发网络。
/// 抽成可测函数，便于无外网断言参数口径（见 `tests/smoke.rs`）。
pub fn build_list_params(q: &Value) -> Map<String, Value> {
    // JS `firstValue`：取第一个「非 null/空串」的值，空串视为缺失。
    let video_id = first_param(q, &["video_id", "childrenid", "id"]);
    let hash = first_param(q, &["hash", "mvhash", "extdata"]);
    let name = first_param(q, &["name", "video_name", "childrenname"]);

    // JS `firstValue(params.page, params.p, 1)`：缺省传数字 1（非字符串）。
    let p_raw = first_param(q, &["page", "p"]);
    let p: Value = if p_raw.is_empty() {
        json!(1)
    } else {
        json!(p_raw)
    };
    // JS `firstValue(params.pagesize, 20)`：缺省传数字 20。
    let pagesize_raw = q_str(q, "pagesize", "");
    let pagesize: Value = if pagesize_raw.is_empty() {
        json!(20)
    } else {
        json!(pagesize_raw)
    };

    // JS `compact`：丢掉空串；childrenid 为空即被丢弃，extdata 仅当 video_id
    // 为空时携带（video_id 非空时该键不得出现 —— 故此处条件插入）。
    let mut params = compact_map(vec![
        ("r", json!("comments/getCommentWithLike")),
        ("code", json!(VIDEO_BARRAGE_CODE)),
        ("childrenid", json!(video_id)),
        ("childrenname", json!(name)),
        ("p", p),
        ("pagesize", pagesize),
    ]);
    if video_id.is_empty() {
        params.insert("extdata".to_string(), json!(hash));
    }

    // JS `...getListAuthParams(params)`：kugouid/ver/clienttoken/appid/clientver/
    // mid/clienttime/key/uuid/dfid（key = signParamsKey(clienttime)）。
    let id = identity(q);
    for (k, v) in list_auth_params(&id) {
        params.insert(k.to_string(), v);
    }

    params
}

/// video_barrage.js → /video/barrage（MV 弹幕列表）。
pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    // 入参校验：video_id 与 hash 都为空 → 400（与 comment_send::bad_request 形态一致）。
    let video_id = first_param(q, &["video_id", "childrenid", "id"]);
    let hash = first_param(q, &["hash", "mvhash", "extdata"]);
    if video_id.is_empty() && hash.is_empty() {
        return Err(bad_request("video_id 和 hash 至少需要传入一个"));
    }

    let params = build_list_params(q);

    let opts = RequestOptions::new(VIDEO_BARRAGE_URL)
        .get(VIDEO_BARRAGE_URL)
        .params(Value::Object(params))
        .header("x-router", VIDEO_BARRAGE_ROUTER)
        .clear_default_params(true)
        .not_signature(true)
        .cookie(q_cookie(q));

    ctx.send(&opts)
}

// ---------------------------------------------------------------------------
// 发送 MV 弹幕：/video/barrage/send
//
// 对照 KuGouMusicApi：
// - `module/_comment.js` 的 `buildVideoBarrageSendConfig`（约 178-195 行）
// - `module/video_barrage_send.js`（入参校验 + 仅传 hash 时先查解析 video_id）
//
// 形态与其它写接口**完全不同**（勿照抄 POST+签名）：
// - method = GET，无请求体（`commentRequestConfig` 未传 method/data，默认 GET）；
// - `notSignature: true`（无 `key`）、`clearDefaultParams: true`；
// - query 里**没有** `clienttime` / `key` / `dfid` / `uuid`（与评论写接口的关键差异）。
// ---------------------------------------------------------------------------

/// MV 弹幕发送入口（JS `r = comments/addcomment`）。
pub const VIDEO_BARRAGE_SEND_R_ADD: &str = "comments/addcomment";
/// 发送侧 ver（JS `ver: firstValue(params.ver, '1.02')`，**字符串** 1.02，注意不是数字 6）。
pub const VIDEO_BARRAGE_SEND_VER_ADD: &str = "1.02";

/// JS `buildVideoBarrageSendConfig`：纯参数构造，不触发网络。
/// content / video_id / name 由调用方解析后显式传入；pid 取自 q（缺省被 `compact` 丢弃）。
/// 只显式带 mid/clienttoken/kugouid/clientver/appid/ver —— 与 JS 一致，
/// **刻意不**带 key / clienttime / dfid / uuid。
pub fn build_send_params(q: &Value, content: &str, video_id: &str, name: &str) -> Map<String, Value> {
    let id = identity(q);
    let pid = q.get("pid").cloned().unwrap_or(Value::Null);

    compact_map(vec![
        ("r", json!(VIDEO_BARRAGE_SEND_R_ADD)),
        ("code", json!(VIDEO_BARRAGE_CODE)),
        ("childrenid", json!(video_id)),
        ("childrenname", json!(name)),
        ("ver", json!(VIDEO_BARRAGE_SEND_VER_ADD)),
        ("content", json!(content)),
        ("pid", pid),
        ("clientver", json!(11440)),
        ("mid", json!(id.mid)),
        ("clienttoken", json!(id.token)),
        ("kugouid", json!(id.userid)),
        ("appid", json!(3116)),
    ])
}

/// video_barrage_send.js → /video/barrage/send（MV 弹幕发送）。
pub fn handle_send(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    // 1) content 去空白后为空 → 400
    let content = q_str(q, "content", "");
    if content.trim().is_empty() {
        return Err(bad_request("content 不能为空"));
    }

    // 2) video_id / hash / name 取值（JS firstValue 优先链）
    let mut video_id = first_param(q, &["video_id", "childrenid", "id"]);
    let hash = first_param(q, &["hash", "mvhash", "extdata"]);
    let mut name = first_param(q, &["name", "video_name", "childrenname"]);

    // 3) video_id 与 hash 都为空 → 400
    if video_id.is_empty() && hash.is_empty() {
        return Err(bad_request("video_id 和 hash 至少需要传入一个"));
    }

    // 4) 仅传 hash：先用列表配置查一次（page=1, pagesize=1），解析真正的 video_id 与 name
    if video_id.is_empty() {
        let lookup = super::comment_send::with_overrides(
            q,
            &[("page", json!(1)), ("pagesize", json!(1))],
        );
        let body = super::comment_send::lookup_body(handle(&lookup, ctx));
        let (resolved_id, resolved_name) = super::comment_send::extract_resolved_resource(&body);
        video_id = resolved_id;
        if name.is_empty() {
            name = resolved_name;
        }
    }

    // 解析不到 video_id → 400
    if video_id.is_empty() {
        return Err(bad_request("无法根据 hash 解析视频弹幕 video_id"));
    }

    // 5) 组参 + 发送（GET，无签名，清空默认参数）
    let params = build_send_params(q, &content, &video_id, &name);
    let opts = RequestOptions::new(VIDEO_BARRAGE_URL)
        .get(VIDEO_BARRAGE_URL)
        .params(Value::Object(params))
        .header("x-router", VIDEO_BARRAGE_ROUTER)
        .clear_default_params(true)
        .not_signature(true)
        .cookie(q_cookie(q));

    let result = ctx.send(&opts);
    // 6) 日志：仅记非敏感字段（已满足安全边界，不在此记录正文/token/cookie）
    super::comment_send::log_send("video_barrage", VIDEO_BARRAGE_CODE, &video_id, &result);
    result
}
