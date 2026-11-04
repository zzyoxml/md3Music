//! 歌曲弹幕列表 + 发送（底层复用歌曲弹幕池 `articulossong`，与歌曲评论池
//! `SONG_CODE=fc4...` 不是同一个池子）。
//!
//! 对照 KuGouMusicApi：
//! - `module/_comment.js` 的 `getListAuthParams` / `commentRequestConfig` /
//!   `buildSongBarrageListConfig`（71-86）/ `buildCommentSendConfig`（104-139）
//!   / `buildSongBarrageSendConfig`（139）
//! - `module/song_barrage.js`（入参校验：special_id 与 hash 至少其一）
//! - `module/song_barrage_send.js`（仅传 hash 时先查解析 special_id）
//!
//! 列表侧与 MV 弹幕（`video_barrage.rs`）同构：走评论服务 `/index.php` +
//! `x-router: m.comment.service.kugou.com`，**跳过签名**（JS `notSignature`）且
//! **清空默认参数**（JS `clearDefaultParams`），设备/账号参数全部显式传入。
//! 与 MV 的唯一差异：额外透传 `mixsongid`（链 `mixsongid` → `album_audio_id`）。
//!
//! 发送侧与 MV 弹幕**完全不同**（勿照抄 `video_barrage::handle_send` 的 GET 版）：
//! 形态是 **POST + 签名**，与歌曲/专辑/歌单评论写接口一致，直接复用
//! `comment_send::send_options`（`r=commentsv3/add`，body `{data:{content,album_audio_id,images}}`，
//! `key=signParamsKey(clienttime+mid+data)`），只需把资源 code 换成 `SONG_BARRAGE_CODE`。
//!
//! 安全边界：`handle_send` 不做任何自动重试（弹幕发布成功即产生真实公开内容），
//! 日志只记录 op/code/childrenid/status/error_code，**不得记录弹幕正文 / token / cookie**
//! （`comment_send::log_send` 已满足，直接复用，勿在此新增日志）。

use crate::modules::comment_send::{
    bad_request, compact_map, extract_resolved_resource, first_param, identity, list_auth_params,
    log_send, lookup_body, send_options, with_overrides,
};
use crate::modules::{q_cookie, q_str, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use serde_json::{json, Map, Value};

/// 歌曲弹幕池资源 code（这是资源 code 字符串，不是 hash；
/// 与 `video_barrage.rs:26` 欠下的 `SONG_BARRAGE_CODE` 相对，此处补全）。
pub const SONG_BARRAGE_CODE: &str = "articulossong";
/// 评论服务 router 头（JS `COMMENT_HOST`）。
const SONG_BARRAGE_ROUTER: &str = "m.comment.service.kugou.com";
/// 评论列表统一入口（JS `url: '/index.php'`）。
const SONG_BARRAGE_URL: &str = "/index.php";

/// JS `buildSongBarrageListConfig`：纯参数构造（含鉴权），不触发网络。
/// 抽成可测函数，便于无外网断言参数口径（见 `tests/smoke.rs`）。
pub fn build_list_params(q: &Value) -> Map<String, Value> {
    // JS `firstValue`：取第一个「非 null/空串」的值，空串视为缺失。
    let special_id = first_param(q, &["special_id", "childrenid", "id"]);
    let hash = first_param(q, &["hash", "schash", "extdata"]);
    let name = first_param(q, &["name", "song_name", "childrenname"]);
    // 与 MV 的唯一差异：透传 mixsongid（JS `_comment.js:81`，链 mixsongid → album_audio_id）。
    let mixsongid = first_param(q, &["mixsongid", "album_audio_id"]);

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

    // JS `compact`：丢掉空串；childrenid 为空即被丢弃，extdata 仅当 special_id
    // 为空时携带（special_id 非空时该键不得出现 —— 故此处条件插入）。mixsongid
    // 为空同样被 compact 丢弃，非空才下发。
    let mut params = compact_map(vec![
        ("r", json!("comments/getCommentWithLike")),
        ("code", json!(SONG_BARRAGE_CODE)),
        ("childrenid", json!(special_id)),
        ("childrenname", json!(name)),
        ("mixsongid", json!(mixsongid)),
        ("p", p),
        ("pagesize", pagesize),
    ]);
    if special_id.is_empty() {
        params.insert("extdata".to_string(), json!(hash));
    }

    // JS `...getListAuthParams(params)`：kugouid/ver/clienttoken/appid/clientver/
    // mid/clienttime/key/uuid/dfid（key = signParamsKey(clienttime)）。
    let id = identity(q);
    params.extend(list_auth_params(q, &id));

    params
}

/// song_barrage.js → /song/barrage（歌曲弹幕列表）。
pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    // 入参校验：special_id 与 hash 都为空 → 400（与 comment_send::bad_request 形态一致）。
    let special_id = first_param(q, &["special_id", "childrenid", "id"]);
    let hash = first_param(q, &["hash", "schash", "extdata"]);
    if special_id.is_empty() && hash.is_empty() {
        return Err(bad_request("special_id 和 hash 至少需要传入一个"));
    }

    let params = build_list_params(q);

    let opts = RequestOptions::new(SONG_BARRAGE_URL)
        .get(SONG_BARRAGE_URL)
        .params(Value::Object(params))
        .header("x-router", SONG_BARRAGE_ROUTER)
        .clear_default_params(true)
        .not_signature(true)
        .cookie(q_cookie(q));

    ctx.send(&opts)
}

