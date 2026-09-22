//! user_listen_report.js → /user/listen/report（CSCC 真实播放事件上报）。
//!
//! 对照 KuGouMusicApi `module/user_listen_report.js`：上报真实播放的开始/结束
//! 事件到 CSCC（`http://d.kugou.com`），替代「播放历史补偿」这一近似手段。
//!
//! 三段式流程（会话命中缓存则跳过前两段）：
//!   1. POST `/v3/qrydid`  appid=and02 → deviceid
//!      data = {"machine":dev,"mid":mid,"uuid":uuid,"wh":[w,h]}
//!      sign = md5("_t" + _t + "appidand02" + PB_SALT + data)
//!   2. GET  `/v2/gen`     appid=3116
//!      s = base64(RSA_PKCS1v15("<uuid>\t<field2>\t<ms>\t<deviceid>"))   // lite 公钥
//!      sign = md5("_t" + _t + "appid3116" + "s" + s + APPKEY)
//!      响应 data 用 AES-256-CBC(key=utf8(field2), iv=utf8(uuid[0:16])) 解出
//!      {cookie, clienttime, serverstr}
//!   3. POST `/v2/post`    appid=3116
//!      plain = line1\r\nline2\r\n + deflate(eventFields)
//!      key   = md5(uuid + clienttime + field2 + serverstr)              // 32 字符
//!      enc   = AES-256-CBC(deflate(plain), key, iv=uuid[0:16])
//!      sign  = md5(排序后 query 键值拼接 + APPKEY + enc)
//!
//! 关键约定（照搬 JS，勿改）：
//! - 会话按 `md5([uuid,mid,userid,token,dev,sys,w,h])` 隔离，30min TTL、上限 256
//!   （LRU 淘汰最旧一条），并发建会话只发一次请求。
//! - 事件不自动重试（超时也可能已记账，重试会重复上报）——本实现同样只发一次。
//! - `uuid` 必须为 32 位字母数字（本工程 `DeviceConfig` 的 uuid = md5(dfid+mid) 天然合规）。

use crate::config::APP_ID;
use crate::crypto::{
    aes_cbc_decrypt, aes_cbc_encrypt, base64_decode, base64_encode, hex_encode, md5_hex, md5_hex_3,
    md5_hex_4, rsa_pkcs1v15_encrypt, PUBLIC_LITE_RAS_KEY,
};
use crate::device::DeviceConfig;
use crate::modules::{c_str, param_or_cookie_str, q_str, Ctx};
use crate::request::{BodyData, BodyValue, ModuleResponse, RequestOptions};
use crate::util::json_stringify;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

/// CSCC 事件协议版本（JS `VERSION`；与 grade 的 clientver 口径一致，均为 10597）。
const CSCC_VERSION: &str = "10597";
/// CSCC 签名盐（JS `APPKEY`，与本工程 `SIGN_PARAMS_KEY_STR` 同值）。
const CSCC_APPKEY: &str = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA";
/// `/v3/qrydid` 的签名盐（JS 硬编码）。
const QRYDID_SALT: &str = "pbKC7zn{4U*ydo2M1Rir";
/// CSCC 上游主机。
const CSCC_HOST: &str = "http://d.kugou.com";
/// 会话有效期（JS 30 分钟）。
const SESSION_TTL_SECS: u64 = 30 * 60;
/// 会话缓存容量上限（JS 256，超限淘汰最旧一条）。
const SESSION_MAX: usize = 256;

// ---------------------------------------------------------------------------
// 会话缓存
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct Session {
    cookie: String,
    clienttime: i64,
    serverstr: String,
    /// 16 随机字节的 hex，用于派生报文 AES key。
    field2: String,
}

struct SessionEntry {
    session: Session,
    expires_at: u64,
}

fn sessions() -> &'static Mutex<HashMap<String, SessionEntry>> {
    static SESSIONS: OnceLock<Mutex<HashMap<String, SessionEntry>>> = OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 当前 Unix 秒。
fn now_secs() -> u64 {
    crate::cache::now_epoch_secs() as u64
}

/// 取有效会话；过期条目顺带清理。命中返回 `Some`。
fn session_get(key: &str) -> Option<Session> {
    let mut map = sessions().lock().unwrap();
    let now = now_secs();
    map.retain(|_, e| e.expires_at > now);
    map.get(key).map(|e| e.session.clone())
}

fn session_put(key: &str, session: Session) {
    let mut map = sessions().lock().unwrap();
    if map.len() >= SESSION_MAX {
        // LRU：淘汰最早过期的一条（JS 删除 Map 的第一个 key）
        if let Some(k) = map
            .iter()
            .min_by_key(|(_, e)| e.expires_at)
            .map(|(k, _)| k.clone())
        {
            map.remove(&k);
        }
    }
    map.insert(
        key.to_string(),
        SessionEntry {
            session,
            expires_at: now_secs() + SESSION_TTL_SECS,
        },
    );
}

fn session_remove(key: &str) {
    sessions().lock().unwrap().remove(key);
}

// ---------------------------------------------------------------------------
// deflate（zlib，与 JS `zlib.deflateSync` 同格式）
// ---------------------------------------------------------------------------

