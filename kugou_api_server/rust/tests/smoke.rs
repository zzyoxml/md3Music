//! 本地冒烟测试：启动 server 并验证 HTTP 中间件行为（不依赖外网）。

use std::io::{Read, Write};
use std::time::Duration;

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
    let port: u16 = 18080;
    let dir = std::env::temp_dir().join("kugou_smoke").to_string_lossy().into_owned();
    assert!(kugou_server::server::start(port, dir));

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
        "GET /youth/channel/all HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /youth/channel/song?global_collection_id=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /youth/channel/song/detail?global_collection_id=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /youth/dynamic HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /youth/dynamic/recent HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /youth/month/vip/record HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /youth/union/vip HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /youth/user/song?userid=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /youth/vip HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /song/url?hash=abc HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /song/url/new?hash=abc HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "POST /login HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        "POST /playlist/add HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        "POST /user/cloud HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
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
