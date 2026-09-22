//! 评论写接口：歌曲顶层评论 / 楼层回复 / 歌单评论 / 专辑评论。
//!
//! 对照 KuGouMusicApi：
//! - `module/_comment.js`（身份解析、签名、请求配置）
//! - `module/comment_music_send.js`     → `/comment/music/send`
//! - `module/comment_floor_send.js`     → `/comment/floor/send`
//! - `module/comment_playlist_send.js`  → `/comment/playlist/send`
//! - `module/comment_album_send.js`     → `/comment/album/send`
//!
//! 与读取侧（`comment_music.rs` / `comment_more.rs` 走明文 lite 路径）不同：
//! 写侧统一走评论服务 `/index.php` + `x-router: m.comment.service.kugou.com`，
//! **跳过签名**（JS `notSignature`）且**清空默认参数**（JS `clearDefaultParams`），
//! 设备/账号参数全部显式传入，另带 `key = signParamsKey(...)`。
//!
//! 安全边界（勿改）：
//! - 不做任何自动重试——评论发布成功即产生真实公开内容，重试可能重复发布；
//! - 日志只记录 op/code/childrenid/status/error_code，**不得**记录评论正文、token、cookie。
//!
//! 列表侧鉴权由 `list_auth_params` 提供，供 `video_barrage.rs` 复用。

