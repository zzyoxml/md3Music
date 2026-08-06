//! HTTP server replicating `server.js` + `util/apicache.js` middleware chain.
//!
//! Middleware order (matching Express):
//!  1. CORS (+ OPTIONS 204)
//!  2. cookie parse + platform-cookie injection
//!  3. body parse (json / urlencoded / octet-stream)
//!  4. apicache (2 minutes, only status 200 cached)
//!  5. module route dispatch

use crate::cache::{CacheEntry, CACHE};
use crate::crypto::crypto_md5_str;
use crate::device::DeviceConfig;
use crate::modules::{Ctx, ModuleFn};
use crate::request::{BodyValue, ModuleResponse};
use crate::util::{
    calculate_mid, get_guid, json_stringify, percent_decode_preserve_plus, random_string,
};
use serde_json::{json, Map, Value};
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tiny_http::{Header, Method, Request, Response, Server};

/// apicache '2 minutes' = 120000 ms.
const CACHE_DURATION: f64 = 120.0;
const CACHE_DURATION_MS: u64 = 120_000;

static RUNNING: AtomicBool = AtomicBool::new(false);
static PORT: AtomicU16 = AtomicU16::new(0);

/// data_dir（持久化 device_info.json），start() 时写入。
static DATA_DIR: OnceLock<String> = OnceLock::new();

/// P0: 路由表全局缓存。原先每个请求都重新 `register` 165+ 次 push，
/// 改为启动后构建一次，全请求共享（路由是静态注册，不会变化）。
static ROUTES: OnceLock<Vec<(&'static str, ModuleFn)>> = OnceLock::new();

fn routes() -> &'static Vec<(&'static str, ModuleFn)> {
    ROUTES.get_or_init(|| {
        let mut routes: Vec<(&'static str, ModuleFn)> = Vec::new();
        crate::modules::register(&mut routes);
        routes
    })
}

/// guid = cryptoMd5(getGuid()) (server.js module-level const).
fn session_guid() -> &'static str {
    static G: OnceLock<String> = OnceLock::new();
    G.get_or_init(|| crypto_md5_str(&get_guid()))
}

/// mid = calculateMid(process.env.KUGOU_API_GUID ?? guid); env not set → guid.
fn session_mid() -> &'static str {
    static M: OnceLock<String> = OnceLock::new();
    M.get_or_init(|| calculate_mid(session_guid()))
}

/// serverDev = randomString(10).toUpperCase().
fn session_dev() -> &'static str {
    static D: OnceLock<String> = OnceLock::new();
    D.get_or_init(|| random_string(10).to_uppercase())
}

/// Start the HTTP server on 127.0.0.1.
///
/// - `port == 0`：随机挑选 [10000, 60000] 内的端口（避开系统保留端口与常用
///   服务端口）。若被占用则等待 1s 换下一个，最多尝试 10 次。
/// - `port != 0`：固定端口，单次尝试（失败立即返回 None）。
///
/// 返回 Some(实际端口) 表示启动成功（或已在运行），None 表示失败。
pub fn start(port: u16, data_dir: String) -> Option<u16> {
    if RUNNING.load(Ordering::SeqCst) {
        return Some(PORT.load(Ordering::SeqCst));
    }
    let _ = DATA_DIR.set(data_dir.clone());
    let _ = DeviceConfig::instance().load_cached(&data_dir);

    let max_attempts: u32 = if port == 0 { 10 } else { 1 };
    let mut attempts: u32 = 0;
    let (server, chosen) = loop {
        let candidate = if port == 0 { random_port() } else { port };
        match Server::http(("127.0.0.1", candidate)) {
            Ok(s) => break (s, candidate),
            Err(_) => {
                attempts += 1;
                if attempts >= max_attempts {
                    return None;
                }
                std::thread::sleep(Duration::from_secs(1));
            }
        }
    };

    PORT.store(chosen, Ordering::SeqCst);
    RUNNING.store(true, Ordering::SeqCst);
    std::thread::spawn(move || run_loop(server, data_dir));
    Some(chosen)
}

