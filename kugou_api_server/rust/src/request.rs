use crate::cache::now_epoch_secs;
use crate::crypto::base64_encode;
use crate::helper;
use crate::simulate::generate_simulate;
use crate::util::{encode_uri_component, js_string, parse_cookie_string, to_number};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::io::Read;
use std::time::Duration;

pub const DEFAULT_UA: &str = "Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi";
pub const DEFAULT_BASE_URL: &str = "https://gateway.kugou.com";

/// Body sent upstream (equivalent of axios `data`).
#[derive(Debug, Clone)]
pub enum BodyData {
    None,
    Json(Value),
    String(String),
    Bytes(Vec<u8>),
}

impl BodyData {
    pub fn is_none(&self) -> bool {
        matches!(self, BodyData::None)
    }
    /// sigData: Buffer stays raw bytes; object -> JSON string; string -> itself; none -> "".
    pub fn sig_data(&self) -> (Vec<u8>, bool) {
        match self {
            BodyData::Bytes(b) => (b.clone(), true),
            BodyData::Json(v) => (crate::util::json_stringify(v).into_bytes(), false),
            BodyData::String(s) => (s.clone().into_bytes(), false),
            BodyData::None => (Vec::new(), false),
        }
    }
}

/// Module response body. Bytes preserve raw arraybuffer responses so modules can
/// call `.to_base64()` (JS `res.body.toString('base64')`) before decrypting.
///
/// Stream 供云盘上传等长耗时端点边执行边回传进度（NDJSON 行流）：
/// 仅 `server.rs::respond_module` 消费（不缓冲、不进 apicache），
/// `to_json`/`to_bytes` 等缓冲方法对它一律返回空值。
pub enum BodyValue {
    Json(Value),
    Bytes(Vec<u8>),
    Stream(Box<dyn Read + Send>),
}

impl std::fmt::Debug for BodyValue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BodyValue::Json(v) => write!(f, "Json({v})"),
            BodyValue::Bytes(b) => write!(f, "Bytes({} bytes)", b.len()),
            BodyValue::Stream(_) => write!(f, "Stream(<reader>)"),
        }
    }
}

impl BodyValue {
    pub fn from_bytes(buf: &[u8]) -> Self {
        let text = String::from_utf8_lossy(buf).into_owned();
        match serde_json::from_str::<Value>(&text) {
            Ok(v) => BodyValue::Json(v),
            Err(_) => BodyValue::Bytes(buf.to_vec()),
        }
    }

    pub fn to_json(&self) -> Value {
        match self {
            BodyValue::Json(v) => v.clone(),
            BodyValue::Bytes(b) => {
                let text = String::from_utf8_lossy(b).into_owned();
                serde_json::from_str(&text).unwrap_or(Value::String(text))
            }
            // 流式体不缓冲；只有 respond_module 消费它，不会走到这些方法。
            BodyValue::Stream(_) => Value::Null,
        }
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        match self {
            BodyValue::Json(v) => crate::util::json_stringify(v).into_bytes(),
            BodyValue::Bytes(b) => b.clone(),
            BodyValue::Stream(_) => Vec::new(),
        }
    }

    pub fn to_string_utf8(&self) -> String {
        match self {
            BodyValue::Json(v) => crate::util::json_stringify(v),
            BodyValue::Bytes(b) => String::from_utf8_lossy(b).into_owned(),
            BodyValue::Stream(_) => String::new(),
        }
    }

    pub fn to_base64(&self) -> String {
        match self {
            BodyValue::Json(_) => base64_encode(&self.to_bytes()),
            BodyValue::Bytes(b) => base64_encode(b),
            BodyValue::Stream(_) => String::new(),
        }
    }

    pub fn set_json(&mut self, v: Value) {
        *self = BodyValue::Json(v);
    }

    pub fn as_mut_json(&mut self) -> Option<&mut Value> {
        match self {
            BodyValue::Json(v) => Some(v),
            BodyValue::Bytes(_) | BodyValue::Stream(_) => None,
        }
    }
}

#[derive(Debug)]
pub struct ModuleResponse {
    pub status: u16,
    pub body: BodyValue,
    pub cookie: Vec<String>,
    pub headers: HashMap<String, String>,
}