use crate::cache::now_epoch_secs;
use crate::helper::sign_params_key;
use crate::modules::{c_str, param_or_cookie_num, param_or_cookie_str, q_cookie, q_str, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use serde_json::{json, Map, Value};

/// 歌曲评论池（与 `/song/barrage/send` 的歌曲弹幕池不是同一个池子）。
pub const SONG_CODE: &str = "fc4be23b4e972707f36b8a828a93ba8a";
/// 专辑评论池。
pub const ALBUM_CODE: &str = "94f1792ced1df89aa68a7939eaf2efca";
/// 歌单评论池。
pub const PLAYLIST_CODE: &str = "ca53b96fe5a1d9c22d71c8f522ef7c4f";
/// 评论服务 router 头（JS `COMMENT_HOST`）。
const COMMENT_ROUTER: &str = "m.comment.service.kugou.com";
/// 评论写接口统一入口（JS `url: '/index.php'`）。
const COMMENT_URL: &str = "/index.php";
/// 评论写接口客户端版本（JS `ver` 默认 6）。
const COMMENT_VER: i64 = 6;

// ---------------------------------------------------------------------------
// 参数工具（对齐 JS _comment.js 的 compact / firstValue）
// ---------------------------------------------------------------------------

/// JS `compact(object)`：丢掉 undefined / null / 空字符串，其余保留（含空数组）。
pub(crate) fn compact_map(pairs: Vec<(&str, Value)>) -> Map<String, Value> {
    let mut out = Map::new();
    for (k, v) in pairs {
        if matches!(&v, Value::Null) {
            continue;
        }
        if let Value::String(s) = &v {
            if s.is_empty() {
                continue;
            }
        }
        out.insert(k.to_string(), v);
    }
    out
}

/// JS `firstValue(...)`：取第一个「非 null/空串」的值并字符串化。
fn first_value_str(candidates: &[Option<&Value>]) -> String {
    for c in candidates.iter().flatten() {
        match c {
            Value::Null => continue,
            Value::String(s) if s.is_empty() => continue,
            Value::String(s) => return s.clone(),
            Value::Number(n) => return n.to_string(),
            Value::Bool(b) => return b.to_string(),
            _ => continue,
        }
    }
    String::new()
}

/// 查询参数里第一个非空的键值（JS `firstValue(params.a, params.b, ...)`）。
pub(crate) fn first_param(q: &Value, keys: &[&str]) -> String {
    for k in keys {
        let v = q_str(q, k, "");
        if !v.is_empty() {
            return v;
        }
    }
    String::new()
}

/// 复制查询并覆盖若干字段（JS `{...params, page: 1, pagesize: 1}`）。
pub(crate) fn with_overrides(q: &Value, overrides: &[(&str, Value)]) -> Value {
    let mut out = q.clone();
    if let Some(m) = out.as_object_mut() {
        for (k, v) in overrides {
            m.insert((*k).to_string(), v.clone());
        }
    }
    out
}

// ---------------------------------------------------------------------------
// 身份与签名
// ---------------------------------------------------------------------------

/// JS `getIdentity(params)`。写接口不依赖请求层默认参数，因此每一项都显式取。
pub struct Identity {
    pub clienttime: i64,
    pub mid: String,
    pub token: String,
    pub userid: i64,
    pub dfid: String,
    pub uuid: String,
}

pub fn identity(q: &Value) -> Identity {
    // JS `firstValue(params.clienttime, now)`：显式传入可复现（测试即依赖此点）。
    let clienttime = {
        let raw = q_str(q, "clienttime", "");
        if raw.is_empty() {
            now_epoch_secs() as i64
        } else {
            raw.trim().parse::<i64>().unwrap_or_else(|_| now_epoch_secs() as i64)
        }
    };
    let userid = {
        let k = q_str(q, "kugouid", "");
        if k.is_empty() {
            param_or_cookie_num(q, "userid", 0)
        } else {
            k.trim().parse::<i64>().unwrap_or(0)
        }
    };
    let token = {
        let t = q_str(q, "clienttoken", "");
        if t.is_empty() {
            param_or_cookie_str(q, "token", "")
        } else {
            t
        }
    };
    let mid = {
        let m = c_str(q, "KUGOU_API_MID");
        // 与 request.rs 的默认口径一致（cookie 无 MID 时用 "-"）
        if m.is_empty() { "-".to_string() } else { m }
    };
    Identity {
        clienttime,
        mid,
        token,
        userid,
        dfid: param_or_cookie_str(q, "dfid", "-"),
        uuid: param_or_cookie_str(q, "uuid", "-"),
    }
}

/// 写接口的公共鉴权参数（JS `buildCommentSendConfig` / `buildCommentReplyConfig`
/// 里那段显式 params），`key` 由调用方按各自签名输入传入。
pub(crate) fn auth_params(id: &Identity, key: &str) -> Vec<(&'static str, Value)> {
    vec![
        ("kugouid", json!(id.userid)),
        ("ver", json!(COMMENT_VER)),
        ("clienttoken", json!(id.token)),
        ("appid", json!(3116)),
        ("clientver", json!(11440)),
        ("mid", json!(id.mid)),
        ("clienttime", json!(id.clienttime)),
        ("key", json!(key)),
        ("uuid", json!(id.uuid)),
        ("dfid", json!(id.dfid)),
    ]
}

/// 列表侧公共鉴权参数（JS `getListAuthParams`）：与写接口 `auth_params` 仅 `key` 的输入不同
/// —— 列表用 `signParamsKey(clienttime)`，写用 `signParamsKey(clienttime+mid+data)`。
/// 复用 `auth_params`，不重造。
pub(crate) fn list_auth_params(id: &Identity) -> Vec<(&'static str, Value)> {
    let key = sign_params_key(&id.clienttime.to_string(), "", "");
    auth_params(id, &key)
}

// ---------------------------------------------------------------------------
// 请求构造
// ---------------------------------------------------------------------------

/// JS `buildCommentSendConfig` → `r=commentsv3/add`（顶层评论，四个资源共用）。
pub fn send_options(
    q: &Value,
    content: &str,
    children_id: &str,
    name: &str,
    code: &str,
    mixsongid: &str,
) -> RequestOptions {
    let id = identity(q);

    // body 键序固定 content → album_audio_id → images（JS JSON.stringify 逐字节对齐）
    let body_json = json!({
        "data": compact_map(vec![
            ("content", json!(content)),
            (
                "album_audio_id",
                if mixsongid.is_empty() { Value::Null } else { json!(mixsongid) }
            ),
            ("images", json!([])),
        ]),
    });
    let data = crate::util::json_stringify(&body_json);
    let key = sign_params_key(
        &format!("{}{}{}", id.clienttime, id.mid, data),
        "",
        "",
    );

    let mut params = compact_map(vec![
        ("r", json!("commentsv3/add")),
        ("code", json!(code)),
        ("childrenid", json!(children_id)),
        ("childrenname", json!(name)),
    ]);
    for (k, v) in auth_params(&id, &key) {
        params.insert(k.to_string(), v);
    }

    RequestOptions::new(COMMENT_URL)
        .post(COMMENT_URL)
        .params(Value::Object(params))
        .string_body(data)
        .header("x-router", COMMENT_ROUTER)
        .header("Content-Type", "application/json; charset=UTF-8")
        .clear_default_params(true)
        .not_signature(true)
        .cookie(q_cookie(q))
}

/// JS `buildCommentReplyConfig` → `r=commentsv2/reply`（楼层回复，无请求体）。
pub fn reply_options(
    q: &Value,
    content: &str,
    children_id: &str,
    name: &str,
    code: &str,
    tid: &str,
) -> RequestOptions {
    let id = identity(q);
    let pid: Value = {
        let raw = q.get("pid").cloned().unwrap_or(Value::Null);
        if matches!(&raw, Value::Null) {
            json!(0)
        } else {
            raw
        }
    };
    // JS：is_t 缺省时 pid == '0' → 1，否则 0
    let is_t: Value = {
        let t = q.get("is_t").cloned().unwrap_or(Value::Null);
        match &t {
            Value::Null => {
                if pid.to_string().trim_matches('"') == "0" { json!(1) } else { json!(0) }
            }
            _ => t,
        }
    };

    let key = sign_params_key(&format!("{}{}", id.clienttime, id.mid), "", "");

    let mut params = compact_map(vec![
        ("r", json!("commentsv2/reply")),
        ("code", json!(code)),
        ("childrenid", json!(children_id)),
        ("childrenname", json!(name)),
    ]);
    for (k, v) in auth_params(&id, &key) {
        params.insert(k.to_string(), v);
    }
    params.insert("content".to_string(), json!(content));
    params.insert("tid".to_string(), json!(tid));
    params.insert("is_t".to_string(), is_t);
    params.insert("pid".to_string(), pid);

    RequestOptions::new(COMMENT_URL)
        .post(COMMENT_URL)
        .params(Value::Object(params))
        .header("x-router", COMMENT_ROUTER)
        .clear_default_params(true)
        .not_signature(true)
        .cookie(q_cookie(q))
}

// ---------------------------------------------------------------------------
// 资源解析
// ---------------------------------------------------------------------------

/// JS `comment_floor_send.resolveCode`：显式 `code` 优先；否则按 `resource_type`
/// （song/album/playlist，缺省 song，大小写不敏感）取池 code。
pub fn resolve_code(q: &Value) -> String {
    let explicit = q_str(q, "code", "");
    if !explicit.is_empty() {
        return explicit;
    }
    let rt = {
        let a = q_str(q, "resource_type", "");
        let b = q_str(q, "resourceType", "");
        let v = if a.is_empty() { b } else { a };
        if v.is_empty() { "song".to_string() } else { v.to_lowercase() }
    };
    match rt.as_str() {
        "album" => ALBUM_CODE.to_string(),
        "playlist" => PLAYLIST_CODE.to_string(),
        _ => SONG_CODE.to_string(),
    }
}

/// JS `extractResolvedResource`：从评论查询响应里取 (special_id, 资源名)。
/// 顶层给 `childrenid`，列表项给 `special_child_id` / `special_child_name`。
pub fn extract_resolved_resource(body: &Value) -> (String, String) {
    let first = body
        .get("list")
        .and_then(|v| v.as_array())
        .and_then(|a| a.first())
        .cloned()
        .unwrap_or(Value::Null);
    (
        first_value_str(&[body.get("childrenid"), first.get("special_child_id")]),
        first_value_str(&[
            first.get("special_child_name"),
            first.get("song_show_text"),
        ]),
    )
}

/// JS `buildCommentReplyConfig` 的内容拼接：被回复用户与原评论都提供且正文尚不含
/// 引用后缀时，追加「//@用户名:原评论」。
pub fn with_quote_suffix(content: &str, reply_user_name: &str, reply_content: &str) -> String {
    if !reply_user_name.is_empty() && !reply_content.is_empty() && !content.contains("//@") {
        format!("{}//@{}:{}", content, reply_user_name, reply_content)
    } else {
        content.to_string()
    }
}

// ---------------------------------------------------------------------------
// handler
// ---------------------------------------------------------------------------

/// 入参错误（HTTP 400，body 形态与 listen_report.rs 的 `bad_request` 一致）。
pub(crate) fn bad_request(msg: &str) -> ModuleResponse {
    use crate::request::BodyValue;
    use std::collections::HashMap;
    ModuleResponse {
        status: 400,
        body: BodyValue::Json(json!({ "status": 0, "error_code": 400, "msg": msg })),
        cookie: Vec::new(),
        headers: HashMap::new(),
    }
}

/// 取内部「解析查询」的响应体。JS 侧 useAxios 对成功与上游业务错误都 resolve，
/// 因此两条分支都要读 body（读不到字段等价于空对象）。
pub(crate) fn lookup_body(result: Result<ModuleResponse, ModuleResponse>) -> Value {
    match result {
        Ok(r) => r.body.to_json(),
        Err(e) => e.body.to_json(),
    }
}

/// 发送结果日志：只记录非敏感字段（不得记录正文/token/cookie）。
pub(crate) fn log_send(op: &str, code: &str, children_id: &str, result: &Result<ModuleResponse, ModuleResponse>) {
    let (http, body) = match result {
        Ok(r) => (r.status, r.body.to_json()),
        Err(e) => (e.status, e.body.to_json()),
    };
    log::info!(
        "comment/send op={} code={} childrenid={} http={} status={} error_code={}",
        op,
        code,
        children_id,
        http,
        body.get("status").map(|v| v.to_string()).unwrap_or_default(),
        body.get("error_code").map(|v| v.to_string()).unwrap_or_default(),
    );
}

/// comment_music_send.js → /comment/music/send（歌曲顶层评论）。
pub fn handle_music_send(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let content = q_str(q, "content", "");
    if content.trim().is_empty() {
        return Err(bad_request("content 不能为空"));
    }

    let mixsongid = first_param(q, &["mixsongid", "album_audio_id"]);
    let mut special_id = first_param(q, &["special_id", "childrenid", "id"]);
    let mut name = first_param(q, &["name", "song_name", "childrenname"]);

    // 仅传 mixsongid 时先查一次歌曲评论，自动解析 special_id 与歌曲名
    if (special_id.is_empty() || name.is_empty()) && !mixsongid.is_empty() {
        let lookup = with_overrides(
            q,
            &[
                ("mixsongid", json!(mixsongid)),
                ("page", json!(1)),
                ("pagesize", json!(1)),
            ],
        );
        let (resolved_id, resolved_name) =
            extract_resolved_resource(&lookup_body(super::comment_music::handle(&lookup, ctx)));
        if special_id.is_empty() {
            special_id = resolved_id;
        }
        if name.is_empty() {
            name = resolved_name;
        }
    }

    if special_id.is_empty() {
        return Err(bad_request("无法解析歌曲评论 special_id，请传入 mixsongid 或 special_id"));
    }

    let opts = send_options(q, &content, &special_id, &name, SONG_CODE, &mixsongid);
    let result = ctx.send(&opts);
    log_send("music", SONG_CODE, &special_id, &result);
    result
}

/// comment_floor_send.js → /comment/floor/send（楼层回复，歌曲/歌单/专辑共用）。
pub fn handle_floor_send(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let content = q_str(q, "content", "");
    if content.trim().is_empty() {
        return Err(bad_request("content 不能为空"));
    }

    let special_id = first_param(q, &["special_id", "childrenid", "id"]);
    if special_id.is_empty() {
        return Err(bad_request("special_id 不能为空"));
    }

    // JS `firstValue(params.tid)` 的 truthiness：缺失/0 → 参数错误
    let tid = {
        let t = q_str(q, "tid", "");
        if t.is_empty() { "0".to_string() } else { t }
    };
    if tid == "0" {
        return Err(bad_request("tid 不能为空"));
    }

    let code = resolve_code(q);
    let mut name = first_param(q, &["name", "song_name", "album_name", "playlist_name", "childrenname"]);

    if name.is_empty() {
        let lookup = with_overrides(
            q,
            &[
                ("special_id", json!(special_id)),
                ("code", json!(code)),
                ("page", json!(1)),
                ("pagesize", json!(1)),
            ],
        );
        let (_, resolved_name) =
            extract_resolved_resource(&lookup_body(super::comment_more::handle_floor(&lookup, ctx)));
        name = resolved_name;
    }

    let content = with_quote_suffix(
        &content,
        &q_str(q, "reply_user_name", ""),
        &q_str(q, "reply_content", ""),
    );
    let opts = reply_options(q, &content, &special_id, &name, &code, &tid);
    let result = ctx.send(&opts);
    log_send("floor", &code, &special_id, &result);
    result
}

/// comment_playlist_send.js → /comment/playlist/send（歌单顶层评论）。
pub fn handle_playlist_send(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let content = q_str(q, "content", "");
    if content.trim().is_empty() {
        return Err(bad_request("content 不能为空"));
    }

    let id = first_param(q, &["playlist_id", "special_id", "childrenid", "id"]);
    if id.is_empty() {
        return Err(bad_request("id 不能为空"));
    }

    let mut name = first_param(q, &["name", "playlist_name", "childrenname"]);
    if name.is_empty() {
        let lookup = with_overrides(q, &[("id", json!(id)), ("page", json!(1)), ("pagesize", json!(1))]);
        let (_, resolved_name) =
            extract_resolved_resource(&lookup_body(super::comment_more::handle_playlist(&lookup, ctx)));
        name = resolved_name;
    }

    let opts = send_options(q, &content, &id, &name, PLAYLIST_CODE, "");
    let result = ctx.send(&opts);
    log_send("playlist", PLAYLIST_CODE, &id, &result);
    result
}

/// comment_album_send.js → /comment/album/send（专辑顶层评论）。
pub fn handle_album_send(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let content = q_str(q, "content", "");
    if content.trim().is_empty() {
        return Err(bad_request("content 不能为空"));
    }

    let id = first_param(q, &["album_id", "special_id", "childrenid", "id"]);
    if id.is_empty() {
        return Err(bad_request("id 不能为空"));
    }

    let mut name = first_param(q, &["name", "album_name", "childrenname"]);
    if name.is_empty() {
        let lookup = with_overrides(q, &[("id", json!(id)), ("page", json!(1)), ("pagesize", json!(1))]);
        let (_, resolved_name) =
            extract_resolved_resource(&lookup_body(super::comment_more::handle_album(&lookup, ctx)));
        name = resolved_name;
    }

    let opts = send_options(q, &content, &id, &name, ALBUM_CODE, "");
    let result = ctx.send(&opts);
    log_send("album", ALBUM_CODE, &id, &result);
    result
}