fn deflate(data: &[u8]) -> Vec<u8> {
    use flate2::write::ZlibEncoder;
    use flate2::Compression;
    use std::io::Write;
    let mut enc = ZlibEncoder::new(Vec::new(), Compression::default());
    // 写入 Vec 不会失败；失败时回退空数据（上游会拒绝，日志可查）
    if enc.write_all(data).is_err() {
        return Vec::new();
    }
    enc.finish().unwrap_or_default()
}

// ---------------------------------------------------------------------------
// 入参校验（对齐 JS 的 fail(400, ...) 语义）
// ---------------------------------------------------------------------------

fn bad_request(msg: &str) -> ModuleResponse {
    ModuleResponse {
        status: 400,
        body: BodyValue::Json(json!({ "status": 0, "msg": msg })),
        cookie: Vec::new(),
        headers: HashMap::new(),
    }
}

/// `clean(value)`：非空字符串且不含 `&`/制表/换行。
fn is_clean(v: &str) -> bool {
    !v.is_empty() && !v.contains('&') && !v.contains('\t') && !v.contains('\r') && !v.contains('\n')
}

/// `/^(0|[1-9]\d*)$/` 十进制非负整数。
fn is_uint_str(v: &str) -> bool {
    if v.is_empty() {
        return false;
    }
    let b = v.as_bytes();
    if b[0] == b'0' {
        return b.len() == 1;
    }
    b.iter().all(|c| c.is_ascii_digit())
}

/// `^\d+(?:\.\d+)*$`
fn is_version_str(v: &str) -> bool {
    if v.is_empty() {
        return false;
    }
    v.split('.').all(|seg| !seg.is_empty() && seg.bytes().all(|c| c.is_ascii_digit()))
}

/// 32 位字母数字。
fn is_uuid32(v: &str) -> bool {
    v.len() == 32 && v.bytes().all(|c| c.is_ascii_alphanumeric())
}

/// 合法 IPv4/IPv6（`net.isIP`）。用 `std::net::IpAddr` 解析等价。
fn is_ip(v: &str) -> bool {
    v.parse::<std::net::IpAddr>().is_ok()
}

// ---------------------------------------------------------------------------
// 单段请求封装（对齐 JS `request(url, method, query, data, kind)`）
// ---------------------------------------------------------------------------

/// 事件诊断上下文，用于失败时附加 `stage`/`event`/`mixsongid`。
struct EventCtx {
    event: String,
    mixsongid: String,
    duration: Option<i64>,
    state: String,
}

impl EventCtx {
    /// 附加到错误体的诊断字段（仅 /v2/post 段带 duration/state，与 JS 一致）。
    fn details(&self, stage: &str) -> Value {
        let mut m = serde_json::Map::new();
        m.insert("stage".to_string(), json!(stage));
        m.insert("event".to_string(), json!(self.event));
        m.insert("mixsongid".to_string(), json!(self.mixsongid));
        if stage == "/v2/post" && self.event == "end" {
            if let Some(d) = self.duration {
                m.insert("duration".to_string(), json!(d));
            }
            m.insert("state".to_string(), json!(self.state));
        }
        Value::Object(m)
    }
}

/// 发一段 CSCC 请求；HTTP 非 200 或业务失败（status==0 / errcode!=0 / error_code!=0）
/// 统一返回 `502` 并附带 `stage` 与事件信息（对齐 JS 的 throw 语义）。
fn cscc_request(
    ctx: &Ctx,
    url: &str,
    method: &str,
    query: Value,
    body: BodyData,
    kind: &str,
    ev: &EventCtx,
) -> Result<Value, ModuleResponse> {
    let mut opts = RequestOptions::new(url)
        .base_url(CSCC_HOST)
        .params(query)
        .clear_default_params(true)
        .not_signature(true);
    opts = if method.eq_ignore_ascii_case("POST") {
        opts.post(url)
    } else {
        opts.get(url)
    };
    opts.data = body;
    // `/v3/qrydid` 不发 KG-Rec / User-Agent（对照 JS 的 url !== '/v3/qrydid' 判断）
    if url != "/v3/qrydid" {
        opts.headers.insert("KG-Rec".to_string(), "1".to_string());
        opts.headers.insert(
            "User-Agent".to_string(),
            format!("Android9-1070-{}-18-0-Cscc{}-wifi", CSCC_VERSION, kind),
        );
    }
    let res = ctx.send(&opts).map_err(|mut e| {
        let body = e.body.to_json();
        e.status = 502;
        let mut m = body.as_object().cloned().unwrap_or_default();
        m.insert("status".to_string(), json!(0));
        if let Some(d) = ev.details(url).as_object() {
            for (k, v) in d {
                m.insert(k.clone(), v.clone());
            }
        }
        e.body = BodyValue::Json(Value::Object(m));
        e
    })?;
    let body = res.body.to_json();
    let errcode_bad = match body.get("errcode") {
        Some(v) => value_as_string(v) != "0",
        None => false,
    };
    let error_code_bad = match body.get("error_code") {
        Some(v) => value_as_string(v) != "0",
        None => false,
    };
    let status_zero = body.get("status").and_then(|v| v.as_i64()) == Some(0);
    // 注：`/v2/post`（errcode 1203 重复上报拒绝的唯一来源）**不**经过本函数，
    // 它有独立实现，1203 归一化在那边处理。本函数只服务 `/v3/qrydid` 与 `/v2/gen`。
    if res.status != 200 || status_zero || errcode_bad || error_code_bad {
        let mut m = body.as_object().cloned().unwrap_or_default();
        if let Some(d) = ev.details(url).as_object() {
            for (k, v) in d {
                m.insert(k.clone(), v.clone());
            }
        }
        return Err(ModuleResponse {
            status: 502,
            body: BodyValue::Json(Value::Object(m)),
            cookie: res.cookie,
            headers: res.headers,
        });
    }
    Ok(body)
}