#[derive(Debug, Clone)]
pub struct RequestOptions {
    pub method: String,
    pub url: String,
    pub base_url: Option<String>,
    pub params: Value,
    pub data: BodyData,
    pub headers: HashMap<String, String>,
    pub encrypt_type: Option<String>,
    pub cookie: Value,
    pub encrypt_key: bool,
    pub clear_default_params: bool,
    pub not_signature: bool,
    pub not_sign: bool,
    pub ip: String,
    pub real_ip: String,
    pub response_type: Option<String>,
    /// 使用标准版(非概念版)签名盐。刷刷(brush) feed 接口 appid=1005 需要标准盐。
    pub standard_signature: bool,
    /// 小-MSS 传输开关：Some(字节数) 时本次请求走 mss_http 自管 TCP+TLS
    /// （钳制出站段大小 + 头/体分 record + fresh 连接 + 确定性超时），
    /// 用于黑名单等大上行端点在 PMTU 黑洞网络下的挂死规避。见 mss_http 模块注释。
    pub mss_clamp: Option<u32>,
    /// 请求级上游超时（秒）。None 时使用全局 20s 默认；
    /// 对偶发无响应的上游（如 /user/grade/info）单独收紧，避免客户端已放弃而服务器继续空转。
    pub timeout_secs: Option<u64>,
}

impl RequestOptions {
    pub fn new(url: &str) -> Self {
        RequestOptions {
            method: "GET".to_string(),
            url: url.to_string(),
            base_url: None,
            params: json!({}),
            data: BodyData::None,
            headers: HashMap::new(),
            encrypt_type: None,
            cookie: json!({}),
            encrypt_key: false,
            clear_default_params: false,
            not_signature: false,
            not_sign: false,
            ip: String::new(),
            real_ip: String::new(),
            response_type: None,
            standard_signature: false,
            timeout_secs: None,
            mss_clamp: None,
        }
    }

    pub fn get(mut self, url: &str) -> Self {
        self.method = "GET".to_string();
        self.url = url.to_string();
        self
    }

    pub fn post(mut self, url: &str) -> Self {
        self.method = "POST".to_string();
        self.url = url.to_string();
        self
    }

    pub fn params(mut self, v: Value) -> Self {
        self.params = v;
        self
    }

    pub fn base_url(mut self, v: &str) -> Self {
        self.base_url = Some(v.to_string());
        self
    }

    pub fn header(mut self, k: &str, v: &str) -> Self {
        self.headers.insert(k.to_string(), v.to_string());
        self
    }

    pub fn cookie(mut self, v: Value) -> Self {
        self.cookie = v;
        self
    }

    pub fn encrypt_type(mut self, v: &str) -> Self {
        self.encrypt_type = Some(v.to_string());
        self
    }

    pub fn encrypt_key(mut self, v: bool) -> Self {
        self.encrypt_key = v;
        self
    }

    pub fn clear_default_params(mut self, v: bool) -> Self {
        self.clear_default_params = v;
        self
    }

    pub fn not_signature(mut self, v: bool) -> Self {
        self.not_signature = v;
        self
    }

    pub fn not_sign(mut self, v: bool) -> Self {
        self.not_sign = v;
        self
    }

    pub fn ip(mut self, v: &str) -> Self {
        self.ip = v.to_string();
        self
    }

    pub fn response_type(mut self, v: &str) -> Self {
        self.response_type = Some(v.to_string());
        self
    }

    pub fn standard_signature(mut self, v: bool) -> Self {
        self.standard_signature = v;
        self
    }

    /// 启用小-MSS 传输并钳制出站 TCP 段大小（字节）。见 mss_http 模块注释。
    pub fn mss_clamp(mut self, v: u32) -> Self {
        self.mss_clamp = Some(v);
        self
    }

    pub fn timeout_secs(mut self, v: u64) -> Self {
        self.timeout_secs = Some(v);
        self
    }

    pub fn json_body(mut self, v: Value) -> Self {
        self.data = BodyData::Json(v);
        self
    }

    pub fn string_body(mut self, v: String) -> Self {
        self.data = BodyData::String(v);
        self
    }

    pub fn bytes_body(mut self, v: Vec<u8>) -> Self {
        self.data = BodyData::Bytes(v);
        self
    }
}

/// cookie helper accessors (JS `options?.cookie?.x || default` semantics).
pub fn cookie_val(cookie: &Value, key: &str, default: &str) -> String {
    match cookie.get(key) {
        Some(Value::String(s)) if !s.is_empty() => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => default.to_string(),
    }
}

/// insert header into a map, replacing an existing case-insensitive duplicate
/// (matches axios's case-insensitive header handling where later wins).
fn insert_ci(map: &mut HashMap<String, String>, key: &str, value: &str) {
    map.retain(|k, _| !k.eq_ignore_ascii_case(key));
    map.insert(key.to_string(), value.to_string());
}

