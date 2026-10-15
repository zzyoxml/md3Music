//! dycover 系列：`/album/dycover`（专辑动态封面元数据）与其媒体代理
//! `/album/dycover/media`。对应 JS `module/album_dycover.js`。
//!
//! ## 上游特征（2026-09-17 实测）
//! - `GET https://kmrcdn.service.kugou.com/v2/album/audio`
//! - **固定**使用标准版(手机版)身份：`appid=1005` / `clientver=20489`，
//!   盐值 `OIlwieks28dk2k092lksi2UIkp`（本仓库默认的概念版 3116/11440 会返回
//!   `20006 sign error`，与 `process.env.platform` 无关）
//! - 签名只覆盖 `appid/clientver/data/isCdn/query` 五个参数；其中 `data` 是数组，
//!   需 `JSON.stringify` 后既参与签名拼接、又 `encodeURIComponent` 后进查询串。
//!   等价实现即 `helper::signature_android_params_standard(params, b"", false)`
//! - 仅发送 `dfid: -` / `mid: undefined` / `clienttime` 三个身份头（不发 UA、不带
//!   kg-* 默认头，否则会随机 sign error）
//! - `data[].dycover` 缺失或无动态封面时为 `{}`，解析端必须全字段兜底
//!
//! ## 代理安全边界
//! 本文件的媒体代理**只接受 `album_audio_id`**（服务端自行解析 CDN 地址），
//! 不接受任意 URL；且服务器仅监听 `127.0.0.1`。这与 `server.rs` 中显式禁用的
//! `/audio/proxy` 不冲突，也不构成通用转发能力。

use crate::helper;
use crate::modules::q_str;
use crate::request::{raw_request, BodyData, ModuleResponse};
use crate::util::{encode_uri_component, js_string};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::io::Read;

/// 动态封面 CDN（标准版签名专用域名，对请求头敏感）。
pub const DYCOVER_HOST: &str = "https://kmrcdn.service.kugou.com";
pub const DYCOVER_APPID: i64 = 1005;
pub const DYCOVER_CLIENTVER: i64 = 20489;
/// 媒体代理上限：实测 1080×1080 h264 短视频约 9.5MB，留 4 倍余量。
/// 超出即拒绝，避免异常上游把大文件灌进转发链路。
pub const MEDIA_MAX_BYTES: u64 = 40 * 1024 * 1024;

/// 把 query 里的 `album_audio_id` / `album_id`（均支持逗号分隔批量）转成上游 `data` 数组。
///
/// 对齐 JS：`Number(s) || 0` —— 非数字一律落 0；`album_id` 为 0 时不写入该字段
/// （JS 只在 `album_id > 0` 时补字段）。
fn build_data(album_audio_id: &str, album_id: &str) -> Value {
    let album_ids: Vec<&str> = album_id.split(',').collect();
    let mut items: Vec<Value> = Vec::new();
    for (i, raw) in album_audio_id.split(',').enumerate() {
        let raw = raw.trim();
        if raw.is_empty() {
            continue;
        }
        let audio_id: i64 = raw.parse().unwrap_or(0);
        let aid: i64 = album_ids
            .get(i)
            .map(|s| s.trim())
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(0);
        let mut obj = Map::new();
        obj.insert("album_audio_id".to_string(), json!(audio_id));
        if aid > 0 {
            obj.insert("album_id".to_string(), json!(aid));
        }
        items.push(Value::Object(obj));
    }
    Value::Array(items)
}

/// 构造上游完整 URL（含手写查询串 + signature）。
///
/// 不能复用 `request::serialize_params`：它会把 `data` 的 JSON 字符串再编码一次
/// （双重编码），上游解析出的 data 与签名时使用的字节不一致 → 20006。
fn build_upstream_url(data: &Value, query_type: &str) -> String {
    let params = json!({
        "appid": DYCOVER_APPID,
        "clientver": DYCOVER_CLIENTVER,
        "data": data,
        "isCdn": 1,
        "query": query_type,
    });
    // 键序与 JS Object.keys(...).sort() 一致：appid, clientver, data, isCdn, query
    let order = ["appid", "clientver", "data", "isCdn", "query"];
    let mut qs: Vec<String> = Vec::new();
    for k in order {
        let v = params.get(k).cloned().unwrap_or(Value::Null);
        let sv = match &v {
            Value::Object(_) | Value::Array(_) => crate::util::json_stringify(&v),
            other => js_string(Some(other)),
        };
        qs.push(format!("{}={}", k, encode_uri_component(&sv)));
    }
    let signature = helper::signature_android_params_standard(&params, &[], false);
    format!(
        "{}/v2/album/audio?{}&signature={}",
        DYCOVER_HOST,
        qs.join("&"),
        signature
    )
}

