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

/// 请求级超时：`timeout_secs` 必须被正确记录（默认 None，设置后 Some(secs)）。
/// 回归：/user/grade/info 依赖此字段把上游超时从全局 20s 收紧到 8s，
/// 先于客户端 dio 15s 放弃，避免「客户端已超时、服务器继续空转」的空耗。
#[test]
fn request_options_timeout_secs() {
    use kugou_server::request::RequestOptions;
    let default = RequestOptions::new("/v2/get_grade_info");
    assert_eq!(default.timeout_secs, None);
    let tightened = RequestOptions::new("/v2/get_grade_info").timeout_secs(8);
    assert_eq!(tightened.timeout_secs, Some(8));
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
        "GET /effects/brand HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /effects/brand/detail?brand_id=55 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /effects/match HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /effects/artist HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /song/url?hash=abc HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /song/url?hash=abc&quality=flac HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /song/url/new?hash=abc HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /user/cloud/url?hash=abc&album_audio_id=123&audio_id=456 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "POST /login HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        "POST /playlist/add HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        // 评论写接口：content 为空 → 400（不发上游请求）。非 404 即证明 dispatch 成功。
        "POST /comment/music/send HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        "POST /comment/floor/send HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        "POST /comment/playlist/send HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        "POST /comment/album/send HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        "POST /user/cloud HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        // 上传路由：无文件二进制 body → 400（"请通过请求体传入文件二进制数据"），非 404 即证明 dispatch 成功
        "POST /user/cloud/upload HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        // 专辑动态封面：元数据路由必须命中（上游可达时 200，不可达时 502，均非 404）
        "GET /album/dycover?album_audio_id=468087825&album_id=65482908 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    ];
    for raw in paths {
        let resp = tcp_request(port, raw);
        assert!(
            !resp.contains("Cannot GET") && !resp.contains("Cannot POST"),
            "route returned 404 for: {}",
            raw.lines().next().unwrap_or("")
        );
    }

    // 评论写接口必须真正命中本地 handler（空 content → 400 "content 不能为空"），
    // 而不是被更短的 /comment/floor|playlist|album|music 前缀抢先当成查询接口转发到上游。
    // 上面那条「非 404」断言抓不到这种抢前缀：转发到上游同样不是 404（是 502 或超时）。
    for route in ["music", "floor", "playlist", "album"] {
        let raw = format!(
            "POST /comment/{}/send HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{{}}",
            route
        );
        let resp = tcp_request(port, &raw);
        assert!(
            resp.contains("400 Bad Request") && resp.contains("content 不能为空"),
            "POST /comment/{}/send 未命中本地写接口 handler（疑似被短前缀路由抢先）:\n{}",
            route,
            resp
        );
    }

    kugou_server::server::stop();
}