/// axios default paramsSerializer.
pub fn serialize_params(params: &Value) -> String {
    let mut parts: Vec<String> = Vec::new();
    if let Some(map) = params.as_object() {
        for (key, val) in map {
            if val.is_null() {
                continue;
            }
            if let Some(arr) = val.as_array() {
                let k = format!("{}[]", key);
                for v in arr {
                    parts.push(format!("{}={}", encode_uri_component(&k), encode_query_value(v)));
                }
            } else {
                parts.push(format!(
                    "{}={}",
                    encode_uri_component(key),
                    encode_query_value(val)
                ));
            }
        }
    }
    parts.join("&")
}

fn encode_query_value(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::Bool(b) => encode_uri_component(&b.to_string()),
        Value::Number(n) => encode_uri_component(&n.to_string()),
        Value::String(s) => encode_uri_component(s),
        Value::Object(_) | Value::Array(_) => encode_uri_component(&crate::util::json_stringify(v)),
    }
}

fn agent() -> ureq::Agent {
    static AGENT: std::sync::OnceLock<ureq::Agent> = std::sync::OnceLock::new();
    AGENT
        .get_or_init(|| {
            ureq::AgentBuilder::new()
                .timeout(Duration::from_secs(20))
                .build()
        })
        .clone()
}

struct RawResponse {
    cookies: Vec<String>,
    ssa_code: Option<String>,
    body: Vec<u8>,
}

/// 只有完整读完上游响应才返回body；读取中断不能被误当成成功响应。
fn read_response_body(mut reader: impl Read) -> Result<Vec<u8>, String> {
    let mut body = Vec::new();
    reader
        .read_to_end(&mut body)
        .map_err(|error| format!("response body read failed: {error}"))?;
    Ok(body)
}

fn response_body_value(response_type: Option<&str>, body: &[u8]) -> BodyValue {
    if is_arraybuffer_response(response_type) {
        BodyValue::Bytes(body.to_vec())
    } else {
        BodyValue::from_bytes(body)
    }
}

fn is_arraybuffer_response(response_type: Option<&str>) -> bool {
    response_type.is_some_and(|value| value.eq_ignore_ascii_case("arraybuffer"))
}

fn response_is_error(response_type: Option<&str>, body: &BodyValue) -> bool {
    !is_arraybuffer_response(response_type) && body_is_error(body)
}

/// Low-level HTTP send replicating axios behavior for our purposes.
fn do_send(opts: &RequestOptions, params: &Value, final_headers: &HashMap<String, String>, extra: &HashMap<String, String>) -> Result<RawResponse, String> {
    let base_url = opts.base_url.clone().unwrap_or_else(|| DEFAULT_BASE_URL.to_string());
    // axios combineURLs semantics: absolute url wins; otherwise baseURL + path
    // (joins with a single '/', tolerating urls without a leading slash).
    let mut url = if opts.url.starts_with("http://") || opts.url.starts_with("https://") {
        opts.url.clone()
    } else {
        let base = base_url.trim_end_matches('/');
        let path = if opts.url.starts_with('/') {
            opts.url.clone()
        } else {
            format!("/{}", opts.url)
        };
        format!("{}{}", base, path)
    };

    if base_url.contains("openapicdn") {
        let qs: String = params
            .as_object()
            .map(|m| {
                m.iter()
                    .map(|(k, v)| format!("{}={}", k, crate::util::js_string(Some(v))))
                    .collect::<Vec<_>>()
                    .join("&")
            })
            .unwrap_or_default();
        url = format!("{}?{}", url, qs);
    } else {
        let qs = serialize_params(params);
        if !qs.is_empty() {
            if url.contains('?') {
                url = format!("{}&{}", url, qs);
            } else {
                url = format!("{}?{}", url, qs);
            }
        }
    }

    // 小-MSS 传输分支（黑名单等大上行端点 opt-in）：签名/头/SSA 重试逻辑
    // 全部复用本管线，仅替换 socket/TLS 层。见 mss_http 模块注释。
    if let Some(mss) = opts.mss_clamp {
        let content_type: Option<String> = final_headers
            .iter()
            .chain(extra.iter())
            .find(|(k, _)| k.eq_ignore_ascii_case("content-type"))
            .map(|(_, v)| v.clone());
        let hdrs: Vec<(String, String)> = final_headers
            .iter()
            .chain(extra.iter())
            .filter(|(k, _)| !k.eq_ignore_ascii_case("content-type"))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        return mss_transport_send(opts, &url, hdrs, content_type, mss);
    }

    // 统一使用全局 Agent（连接池共享，keep-alive/TLS 会话跨请求复用）；
    // 请求级超时仅在本次请求生效（ureq 2.x Request::timeout）。
    let mut req = agent().request(&opts.method, &url);
    if let Some(secs) = opts.timeout_secs {
        req = req.timeout(Duration::from_secs(secs));
    }
    let mut content_type: Option<String> = None;
    for (k, v) in final_headers {
        if k.eq_ignore_ascii_case("content-type") {
            content_type = Some(v.clone());
            continue;
        }
        req = req.set(k, v);
    }
    for (k, v) in extra {
        if k.eq_ignore_ascii_case("content-type") {
            content_type = Some(v.clone());
            continue;
        }
        req = req.set(k, v);
    }

    let resp = match &opts.data {
        BodyData::None => req.call(),
        BodyData::Json(v) => {
            let ct = content_type.unwrap_or_else(|| "application/json;charset=utf-8".to_string());
            req = req.set("Content-Type", ct.as_str());
            req.send_string(&crate::util::json_stringify(v))
        }
        BodyData::String(s) => {
            if let Some(ct) = &content_type {
                req = req.set("Content-Type", ct);
            }
            req.send_string(s)
        }
        BodyData::Bytes(b) => {
            if let Some(ct) = &content_type {
                req = req.set("Content-Type", ct);
            }
            req.send_bytes(b)
        }
    };

    let resp = match resp {
        Ok(r) => r,
        Err(e) => return Err(format!("{}", e)),
    };

    let status = resp.status();
    let mut cookies = Vec::new();
    for hv in resp.all("set-cookie") {
        cookies.push(parse_cookie_string(hv));
    }
    let ssa_code = resp.header("ssa-code").map(|s| s.to_string());

    if !(200..300).contains(&status) {
        return Err(format!("status {}", status));
    }

    let body = read_response_body(resp.into_reader())?;

    Ok(RawResponse {
        cookies,
        ssa_code,
        body,
    })
}

