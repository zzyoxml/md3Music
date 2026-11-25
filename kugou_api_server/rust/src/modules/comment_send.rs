//! 评论写接口：歌曲顶层评论 / 楼层回复 / 歌单评论 / 专辑评论。
//!
//! 对照 KuGouMusicApi：
//! - `module/_comment.js`（身份解析、签名、请求配置）
//! - `module/comment_music_send.js`     → `/comment/music/send`
//! - `module/comment_floor_send.js`     → `/comment/floor/send`
//! - `module/comment_playlist_send.js`  → `/comment/playlist/send`
//! - `module/comment_album_send.js`     → `/comment/album/send`
//! - `module/comment_music_del.js`      → `/comment/music/del`（删除，歌曲/专辑/歌单共用）
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

/// JS 顶层透传参数（`source`/`extdata` 等）：原值经 `compact` 语义
/// （null/空串丢弃，其余原样）后插入，缺省时该键不出现。
pub(crate) fn insert_passthrough(params: &mut Map<String, Value>, q: &Value, key: &str) {
    match q.get(key) {
        Some(Value::Null) | None => {}
        Some(Value::String(s)) if s.is_empty() => {}
        Some(v) => {
            params.insert(key.to_string(), v.clone());
        }
    }
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
        // JS `firstValue(params.mid, cookie.KUGOU_API_MID)`；都没有时沿用
        // request.rs 的默认口径（"-"）
        let p = q_str(q, "mid", "");
        if !p.is_empty() {
            p
        } else {
            let m = c_str(q, "KUGOU_API_MID");
            if m.is_empty() { "-".to_string() } else { m }
        }
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

/// JS `buildCommentSendConfig` / `buildCommentReplyConfig` 里那段显式 params，
/// `key` 由调用方按各自签名输入传入。
///
/// 返回值已按 JS `compact` 语义处理（null/空串丢弃，数字 0 如 kugouid 保留），
/// 因此空 token 时 `clienttoken` 不下发，与 JS 一致。
pub(crate) fn auth_params(q: &Value, id: &Identity, key: &str) -> Map<String, Value> {
    compact_map(vec![
        ("kugouid", json!(id.userid)),
        ("ver", ver_value(q)),
        ("clienttoken", json!(id.token)),
        ("appid", json!(3116)),
        ("clientver", json!(11440)),
        ("mid", json!(id.mid)),
        ("clienttime", json!(id.clienttime)),
        ("key", json!(key)),
        ("uuid", json!(id.uuid)),
        ("dfid", json!(id.dfid)),
    ])
}

/// JS `firstValue(params.ver, 6)`：显式传入原样透传（含数字 0 这类真值边界），
/// 缺省/空串取 6。
fn ver_value(q: &Value) -> Value {
    match q.get("ver") {
        Some(Value::String(s)) if s.is_empty() => json!(COMMENT_VER),
        Some(v) if !matches!(v, Value::Null) => v.clone(),
        _ => json!(COMMENT_VER),
    }
}

/// 列表侧公共鉴权参数（JS `getListAuthParams`）：与写接口 `auth_params` 仅 `key` 的输入不同
/// —— 列表用 `signParamsKey(clienttime)`，写用 `signParamsKey(clienttime+mid+data)`。
/// 复用 `auth_params`，不重造。
pub(crate) fn list_auth_params(q: &Value, id: &Identity) -> Map<String, Value> {
    let key = sign_params_key(&id.clienttime.to_string(), "", "");
    auth_params(q, id, &key)
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

    // body 键序固定 content → album_audio_id → title → extdata → images
    // （JS JSON.stringify 逐字节对齐）；title/extdata(=content_extdata) 经 compact
    // 缺省丢弃，images 非数组时归 []（空数组保留，与 JS compact 一致）。
    let images = match q.get("images") {
        Some(Value::Array(a)) => json!(a),
        _ => json!([]),
    };
    let body_json = json!({
        "data": compact_map(vec![
            ("content", json!(content)),
            (
                "album_audio_id",
                if mixsongid.is_empty() { Value::Null } else { json!(mixsongid) }
            ),
            ("title", q.get("title").cloned().unwrap_or(Value::Null)),
            ("extdata", q.get("content_extdata").cloned().unwrap_or(Value::Null)),
            ("images", images),
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
    params.extend(auth_params(q, &id, &key));
    insert_passthrough(&mut params, q, "source");

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
    // JS `pid = firstValue(params.pid, 0)`：null/空串取 0，其余（含数字 0）原样
    let pid: Value = match q.get("pid") {
        Some(Value::String(s)) if s.is_empty() => json!(0),
        Some(v) if !matches!(v, Value::Null) => v.clone(),
        _ => json!(0),
    };
    // JS：显式 is_t / isT 原样透传；都缺省时 pid == '0' → 1，否则 0
    let is_t: Value = {
        let explicit = [q.get("is_t"), q.get("isT")]
            .into_iter()
            .flatten()
            .find_map(|v| match v {
                Value::Null => None,
                Value::String(s) if s.is_empty() => None,
                other => Some(other.clone()),
            });
        explicit.unwrap_or_else(|| {
            if pid.to_string().trim_matches('"') == "0" { json!(1) } else { json!(0) }
        })
    };

    let key = sign_params_key(&format!("{}{}", id.clienttime, id.mid), "", "");

    let mut params = compact_map(vec![
        ("r", json!("commentsv2/reply")),
        ("code", json!(code)),
        ("childrenid", json!(children_id)),
        ("childrenname", json!(name)),
    ]);
    params.extend(auth_params(q, &id, &key));
    params.insert("content".to_string(), json!(content));
    params.insert("tid".to_string(), json!(tid));
    params.insert("is_t".to_string(), is_t);
    params.insert("pid".to_string(), pid);
    // JS 透传 extdata / source（compact 丢空）
    insert_passthrough(&mut params, q, "extdata");
    insert_passthrough(&mut params, q, "source");

    RequestOptions::new(COMMENT_URL)
        .post(COMMENT_URL)
        .params(Value::Object(params))
        .header("x-router", COMMENT_ROUTER)
        .clear_default_params(true)
        .not_signature(true)
        .cookie(q_cookie(q))
}

/// JS `buildCommentDelConfig` → `r=commentsv2/delcomment`（删除评论，GET 无请求体）。
///
/// 与 `reply_options` 的差别只有 `r` 与参数集合（`cid`/`tid` 代替 content/is_t/pid），
/// `key` 算法完全一致（`signParamsKey(clienttime+mid)`），因此复用 `auth_params`。
pub fn del_options(q: &Value, cid: &str, children_id: &str, code: &str, tid: &str) -> RequestOptions {
    let id = identity(q);
    let key = sign_params_key(&format!("{}{}", id.clienttime, id.mid), "", "");

    let mut params = compact_map(vec![
        ("r", json!("commentsv2/delcomment")),
        ("code", json!(code)),
        ("childrenid", json!(children_id)),
        ("cid", json!(cid)),
        ("tid", json!(tid)),
    ]);
    params.extend(auth_params(q, &id, &key));

    RequestOptions::new(COMMENT_URL)
        .get(COMMENT_URL)
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

/// JS `firstValue(params.reply_user_name, params.puser)` /
/// `firstValue(params.reply_content, params.pcontent)`。
pub fn reply_quote_fields(q: &Value) -> (String, String) {
    (
        first_param(q, &["reply_user_name", "puser"]),
        first_param(q, &["reply_content", "pcontent"]),
    )
}

/// JS `!firstValue(params.tid)` 的校验：仅缺失/空串拒绝（字符串 "0" 是真值，
/// 与 JS 一致放行转发上游；JSON body 的数字 0 经 `q_str` 归空同样拒绝）。
pub fn floor_tid(q: &Value) -> Result<String, ModuleResponse> {
    let tid = q_str(q, "tid", "");
    if tid.is_empty() {
        Err(bad_request("tid 不能为空"))
    } else {
        Ok(tid)
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

/// comment_music_del.js → /comment/music/del（删除评论，歌曲/专辑/歌单共用）。
///
/// [cid] 为评论列表返回的评论 id；`special_id` 必须取列表项的 `special_child_id`
/// （**不要**用发送评论响应里的 `special_id`）；只传 mixsongid 时服务端先查一次
/// 歌曲评论自动反查，最可靠。删楼中楼回复时 [tid]（所属顶层评论 id）必传。
pub fn handle_music_del(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let cid = first_param(q, &["cid", "comment_id"]);
    if cid.is_empty() {
        return Err(bad_request("cid（评论 ID）不能为空，可从评论列表接口获取"));
    }

    let mixsongid = first_param(q, &["mixsongid", "album_audio_id"]);
    let mut special_id = first_param(q, &["special_id", "childrenid"]);

    // 仅传 mixsongid 时先查一次歌曲评论，自动解析 special_id（与 handle_music_send 同策略）
    if special_id.is_empty() && !mixsongid.is_empty() {
        let lookup = with_overrides(
            q,
            &[
                ("mixsongid", json!(mixsongid)),
                ("page", json!(1)),
                ("pagesize", json!(1)),
            ],
        );
        special_id = extract_resolved_resource(&lookup_body(super::comment_music::handle(&lookup, ctx))).0;
    }

    if special_id.is_empty() {
        return Err(bad_request("无法解析评论资源 special_id，请传入 special_id 或 mixsongid"));
    }

    let code = resolve_code(q);
    let tid = first_param(q, &["tid"]);
    let opts = del_options(q, &cid, &special_id, &code, &tid);
    let result = ctx.send(&opts);
    log_send("del", &code, &special_id, &result);
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

    let tid = floor_tid(q)?;

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

    let (reply_user_name, reply_content) = reply_quote_fields(q);
    let content = with_quote_suffix(&content, &reply_user_name, &reply_content);
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