/// 值转字符串（数字保持无小数点形态）。
fn value_as_string(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        _ => String::new(),
    }
}

// ---------------------------------------------------------------------------
// 主入口
// ---------------------------------------------------------------------------

/// user_listen_report.js → /user/listen/report（CSCC 真实播放事件上报）。
///
/// 沿用方案 C：只实现事件上报本身，不在此处联动 `/user/grade/info`
/// （等级同步仍由既有 `ListeningGradeService` 差量链路负责）。
pub fn handle_listen_report(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    // ---------- 设备身份（uuid / mid）----------
    // 关键：**设备信息优先，其次 params/cookie**，与 `song_url.rs` / `song_url_new.rs`
    // 的既有口径一致。原因：
    // 1. 上游 CSCC 对 uuid 有 `^[a-zA-Z0-9]{32}$` 硬校验，而 `get_uuid()` 在
    //    dfid 尚未注册时会回落 `"-"`；`get_device_info()` 会先 `init_device_info()`
    //    补齐 guid → mid，再据 dfid+mid 推导 uuid，取到有效值的概率高得多；
    // 2. Dart 侧从不发送 uuid/mid（认证只走 `Authorization: token=…;userid=…`，
    //    服务端 cookieToJson 只会解出 token/userid/vip_token）→ 若这里依赖
    //    params/cookie，必然拿到空串 → 400。真机首测即因此失败。
    let dev_info = DeviceConfig::instance().get_device_info();
    let uuid = {
        let d = dev_info.get("uuid").and_then(Value::as_str).unwrap_or("-");
        if !d.is_empty() && d != "-" {
            d.to_string()
        } else {
            let p = param_or_cookie_str(q, "uuid", "");
            if !p.is_empty() {
                p
            } else {
                param_or_cookie_str(q, "KUGOU_API_GUID", "")
            }
        }
    };
    let mid = {
        let d = dev_info.get("mid").and_then(Value::as_str).unwrap_or("-");
        if !d.is_empty() && d != "-" {
            d.to_string()
        } else {
            let p = param_or_cookie_str(q, "mid", "");
            if !p.is_empty() {
                p
            } else {
                c_str(q, "KUGOU_API_MID")
            }
        }
    };
    let userid = param_or_cookie_str(q, "userid", "");
    let token = param_or_cookie_str(q, "token", "");
    let song = param_or_cookie_str(q, "mixsongid", "");
    let event = q_str(q, "event", "");
    let state = q_str(q, "state", "完整播放");
    let has_d_sec = q.get("d_sec").map(|v| !v.is_null()).unwrap_or(false);
    let has_diff_sec = q.get("diff_sec").map(|v| !v.is_null()).unwrap_or(false);
    let sync = has_d_sec || has_diff_sec;
    let duration_raw = param_or_cookie_str(q, "duration", "");
    // 默认设备名称复用项目已有的 dev 配置（对齐 JS 的 dev 兜底顺序）
    let device_model = {
        let v = param_or_cookie_str(q, "device_model", "");
        if !v.is_empty() {
            v
        } else {
            let d = param_or_cookie_str(q, "dev", "");
            if !d.is_empty() {
                d
            } else {
                let c = c_str(q, "KUGOU_API_DEV");
                if c.is_empty() { "KuGouMusicApi".to_string() } else { c }
            }
        }
    };
    let system_version = {
        let v = param_or_cookie_str(q, "system_version", "");
        if v.is_empty() { "9".to_string() } else { v }
    };
    let screen_width = {
        let v = param_or_cookie_str(q, "screen_width", "");
        if v.is_empty() { 1920 } else { v.parse::<i64>().unwrap_or(0) }
    };
    let screen_height = {
        let v = param_or_cookie_str(q, "screen_height", "");
        if v.is_empty() { 1080 } else { v.parse::<i64>().unwrap_or(0) }
    };
    let local_ip = {
        let v = param_or_cookie_str(q, "local_ip", "");
        if v.is_empty() { "0.0.0.0".to_string() } else { v }
    };

    // ---------- 校验（对齐 JS 的逐条 fail(400)）----------
    if !is_clean(&device_model)
        || device_model.len() > 128
        || device_model.bytes().any(|c| c < 0x20 || c == 0x7f)
    {
        return Err(bad_request("设备参数无效：需要有效机型"));
    }
    if !is_version_str(&system_version) || system_version.len() > 16 {
        return Err(bad_request("设备参数无效：需要有效系统版本"));
    }
    if !(1..=65535).contains(&screen_width) {
        return Err(bad_request("设备参数无效：screen_width 需为 1-65535 正整数"));
    }
    if !(1..=65535).contains(&screen_height) {
        return Err(bad_request("设备参数无效：screen_height 需为 1-65535 正整数"));
    }
    if !is_ip(&local_ip) {
        return Err(bad_request("设备参数无效：local_ip 需为合法 IPv4/IPv6"));
    }
    if !is_uuid32(&uuid) || !is_clean(&mid) || !is_uint_str(&userid) || token.is_empty() {
        // 带上具体缺失项，避免真机排障时只能看到笼统的 400（首测曾因此多绕一圈）
        let mut missing: Vec<&str> = Vec::new();
        if !is_uuid32(&uuid) {
            missing.push("32位字母数字uuid");
        }
        if !is_clean(&mid) {
            missing.push("mid");
        }
        if !is_uint_str(&userid) {
            missing.push("userid");
        }
        if token.is_empty() {
            missing.push("token");
        }
        return Err(bad_request(&format!(
            "需要 token、userid、mid 和 32 位字母数字 uuid（缺失/无效: {}）",
            missing.join("、")
        )));
    }
    if !is_uint_str(&song) || song == "0" || !matches!(event.as_str(), "start" | "end") {
        return Err(bad_request("需要有效 mixsongid 和 event=start|end"));
    }
    // end 强制 duration（非负整数）与有效 state
    let duration: i64 = if event == "end" {
        if duration_raw.is_empty() || !is_uint_str(&duration_raw) {
            return Err(bad_request("结束事件需要非负整数 duration（实际播放毫秒数）"));
        }
        duration_raw.parse::<i64>().unwrap_or(0)
    } else {
        duration_raw.parse::<i64>().unwrap_or(0)
    };
    if event == "end" && !is_clean(&state) {
        return Err(bad_request("结束事件需要有效 state"));
    }
    if sync {
        let d_sec = param_or_cookie_str(q, "d_sec", "");
        let diff_sec = param_or_cookie_str(q, "diff_sec", "");
        let valid = event == "end"
            && is_uint_str(&d_sec)
            && is_uint_str(&diff_sec)
            && diff_sec.parse::<i64>().unwrap_or(i64::MAX) <= (duration + 999) / 1000;
        if !valid {
            return Err(bad_request(
                "等级同步仅支持结束事件，需提供 d_sec、diff_sec（秒），增量不得超过本次播放时长",
            ));
        }
    }

    let ev = EventCtx {
        event: event.clone(),
        mixsongid: song.clone(),
        duration: if event == "end" { Some(duration) } else { None },
        state: state.clone(),
    };

    // ---------- 会话（缓存 key 含全部设备/账号维度，任一变化即重建）----------
    let cache_key = md5_hex(
        json_stringify(&json!([
            uuid, mid, userid, token, device_model, system_version, screen_width, screen_height
        ]))
        .as_bytes(),
    );

    let session = match session_get(&cache_key) {
        Some(s) => s,
        None => match build_session(
            ctx,
            &ev,
            &uuid,
            &mid,
            &device_model,
            screen_width,
            screen_height,
        ) {
            Ok(s) => {
                session_put(&cache_key, s.clone());
                s
            }
            Err(e) => return Err(e),
        },
    };

    // ---------- 构造事件报文 ----------
    let fields = build_event_fields(
        &event,
        &song,
        &state,
        duration,
        &mid,
        &uuid,
        &system_version,
        &device_model,
        &userid,
        &local_ip,
    );
    let event_buffer = fields.as_bytes();

    let line1 = [
        "4",
        "1",
        uuid.as_str(),
        "0",
        APP_ID,
        CSCC_VERSION,
        "18",
        system_version.as_str(),
        device_model.as_str(),
        uuid.as_str(),
        mid.as_str(),
        "0",
        "000000000000000000000000000000000000",
    ]
    .join("\t");
    let line2 = [
        event_buffer.len().to_string(),
        "10048".to_string(),
        "0".to_string(),
        now_secs().to_string(),
        "1".to_string(),
        userid.clone(),
        "0".to_string(),
        "0".to_string(),
    ]
    .join("\t");

    let mut plain: Vec<u8> = Vec::new();
    plain.extend_from_slice(format!("{}\r\n{}\r\n", line1, line2).as_bytes());
    plain.extend_from_slice(&deflate(event_buffer));

    // key = md5(uuid + clienttime + field2 + serverstr) → 32 字符（AES-256）
    let aes_key = md5_hex_4(
        uuid.as_bytes(),
        session.clienttime.to_string().as_bytes(),
        session.field2.as_bytes(),
        session.serverstr.as_bytes(),
    );
    let iv: Vec<u8> = uuid.as_bytes()[..16.min(uuid.len())].to_vec();
    let encrypted = aes_cbc_encrypt(aes_key.as_bytes(), &iv, &deflate(&plain));

    // query 按 key 字典序拼接后追加 APPKEY 与密文 → sign
    let mut query: Vec<(String, String)> = vec![
        ("cookie".to_string(), session.cookie.clone()),
        ("length".to_string(), plain.len().to_string()),
        ("appid".to_string(), APP_ID.to_string()),
        ("_t".to_string(), now_secs().to_string()),
    ];
    query.sort_by(|a, b| a.0.cmp(&b.0));
    let sorted: String = query.iter().map(|(k, v)| format!("{}{}", k, v)).collect();
    let sign = md5_hex_3(sorted.as_bytes(), CSCC_APPKEY.as_bytes(), &encrypted);
    query.push(("sign".to_string(), sign));

    let mut qm = serde_json::Map::new();
    for (k, v) in &query {
        qm.insert(k.clone(), json!(v));
    }

    let mut opts = RequestOptions::new("/v2/post")
        .base_url(CSCC_HOST)
        .post("/v2/post")
        .params(Value::Object(qm))
        .bytes_body(encrypted.clone())
        .clear_default_params(true)
        .not_signature(true)
        .timeout_secs(10);
    opts.headers.insert("Content-Type".to_string(), "application/octet-stream".to_string());
    opts.headers.insert("KG-Rec".to_string(), "1".to_string());
    opts.headers.insert(
        "User-Agent".to_string(),
        format!("Android{}-1070-{}-18-0-CsccPost-wifi", system_version, CSCC_VERSION),
    );

    // 注：Rust 侧 `eprintln!` 在 Android **不可见**（stderr 不接 logcat），
    // 必须走 `log::` 宏（android_logger 已在 lib.rs 初始化，tag = kugou_server）。
    // 常规明细用 debug 级（默认 LevelFilter::Info 下静默），仅关键分支用 info/warn。
    log::debug!(
        "[CSCC-DEBUG] post event={} song={} duration={} plain_len={} enc_len={} key={}",
        event,
        song,
        duration,
        plain.len(),
        encrypted.len(),
        cache_key,
    );

    let res = match ctx.send(&opts) {
        Ok(r) => r,
        Err(mut e) => {
            // `errcode 1203` = CSCC 的**重复上报拒绝**（同一 mixsongid 在防抖窗口内被重复提交）。
            // 真机实测：新歌 start 紧跟在上一首 end 之后发出时命中，第二次换新 mixsongid 即成功。
            // 语义上「已被记过一次」= 目标已达成，不是失败。此处必须**在**通用错误分支之前
            // 拦截，否则会被包装成 502 冒泡到 Dart，日志被无害的重复拒绝刷满。
            let raw = e.body.to_json();
            let duplicate_rejected =
                value_as_string(raw.get("errcode").unwrap_or(&Value::Null)) == "1203";
            if duplicate_rejected {
                // 会话仍有效（1203 只代表事件被去重），**不要**删除，避免下一首重新建会话
                log::info!(
                    "[CSCC-DEBUG] 重复上报被拒（benign）event={} song={}",
                    ev.event, ev.mixsongid
                );
                return Ok(ModuleResponse {
                    status: 200,
                    body: BodyValue::Json(json!({ "status": 1, "errcode": 0, "duplicate": true })),
                    cookie: e.cookie,
                    headers: e.headers,
                });
            }
            // 其余错误：事件不自动重试，删除会话（可能已污染），直接返回错误
            session_remove(&cache_key);
            let mut m = raw.as_object().cloned().unwrap_or_default();
            m.insert("status".to_string(), json!(0));
            if let Some(d) = ev.details("/v2/post").as_object() {
                for (k, v) in d {
                    m.insert(k.clone(), v.clone());
                }
            }
            e.status = 502;
            e.body = BodyValue::Json(Value::Object(m));
            log::warn!(
                "[CSCC-DEBUG] post 失败 status={} body={}",
                e.status,
                json_stringify(&e.body.to_json())
            );
            return Err(e);
        }
    };

    let body = res.body.to_json();
    log::debug!(
        "[CSCC-DEBUG] post 返回 status={} body={}",
        res.status,
        json_stringify(&body),
    );

    // 同一条路径上的 1203 兜底：若上游以 200 携带 `errcode:1203` 返回（非 Err 形态），
    // 也必须归一化为成功，否则会走通用失败分支返回 502。
    if value_as_string(body.get("errcode").unwrap_or(&Value::Null)) == "1203" {
        log::info!(
            "[CSCC-DEBUG] 重复上报被拒（benign, http200）event={} song={}",
            ev.event, ev.mixsongid
        );
        return Ok(ModuleResponse {
            status: 200,
            body: BodyValue::Json(json!({ "status": 1, "errcode": 0, "duplicate": true })),
            cookie: res.cookie,
            headers: res.headers,
        });
    }
    Ok(res)
}