/// 小-MSS 传输（黑名单等 mss_clamp 端点专用，见 mss_http 模块注释）：
/// 请求体序列化与 ureq 路径同源（Json → json_stringify），响应映射回
/// RawResponse 后走与 ureq 完全相同的 SSA 重试/响应塑形管线。
fn mss_transport_send(
    opts: &RequestOptions,
    url: &str,
    mut hdrs: Vec<(String, String)>,
    content_type: Option<String>,
    mss: u32,
) -> Result<RawResponse, String> {
    let body: Option<String> = match &opts.data {
        BodyData::None => None,
        BodyData::Json(v) => Some(crate::util::json_stringify(v)),
        BodyData::String(s) => Some(s.clone()),
        BodyData::Bytes(_) => {
            return Err("mss transport: binary body not supported".to_string());
        }
    };
    if let Some(ct) = content_type {
        hdrs.push(("Content-Type".to_string(), ct));
    }
    let resp = crate::mss_http::https_send(
        &opts.method,
        url,
        &hdrs,
        body.as_deref(),
        mss,
    )?;
    if !(200..300).contains(&resp.status) {
        return Err(format!("status {}", resp.status));
    }
    Ok(RawResponse {
        cookies: resp
            .set_cookies
            .iter()
            .map(|c| parse_cookie_string(c))
            .collect(),
        ssa_code: resp
            .headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case("ssa-code"))
            .map(|(_, v)| v.clone()),
        body: resp.body,
    })
}

