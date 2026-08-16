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
#[derive(Debug, Clone)]
pub enum BodyValue {
    Json(Value),
    Bytes(Vec<u8>),
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
        }
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        match self {
            BodyValue::Json(v) => crate::util::json_stringify(v).into_bytes(),
            BodyValue::Bytes(b) => b.clone(),
        }
    }

    pub fn to_string_utf8(&self) -> String {
        match self {
            BodyValue::Json(v) => crate::util::json_stringify(v),
            BodyValue::Bytes(b) => String::from_utf8_lossy(b).into_owned(),
        }
    }

    pub fn to_base64(&self) -> String {
        match self {
            BodyValue::Json(_) => base64_encode(&self.to_bytes()),
            BodyValue::Bytes(b) => base64_encode(b),
        }
    }

    pub fn set_json(&mut self, v: Value) {
        *self = BodyValue::Json(v);
    }

    pub fn as_mut_json(&mut self) -> Option<&mut Value> {
        match self {
            BodyValue::Json(v) => Some(v),
            BodyValue::Bytes(_) => None,
        }
    }
}

#[derive(Debug, Clone)]
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

    let mut req = agent().request(&opts.method, &url);
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

    let mut body = Vec::new();
    let mut reader = resp.into_reader();
    let _ = reader.read_to_end(&mut body);

    Ok(RawResponse {
        cookies,
        ssa_code,
        body,
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
        params_map.insert("appid".to_string(), json!(3116));
        params_map.insert("clientver".to_string(), json!(11440));
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

    let mut body = BodyValue::from_bytes(&raw.body);
    let mut cookies = raw.cookies;
    ssa_code = raw.ssa_code;
    let is_error = body_is_error(&body);

    if is_error && ssa_code.is_some() {
        let sim = generate_simulate(&mid, &userid.to_string(), &dfid, webgl_hash.as_deref());
        extra.insert("edt".to_string(), sim.edt);
        extra.insert("sid".to_string(), sim.sid);
        match do_send(opts, &params, &final_headers, &extra) {
            Ok(r) => {
                body = BodyValue::from_bytes(&r.body);
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

    if body_is_error(&answer.body) {
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

/// Direct raw HTTP GET (replicating lyric.js which calls `axios` directly,
/// bypassing the signing machinery). params are serialized like axios default.
pub fn raw_get(url: &str, params: &Value) -> Result<ModuleResponse, ModuleResponse> {
    let mut full = url.to_string();
    let qs = serialize_params(params);
    if !qs.is_empty() {
        if full.contains('?') {
            full = format!("{}&{}", full, qs);
        } else {
            full = format!("{}?{}", full, qs);
        }
    }
    let resp = match agent().get(&full).call() {
        Ok(r) => r,
        Err(e) => return Err(transport_error_with(e.to_string())),
    };
    let status = resp.status();
    let mut body = Vec::new();
    let mut reader = resp.into_reader();
    let _ = reader.read_to_end(&mut body);
    Ok(ModuleResponse {
        status,
        body: BodyValue::from_bytes(&body),
        cookie: Vec::new(),
        headers: HashMap::new(),
    })
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
    let mut full = url.to_string();
    let qs = serialize_params(params);
    if !qs.is_empty() {
        if full.contains('?') {
            full = format!("{}&{}", full, qs);
        } else {
            full = format!("{}?{}", full, qs);
        }
    }
    let mut req = agent().request(method, &full);
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
    let mut body = Vec::new();
    let mut reader = resp.into_reader();
    let _ = reader.read_to_end(&mut body);
    Ok(ModuleResponse {
        status,
        body: BodyValue::from_bytes(&body),
        cookie: Vec::new(),
        headers: HashMap::new(),
    })
}

fn transport_error_with(msg: String) -> ModuleResponse {
    ModuleResponse {
        status: 502,
        body: BodyValue::Json(json!({ "status": 0, "msg": msg })),
        cookie: Vec::new(),
        headers: HashMap::new(),
    }
}