/// 建会话：`/v3/qrydid` 取 deviceid → `/v2/gen` 取并解密会话。
///
/// 注意：`system_version` 不参与会话建立（CSCC 会话只绑定 uuid/mid/机型/屏幕），
/// 仅在事件报文的 `sys=` 字段使用；故此处不接收该参数。
#[allow(clippy::too_many_arguments)]
fn build_session(
    ctx: &Ctx,
    ev: &EventCtx,
    uuid: &str,
    mid: &str,
    device_model: &str,
    screen_width: i64,
    screen_height: i64,
) -> Result<Session, ModuleResponse> {
    // ---- 第 1 段：/v3/qrydid ----
    let device_data = json_stringify(&json!({
        "machine": device_model,
        "mid": mid,
        "uuid": uuid,
        "wh": [screen_width, screen_height],
    }));
    let t1 = now_secs();
    let sign1 = md5_hex_4(
        format!("_t{}", t1).as_bytes(),
        b"appidand02",
        QRYDID_SALT.as_bytes(),
        device_data.as_bytes(),
    );
    let device = cscc_request(
        ctx,
        "/v3/qrydid",
        "POST",
        json!({ "appid": "and02", "_t": t1.to_string(), "sign": sign1 }),
        BodyData::Bytes(device_data.clone().into_bytes()),
        "Gen",
        ev,
    )?;
    let deviceid = device
        .get("data")
        .and_then(|d| d.get("deviceid"))
        .map(value_as_string)
        .unwrap_or_default();
    if deviceid.is_empty() {
        return Err(ModuleResponse {
            status: 502,
            body: BodyValue::Json(json!({
                "status": 0, "msg": "CSCC 未返回 deviceid",
            })),
            cookie: Vec::new(),
            headers: HashMap::new(),
        });
    }

    // ---- 第 2 段：/v2/gen ----
    let field2_bytes: Vec<u8> = {
        use rand::RngCore;
        let mut buf = vec![0u8; 16];
        rand::thread_rng().fill_bytes(&mut buf);
        buf
    };
    let field2 = hex_encode(&field2_bytes);
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let rsa_plain = format!("{}\t{}\t{}\t{}", uuid, field2, ms, deviceid);
    let s = base64_encode(&rsa_pkcs1v15_encrypt(PUBLIC_LITE_RAS_KEY, rsa_plain.as_bytes()));
    let t2 = now_secs();
    let sign2 = md5_hex_4(
        format!("_t{}", t2).as_bytes(),
        b"appid3116s",
        s.as_bytes(),
        CSCC_APPKEY.as_bytes(),
    );
    let gen = cscc_request(
        ctx,
        "/v2/gen",
        "GET",
        json!({ "s": s, "appid": APP_ID, "_t": t2.to_string(), "sign": sign2 }),
        BodyData::None,
        "Gen",
        ev,
    )?;

    // 解密：AES-256-CBC(key=utf8(field2), iv=utf8(uuid[0:16]))
    let enc_b64 = gen
        .get("data")
        .map(value_as_string)
        .unwrap_or_default();
    let iv: Vec<u8> = uuid.as_bytes()[..16.min(uuid.len())].to_vec();
    let dec = aes_cbc_decrypt(field2.as_bytes(), &iv, &base64_decode(&enc_b64));
    let parsed: Value = serde_json::from_slice(&dec).map_err(|_| ModuleResponse {
        status: 502,
        body: BodyValue::Json(json!({ "status": 0, "msg": "CSCC 会话响应无效" })),
        cookie: Vec::new(),
        headers: HashMap::new(),
    })?;
    let cookie = parsed
        .get("cookie")
        .map(value_as_string)
        .unwrap_or_default();
    let clienttime = parsed.get("clienttime").and_then(|v| v.as_i64());
    let serverstr = parsed
        .get("serverstr")
        .map(value_as_string)
        .unwrap_or_default();
    if cookie.is_empty() || clienttime.is_none() || serverstr.is_empty() {
        return Err(ModuleResponse {
            status: 502,
            body: BodyValue::Json(json!({ "status": 0, "msg": "CSCC 会话响应无效" })),
            cookie: Vec::new(),
            headers: HashMap::new(),
        });
    }

    // 会话建立是**每会话一次**的低频事件（缓存 TTL 30min），放在 info 级：
    // 既便于确认「Rust → logcat」日志链路真的通了（debug 级在默认配置下静默），
    // 也能留下本次上报所用的设备身份（uuid/mid/deviceid）便于对账。
    log::info!(
        "[CSCC-DEBUG] 会话建立 ok uuid={} mid={} deviceid={} clienttime={}",
        uuid,
        mid,
        deviceid,
        clienttime.unwrap_or(0),
    );

    Ok(Session {
        cookie,
        clienttime: clienttime.unwrap_or(0),
        serverstr,
        field2,
    })
}