/// createRequest(options) equivalent. Returns Ok(answer) on success or a
/// rejected answer (status 502) replicating the JS promise rejection.
pub fn create_request(opts: &RequestOptions) -> Result<ModuleResponse, ModuleResponse> {
    let dfid = cookie_val(&opts.cookie, "dfid", "-");
    let mid = match opts.cookie.get("KUGOU_API_MID") {
        Some(v) => js_string(Some(v)),
        None => "-".to_string(),
    };
    let token = cookie_val(&opts.cookie, "token", "");
    let userid = to_number(opts.cookie.get("userid"));
    let clienttime = now_epoch_secs() as i64;
    let ip = if !opts.real_ip.is_empty() {
        opts.real_ip.clone()
    } else {
        opts.ip.clone()
    };

    let cookie_str = match opts.cookie.as_object() {
        Some(m) => m
            .iter()
            .filter(|(k, v)| !k.is_empty() && !v.is_null())
            .map(|(k, v)| format!("{}={}", k, crate::util::js_string(Some(v))))
            .collect::<Vec<_>>()
            .join("; "),
        None => String::new(),
    };

    let mut base_headers: HashMap<String, String> = HashMap::new();
    base_headers.insert("dfid".to_string(), dfid.clone());
    base_headers.insert("clienttime".to_string(), clienttime.to_string());
    base_headers.insert("mid".to_string(), mid.clone());
    base_headers.insert("kg-rc".to_string(), "1".to_string());
    base_headers.insert("kg-thash".to_string(), "5d816a0".to_string());
    base_headers.insert("kg-rec".to_string(), "1".to_string());
    base_headers.insert("kg-rf".to_string(), "B9EDA08A64250DEFFBCADDEE00F8F25F".to_string());
    if !cookie_str.is_empty() {
        base_headers.insert("Cookie".to_string(), cookie_str);
    }
    if !ip.is_empty() {
        base_headers.insert("X-Real-IP".to_string(), ip.clone());
        base_headers.insert("X-Forwarded-For".to_string(), ip.clone());
    }

    let mut params_map: Map<String, Value> = Map::new();
    if !opts.clear_default_params {
        params_map.insert("dfid".to_string(), json!(dfid));
        params_map.insert("mid".to_string(), json!(mid));
        params_map.insert("uuid".to_string(), json!("-"));
        // 标准盐(standard_signature)必须配 appid=1005/clientver=20789：
        // 概念版 3116/11440 会让上游把长音频章节的 fail_process 归 0，
        // 导致详情页付费章节过滤失效（免费章节 0、付费章节 32 全部被当免费）。
        params_map.insert(
            "appid".to_string(),
            json!(if opts.standard_signature { 1005 } else { 3116 }),
        );
        params_map.insert(
            "clientver".to_string(),
            json!(if opts.standard_signature { 20789 } else { 11440 }),
        );
        params_map.insert("clienttime".to_string(), json!(clienttime));
        if !token.is_empty() {
            params_map.insert("token".to_string(), json!(token));
        }
        if userid != 0 {
            params_map.insert("userid".to_string(), json!(userid));
        }
    }
    if let Some(om) = opts.params.as_object() {
        for (k, v) in om {
            params_map.insert(k.clone(), v.clone());
        }
    }
    let mut params = Value::Object(params_map);

    let clienttime_param = params
        .get("clienttime")
        .map(|v| v.to_string())
        .unwrap_or_default();
    base_headers.insert("clienttime".to_string(), clienttime_param.clone());

    if opts.encrypt_key {
        let hash = js_string(params.get("hash"));
        let p_mid = js_string(params.get("mid"));
        let p_uid = js_string(params.get("userid"));
        let p_appid = js_string(params.get("appid"));
        let key = helper::sign_key(&hash, &p_mid, &p_uid, &p_appid);
        params
            .as_object_mut()
            .unwrap()
            .insert("key".to_string(), json!(key));
    }

    let has_signature = match params.get("signature") {
        Some(Value::String(s)) => !s.is_empty(),
        Some(_) => true,
        None => false,
    };
    if !has_signature && !opts.not_signature && !opts.not_sign {
        let (sig_data, is_buffer) = opts.data.sig_data();
        let sig = match opts.encrypt_type.as_deref() {
            Some("register") => helper::signature_register_params(&params),
            Some("web") => helper::signature_web_params(&params),
            _ => {
                if opts.standard_signature {
                    helper::signature_android_params_standard(&params, &sig_data, is_buffer)
                } else {
                    helper::signature_android_params(&params, &sig_data, is_buffer)
                }
            }
        };
        params
            .as_object_mut()
            .unwrap()
            .insert("signature".to_string(), json!(sig));
    }

    // final upstream headers
    let mut final_headers: HashMap<String, String> = HashMap::new();
    final_headers.insert("User-Agent".to_string(), DEFAULT_UA.to_string());
    for (k, v) in &opts.headers {
        insert_ci(&mut final_headers, k, v);
    }
    final_headers.insert("dfid".to_string(), dfid.clone());
    final_headers.insert("clienttime".to_string(), clienttime_param.clone());
    final_headers.insert("mid".to_string(), mid.clone());
    for (k, v) in &base_headers {
        insert_ci(&mut final_headers, k, v);
    }

    let webgl_hash = match opts.cookie.get("KUGOU_API_WEBGL") {
        Some(Value::String(s)) if !s.is_empty() => Some(s.clone()),
        _ => None,
    };

    let mut extra: HashMap<String, String> = HashMap::new();
    let mut ssa_code: Option<String>;

    // First attempt (+ possible SSA retry), replicating request.js.
    let raw = match do_send(opts, &params, &final_headers, &extra) {
        Ok(r) => r,
        // 携带具体错误原因（DNS/TLS/连接等），便于定位 transport 失败。
        Err(e) => return Err(transport_error_with(e.to_string())),
    };

    let mut body = response_body_value(opts.response_type.as_deref(), &raw.body);
    let mut cookies = raw.cookies;
    ssa_code = raw.ssa_code;
    let is_error = response_is_error(opts.response_type.as_deref(), &body);

    if is_error && ssa_code.is_some() {
        let sim = generate_simulate(&mid, &userid.to_string(), &dfid, webgl_hash.as_deref());
        extra.insert("edt".to_string(), sim.edt);
        extra.insert("sid".to_string(), sim.sid);
        match do_send(opts, &params, &final_headers, &extra) {
            Ok(r) => {
                body = response_body_value(opts.response_type.as_deref(), &r.body);
                cookies = r.cookies;
                ssa_code = r.ssa_code;
            }
            Err(_) => return Err(transport_error()),
        }
    }

    let mut answer = ModuleResponse {
        status: 200,
        body,
        cookie: cookies,
        headers: HashMap::new(),
    };
    if let Some(code) = &ssa_code {
        answer
            .headers
            .insert("ssa-code".to_string(), code.clone());
    }

    if response_is_error(opts.response_type.as_deref(), &answer.body) {
        if answer.body.to_json().get("status").and_then(|v| v.as_i64()) == Some(2) {
            answer.status = 200;
            Ok(answer)
        } else {
            answer.status = 502;
            if ssa_code.is_some() {
                let sim = generate_simulate(&mid, &userid.to_string(), &dfid, webgl_hash.as_deref());
                if let Some(obj) = answer.body.as_mut_json() {
                    if let Some(m) = obj.as_object_mut() {
                        m.insert("edt".to_string(), json!(sim.edt));
                        m.insert("sid".to_string(), json!(sim.sid));
                        m.insert("ssaCode".to_string(), json!(ssa_code.clone().unwrap_or_default()));
                    }
                }
            }
            Err(answer)
        }
    } else {
        Ok(answer)
    }
}