/// 该 CDN 只认这三个身份头：dfid/mid 为 JS 侧固定字面量，clienttime 为当前秒。
fn dycover_headers() -> HashMap<String, String> {
    let mut h = HashMap::new();
    h.insert("dfid".to_string(), "-".to_string());
    h.insert("mid".to_string(), "undefined".to_string());
    h.insert(
        "clienttime".to_string(),
        format!("{}", crate::cache::now_epoch_secs() as i64),
    );
    h
}

/// `/album/dycover` —— 专辑动态封面元数据。
///
/// 原样透传上游响应体（`data[i].dycover` 由 Dart 侧解析），仅在传输失败时
/// 返回 502，保持与其它模块一致的错误语义。
pub fn handle_dycover(
    q: &Value,
    _ctx: &crate::modules::Ctx,
) -> Result<ModuleResponse, ModuleResponse> {
    let data = build_data(&q_str(q, "album_audio_id", ""), &q_str(q, "album_id", ""));
    let query_type = {
        let v = q_str(q, "query", "");
        if v.is_empty() {
            "audioPlay".to_string()
        } else {
            v
        }
    };
    let url = build_upstream_url(&data, &query_type);
    let headers = dycover_headers();
    raw_request("GET", &url, &json!({}), BodyData::None, &headers)
}

/// 从 `/album/dycover` 响应体中取出第 0 条的可播放地址（优先 h264，回落备份地址）。
///
/// 返回 `Err(msg)` 表示「该专辑没有动态封面」或「响应不可解析」，调用方据此回 502。
pub fn extract_media_url(body: &Value) -> Result<String, String> {
    let item = body
        .get("data")
        .and_then(|d| d.as_array())
        .and_then(|a| a.first())
        .ok_or_else(|| "no data".to_string())?;
    let dy = item
        .get("dycover")
        .ok_or_else(|| "no dycover".to_string())?;
    let primary = dy
        .get("h264_url")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    if let Some(u) = primary {
        return Ok(u.to_string());
    }
    dy.get("h264_backup_url")
        .and_then(Value::as_array)
        .and_then(|a| a.first())
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .ok_or_else(|| "no h264 url".to_string())
}

/// 解析某专辑的动态封面 mp4 直链（元数据请求 + 提取）。媒体代理每次请求调用一次。
pub fn resolve_media_url(album_audio_id: &str) -> Result<String, String> {
    let data = build_data(album_audio_id, "");
    let url = build_upstream_url(&data, "audioPlay");
    let headers = dycover_headers();
    let res = raw_request("GET", &url, &json!({}), BodyData::None, &headers)
        .map_err(|_| "dycover metadata request failed".to_string())?;
    extract_media_url(&res.body.to_json())
}

/// 从原始 URL 里取一个查询参数（只用于纯数字的 album_audio_id，不做百分号解码）。
fn raw_query_param(url: &str, key: &str) -> String {
    let qs = match url.split_once('?') {
        Some((_, q)) => q,
        None => return String::new(),
    };
    for pair in qs.split('&') {
        if let Some((k, v)) = pair.split_once('=') {
            if k == key {
                return v.to_string();
            }
        }
    }
    String::new()
}