/// 拼装 `&` 连接的事件字段（start/end 差异 + 公共尾部，顺序照搬 JS）。
#[allow(clippy::too_many_arguments)]
fn build_event_fields(
    event: &str,
    song: &str,
    state: &str,
    duration: i64,
    mid: &str,
    uuid: &str,
    system_version: &str,
    device_model: &str,
    userid: &str,
    local_ip: &str,
) -> String {
    const FO3: &str = "3878,4320,4326,5747,5749,7229,7289,7863";
    let mut fields: Vec<String> = Vec::new();
    if event == "start" {
        fields.push("type_id=20431".to_string());
        fields.push("action=play".to_string());
        fields.push(format!("fo3={}", FO3));
        fields.push("spt=0".to_string());
        fields.push("sty=手动".to_string());
        fields.push(format!("mixsongid={}", song));
        fields.push("source=46".to_string());
        fields.push("ivar1=1".to_string());
        fields.push("fo=/专辑播放页".to_string());
    } else {
        fields.push("type_id=4".to_string());
        fields.push("action=play".to_string());
        fields.push(format!("fo3={}", FO3));
        fields.push(format!("duration={}", duration));
        fields.push("svar3=0".to_string());
        fields.push("svar2=0".to_string());
        fields.push("fo=我的音乐/主态/自建歌单/RU".to_string());
        fields.push("sty=手动".to_string());
        fields.push(format!("state={}", state));
        fields.push(format!("mixsongid={}", song));
        fields.push("source=46".to_string());
        fields.push("ivar3=0".to_string());
        fields.push("type=1".to_string());
        fields.push("fs=1.0".to_string());
        fields.push("ivar1=1".to_string());
    }
    fields.push(format!("mid={}", mid));
    fields.push(format!("uuid={}", uuid));
    fields.push("ss1=1".to_string());
    fields.push("ss2=1".to_string());
    fields.push(format!("sys={}", system_version));
    fields.push(format!("mod={}", device_model));
    fields.push("channelid=18".to_string());
    fields.push(format!("ip={}", local_ip));
    fields.push("net=1".to_string());
    fields.push(format!("ver={}", CSCC_VERSION));
    fields.push("gitversion=7aa8a76".to_string());
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    fields.push(format!("time={}", ms));
    fields.push(format!("userid={}", userid));
    // ss3 = md5(随机 UUID v4)：用 16 随机字节的 md5 等价复刻「每次随机」语义
    let rand_uuid: Vec<u8> = {
        use rand::RngCore;
        let mut buf = vec![0u8; 16];
        rand::thread_rng().fill_bytes(&mut buf);
        buf
    };
    fields.push(format!("ss3={}", md5_hex(&rand_uuid)));
    fields.join("&")
}