fn transport_error() -> ModuleResponse {
    ModuleResponse {
        status: 502,
        body: BodyValue::Json(json!({ "status": 0, "msg": json!({}) })),
        cookie: Vec::new(),
        headers: HashMap::new(),
    }
}

fn body_is_error(body: &BodyValue) -> bool {
    let j = body.to_json();
    match j.get("status") {
        Some(Value::Number(n)) => {
            if n.as_i64() == Some(0) {
                return true;
            }
        }
        _ => {}
    }
    match j.get("error_code") {
        Some(Value::Number(n)) => n.as_i64() != Some(0),
        _ => false,
    }
}

/// 一次原始上游交互的完整结果。
///
/// 与 [ModuleResponse] 的区别：`raw_get`/`raw_request` 只把 body 交给模块，
/// Set-Cookie 与「跟随重定向之后的最终 URL」都被丢弃。QQ 扫码登录这两项都要
/// （xlogin / ptqrshow 的会话 cookie、扫码成功后 proxy.htm 跳转里的
/// openid+access_token），故单独给出可捕获结构。
pub struct RawCapture {
    pub status: u16,
    pub body: Vec<u8>,
    /// **原始** `Set-Cookie` 头值（未裁剪）。需要 `k=v` 的调用方用
    /// [cookie_pairs]；`raw_get`/`raw_request` 的老语义由 [Self::to_response]
    /// 用 `parse_cookie_string` 还原。
    pub cookies: Vec<String>,
    /// ureq 跟随重定向后的最终地址；不跟随重定向时即请求地址。
    pub final_url: String,
    /// 仅不跟随重定向时有值（3xx 的 Location 头原样）。
    pub location: Option<String>,
}

/// JS `c.split(';')[0]` 的 Set-Cookie → `(name, value)`（首个 `=` 切分）。
pub fn cookie_pairs(raw: &[String]) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for c in raw {
        let kv = c.split(';').next().unwrap_or("");
        if let Some(idx) = kv.find('=') {
            if idx > 0 {
                out.push((kv[..idx].to_string(), kv[idx + 1..].to_string()));
            }
        }
    }
    out
}

impl RawCapture {
    pub fn body_text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }

    pub fn to_response(self) -> ModuleResponse {
        // 与改造前 raw_get / raw_request 完全一致：body 透传，cookie 丢弃
        // （既有调用方如 lyric / dycover / user 都不读响应 cookie）。
        ModuleResponse {
            status: self.status,
            body: BodyValue::from_bytes(&self.body),
            cookie: Vec::new(),
            headers: HashMap::new(),
        }
    }
}