/// 动态封面媒体代理：缺 album_audio_id → 400；上游不可达/无动态封面 → 502。
/// 两种都必须命中路由（非 404），证明特判分支已生效。
#[test]
fn dycover_media_proxy_validation() {
    let _guard = SERVER_LOCK.lock().unwrap();
    let port: u16 = 18082;
    let dir = std::env::temp_dir().join("kugou_smoke_media").to_string_lossy().into_owned();
    assert_eq!(kugou_server::server::start(port, dir), Some(port));

    // 缺参 → 400，且 body 是 JSON（不是 HTML 404 页）
    let resp = tcp_request(
        port,
        "GET /album/dycover/media HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    );
    assert!(resp.contains("400 Bad Request"), "got: {}", resp);
    assert!(!resp.contains("Cannot GET"), "got: {}", resp);
    assert!(resp.contains("album_audio_id"), "got: {}", resp);

    // 无效 id → 502（上游无对应动态封面），仍非 404
    let resp = tcp_request(
        port,
        "GET /album/dycover/media?album_audio_id=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    );
    assert!(
        !resp.contains("Cannot GET") && !resp.contains("400 Bad Request"),
        "got: {}",
        resp
    );

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

/// /song/url/new 的音质挑选。上游请求体不带 quality，所以响应里的 url 有两种语义：
/// 多链接（与 qualities 一一对应）→ 按请求档位下标取；单链接（只给最高可用音质）
/// → 只能由码率反推。两种情况都必须把**真实**音质写回 data.quality。
/// 回归：Dart 侧曾把请求值当成实际音质，导致没有 Hi-Res 音源时 UI 仍显示 Hi-Res。
#[test]
fn song_url_new_picks_actual_quality() {
    use kugou_server::modules::song_url_new::apply_quality;
    use serde_json::json;

    // 多链接且目标档位可用 → 取该档位，音质即请求值
    let mut data = json!({
        "url": ["u128", "u320", "uflac", "uhigh", "", "", "", "", ""],
        "bitRate": 4608,
    });
    apply_quality(&mut data, "high");
    assert_eq!(data["url"], json!("uhigh"));
    assert_eq!(data["quality"], json!("high"));

    // 多链接但目标档位为空 → 往下退到第一个非空，音质由码率反推（不能虚标 high）
    let mut data = json!({
        "url": ["u128", "u320", "", "", "", "", "", "", ""],
        "bitRate": 320,
    });
    apply_quality(&mut data, "high");
    assert_eq!(data["url"], json!("u320"));
    assert_eq!(data["quality"], json!("320"));

    // 单链接 → 由码率反推。优先 fileSize/timeLength 反算（单位恒为 bps），
    // 样本取自真机实测：上游静默降质时会给出远小于请求音质的文件。
    // ≈1663kbps 的 flac → Hi-Res
    let mut data = json!({
        "url": ["uflac"],
        "fileSize": 37219528,
        "timeLength": 179,
        "extName": "flac",
    });
    apply_quality(&mut data, "high");
    assert_eq!(data["quality"], json!("high"));

    // ≈98kbps 的 ogg → 标准（请求 high 时不能虚标）
    let mut data = json!({
        "url": ["uogg"],
        "fileSize": 3194531,
        "timeLength": 259,
        "extName": "ogg",
    });
    apply_quality(&mut data, "high");
    assert_eq!(data["quality"], json!("128"));

    // ≈667kbps 的 flac → 无损
    let mut data = json!({
        "url": ["uflac"],
        "fileSize": 20000000,
        "timeLength": 240,
        "extName": "flac",
    });
    apply_quality(&mut data, "high");
    assert_eq!(data["quality"], json!("flac"));

    // 320kbps 的 mp3 → 高音质（有损容器不参与无损档位判定）
    let mut data = json!({
        "url": ["u320"],
        "fileSize": 9600000,
        "timeLength": 240,
        "extName": "mp3",
    });
    apply_quality(&mut data, "high");
    assert_eq!(data["quality"], json!("320"));

    // 没有时长时退回 bitRate 字段：bps 口径
    let mut data = json!({ "url": ["uflac"], "bitRate": 1411000 });
    apply_quality(&mut data, "high");
    assert_eq!(data["quality"], json!("flac"));

    // 没有时长时退回 bitRate 字段：kbps 口径
    let mut data = json!({ "url": ["u128"], "bitRate": 128 });
    apply_quality(&mut data, "flac");
    assert_eq!(data["quality"], json!("128"));

    // 没有 url 字段 → 不改写响应
    let mut data = json!({ "priv_status": 0 });
    apply_quality(&mut data, "high");
    assert_eq!(data.get("quality"), None);
}

/// 请求层端到端回归：预置 device_info.json 后起真实服务器，请求 /register/dev
/// 应**命中幂等短路面**——直接返回缓存的 dfid，且不透传到真实上游（无网络）。
/// 同时注入的 KUGOU_API_GUID cookie 必须是持久化的那个 guid（不是每次随机）。
/// 这正是"不再一启动就刷一台新设备"的可执行证明。
#[test]
fn register_dev_reuses_persisted_identity_without_upstream() {
    let _guard = SERVER_LOCK.lock().unwrap();
    let port: u16 = 18081;
    let dir_path = std::env::temp_dir().join("kugou_smoke_dev").to_string_lossy().into_owned();
    let file = format!("{}/device_info.json", dir_path);
    let _ = std::fs::remove_file(&file);
    std::fs::create_dir_all(&dir_path).unwrap();

    // 预置一份"上次会话"的设备指纹（模拟残留的持久化状态）。
    let seeded_guid = "aaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
    let seeded_dfid = "TESTDFID1234567890";
    let seeded = format!(
        r#"{{"dfid":"{}","guid":"{}","serverDev":"ABCDEFGHIJ","mac":"02:00:00:00:00:00"}}"#,
        seeded_dfid, seeded_guid
    );
    std::fs::write(&file, seeded).unwrap();

    assert_eq!(kugou_server::server::start(port, dir_path), Some(port));

    let resp = tcp_request(
        port,
        "GET /register/dev HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    );

    // 1) 返回缓存 dfid（而非重新注册新设备），证明短路面已在完整请求链生效。
    assert!(
        resp.contains(&format!("\"dfid\":\"{}\"", seeded_dfid)),
        "register /dev did not short-circuit to cached dfid:\n{}",
        resp
    );
    // 2) 指定 Set-Cookie 注入持久化 dfid。
    assert!(
        resp.contains(&format!("Set-Cookie: dfid={}", seeded_dfid)),
        "missing persisted dfid cookie:\n{}",
        resp
    );
    // 3) KUGOU_API_GUID cookie 必须是持久化 guid（修复前每次启动随机）。
    assert!(
        resp.contains(&format!("KUGOU_API_GUID={}", seeded_guid)),
        "KUGOU_API_GUID not from persisted device (should reuse {}):\n{}",
        seeded_guid,
        resp
    );

    // 4) 幂等：第二次请求返回同一 dfid，且绝无上游错误码 502（502 表示有网络透传）。
    let resp2 = tcp_request(
        port,
        "GET /register/dev HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    );
    assert!(
        resp2.contains(&format!("\"dfid\":\"{}\"", seeded_dfid)),
        "second register /dev must return the same persisted dfid:\n{}",
        resp2
    );
    assert!(
        !resp2.starts_with("HTTP/1.1 502"),
        "second register /dev must NOT touch upstream (got 502):\n{}",
        resp2
    );

    kugou_server::server::stop();
    let _ = std::fs::remove_file(&file);
}

/// 一起听：music_room_audios 必须复刻 JS：解析数组（含 JSON 字符串）、
/// 截断 50 条、映射 {hash, mixsongid, fid}、过滤空 hash。
#[test]
fn listen_together_audios_normalize() {
    use kugou_server::modules::listen_together::music_room_audios;
    use serde_json::{json, Value};

    // 正常数组：空 hash 被过滤；mixsongid 兼容 mixSongId；fid 缺省 0
    let q = json!({
        "audios": [
            { "hash": "AAA", "mixsongid": "111", "fid": 7 },
            { "hash": "", "mixsongid": "222" },
            { "hash": "BBB", "mixSongId": 333 }
        ]
    });
    let audios = music_room_audios(&q);
    assert_eq!(audios, json!([
        { "hash": "AAA", "mixsongid": "111", "fid": 7 },
        { "hash": "BBB", "mixsongid": "333", "fid": 0 }
    ]));

    // audios 以 JSON 字符串传入（HTTP query 场景）也能解析
    let q2 = json!({ "audios": "[{\"hash\":\"CCC\",\"mixsongid\":\"9\"}]" });
    assert_eq!(
        music_room_audios(&q2),
        json!([{ "hash": "CCC", "mixsongid": "9", "fid": 0 }])
    );

    // 超过 50 条截断到 50
    let big: Vec<Value> = (0..60)
        .map(|i| json!({ "hash": format!("H{i}"), "mixsongid": i.to_string() }))
        .collect();
    assert_eq!(music_room_audios(&json!({ "audios": big })).as_array().unwrap().len(), 50);

    // 缺失/非法 → 空数组
    assert_eq!(music_room_audios(&json!({})), json!([]));
    assert_eq!(music_room_audios(&json!({ "audios": "not-json" })), json!([]));
}

/// 一起听：auth_body 的 userid 必须是数字（rmservice 强制），token 取自 cookie。
#[test]
fn listen_together_auth_body() {
    use kugou_server::modules::listen_together::{auth_body, resolve_biz};
    use serde_json::json;

    // cookie userid 为数字字符串 → 转数字
    let q = json!({ "cookie": { "userid": "12345", "token": "TOK" } });
    assert_eq!(auth_body(&q), json!({ "userid": 12345, "token": "TOK" }));

    // 顶层 userid 优先；缺失 token 为空串
    let q2 = json!({ "userid": "9", "cookie": {} });
    assert_eq!(auth_body(&q2), json!({ "userid": 9, "token": "" }));

    // biz 默认 1000（自习室），可显式 1009
    assert_eq!(resolve_biz(&json!({})), 1000);
    assert_eq!(resolve_biz(&json!({ "biz": "1009" })), 1009);
}

/// 一起听：merge_input 必须把 body 字段展开覆盖顶层（JS {...params, ...body}），
/// cookie 不进 input（cookie 始终单独从 q 取，不允许 body 覆盖）。
#[test]
fn listen_together_merge_input() {
    use kugou_server::modules::listen_together::merge_input;
    use serde_json::json;

    let q = json!({
        "operation": "join",
        "room_id": "R1",
        "body": { "groupid": "G2", "extra": 1 },
        "cookie": { "token": "T" }
    });
    let input = merge_input(&q);
    assert_eq!(input["groupid"], json!("G2"));
    assert_eq!(input["extra"], json!(1));
    // 顶层原有键保留
    assert_eq!(input["operation"], json!("join"));
    assert!(input.get("cookie").is_none());
}

/// 一起听：room/group id 读取必须兼容 roomid/groupid/room_id 三种键
/// （EchoMusic 平铺发 room_id，KuGouMusicApi 发 groupid/roomid）。
#[test]
fn listen_together_room_id_compat() {
    use kugou_server::modules::listen_together::{group_id, room_id};
    use serde_json::json;

    assert_eq!(room_id(&json!({ "room_id": "A" })), "A");
    assert_eq!(room_id(&json!({ "roomid": "B" })), "B");
    assert_eq!(group_id(&json!({ "groupid": "C" })), "C");
    assert_eq!(group_id(&json!({ "room_id": "D" })), "D");
    // body 中的键同样生效
    assert_eq!(room_id(&json!({ "body": { "room_id": "E" } })), "E");
}

/// 专辑动态封面（dycover）签名必须与 JS `signatureStandardParams` 逐字节一致：
/// md5(SALT + 按键排序的 k=v 拼接 + SALT)，SALT=OIlwieks28dk2k092lksi2UIkp。
/// 黄金值来自 2026-09-17 实测（该签名请求上游返回 status:1）。
/// 回归：A) 用概念版盐/3116 会 20006 sign error；B) serde_json 键序若与 JS 不一致，
/// data 段的 JSON 字节会变，签名随之失效。
#[test]
fn dycover_signature_matches_js() {
    use serde_json::json;

    let data = json!([{ "album_audio_id": 468087825, "album_id": 65482908 }]);
    let params = json!({
        "appid": 1005,
        "clientver": 20489,
        "data": data,
        "isCdn": 1,
        "query": "audioPlay",
    });

    // 1) 复用标准盐签名（等价 JS signatureStandardParams）
    let sig = kugou_server::helper::signature_android_params_standard(&params, &[], false);
    assert_eq!(sig, "83887d10eef4a963e33cad542ca1d6cd");

    // 2) data 段序列化字节必须与 JS JSON.stringify 一致（键序 + 无空格）
    let data_str = kugou_server::util::json_stringify(&params["data"]);
    assert_eq!(
        data_str,
        r#"[{"album_audio_id":468087825,"album_id":65482908}]"#
    );
}

/// /video/barrage（MV 弹幕列表）参数口径，对齐 JS `buildVideoBarrageListConfig`。
/// 仅断言参数构造，不触发网络。
#[test]
fn video_barrage_list_params_both_ids() {
    use kugou_server::modules::video_barrage::build_list_params;
    use serde_json::json;

    // video_id + hash 同时传入：childrenid = video_id，extdata 键必须不出现。
    let q = json!({ "video_id": "VID123", "hash": "HASH456" });
    let p = build_list_params(&q);
    assert_eq!(p["childrenid"], json!("VID123"));
    assert!(p.get("extdata").is_none(), "video_id 非空时 extdata 不得出现");
}

#[test]
fn video_barrage_list_params_hash_only() {
    use kugou_server::modules::video_barrage::build_list_params;
    use serde_json::json;

    // 仅传 hash：extdata = hash，childrenid 键必须不出现。
    let q = json!({ "hash": "HASH456" });
    let p = build_list_params(&q);
    assert_eq!(p["extdata"], json!("HASH456"));
    assert!(p.get("childrenid").is_none(), "video_id 为空时 childrenid 不得出现");
}

#[test]
fn video_barrage_list_params_code_router_and_defaults() {
    use kugou_server::modules::video_barrage::{build_list_params, VIDEO_BARRAGE_CODE};
    use serde_json::json;

    let q = json!({ "video_id": "VID123" });
    let p = build_list_params(&q);

    // r / code 取值正确（MV 弹幕池，非歌曲评论池）
    assert_eq!(p["r"], json!("comments/getCommentWithLike"));
    assert_eq!(p["code"], json!(VIDEO_BARRAGE_CODE));
    // 鉴权全集：appid / clientver / ver
    assert_eq!(p["appid"], json!(3116));
    assert_eq!(p["clientver"], json!(11440));
    assert_eq!(p["ver"], json!(6));
    // p / pagesize 缺省为数字（非字符串）
    assert_eq!(p["p"], json!(1));
    assert_eq!(p["pagesize"], json!(20));
}

#[test]
fn video_barrage_list_params_key_matches_sign_helper() {
    use kugou_server::helper::sign_params_key;
    use kugou_server::modules::video_barrage::build_list_params;
    use serde_json::json;

    // 固定 clienttime，key 必须 = signParamsKey(clienttime)（用既有 helper 比对，不硬编码 md5）。
    let q = json!({ "video_id": "VID123", "clienttime": "1700000000" });
    let p = build_list_params(&q);
    let expected = sign_params_key("1700000000", "", "");
    assert_eq!(p["key"], json!(expected));
}

#[test]
fn video_barrage_handle_requires_video_id_or_hash() {
    use kugou_server::modules::video_barrage::handle;
    use kugou_server::modules::Ctx;
    use serde_json::json;

    // video_id 与 hash 皆空 → 400，body 含 error_code = 400（不触网）。
    let ctx = Ctx { ip: String::new(), body_bytes: None };
    let result = handle(&json!({}), &ctx);
    assert!(result.is_err(), "两者皆空应返回 Err(400)");
    let resp = result.err().unwrap();
    assert_eq!(resp.status, 400);
    let body = resp.body.to_json();
    assert_eq!(body["error_code"], json!(400));
    assert_eq!(body["status"], json!(0));
    assert_eq!(body["msg"], json!("video_id 和 hash 至少需要传入一个"));
}

/// /video/barrage/send 参数口径，对齐 JS `buildVideoBarrageSendConfig`。
/// 仅断言参数构造，不触发网络。
#[test]
fn video_barrage_send_params_shape() {
    use kugou_server::modules::video_barrage::{
        build_send_params, VIDEO_BARRAGE_CODE, VIDEO_BARRAGE_SEND_R_ADD, VIDEO_BARRAGE_SEND_VER_ADD,
    };
    use serde_json::json;

    let q = json!({
        "video_id": "VID1",
        "content": "hi",
        "kugouid": "123",
        "clienttoken": "T",
        "cookie": { "KUGOU_API_MID": "MID1" },
        "pid": "55",
    });
    let p = build_send_params(&q, "hi", "VID1", "name");

    // r / code 取值正确（MV 弹幕池，非歌曲评论池）
    assert_eq!(p["r"], json!(VIDEO_BARRAGE_SEND_R_ADD));
    assert_eq!(p["r"], json!("comments/addcomment"));
    assert_eq!(p["code"], json!(VIDEO_BARRAGE_CODE));
    // ver 必须是字符串 "1.02"（不是数字 6）
    assert_eq!(p["ver"], json!(VIDEO_BARRAGE_SEND_VER_ADD));
    assert_eq!(p["ver"], json!("1.02"));
    // 客户端版本 / appid
    assert_eq!(p["clientver"], json!(11440));
    assert_eq!(p["appid"], json!(3116));
    // 资源标识
    assert_eq!(p["childrenid"], json!("VID1"));
    assert_eq!(p["childrenname"], json!("name"));
    assert_eq!(p["content"], json!("hi"));
    // 鉴权字段来自 identity（kugouid/clienttoken/mid）
    assert_eq!(p["kugouid"], json!(123));
    assert_eq!(p["clienttoken"], json!("T"));
    assert_eq!(p["mid"], json!("MID1"));
}

/// 发送侧与写接口的关键差异：无签名、无默认鉴权时间字段，
/// 不得出现 key / clienttime / dfid / uuid（防止后来者"顺手补齐"成 POST+签名）。
#[test]
fn video_barrage_send_params_no_signature_keys() {
    use kugou_server::modules::video_barrage::build_send_params;
    use serde_json::json;

    let q = json!({ "video_id": "VID1", "content": "hi" });
    let p = build_send_params(&q, "hi", "VID1", "name");
    assert!(p.get("key").is_none(), "发送弹幕不应带 key");
    assert!(p.get("clienttime").is_none(), "发送弹幕不应带 clienttime");
    assert!(p.get("dfid").is_none(), "发送弹幕不应带 dfid");
    assert!(p.get("uuid").is_none(), "发送弹幕不应带 uuid");
}

/// pid 缺省时被 compact 丢弃；传入时出现在参数里。
#[test]
fn video_barrage_send_params_pid_optional() {
    use kugou_server::modules::video_barrage::build_send_params;
    use serde_json::json;

    let q = json!({ "video_id": "VID1", "content": "hi" });
    let p = build_send_params(&q, "hi", "VID1", "name");
    assert!(p.get("pid").is_none(), "pid 缺省时不应出现");

    let q2 = json!({ "video_id": "VID1", "content": "hi", "pid": "99" });
    let p2 = build_send_params(&q2, "hi", "VID1", "name");
    assert_eq!(p2["pid"], json!("99"), "pid 传入时应出现在参数里");
}

/// content 为空 → 400 且 body 含 error_code = 400（不触网）。
#[test]
fn video_barrage_send_requires_content() {
    use kugou_server::modules::Ctx;
    use kugou_server::modules::video_barrage::handle_send;
    use serde_json::json;

    let ctx = Ctx { ip: String::new(), body_bytes: None };
    let result = handle_send(&json!({ "video_id": "VID1" }), &ctx);
    assert!(result.is_err(), "content 为空应返回 Err(400)");
    let resp = result.err().unwrap();
    assert_eq!(resp.status, 400);
    let body = resp.body.to_json();
    assert_eq!(body["error_code"], json!(400));
    assert_eq!(body["status"], json!(0));
    assert_eq!(body["msg"], json!("content 不能为空"));
}

/// video_id 与 hash 皆空 → 400（不触网）。
#[test]
fn video_barrage_send_requires_video_id_or_hash() {
    use kugou_server::modules::Ctx;
    use kugou_server::modules::video_barrage::handle_send;
    use serde_json::json;

    let ctx = Ctx { ip: String::new(), body_bytes: None };
    let result = handle_send(&json!({ "content": "hi" }), &ctx);
    assert!(result.is_err(), "两者皆空应返回 Err(400)");
    let resp = result.err().unwrap();
    assert_eq!(resp.status, 400);
    let body = resp.body.to_json();
    assert_eq!(body["error_code"], json!(400));
    assert_eq!(body["msg"], json!("video_id 和 hash 至少需要传入一个"));
}

/// 路由注册顺序：`/video/barrage/send` 必须出现在 `/video/barrage` 之前。
/// 本项目前缀匹配会把发送请求误送进列表 handler，顺序错误即回归。
#[test]
fn video_barrage_send_route_order() {
    use kugou_server::modules::{register, ModuleFn};
    let mut routes: Vec<(&'static str, ModuleFn)> = Vec::new();
    register(&mut routes);
    let paths: Vec<&str> = routes.iter().map(|(p, _)| *p).collect();

    let send_idx = paths.iter().position(|p| *p == "/video/barrage/send");
    let list_idx = paths.iter().position(|p| *p == "/video/barrage");
    assert!(send_idx.is_some(), "/video/barrage/send 未注册");
    assert!(list_idx.is_some(), "/video/barrage 未注册");
    assert!(
        send_idx.unwrap() < list_idx.unwrap(),
        "/video/barrage/send 必须注册在 /video/barrage 之前（前缀匹配会把发送请求送进列表 handler）"
    );
}