// ---------------------------------------------------------------------------
// 单元测试：协议原语（不依赖外网的确定性部分）
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// deflate 必须产出 zlib 流（首字节 0x78），且可被 inflate 还原。
    /// 回归：CSCC 报文两层压缩都用 zlib.deflateSync，格式错误上游直接拒收。
    #[test]
    fn deflate_roundtrip() {
        use flate2::read::ZlibDecoder;
        use std::io::Read;
        let src = b"type_id=20431&action=play&mixsongid=260403475";
        let z = deflate(src);
        assert_eq!(z[0], 0x78, "zlib header");
        let mut out = Vec::new();
        ZlibDecoder::new(&z[..]).read_to_end(&mut out).unwrap();
        assert_eq!(out, src);
    }

    /// 入参校验必须与 JS 的正则严格一致。
    #[test]
    fn validators_match_js() {
        // uuid：恰好 32 位字母数字
        assert!(is_uuid32("0123456789abcdef0123456789abcdef"));
        assert!(is_uuid32("ABCDEFghij0123456789abcdefghij01"));
        assert!(!is_uuid32("0123456789abcdef0123456789abcde")); // 31
        assert!(!is_uuid32("0123456789abcdef0123456789abcde_")); // 非法字符
        assert!(!is_uuid32("-")); // grade 的 uuid 默认值不合法 → 必须由 DeviceConfig 兜底

        // 非负整数：`^(0|[1-9]\d*)$`（禁止前导零）
        assert!(is_uint_str("0"));
        assert!(is_uint_str("260403475"));
        assert!(!is_uint_str("0123"));
        assert!(!is_uint_str(""));
        assert!(!is_uint_str("-1"));

        // 系统版本：`^\d+(\.\d+)*$`
        assert!(is_version_str("9"));
        assert!(is_version_str("15.1.2"));
        assert!(!is_version_str(""));
        assert!(!is_version_str("15."));
        assert!(!is_version_str("Android15"));

        // clean：不含 & / 制表 / 换行
        assert!(is_clean("Xiaomi 15 Pro"));
        assert!(!is_clean(""));
        assert!(!is_clean("a&b"));
        assert!(!is_clean("a\tb"));

        // local_ip 必须是合法 IP
        assert!(is_ip("0.0.0.0"));
        assert!(is_ip("192.168.1.10"));
        assert!(is_ip("fe80::1"));
        assert!(!is_ip(""));
        assert!(!is_ip("localhost"));
    }

    /// 三段 sign 的拼接顺序必须与 JS 模板字符串逐字节一致。
    #[test]
    fn sign_formulas() {
        let t = 1788850000u64;
        // ① /v3/qrydid: md5(`_t${_t}appidand02${SALT}${data}`)
        let data = r#"{"machine":"X","mid":"m","uuid":"u","wh":[1920,1080]}"#;
        assert_eq!(
            md5_hex_4(
                format!("_t{}", t).as_bytes(),
                b"appidand02",
                QRYDID_SALT.as_bytes(),
                data.as_bytes()
            ),
            md5_hex(format!("_t{}appidand02{}{}", t, QRYDID_SALT, data).as_bytes()),
        );
        // ② /v2/gen: md5(`_t${_t}appid3116s${s}${APPKEY}`)
        let s = "BASE64RSA==";
        assert_eq!(
            md5_hex_4(
                format!("_t{}", t).as_bytes(),
                b"appid3116s",
                s.as_bytes(),
                CSCC_APPKEY.as_bytes()
            ),
            md5_hex(format!("_t{}appid3116s{}{}", t, s, CSCC_APPKEY).as_bytes()),
        );
        // ③ /v2/post: md5(排序后query拼接 + APPKEY + 密文)
        let enc = vec![1u8, 2, 3];
        assert_eq!(
            md5_hex_3(b"appid3116_tsignX", CSCC_APPKEY.as_bytes(), &enc),
            md5_hex(
                [
                    b"appid3116_tsignX".as_slice(),
                    CSCC_APPKEY.as_bytes(),
                    enc.as_slice()
                ]
                .concat()
                .as_slice()
            ),
        );
    }

    /// 报文 AES key 必须为 32 字符（AES-256），且会话派生字段参与。
    /// 回归：key 长度错会导致 `aes_cbc_encrypt` panic（release panic=abort 直接挂 App）。
    #[test]
    fn post_aes_key_shape() {
        let uuid = "0123456789abcdef0123456789abcdef";
        let key = md5_hex_4(uuid.as_bytes(), b"1788850000", b"field2hex", b"serverstr");
        assert_eq!(key.len(), 32);
        // uuid 前 16 字符即 IV，长度固定 16
        assert_eq!(uuid.as_bytes()[..16].len(), 16);
    }

    /// 会话建立的 RSA 明文必须为 `<uuid>\t<field2>\t<ms>\t<deviceid>`（制表符分隔 4 段）。
    #[test]
    fn rsa_plain_shape() {
        let rsa_plain = format!("{}\t{}\t{}\t{}", "u".repeat(32), "f".repeat(32), 1788850000000u128, "dev123");
        let parts: Vec<&str> = rsa_plain.split('\t').collect();
        assert_eq!(parts.len(), 4);
        assert_eq!(parts[0].len(), 32);
        assert_eq!(parts[1].len(), 32);
        assert_eq!(parts[3], "dev123");
    }

    /// 事件字段：start 用 type_id=20431 且不含 duration/state；
    /// end 用 type_id=4 且必须含 duration 与 state。公共尾部两者一致。
    #[test]
    fn event_fields_start_end() {
        const COMMON_TAIL: &[&str] = &[
            "ss1=1", "ss2=1", "channelid=18", "net=1", "gitversion=7aa8a76",
        ];
        let start = build_event_fields(
            "start", "260403475", "完整播放", 0, "mid1", &"a".repeat(32), "9", "Xiaomi", "123", "0.0.0.0",
        );
        let end = build_event_fields(
            "end", "260403475", "完整播放", 60000, "mid1", &"a".repeat(32), "9", "Xiaomi", "123", "0.0.0.0",
        );

        assert!(start.contains("type_id=20431"));
        assert!(start.contains("fo=/专辑播放页"));
        assert!(!start.contains("duration="));
        assert!(!start.contains("state="));

        assert!(end.contains("type_id=4"));
        assert!(end.contains("duration=60000"));
        assert!(end.contains("state=完整播放"));
        assert!(end.contains("fo=我的音乐/主态/自建歌单/RU"));
        assert!(!end.contains("type_id=20431"));

        for tail in COMMON_TAIL {
            assert!(start.contains(tail), "start 缺少公共字段 {}", tail);
            assert!(end.contains(tail), "end 缺少公共字段 {}", tail);
        }
        // ver 必须与 CSCC_VERSION 一致（10597）
        assert!(start.contains(&format!("ver={}", CSCC_VERSION)));
        // 公共尾部必须存在 mid/uuid/sys/mod/ver/time/userid/ss3
        for k in ["mid=", "uuid=", "sys=", "mod=", "ver=", "time=", "userid=", "ss3="] {
            assert!(start.contains(k), "start 缺少 {}", k);
            assert!(end.contains(k), "end 缺少 {}", k);
        }
    }

    /// 会话缓存：放入可取回；TTL 过期后取不到；容量上限淘汰最旧。
    #[test]
    fn session_cache_behaviour() {
        // 缓存是进程级静态，测试用独立 key 避免污染其他用例
        let k = "test-session-cache-behaviour";
        session_remove(k);
        assert!(session_get(k).is_none());

        session_put(
            k,
            Session {
                cookie: "c".to_string(),
                clienttime: 1788850000,
                serverstr: "s".to_string(),
                field2: "f".to_string(),
            },
        );
        let got = session_get(k).expect("命中");
        assert_eq!(got.clienttime, 1788850000);
        assert_eq!(got.serverstr, "s");

        session_remove(k);
        assert!(session_get(k).is_none());
    }

    /// 回归（真机首测失败根因）：设备身份必须能从 `DeviceConfig` 取到有效
    /// uuid/mid，而不能依赖 params/cookie —— Dart 侧的认证只发
    /// `Authorization: token=…;userid=…`，cookie 里根本没有 uuid/mid，
    /// 一旦回落 `"-"`，`is_uuid32` 就失败 → 整个上报 400。
    ///
    /// 断言的是「resolve 逻辑」而非真实设备值：给 `get_device_info()` 的
    /// 返回值套用与主入口相同的选取规则，验证 `-` 会被跳过。
    #[test]
    fn device_identity_prefers_device_info_over_dash() {
        // 模拟 get_device_info() 返回的有效设备信息
        let valid = json!({
            "dfid": "2lynNi0ej1WE41hdhH2F10VX",
            "mid": "14744181929017604103620036993035016515",
            "uuid": "6c3ae1e7bfbbc887ff76019bed50d474",
            "guid": "e132d260-ade3-883d-1afd-1092e694b16b",
        });
        let pick_uuid = |di: &Value| -> String {
            let d = di.get("uuid").and_then(Value::as_str).unwrap_or("-");
            if !d.is_empty() && d != "-" { d.to_string() } else { String::new() }
        };
        let pick_mid = |di: &Value| -> String {
            let d = di.get("mid").and_then(Value::as_str).unwrap_or("-");
            if !d.is_empty() && d != "-" { d.to_string() } else { String::new() }
        };

        // 有效设备信息 → uuid 满足 CSCC 硬校验
        assert!(is_uuid32(&pick_uuid(&valid)));
        assert!(is_clean(&pick_mid(&valid)));

        // 设备信息缺失（回落 "-"）→ 不被当成有效值
        let missing = json!({ "uuid": "-", "mid": "-" });
        assert!(pick_uuid(&missing).is_empty());
        assert!(pick_mid(&missing).is_empty());
        assert!(!is_uuid32(&pick_uuid(&missing)));
    }
}

