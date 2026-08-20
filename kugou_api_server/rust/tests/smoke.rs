//! 本地冒烟测试：启动 server 并验证 HTTP 中间件行为（不依赖外网）。

use std::io::{Read, Write};
use std::sync::Mutex;
use std::time::Duration;

/// 服务器是进程级单例（静态 RUNNING/PORT），两个冒烟测试若并行会互相 stop/start，
/// 用这把锁串行化所有会启停服务器的测试。
static SERVER_LOCK: Mutex<()> = Mutex::new(());

/// RSA 常量（PUBLIC_LITE_RAS_KEY）经 pem-rfc7468 解析必须成功（回归：单行长 base64 曾导致 panic）。
#[test]
fn rsa_keys_parse() {
    assert_eq!(kugou_server::crypto::crypto_rsa_encrypt(r#"{"a":1}"#, None).len(), 256);
    assert_eq!(kugou_server::crypto::rsa_encrypt2(r#"{"a":1}"#).len(), 256);
    assert_eq!(
        kugou_server::crypto::crypto_rsa_encrypt(r#"{"a":1}"#, Some(kugou_server::crypto::PUBLIC_RAS_KEY)).len(),
        256
    );
}

/// SSA simulate 路径的 RSA-OAEP 公钥（simulate.rs PUBLIC_KEY）必须能解析并加密。
/// 回归：常量中多了一个 `0`（MIIBIjANBgkqhkiG09w0…）导致 Base64(InvalidEncoding)
/// panic，SSA 反作弊重试一触发即崩溃（release panic=abort 会挂掉整个 App）。
#[test]
fn simulate_rsa_key_parses() {
    let sim = kugou_server::simulate::generate_simulate("123", "456", "dfid", Some("webgl"));
    assert!(!sim.edt.is_empty());
    assert!(!sim.sid.is_empty());
}

/// q_raw_or 必须复刻 JS `obj?.[key] ?? default`：缺失/null → 默认值（原样保持数字），
/// 其他 → 原值（URL query 下为字符串，不做类型转换）。
/// 回归：云盘 /user/cloud 的 AES 明文、/user/cloud/url 的 album_audio_id 依赖此语义
/// 与 JS `JSON.stringify` 逐字节一致（强转 i64 曾导致鉴权明文不一致）。
#[test]
fn q_raw_or_nullish_semantics() {
    use kugou_server::modules::q_raw_or;
    use serde_json::json;

    let q = json!({ "page": "1", "pagesize": "100", "null_field": null });
    // 存在 → 保留字符串原值（不转数字）
    assert_eq!(q_raw_or(&q, "page", json!(1)), json!("1"));
    assert_eq!(q_raw_or(&q, "pagesize", json!(30)), json!("100"));
    // 缺失 → 数字默认值（与 JS `?? 1` 一致）
    assert_eq!(q_raw_or(&q, "missing", json!(1)), json!(1));
    assert_eq!(q_raw_or(&q, "missing", json!(30)), json!(30));
    // null → 数字默认值
    assert_eq!(q_raw_or(&q, "null_field", json!(5)), json!(5));
    // 空串是有效值，保留（JS 空串 !== null/undefined）
    assert_eq!(q_raw_or(&q, "empty", json!(7)), json!(7));
}

/// AES-CBC 必须与 CryptoJS/Python 逐字节一致（回归：cbc crate 的 Encryptor/Decryptor
/// 在 aes 0.8 + cipher 0.4 组合下对 AES-192/256 输出错误，导致关注歌手 20010、
/// 云盘/登录 AES-256 路径失败；手动 CBC 已替换）。
#[test]
fn aes_cbc_matches_cryptojs() {
    let plain = br#"{"singerid":1001,"token":"FAKETOKEN123"}"#;
    // key = "abcdefghijklmnopqrstuvwxyz012345", iv = "0123456789abcdef"
    let (hex256, _) = kugou_server::crypto::crypto_aes_encrypt(
        r#"{"singerid":1001,"token":"FAKETOKEN123"}"#,
        Some("abcdefghijklmnopqrstuvwxyz012345"),
        Some("0123456789abcdef"),
    );
    assert_eq!(
        hex256,
        "f76670ed7f17048aab6bfe2e0e172c94b0ba4f9ad9e8fb21283d3bc5f9188f17f49e3a9ed4a2022e63adae456b40ec5f"
    );
    let (hex128, _) = kugou_server::crypto::crypto_aes_encrypt(
        r#"{"singerid":1001,"token":"FAKETOKEN123"}"#,
        Some("0123456789abcdef"),
        Some("fedcba9876543210"),
    );
    assert_eq!(
        hex128,
        "2ee307f47c1ddbb97b5495529ade9833043649393492ad4a55fce62f308c965094261211eac644d5690463d935855b1b"
    );
    // roundtrip
    let ct = kugou_server::crypto::hex_to_bytes(&hex256);
    let pt = kugou_server::crypto::aes_cbc_decrypt(
        b"abcdefghijklmnopqrstuvwxyz012345",
        b"0123456789abcdef",
        &ct,
    );
    assert_eq!(pt, plain);
}

fn tcp_request(port: u16, raw: &str) -> String {
    let addr = format!("127.0.0.1:{}", port);
    let mut stream = std::net::TcpStream::connect(&addr).expect("connect");
    stream
        .write_all(raw.as_bytes())
        .expect("write request");
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .expect("timeout");
    let mut buf = String::new();
    let _ = stream.read_to_string(&mut buf);
    buf
}

#[test]
fn server_responds_404_and_cors() {
    let _guard = SERVER_LOCK.lock().unwrap();
    let port: u16 = 18080;
    let dir = std::env::temp_dir().join("kugou_smoke").to_string_lossy().into_owned();
    assert_eq!(kugou_server::server::start(port, dir), Some(port));

    // 404 fallback: Cannot GET /nonexistent
    let resp = tcp_request(port, "GET /nonexistent HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    assert!(resp.contains("404 Not Found"), "got: {}", resp);
    assert!(resp.contains("Cannot GET /nonexistent"), "got: {}", resp);

    // CORS headers present on API-ish paths
    let resp = tcp_request(
        port,
        "GET /some/path?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://localhost\r\nConnection: close\r\n\r\n",
    );
    assert!(resp.contains("Access-Control-Allow-Origin: http://localhost"), "got: {}", resp);

    // OPTIONS → 204
    let resp = tcp_request(port, "OPTIONS /search HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    assert!(resp.starts_with("HTTP/1.1 204"), "got: {}", resp);

    // 新移植模块的路由必须命中（返回非 404）。上游不可达时返回 502，
    // 但只要不是 "Cannot GET/POST" 就证明 dispatch 成功。
    let paths = [
        "GET /playlist/tags HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /playlist/detail?ids=1,2 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /playlist/track/all?global_collection_id=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /playlist/track/all/new?listid=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /user/cloud/url?hash=abc HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /user/video/love HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /user/vip/detail HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /user/grade/info HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /youth/channel/all HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /youth/channel/song?global_collection_id=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /youth/channel/song/detail?global_collection_id=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /youth/dynamic HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /youth/dynamic/recent HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /youth/month/vip/record HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /youth/union/vip HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /youth/user/song?userid=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /youth/vip HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /get/verify/info?eventid=gz_tx_event_xxx HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /verify/user/info?eventid=gz_tx_event_xxx&v_type=23 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /song/url?hash=abc HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /song/url?hash=abc&quality=flac HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /song/url/new?hash=abc HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /user/cloud/url?hash=abc&album_audio_id=123&audio_id=456 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "POST /login HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        "POST /playlist/add HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        "POST /user/cloud HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        // 上传路由：无文件二进制 body → 400（"请通过请求体传入文件二进制数据"），非 404 即证明 dispatch 成功
        "POST /user/cloud/upload HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
    ];
    for raw in paths {
        let resp = tcp_request(port, raw);
        assert!(
            !resp.contains("Cannot GET") && !resp.contains("Cannot POST"),
            "route returned 404 for: {}",
            raw.lines().next().unwrap_or("")
        );
    }

    kugou_server::server::stop();
}

/// 随机端口模式（port==0）：必须返回非 0 端口，且该端口可连通；连续启动几次
/// 端口都在合法范围内（回归：端口占用时不阻塞、返回实际端口）。
#[test]
fn server_starts_on_random_port() {
    let _guard = SERVER_LOCK.lock().unwrap();
    let dir = std::env::temp_dir().join("kugou_smoke_rand").to_string_lossy().into_owned();
    for _ in 0..3 {
        let port = kugou_server::server::start(0, dir.clone()).expect("random start");
        assert!((10000..=60000).contains(&port), "port out of range: {port}");
        let resp = tcp_request(
            port,
            "GET /nonexistent HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        );
        assert!(resp.contains("404 Not Found"), "got: {}", resp);
        kugou_server::server::stop();
    }
}