/// 随机端口，范围 [10000, 60000]，避开系统保留端口（<1024）与常见开发服务端口。
fn random_port() -> u16 {
    10000 + (rand::random::<u32>() % 50_001) as u16
}

pub fn stop() {
    RUNNING.store(false, Ordering::SeqCst);
    PORT.store(0, Ordering::SeqCst);
}

pub fn is_running() -> bool {
    RUNNING.load(Ordering::SeqCst)
}

pub fn get_port() -> u16 {
    PORT.load(Ordering::SeqCst)
}

fn run_loop(server: Server, data_dir: String) {
    while RUNNING.load(Ordering::SeqCst) {
        match server.recv_timeout(Duration::from_millis(500)) {
            Ok(Some(request)) => {
                // 每个请求独立线程处理：云盘上传等耗时请求（分片串行可达数十秒）
                // 不再阻塞其他请求（如列表刷新、搜索），避免串行排队造成"卡住"。
                // 全局状态（CACHE/DeviceConfig/session 常量）均持锁或 OnceLock，并发安全。
                // P0: 减小线程栈（默认 2MB → 256KB），100 并发从 ~200MB 降到 ~25MB。
                let dd = data_dir.clone();
                if let Err(e) = std::thread::Builder::new()
                    .name("req".into())
                    .stack_size(256 * 1024)
                    .spawn(move || {
                        if let Err(e) = handle_request(request, &dd) {
                            eprintln!("[server] handler error: {}", e);
                        }
                    })
                {
                    eprintln!("[server] spawn handler thread failed: {}", e);
                }
            }
            Ok(None) => {}
            Err(_) => {
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }
}

struct Req {
    /// originalUrl = path + query.
    original_url: String,
    headers: std::collections::HashMap<String, String>,
    body: Vec<u8>,
}

fn handle_request(mut request: Request, _data_dir: &str) -> Result<(), String> {
    let method = request.method().clone();
    let url = request.url().to_string();
    let (path, _query_part) = match url.find('?') {
        Some(i) => (url[..i].to_string(), url[i + 1..].to_string()),
        None => (url.clone(), String::new()),
    };

    let mut headers: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    for h in request.headers() {
        let k = h.field.as_str().to_string().to_ascii_lowercase();
        let v = h.value.as_str().to_string();
        headers.entry(k).or_insert(v);
    }

    // ---- CORS middleware ----
    let cors_target = path != "/" && !path.contains('.');
    let mut cors_headers: Vec<(String, String)> = Vec::new();
    if cors_target {
        let origin = headers
            .get("origin")
            .cloned()
            .unwrap_or_else(|| "*".to_string());
        cors_headers.push(("Access-Control-Allow-Credentials".into(), "true".into()));
        cors_headers.push(("Access-Control-Allow-Origin".into(), origin));
        cors_headers.push((
            "Access-Control-Allow-Headers".into(),
            "Authorization,X-Requested-With,Content-Type,Cache-Control".into(),
        ));
        cors_headers.push((
            "Access-Control-Allow-Methods".into(),
            "PUT,POST,GET,DELETE,OPTIONS".into(),
        ));
        cors_headers.push(("Content-Type".into(), "application/json; charset=utf-8".into()));
    }
    if method == Method::Options {
        let mut resp = Response::empty(204);
        for (k, v) in &cors_headers {
            resp = resp.with_header(make_header(k, v)?);
        }
        request.respond(resp).map_err(|e| e.to_string())?;
        return Ok(());
    }

    // ---- audio proxy disabled (safety) ----
    if url.starts_with("/audio/proxy") {
        let body = json_stringify(&json!({
            "error": "Audio proxy is disabled. Use the URL from /song/url directly.",
            "reason": "Server traffic limit exceeded. Clients must play audio directly from CDN.",
        }));
        let mut resp = Response::from_data(body.into_bytes()).with_status_code(403);
        for (k, v) in &cors_headers {
            resp = resp.with_header(make_header(k, v)?);
        }
        request.respond(resp).map_err(|e| e.to_string())?;
        return Ok(());
    }

    // ---- body parse ----
    let mut body_bytes: Vec<u8> = Vec::new();
    {
        let reader = request.as_reader();
        let _ = reader.read_to_end(&mut body_bytes);
    }
    let ct = headers
        .get("content-type")
        .cloned()
        .unwrap_or_default()
        .to_ascii_lowercase();
    let body_value: Option<Value> = if ct.contains("application/json") {
        match parse_json_body(&body_bytes) {
            Ok(v) => Some(v),
            Err(e) => {
                let mut resp = Response::from_data(e.into_bytes()).with_status_code(400);
                resp = resp.with_header(
                    make_header("Content-Type", "text/plain; charset=utf-8").unwrap(),
                );
                for (k, v) in &cors_headers {
                    resp = resp.with_header(make_header(k, v)?);
                }
                request.respond(resp).map_err(|e| e.to_string())?;
                return Ok(());
            }
        }
    } else if ct.contains("application/x-www-form-urlencoded") {
        Some(parse_qs_body(&body_bytes))
    } else {
        None
    };
    let body_is_buffer = ct.contains("application/octet-stream");

    // ---- apicache: check hit before dispatching ----
    let hostname = headers
        .get("host")
        .map(|h| h.split(':').next().unwrap_or(h).to_string())
        .unwrap_or_else(|| "127.0.0.1".to_string());
    let cache_key = format!("{}{}", hostname, url);
    let bypass = headers.get("x-apicache-bypass").is_some()
        || headers.get("x-apicache-force-fetch").is_some();

    if !bypass {
        if let Some(entry) = CACHE.get_or_init(crate::cache::Cache::new).get(&cache_key) {
            let remaining = (CACHE_DURATION - (crate::cache::now_epoch_secs() - entry.timestamp))
                .max(0.0);
            let cache_control = format!("max-age={:.0}", remaining);
            let mut resp = Response::from_data(entry.data).with_status_code(entry.status);
            for (k, v) in &cors_headers {
                resp = resp.with_header(make_header(k, v)?);
            }
            for (k, v) in &entry.headers {
                if k.eq_ignore_ascii_case("cache-control") {
                    continue;
                }
                resp = resp.with_header(make_header(k, v)?);
            }
            resp = resp.with_header(make_header("cache-control", &cache_control)?);
            request.respond(resp).map_err(|e| e.to_string())?;
            return Ok(());
        }
    }

    // ---- cookie parse (Express middleware) ----
    let mut cookies: Map<String, Value> = Map::new();
    if let Some(cookie_header) = headers.get("cookie") {
        parse_express_cookies(cookie_header, &mut cookies);
    }

    // platform-cookie injection
    let cookie_suffix = "; PATH=/";
    let mut set_cookies: Vec<String> = Vec::new();
    ensure_cookie(
        &mut cookies,
        "KUGOU_API_PLATFORM",
        "undefined",
        cookie_suffix,
        &mut set_cookies,
    );
    ensure_cookie(
        &mut cookies,
        "KUGOU_API_MID",
        session_mid(),
        cookie_suffix,
        &mut set_cookies,
    );
    ensure_cookie(
        &mut cookies,
        "KUGOU_API_GUID",
        session_guid(),
        cookie_suffix,
        &mut set_cookies,
    );
    ensure_cookie(
        &mut cookies,
        "KUGOU_API_DEV",
        &session_dev().to_uppercase(),
        cookie_suffix,
        &mut set_cookies,
    );
    ensure_cookie(
        &mut cookies,
        "KUGOU_API_MAC",
        "02:00:00:00:00:00",
        cookie_suffix,
        &mut set_cookies,
    );

    // ---- build query object ----
    let req = Req {
        original_url: url.clone(),
        headers,
        body: body_bytes,
    };

    let query = build_query(&req, &cookies, &body_value, body_is_buffer);
    let no_cookie = query_truthy(&query, "noCookie");

    // ---- module dispatch ----
    // P0: 复用全局缓存的路由表（OnceLock 启动时构建一次），避免每请求重建 165+ 项
    for (route, module_fn) in routes() {
        if prefix_match(route, &path) {
            let ctx = Ctx {
                ip: String::new(),
                body_bytes: if body_is_buffer { req.body.clone().into() } else { None },
            };
            let result = module_fn(&query, &ctx);
            return respond_module(request, result, &cors_headers, &mut set_cookies, no_cookie, &cache_key, bypass, *route == "/register/dev");
        }
    }

    // 404 fallback (Express default "Cannot GET /path")
    let body = format!("Cannot {} {}", method_name(&method), path);
    let mut resp = Response::from_data(body.into_bytes()).with_status_code(404);
    resp = resp.with_header(make_header("Content-Type", "text/html; charset=utf-8")?);
    for (k, v) in &cors_headers {
        resp = resp.with_header(make_header(k, v)?);
    }
    request.respond(resp).map_err(|e| e.to_string())?;
    Ok(())
}

fn respond_module(
    request: Request,
    result: Result<ModuleResponse, ModuleResponse>,
    cors_headers: &[(String, String)],
    set_cookies: &mut Vec<String>,
    no_cookie: bool,
    cache_key: &str,
    bypass: bool,
    is_register_dev: bool,
) -> Result<(), String> {
    let mr = result.unwrap_or_else(|e| e);
    let status = mr.status;

    if is_register_dev && status == 200 {
        persist_registered_device(&mr.body);
    }

    let mut headers: Vec<(String, String)> = Vec::new();
    for (k, v) in cors_headers {
        headers.push((k.clone(), v.clone()));
    }
    for c in set_cookies.iter() {
        headers.push(("Set-Cookie".to_string(), c.clone()));
    }
    if !no_cookie {
        for c in &mr.cookie {
            headers.push(("Set-Cookie".to_string(), format!("{}; PATH=/", c)));
        }
    }
    for (k, v) in &mr.headers {
        headers.push((k.clone(), v.clone()));
    }

    if status == 200 {
        headers.push(("cache-control".to_string(), "max-age=120".to_string()));
    } else {
        headers.push((
            "cache-control".to_string(),
            "no-cache, no-store, must-revalidate".to_string(),
        ));
    }

    let body = mr.body.to_bytes();

    if status == 200 && !bypass {
        let entry = CacheEntry {
            status,
            headers: headers.clone(),
            data: body.clone(),
            timestamp: crate::cache::now_epoch_secs(),
            expire: Instant::now() + Duration::from_millis(CACHE_DURATION_MS),
        };
        CACHE.get_or_init(crate::cache::Cache::new).put(cache_key.to_string(), entry);
    }

    let mut resp = Response::from_data(body).with_status_code(status);
    for (k, v) in &headers {
        resp = resp.with_header(make_header(k, v)?);
    }
    request.respond(resp).map_err(|e| e.to_string())
}

fn make_header(k: &str, v: &str) -> Result<Header, String> {
    Header::from_bytes(k.as_bytes(), v.as_bytes()).map_err(|_| format!("bad header {}:{}", k, v))
}

/// /register/dev 成功后（status==1），把 dfid/mid 写入 DeviceConfig 并持久化
/// device_info.json（等价 server.js registerDeviceAndGetDfid）。
fn persist_registered_device(body: &BodyValue) {
    let j = body.to_json();
    if j.get("status").and_then(Value::as_i64) != Some(1) {
        return;
    }
    let data = j.get("data");
    let dfid = data
        .and_then(|d| d.get("dfid"))
        .and_then(Value::as_str)
        .unwrap_or("");
    if dfid.is_empty() {
        return;
    }
    let mid = data.and_then(|d| d.get("mid")).and_then(Value::as_str);
    let dev = DeviceConfig::instance();
    dev.set_dfid(dfid);
    if let Some(m) = mid {
        if !m.is_empty() {
            dev.set_mid(m);
        }
    }
    if let Some(dir) = DATA_DIR.get() {
        dev.save(dir, dfid, mid);
    }
}

/// Express `app.use('/route')` prefix matching: path == route or path starts with route + '/'.
fn prefix_match(route: &str, path: &str) -> bool {
    if path == route {
        return true;
    }
    path.len() > route.len()
        && path.starts_with(route)
        && path.as_bytes().get(route.len()) == Some(&b'/')
}

fn method_name(m: &Method) -> &str {
    match m {
        Method::Get => "GET",
        Method::Post => "POST",
        Method::Put => "PUT",
        Method::Delete => "DELETE",
        Method::Head => "HEAD",
        Method::Options => "OPTIONS",
        Method::Patch => "PATCH",
        _ => "GET",
    }
}

fn query_truthy(q: &Value, key: &str) -> bool {
    match q.get(key) {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(Value::String(s)) => !s.is_empty(),
        Some(_) => true,
    }
}

/// Express cookie parser middleware: split on ';', first '=', decode, trim.
fn parse_express_cookies(cookie: &str, out: &mut Map<String, Value>) {
    for pair in cookie.split(';') {
        let pair = pair.trim();
        if pair.is_empty() {
            continue;
        }
        if let Some(crack) = pair.find('=') {
            if crack < 1 || crack == pair.len() - 1 {
                continue;
            }
            let key = percent_decode_preserve_plus(&pair[..crack]).trim().to_string();
            let val = percent_decode_preserve_plus(&pair[crack + 1..]).trim().to_string();
            out.insert(key, json!(val));
        }
    }
}

fn ensure_cookie(
    cookies: &mut Map<String, Value>,
    key: &str,
    value: &str,
    suffix: &str,
    out: &mut Vec<String>,
) {
    if !cookies.contains_key(key) {
        cookies.insert(key.to_string(), json!(value));
        out.push(format!("{}={}{}", key, value, suffix));
    }
}

/// util/util.js cookieToJson: split ';', each part split('='), obj[arr[0]] = arr[1].
fn cookie_to_json(s: &str) -> Value {
    let mut obj = Map::new();
    for part in s.split(';') {
        let mut arr = part.splitn(2, '=');
        let k = arr.next().unwrap_or("").trim();
        let v = arr.next().unwrap_or("");
        obj.insert(k.to_string(), json!(v));
    }
    Value::Object(obj)
}

/// qs-style query parse (Express default 'extended'). Handles flat keys,
/// `cookie[...]` nesting and repeated keys → arrays.
fn parse_query(s: &str) -> Value {
    let mut root = Map::new();
    for pair in s.split('&') {
        if pair.is_empty() {
            continue;
        }
        let (raw_key, raw_val) = match pair.split_once('=') {
            Some((k, v)) => (k, v),
            None => (pair, ""),
        };
        let val = percent_decode_preserve_plus(raw_val);
        if raw_key.ends_with(']') {
            // cookie[token] / cookie[] / cookie[token][x]
            let open = raw_key.find('[');
            if let Some(open) = open {
                let base = &raw_key[..open];
                let base = percent_decode_preserve_plus(base);
                let inner = &raw_key[open..];
                let mut target = root
                    .get(&base)
                    .cloned()
                    .unwrap_or_else(|| json!({}));
                insert_nested(&mut target, inner, &val);
                root.insert(base, target);
                continue;
            }
        }
        let key = percent_decode_preserve_plus(raw_key);
        insert_flat(&mut root, key, json!(val));
    }
    Value::Object(root)
}

fn insert_nested(target: &mut Value, path: &str, val: &str) {
    // path like "[token]" or "[]" or "[token][x]"
    let trimmed = path
        .strip_prefix('[')
        .and_then(|s| s.strip_suffix(']'))
        .unwrap_or(path);
    if trimmed.is_empty() {
        // [] → append to array
        let arr = target.as_array_mut();
        match arr {
            Some(a) => a.push(json!(val)),
            None => {
                *target = json!([val]);
            }
        }
        return;
    }
    let obj = target.as_object_mut();
    match obj {
        Some(m) => {
            if let Some(existing) = m.get_mut(trimmed) {
                match existing {
                    Value::String(_) | Value::Number(_) | Value::Bool(_) => {
                        m.insert(trimmed.to_string(), json!(val));
                    }
                    _ => {
                        m.insert(trimmed.to_string(), json!(val));
                    }
                }
            } else {
                m.insert(trimmed.to_string(), json!(val));
            }
        }
        None => {
            let mut m = Map::new();
            m.insert(trimmed.to_string(), json!(val));
            *target = Value::Object(m);
        }
    }
}

fn insert_flat(root: &mut Map<String, Value>, key: String, val: Value) {
    match root.get(&key) {
        Some(Value::Array(a)) => {
            let mut a = a.clone();
            a.push(val);
            root.insert(key, Value::Array(a));
        }
        Some(_) => {
            let prev = root.get(&key).cloned().unwrap_or(Value::Null);
            root.insert(key, Value::Array(vec![prev, val]));
        }
        None => {
            root.insert(key, val);
        }
    }
}

fn parse_json_body(body: &[u8]) -> Result<Value, String> {
    let text = String::from_utf8_lossy(body);
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_str::<Value>(trimmed).map_err(|e| format!("{}", e))
}

fn parse_qs_body(body: &[u8]) -> Value {
    let text = String::from_utf8_lossy(body);
    parse_query(&text)
}

/// Build the merged `query` object (server.js Step 2-4).
fn build_query(
    req: &Req,
    cookies: &Map<String, Value>,
    body_value: &Option<Value>,
    body_is_buffer: bool,
) -> Value {
    let (_, query_part) = match req.original_url.find('?') {
        Some(i) => (&req.original_url[..i], &req.original_url[i + 1..]),
        None => (&req.original_url[..], ""),
    };
    let mut req_query = parse_query(query_part);

    // cookieToJson(decode(item.cookie)) for query and body string cookies
    if let Some(obj) = req_query.as_object_mut() {
        if let Some(Value::String(cs)) = obj.get("cookie").cloned() {
            let decoded = percent_decode_preserve_plus(&cs);
            obj.insert("cookie".to_string(), cookie_to_json(&decoded));
        }
    }
    let mut body_query = body_value.clone();
    if let Some(Value::Object(obj)) = body_query.as_mut() {
        if let Some(Value::String(cs)) = obj.get("cookie").cloned() {
            let decoded = percent_decode_preserve_plus(&cs);
            obj.insert("cookie".to_string(), cookie_to_json(&decoded));
        }
    }

    // merged cookie = Object.assign({}, req.cookies, cookieParam)
    let mut merged: Map<String, Value> = cookies.clone();
    if let Some(Value::Object(param)) = req_query.get("cookie") {
        for (k, v) in param {
            merged.insert(k.clone(), v.clone());
        }
    }

    let mut query = Map::new();
    query.insert("cookie".to_string(), Value::Object(merged));

    if let Some(params) = req_query.as_object() {
        for (k, v) in params {
            if k == "cookie" {
                continue;
            }
            query.insert(k.clone(), v.clone());
        }
    }

    if !body_is_buffer {
        if let Some(bv) = body_value {
            query.insert("body".to_string(), bv.clone());
        }
    }

    // Authorization → cookie merge
    if let Some(auth) = req.headers.get("authorization") {
        let auth_cookie = cookie_to_json(auth);
        if let Some(ac) = auth_cookie.as_object() {
            let mut cookie = query.get("cookie").cloned().unwrap_or_else(|| json!({}));
            if let Some(cm) = cookie.as_object_mut() {
                for (k, v) in ac {
                    cm.insert(k.clone(), v.clone());
                }
            }
            query.insert("cookie".to_string(), cookie);
        }
    }

    Value::Object(query)
}