/// `/album/dycover/media?album_audio_id=xxx` —— 把动态封面 mp4 流式转发给本机客户端。
///
/// 由 `server.rs::handle_request` 在 apicache 之前特判调用：
/// ① 模块框架只能整块缓冲 body（`Response::from_data`），10MB 媒体会驻留内存；
/// ② 模块响应会被写入 120s 内存缓存，媒体不宜进缓存；
/// ③ 模块上下文拿不到请求头。
///
/// ## 关于 Range
/// 不实现 Range，并显式回 `Accept-Ranges: none`。依据：
/// - ExoPlayer 的 `DefaultHttpDataSource` 首个请求 position=0 且 length 未设
///   （`buildRangeRequestHeader` 在该条件下返回 null）→ 根本不发 Range 头，
///   顺序读取即为「边下边播」，正是客户端需要的形态；
/// - 万一客户端发了 Range 而拿到 200，ExoPlayer 会用 `bytesToSkip` 跳过已读字节，
///   不会报错（仅多耗一点带宽）；
/// - 私有构建的落盘请求（Task 9，dio 单次 GET）同样不需要断点续传。
/// 若日后实测出现循环/seek 重新拉流造成的卡顿，再补 Range 支持（当前不做，YAGNI）。
pub fn handle_media_proxy(request: tiny_http::Request, url: &str) -> Result<(), String> {
    use tiny_http::{Header, Response, StatusCode};

    let album_audio_id = raw_query_param(url, "album_audio_id");
    if album_audio_id.trim().is_empty() {
        let body = json!({
            "status": 0,
            "error_code": 400,
            "error": "album_audio_id is required",
        });
        let mut resp = Response::from_data(crate::util::json_stringify(&body).into_bytes())
            .with_status_code(StatusCode(400));
        resp = resp.with_header(
            Header::from_bytes("Content-Type", "application/json; charset=utf-8")
                .map_err(|_| "bad header".to_string())?,
        );
        return request.respond(resp).map_err(|e| e.to_string());
    }

    let media_url = match resolve_media_url(&album_audio_id) {
        Ok(u) => u,
        Err(e) => {
            return respond_media_error(request, &format!("dycover unavailable: {}", e))
        }
    };

    let (status, len, ct, reader) = match crate::request::open_stream(&media_url) {
        Ok(v) => v,
        Err(e) => {
            return respond_media_error(request, &format!("media upstream failed: {}", e))
        }
    };
    if let Some(n) = len {
        if n > MEDIA_MAX_BYTES {
            return respond_media_error(request, &format!("media too large: {} bytes", n));
        }
    }

    let mut headers = Vec::new();
    headers.push(
        Header::from_bytes("Content-Type", ct.as_bytes())
            .map_err(|_| "bad content-type".to_string())?,
    );
    // 显式声明不支持 Range：客户端据此不做断点请求，语义无歧义
    headers.push(
        Header::from_bytes("Accept-Ranges", "none").map_err(|_| "bad header".to_string())?,
    );

    // 长度未知时用 chunked（data_length=None），并用 take 兜住体积上限
    let reader = reader.take(MEDIA_MAX_BYTES + 1);
    let resp = Response::new(
        StatusCode(status),
        headers,
        reader,
        len.map(|n| n as usize),
        None,
    )
    // tiny_http 的 chunked_threshold 默认只有 32KB，且判定是「data_length >= 阈值
    // 就改发 Transfer-Encoding: chunked」（见 tiny_http response.rs 的
    // transfer_encoding 判定）→ 9.5MB 的 mp4 会丢掉 Content-Length。
    // 后果：ExoPlayer 拿不到总长度，只能按不可 seek 的流处理，循环播放时可能
    // 重新从头拉一遍（每圈最多 9.5MB 白流量）。把阈值抬到体积上限之上，
    // 让被接受（≤ MEDIA_MAX_BYTES）的响应始终带 Content-Length。
    .with_chunked_threshold(MEDIA_MAX_BYTES as usize + 1);
    request.respond(resp).map_err(|e| e.to_string())
}

/// 媒体代理的 JSON 错误响应（502），语义与 `respond_module` 的失败一致。
fn respond_media_error(request: tiny_http::Request, msg: &str) -> Result<(), String> {
    use tiny_http::{Header, Response, StatusCode};

    let body = json!({ "status": 0, "msg": msg });
    let mut resp = Response::from_data(crate::util::json_stringify(&body).into_bytes())
        .with_status_code(StatusCode(502));
    resp = resp.with_header(
        Header::from_bytes("Content-Type", "application/json; charset=utf-8")
            .map_err(|_| "bad header".to_string())?,
    );
    request.respond(resp).map_err(|e| e.to_string())
}