/// 不跟随重定向的 agent（QQ 扫码的 proxy.htm 跳转必须手工走：
/// ureq 在重定向时会剥掉 Cookie 头，而 QQ 的跳转依赖会话 cookie）。
fn agent_no_redirect() -> ureq::Agent {
    static AGENT: std::sync::OnceLock<ureq::Agent> = std::sync::OnceLock::new();
    AGENT
        .get_or_init(|| {
            ureq::AgentBuilder::new()
                .timeout(Duration::from_secs(20))
                .redirects(0)
                .build()
        })
        .clone()
}

fn raw_fetch_inner(
    method: &str,
    url: &str,
    params: &Value,
    data: BodyData,
    headers: &HashMap<String, String>,
    follow_redirects: bool,
) -> Result<RawCapture, ModuleResponse> {
    let mut full = url.to_string();
    let qs = serialize_params(params);
    if !qs.is_empty() {
        if full.contains('?') {
            full = format!("{}&{}", full, qs);
        } else {
            full = format!("{}?{}", full, qs);
        }
    }
    let client = if follow_redirects { agent() } else { agent_no_redirect() };
    let mut req = client.request(method, &full);
    for (k, v) in headers {
        req = req.set(k, v);
    }
    let resp = match &data {
        BodyData::None => {
            // 对齐 axios 行为：POST 无 body 时也发送 Content-Length: 0。
            // ureq 对空 body 的 POST 默认不带 Content-Length，
            // 部分上游（如云盘上传 bssulbig 的 multipart/complete）会因此返回 411 Length Required。
            if method.eq_ignore_ascii_case("POST") {
                req = req.set("Content-Length", "0");
            }
            req.call()
        }
        BodyData::Json(v) => {
            let body = crate::util::json_stringify(v);
            req = req.set("Content-Type", "application/json;charset=utf-8");
            req.send_string(&body)
        }
        BodyData::String(s) => {
            if let Some((_, ct)) = headers
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case("content-type"))
            {
                req = req.set("Content-Type", ct);
            }
            req.send_string(s)
        }
        BodyData::Bytes(b) => {
            if let Some((_, ct)) = headers
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case("content-type"))
            {
                req = req.set("Content-Type", ct);
            }
            req.send_bytes(b)
        }
    };
    let resp = match resp {
        Ok(r) => r,
        Err(e) => return Err(transport_error_with(e.to_string())),
    };
    let status = resp.status();
    let final_url = resp.get_url().to_string();
    let location = resp.header("location").map(|s| s.to_string());
    let cookies: Vec<String> = resp
        .all("set-cookie")
        .into_iter()
        .map(crate::util::parse_cookie_string)
        .collect();
    let body = match read_response_body(resp.into_reader()) {
        Ok(body) => body,
        Err(error) => return Err(transport_error_with(error)),
    };
    Ok(RawCapture {
        status,
        body,
        cookies,
        final_url,
        location,
    })
}

/// 原始 HTTP 交互，保留 Set-Cookie 与最终 URL；3xx 自动跟随（ureq 默认）。
pub fn raw_fetch(
    method: &str,
    url: &str,
    params: &Value,
    data: BodyData,
    headers: &HashMap<String, String>,
) -> Result<RawCapture, ModuleResponse> {
    raw_fetch_inner(method, url, params, data, headers, true)
}

/// 原始 HTTP 交互但**不跟随重定向**（`location` 由调用方手工处理）。
pub fn raw_fetch_no_redirect(
    method: &str,
    url: &str,
    params: &Value,
    data: BodyData,
    headers: &HashMap<String, String>,
) -> Result<RawCapture, ModuleResponse> {
    raw_fetch_inner(method, url, params, data, headers, false)
}

/// Direct raw HTTP GET (replicating lyric.js which calls `axios` directly,
/// bypassing the signing machinery). params are serialized like axios default.
pub fn raw_get(url: &str, params: &Value) -> Result<ModuleResponse, ModuleResponse> {
    raw_fetch("GET", url, params, BodyData::None, &HashMap::new()).map(|r| r.to_response())
}

/// Direct raw HTTP request with method + params + optional body + headers,
/// replicating bare `axios({...})` calls (wechat modules). No signing.
pub fn raw_request(
    method: &str,
    url: &str,
    params: &Value,
    data: BodyData,
    headers: &HashMap<String, String>,
) -> Result<ModuleResponse, ModuleResponse> {
    raw_fetch(method, url, params, data, headers).map(|r| r.to_response())
}