// ---------------------------------------------------------------------------
// 发送歌曲弹幕：/song/barrage/send
//
// 对照 KuGouMusicApi：
// - `module/_comment.js` 的 `buildSongBarrageSendConfig`（139，直接转调
//   `buildCommentSendConfig(params, SONG_BARRAGE_CODE)`）
// - `module/song_barrage_send.js`（入参校验 + 仅传 hash 时先查解析 special_id）
//
// 形态与歌曲/专辑/歌单评论写接口**相同**（POST + 签名），与 MV 弹幕发送（GET 无签名）
// 相反 —— 直接复用 `comment_send::send_options`，只把 code 换成 `SONG_BARRAGE_CODE`，
// **不得自创口径**。
// ---------------------------------------------------------------------------

/// song_barrage_send.js → /song/barrage/send（歌曲弹幕发送）。
pub fn handle_send(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    // 1) content 去空白后为空 → 400
    let content = q_str(q, "content", "");
    if content.trim().is_empty() {
        return Err(bad_request("content 不能为空"));
    }

    // 2) special_id / hash / name / mixsongid 取值（JS firstValue 优先链）
    let mut special_id = first_param(q, &["special_id", "childrenid", "id"]);
    let hash = first_param(q, &["hash", "schash", "extdata"]);
    let mut name = first_param(q, &["name", "song_name", "childrenname"]);
    let mixsongid = first_param(q, &["mixsongid", "album_audio_id"]);

    // 3) special_id 与 hash 都为空 → 400
    if special_id.is_empty() && hash.is_empty() {
        return Err(bad_request("special_id 和 hash 至少需要传入一个"));
    }

    // 4) 仅传 hash：先用列表配置查一次（page=1, pagesize=1），解析真正的 special_id 与 name。
    //    注意上游实测返回的顶层 childrenid 是 JSON number（如 100285259），
    //    extract_resolved_resource 经 first_value_str 已能接受数字型 childrenid，无需本地归一。
    if special_id.is_empty() {
        let lookup = with_overrides(q, &[("page", json!(1)), ("pagesize", json!(1))]);
        let body = lookup_body(handle(&lookup, ctx));
        let (resolved_id, resolved_name) = extract_resolved_resource(&body);
        special_id = resolved_id;
        if name.is_empty() {
            name = resolved_name;
        }
    }

    // 解析不到 special_id → 400
    if special_id.is_empty() {
        return Err(bad_request("无法根据 hash 解析歌曲弹幕 special_id"));
    }

    // 5) 组参 + 发送（POST + 签名，复用评论写接口公共件，code 换成歌曲弹幕池）
    let opts = send_options(q, &content, &special_id, &name, SONG_BARRAGE_CODE, &mixsongid);
    let result = ctx.send(&opts);
    // 6) 日志：仅记非敏感字段（已满足安全边界，不在此记录正文/token/cookie）
    log_send("song_barrage", SONG_BARRAGE_CODE, &special_id, &result);
    result
}