fn transport_error_with(msg: String) -> ModuleResponse {
    ModuleResponse {
        status: 502,
        body: BodyValue::Json(json!({ "status": 0, "msg": msg })),
        cookie: Vec::new(),
        headers: HashMap::new(),
    }
}

/// 打开一个**不缓冲**的上游响应，交给调用方流式转发。
///
/// 与 `raw_get` / `raw_request` 的区别：这里不 `read_to_end`，避免 10MB 级
/// 媒体在内存里驻留（上游缓冲 + tiny_http 响应体各一份）。
/// 返回 `(状态码, Content-Length, Content-Type, reader)`。
pub fn open_stream(
    url: &str,
) -> Result<(u16, Option<u64>, String, Box<dyn Read + Send + Sync + 'static>), String> {
    let resp = agent().get(url).call().map_err(|e| e.to_string())?;
    let status = resp.status();
    if !(200..300).contains(&status) {
        return Err(format!("status {}", status));
    }
    let len = resp
        .header("Content-Length")
        .and_then(|s| s.trim().parse::<u64>().ok());
    let ct = resp
        .header("Content-Type")
        .unwrap_or("video/mp4")
        .to_string();
    Ok((status, len, ct, resp.into_reader()))
}

#[cfg(test)]
mod response_body_tests {
    use super::{
        create_request, read_response_body, response_body_value, response_is_error, BodyValue,
        RequestOptions,
    };
    use std::io::{self, Read};

    struct PartialThenError {
        sent: bool,
    }

    impl Read for PartialThenError {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            if self.sent {
                return Err(io::Error::new(
                    io::ErrorKind::ConnectionReset,
                    "injected upstream read failure",
                ));
            }
            self.sent = true;
            buf[..7].copy_from_slice(b"partial");
            Ok(7)
        }
    }

    #[test]
    fn rejects_partial_body_when_upstream_read_fails() {
        let result = read_response_body(PartialThenError { sent: false });

        let error = result.expect_err("incomplete response must not be accepted");
        assert!(error.contains("response body read failed"));
        assert!(error.contains("injected upstream read failure"));
    }

    #[test]
    fn preserves_complete_binary_body() {
        let expected = [0, 0xff, 0x10, 0x80];

        assert_eq!(read_response_body(expected.as_slice()).unwrap(), expected);
    }

    #[test]
    fn arraybuffer_keeps_json_looking_bytes_unchanged() {
        let body = br#"{"encrypted":"payload"}"#;

        assert!(matches!(
            response_body_value(Some("arraybuffer"), body),
            BodyValue::Bytes(bytes) if bytes == body
        ));
        assert!(matches!(
            response_body_value(None, body),
            BodyValue::Json(_)
        ));

        let error_like_body = br#"{"status":0,"msg":"encrypted bytes"}"#;
        let arraybuffer = response_body_value(Some("arraybuffer"), error_like_body);
        let json = response_body_value(None, error_like_body);
        assert!(!response_is_error(Some("arraybuffer"), &arraybuffer));
        assert!(response_is_error(None, &json));
    }

    fn serve_one_response(body: Vec<u8>) -> (String, std::thread::JoinHandle<()>) {
        let server = tiny_http::Server::http(("127.0.0.1", 0)).unwrap();
        let address = server.server_addr().to_ip().unwrap();
        let task = std::thread::spawn(move || {
            let request = server.recv().expect("request should reach local fixture");
            request
                .respond(tiny_http::Response::from_data(body))
                .expect("fixture response should be sent");
        });
        (format!("http://{address}"), task)
    }

    fn local_request_options(base_url: &str) -> RequestOptions {
        RequestOptions::new("/response-test")
            .base_url(base_url)
            .get("/response-test")
            .clear_default_params(true)
            .not_signature(true)
    }

    #[test]
    fn create_request_keeps_arraybuffer_json_bytes_out_of_error_classifier() {
        let body = br#"{"status":0,"msg":"opaque payload"}"#.to_vec();
        let (base_url, task) = serve_one_response(body.clone());
        let options = local_request_options(&base_url).response_type("arraybuffer");

        let response = create_request(&options).expect("arraybuffer response should succeed");
        task.join().unwrap();

        assert_eq!(response.status, 200);
        assert!(matches!(response.body, BodyValue::Bytes(bytes) if bytes == body));
    }

    #[test]
    fn create_request_keeps_default_json_error_mapping() {
        let body = br#"{"status":0,"msg":"upstream error"}"#.to_vec();
        let (base_url, task) = serve_one_response(body);

        let error = create_request(&local_request_options(&base_url))
            .expect_err("default JSON error response should be rejected");
        task.join().unwrap();

        assert_eq!(error.status, 502);
    }
}
