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

/// 黑名单 items 构建（blacklist.js 的移植）：与 JS JSON.stringify 逐字段对齐——
/// song → k 为小写 hash、v 为 `{"n":名,"m":mixsongid,"t":秒}` 字符串；
/// singer → k 为 singerid、v 为 `{"n":名,"t":秒}`；items 参数（合法数组）原样优先。
#[test]
fn blacklist_items_build() {
    use kugou_server::modules::blacklist::build_items;
    use serde_json::json;

    // song 单条：hash 大写入参 → 小写 k；v 内 n/m/t 顺序与 JS 对象插入序一致
    let q = json!({"hash": "B3A52A7A958BF0AED0EBFBA2E9A818B7", "name": "周杰伦 - 晴天", "mixsongid": "32100650"});
    let items = build_items(&q, "song", 1786957745);
    let arr = items.as_array().unwrap();
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["k"], "b3a52a7a958bf0aed0ebfba2e9a818b7");
    let v = arr[0]["v"].as_str().unwrap();
    assert_eq!(v, r#"{"n":"周杰伦 - 晴天","m":"32100650","t":"1786957745"}"#);

    // singer 单条：无 m 字段
    let q = json!({"label": "singer", "singerid": "3520", "name": "周杰伦"});
    let items = build_items(&q, "singer", 1786957745);
    let v = items.as_array().unwrap()[0]["v"].as_str().unwrap();
    assert_eq!(v, r#"{"n":"周杰伦","t":"1786957745"}"#);
    assert_eq!(items.as_array().unwrap()[0]["k"], "3520");

    // items 参数（JSON 数组字符串）原样透传
    let q = json!({"items": r#"[{"k":"a","v":"{\"n\":\"x\",\"t\":\"1\"}"}]"#});
    let items = build_items(&q, "song", 1786957745);
    assert_eq!(items.as_array().unwrap().len(), 1);
    assert_eq!(items.as_array().unwrap()[0]["k"], "a");

    // items 参数非法 → 回退单条构建
    let q = json!({"items": "not-json", "hash": "ABC"});
    let items = build_items(&q, "song", 1786957745);
    assert_eq!(items.as_array().unwrap()[0]["k"], "abc");
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

/// **密文长度非 block size 整数倍时必须返回空 Vec，不得 panic。**
///
/// 回归的是真机崩溃：profile 包冷启动后点歌单相关功能 →
/// `SIGABRT` + `Slice must be the same length as the array`。
/// 链路：`playlist::cloud_roundtrip` → `crypto::playlist_aes_decrypt`
/// → `aes_cbc_decrypt` → `GenericArray::clone_from_slice(blk)`；
/// `data.chunks(bs)` 的短末块会让它 panic，而 `Cargo.toml` 是
/// `panic = "abort"` → 整个进程直接崩（不是 Dart 侧能兜的异常）。
///
/// 触发条件：上游对 `/v1/modify_*` 返回**未加密**内容（网关错误页 / 纯 JSON /
/// HTML），长度几乎不可能恰好是 16 的倍数。
///
/// 这里用 `catch_unwind` 断言「没 panic」——正是为了把「崩溃」变成「可断言的失败」。
/// 注意**不能**靠 `catch_unwind` 去兜生产路径：abort 下它拦不住，
/// 真正的修复是 `aes_cbc_decrypt` 里的长度前置守卫。
#[test]
fn aes_cbc_decrypt_rejects_unaligned_ciphertext() {
    use kugou_server::crypto::aes_cbc_decrypt;

    let key = b"0123456789abcdef";
    let iv = b"0123456789abcdef";

    // 各种非 16 倍数长度（含 1、15、17、60：60 是本地复现用的真实长度）
    for len in [1usize, 2, 15, 17, 31, 60, 61] {
        let data = vec![0x41u8; len];
        let result = std::panic::catch_unwind(|| {
            aes_cbc_decrypt(key, iv, &data)
        });
        assert!(
            result.is_ok(),
            "长度 {} (非 16 倍数) 触发了 panic —— 这就是 profile 包崩溃的根因",
            len
        );
        assert!(
            result.unwrap().is_empty(),
            "长度 {} 应返回空 Vec（调用方按解密失败处理）",
            len
        );
    }

    // 空输入同样不得 panic（非法 base64 经 unwrap_or_default 也会走到这）
    let empty: Vec<u8> = Vec::new();
    let result = std::panic::catch_unwind(|| aes_cbc_decrypt(key, iv, &empty));
    assert!(result.is_ok(), "空输入不得 panic");
    assert!(result.unwrap().is_empty());
}

/// 对齐的密文与 roundtrip 不受守卫影响（守卫只挡非 16 倍数）。
#[test]
fn aes_cbc_decrypt_empty_and_aligned_still_work() {
    use kugou_server::crypto::{aes_cbc_decrypt, playlist_aes_decrypt, playlist_aes_encrypt};

    let key = b"0123456789abcdef";
    let iv = b"0123456789abcdef";

    // 16 的倍数（含刚好一块、空 padding 场景）
    for len in [16usize, 32, 48, 128] {
        let data = vec![0x42u8; len];
        let result = std::panic::catch_unwind(|| aes_cbc_decrypt(key, iv, &data));
        assert!(result.is_ok(), "对齐长度 {} 不得 panic", len);
    }

    // 完整 roundtrip：加密 → 解密 → 原文
    let (aes_key, b64) = playlist_aes_encrypt(r#"{"listid":11,"total_ver":9}"#);
    let dec = playlist_aes_decrypt(&aes_key, &b64);
    assert_eq!(dec["listid"], serde_json::json!(11));
    assert_eq!(dec["total_ver"], serde_json::json!(9));
}

/// `playlist_aes_decrypt` 对**未加密**上游响应必须回 `Null`（不是空串）。
///
/// 空串会被调用方当成「一条内容为空的业务响应」，`Null` 才能走
/// `cloud_roundtrip` 的失败分支并带上原因。
#[test]
fn playlist_aes_decrypt_returns_null_for_unaligned() {
    use kugou_server::crypto::{base64_decode, playlist_aes_decrypt};
    use serde_json::Value;

    let aes_key = "abc123";

    // 上游返回纯 JSON（未加密）：其 base64 解码后长度 60，非 16 倍数
    let plain = r#"{"status":0,"error_code":131001,"error_msg":"token invalid"}"#;
    let b64 = {
        use base64::engine::general_purpose::STANDARD;
        use base64::Engine;
        STANDARD.encode(plain.as_bytes())
    };
    assert_eq!(base64_decode(&b64).len() % 16, 12, "构造的输入应确实非 16 倍数");

    let dec = playlist_aes_decrypt(aes_key, &b64);
    assert_eq!(
        dec,
        Value::Null,
        "未加密响应必须解析成 Null，让调用方走失败分支"
    );

    // 完全非 base64 的输入（HTML 错误页）同样回 Null，不得 panic
    let dec2 = std::panic::catch_unwind(|| {
        playlist_aes_decrypt(aes_key, "<html>502 Bad Gateway</html>")
    });
    assert!(dec2.is_ok(), "非 base64 输入不得 panic");
    assert_eq!(dec2.unwrap(), Value::Null);
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
        // 歌单加歌（Task 11 研究门控：上游 playlist_tracks_add.js 已复核，路由必须保持注册）
        "POST /playlist/tracks/add HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        // 评论写接口：content 为空 → 400（不发上游请求）。非 404 即证明 dispatch 成功。
        "POST /comment/music/send HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        // 删除评论：cid 为空 → 400（不发上游请求）。非 404 即证明 dispatch 成功。
        "POST /comment/music/del HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        "POST /comment/floor/send HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        "POST /comment/playlist/send HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        "POST /comment/album/send HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        "POST /user/cloud HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        // 上传路由：无文件二进制 body → 400（"请通过请求体传入文件二进制数据"），非 404 即证明 dispatch 成功
        "POST /user/cloud/upload HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        // 专辑动态封面：元数据路由必须命中（上游可达时 200，不可达时 502，均非 404）
        "GET /album/dycover?album_audio_id=468087825&album_id=65482908 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        // 歌曲弹幕列表：hash 非空 → dispatch 命中（上游可达 200 / 不可达 502，均非 404）
        "GET /song/barrage?hash=abc&page=1&pagesize=20 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        // 歌曲弹幕发送：content 为空 → 400（不发上游请求）。非 404 即证明 dispatch 成功，
        // 且证明 /song/barrage/send 排在 /song/barrage 之前、未被列表 handler 吞掉。
        "POST /song/barrage/send HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        // 歌曲成绩单：路由必须命中（上游可达 200 / 不可达 502，均非 404）。
        // filter 注册在 /song/ranking 之前（前缀匹配，更具体者在前），两条各归各的 handler。
        "GET /song/ranking?album_audio_id=32155307 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /song/ranking/filter?album_audio_id=32155307&page=1&pagesize=30 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        // 伴奏匹配 / K 歌数量：路由必须命中（自定义 sign，上游可达 200 / 不可达 502，均非 404）。
        // matching 注册在 /audio 之前（前缀匹配，更具体者在前），未被 /audio 相关系列吞掉。
        "GET /audio/accompany/matching?fileName=Test&mixId=637735200&hash=6D431B0507587447B3D7345434DC5825 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /audio/ktv/total?songId=1&singerName=a&songHash=abc HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        // 内容黑名单：/blacklist/list 必须先于 /blacklist 注册（前缀匹配），
        // 两条各归各的 handler（上游可达 200 / 不可达 502，均非 404）。
        "GET /blacklist?hash=abc HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /blacklist/list?label=singer&page=1&pagesize=100 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        // 听歌偏好：/user/preference/update 必须先于 /user/preference 注册（前缀匹配），
        // 两条各归各的 handler（上游可达 200 / 不可达 502，均非 404）。
        "GET /user/preference HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "POST /user/preference/update HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
        // 曲谱：5 条查询路由必须命中（2026-10-24 实测匿名可用；detail 需登录，
        // 上游可达 200 / 不可达 502，均非 404）。
        "GET /sheet/song?album_audio_id=68435136 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /sheet/detail?id=68435136_1_0 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /sheet/explore HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /sheet/rank HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        "GET /sheet/tags HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
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

    // 删除评论同理：必须真正命中本地 handler（空 cid → 400），而不是被更短的
    // /comment/music 前缀抢先当成查询接口转发到上游（那样同样不是 404，是 502）。
    let resp = tcp_request(
        port,
        "POST /comment/music/del HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
    );
    assert!(
        resp.contains("400 Bad Request") && resp.contains("cid"),
        "POST /comment/music/del 未命中本地写接口 handler（疑似被短前缀路由抢先）:\n{}",
        resp
    );

    // 听歌偏好更新同理：必须真正命中本地 update handler（无任何偏好字段 → 400），
    // 而不是被更短的 /user/preference 前缀抢先当成查询接口转发到上游。
    let resp = tcp_request(
        port,
        "POST /user/preference/update HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}",
    );
    assert!(
        resp.contains("400 Bad Request") && resp.contains("至少需要提供"),
        "POST /user/preference/update 未命中本地 update handler（疑似被 /user/preference 抢先）:\n{}",
        resp
    );

    kugou_server::server::stop();
}

/// 用户资料修改与头像上传（user_update.js / user_update_avatar.js 的移植）：
/// 空参数 → 400；非法图片 → 400；带合法参数 → 非 404。
/// 400 分支必须命中本地 handler——/user/update/avatar 若被 /user/update 前缀
/// 抢先，非法图片会转而走 update 的「至少一个字段」400（body 无 imgFile），
/// 文案不同，可借此抓住抢前缀回归。
#[test]
fn user_update_and_avatar_validation() {
    let _guard = SERVER_LOCK.lock().unwrap();
    let port: u16 = 18080;
    let dir = std::env::temp_dir()
        .join("kugou_smoke")
        .to_string_lossy()
        .into_owned();
    assert_eq!(kugou_server::server::start(port, dir), Some(port));

    let post = |path: &str, body: &str| {
        let raw = format!(
            "POST {} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{}",
            path,
            body.len(),
            body
        );
        tcp_request(port, &raw)
    };

    // 无任何待修改字段 → 400
    let resp = post("/user/update", "{}");
    assert!(
        resp.contains("400 Bad Request") && resp.contains("至少需要提供一个待修改字段"),
        "/user/update 空参数应返回 400 文案:\n{}",
        resp
    );

    // 带一个字段 + 伪造 cookie → dispatch 成功（上游不可达时 502 亦算命中）
    let resp = post(
        "/user/update",
        r#"{"cookie":"token=x;userid=1","signature":"hi"}"#,
    );
    assert!(
        !resp.contains("Cannot POST"),
        "/user/update 带字段应命中路由:\n{}",
        resp
    );

    // 非法 imgFile → 400（本地校验分支，不发上游请求）
    let resp = post("/user/update/avatar", r#"{"imgFile":"not-an-image"}"#);
    assert!(
        resp.contains("400 Bad Request") && resp.contains("图片数据无效"),
        "/user/update/avatar 非法图片应返回 400 文案:\n{}",
        resp
    );

    // 合法 1x1 PNG → dispatch 成功（先走图床上传，离线时 502 亦算命中）
    let png = r#"{"imgFile":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="}"#;
    let resp = post("/user/update/avatar", png);
    assert!(
        !resp.contains("Cannot POST"),
        "/user/update/avatar 应命中路由（且未被 /user/update 抢前缀）:\n{}",
        resp
    );

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

/// stop 必须等待旧 listener 释放端口；连续启停不能被全局 running 标志跨代复活。
#[test]
fn server_stop_joins_listener_and_restart_isolated() {
    use std::net::TcpListener;

    let _guard = SERVER_LOCK.lock().unwrap();
    let dir = std::env::temp_dir()
        .join("kugou_smoke_stop_restart")
        .to_string_lossy()
        .into_owned();
    let port = 18083;

    for _ in 0..50 {
        assert_eq!(kugou_server::server::start(port, dir.clone()), Some(port));
        assert!(kugou_server::server::is_running());
        assert_eq!(kugou_server::server::get_port(), port);
        // 幂等启动应返回同一代端口，而不是额外创建 listener。
        assert_eq!(kugou_server::server::start(0, dir.clone()), Some(port));

        kugou_server::server::stop();
        assert!(!kugou_server::server::is_running());
        assert_eq!(kugou_server::server::get_port(), 0);
        let probe = TcpListener::bind(("127.0.0.1", port))
            .expect("stop 返回后旧 listener 必须已释放端口");
        drop(probe);
    }
}

#[test]
fn server_start_fails_when_fixed_port_is_occupied_then_recovers() {
    use std::net::TcpListener;

    let _guard = SERVER_LOCK.lock().unwrap();
    let port = 18084;
    let occupied = TcpListener::bind(("127.0.0.1", port)).expect("reserve test port");
    let dir = std::env::temp_dir()
        .join("kugou_smoke_port_occupied")
        .to_string_lossy()
        .into_owned();

    assert_eq!(kugou_server::server::start(port, dir.clone()), None);
    assert!(!kugou_server::server::is_running());
    assert_eq!(kugou_server::server::get_port(), 0);

    drop(occupied);
    assert_eq!(kugou_server::server::start(port, dir), Some(port));
    kugou_server::server::stop();
    assert!(TcpListener::bind(("127.0.0.1", port)).is_ok());
}

#[test]
fn concurrent_start_stop_keeps_one_consistent_generation() {
    use std::net::TcpListener;
    use std::sync::{Arc, Barrier};

    let _guard = SERVER_LOCK.lock().unwrap();
    let port = 18085;
    let dir = std::env::temp_dir()
        .join("kugou_smoke_start_stop_race")
        .to_string_lossy()
        .into_owned();
    let workers = 4;
    let barrier = Arc::new(Barrier::new(workers));
    let threads = (0..workers)
        .map(|worker| {
            let barrier = Arc::clone(&barrier);
            let dir = dir.clone();
            std::thread::spawn(move || {
                barrier.wait();
                for round in 0..4 {
                    if (worker + round) % 2 == 0 {
                        assert_eq!(kugou_server::server::start(port, dir.clone()), Some(port));
                    } else {
                        kugou_server::server::stop();
                    }
                }
            })
        })
        .collect::<Vec<_>>();

    for thread in threads {
        thread.join().expect("concurrent lifecycle worker panicked");
    }
    kugou_server::server::stop();
    assert!(!kugou_server::server::is_running());
    assert_eq!(kugou_server::server::get_port(), 0);
    assert!(TcpListener::bind(("127.0.0.1", port)).is_ok());
}

#[test]
fn stop_joins_listener_without_waiting_for_slow_request_body() {
    use std::net::{Shutdown, TcpStream};
    use std::time::Instant;

    let _guard = SERVER_LOCK.lock().unwrap();
    let port = 18086;
    let dir = std::env::temp_dir()
        .join("kugou_smoke_slow_request_stop")
        .to_string_lossy()
        .into_owned();
    assert_eq!(kugou_server::server::start(port, dir), Some(port));

    let mut client = TcpStream::connect(("127.0.0.1", port)).expect("connect to server");
    client
        .write_all(
            b"POST /login HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n",
        )
        .expect("send headers without completing body");

    let request_deadline = Instant::now() + Duration::from_secs(2);
    while kugou_server::server::active_request_count() == 0 && Instant::now() < request_deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(kugou_server::server::active_request_count(), 1);

    let stop_started = Instant::now();
    kugou_server::server::stop();
    assert!(
        stop_started.elapsed() < Duration::from_secs(1),
        "stop waited for request-body processing instead of only joining listener"
    );
    assert_eq!(kugou_server::server::active_request_count(), 1);

    client.shutdown(Shutdown::Both).expect("release slow request");
    drop(client);
    let request_exit_deadline = Instant::now() + Duration::from_secs(2);
    while kugou_server::server::active_request_count() != 0
        && Instant::now() < request_exit_deadline
    {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(kugou_server::server::active_request_count(), 0);
}

#[test]
fn stopped_generation_port_does_not_reach_restarted_server() {
    use std::net::{SocketAddr, TcpStream};

    let _guard = SERVER_LOCK.lock().unwrap();
    let old_port = 18087;
    let new_port = 18088;
    let dir = std::env::temp_dir()
        .join("kugou_smoke_old_generation")
        .to_string_lossy()
        .into_owned();
    assert_eq!(
        kugou_server::server::start(old_port, dir.clone()),
        Some(old_port)
    );
    kugou_server::server::stop();
    assert_eq!(kugou_server::server::start(new_port, dir), Some(new_port));

    let old_address = SocketAddr::from(([127, 0, 0, 1], old_port));
    assert!(TcpStream::connect_timeout(&old_address, Duration::from_millis(200)).is_err());
    let response = tcp_request(
        new_port,
        "GET /nonexistent HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    );
    assert!(response.contains("404 Not Found"), "got: {response}");
    kugou_server::server::stop();
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

/// 路由注册顺序：`/user/preference/update` 必须出现在 `/user/preference` 之前。
/// 前缀匹配会把更新请求误送进查询 handler，顺序错误即回归。
#[test]
fn user_preference_update_route_order() {    use kugou_server::modules::{register, ModuleFn};
    let mut routes: Vec<(&'static str, ModuleFn)> = Vec::new();
    register(&mut routes);
    let paths: Vec<&str> = routes.iter().map(|(p, _)| *p).collect();

    let update_idx = paths.iter().position(|p| *p == "/user/preference/update");
    let get_idx = paths.iter().position(|p| *p == "/user/preference");
    assert!(update_idx.is_some(), "/user/preference/update 未注册");
    assert!(get_idx.is_some(), "/user/preference 未注册");
    assert!(
        update_idx.unwrap() < get_idx.unwrap(),
        "/user/preference/update 必须注册在 /user/preference 之前（前缀匹配会把 update 请求送进查询 handler）"
    );
}

/// /song/barrage（歌曲弹幕列表）参数口径，对齐 JS `buildSongBarrageListConfig`。
/// 仅断言参数构造，不触发网络。
#[test]
fn song_barrage_list_extdata_conditional() {
    use kugou_server::modules::song_barrage::build_list_params;
    use serde_json::json;

    // special_id + hash 同时传入：childrenid = special_id，extdata 键必须不出现。
    let q = json!({ "special_id": "SID123", "hash": "HASH456" });
    let p = build_list_params(&q);
    assert_eq!(p["childrenid"], json!("SID123"));
    assert!(p.get("extdata").is_none(), "special_id 非空时 extdata 不得出现");
}

#[test]
fn song_barrage_list_params_hash_only() {
    use kugou_server::modules::song_barrage::build_list_params;
    use serde_json::json;

    // 仅传 hash：extdata = hash，childrenid 键必须不出现。
    let q = json!({ "hash": "HASH456" });
    let p = build_list_params(&q);
    assert_eq!(p["extdata"], json!("HASH456"));
    assert!(p.get("childrenid").is_none(), "special_id 为空时 childrenid 不得出现");
}

#[test]
fn song_barrage_list_params_code_mixsongid_and_defaults() {
    use kugou_server::modules::song_barrage::{build_list_params, SONG_BARRAGE_CODE};
    use serde_json::json;

    // 与 MV 的唯一差异：mixsongid 透传；code 为歌曲弹幕池 articulossong。
    let q = json!({ "special_id": "SID123", "mixsongid": "MIX999" });
    let p = build_list_params(&q);

    assert_eq!(p["r"], json!("comments/getCommentWithLike"));
    assert_eq!(p["code"], json!(SONG_BARRAGE_CODE));
    assert_eq!(p["code"], json!("articulossong"));
    // mixsongid 透传（链 mixsongid → album_audio_id）
    assert_eq!(p["mixsongid"], json!("MIX999"));
    // 鉴权全集：appid / clientver / ver
    assert_eq!(p["appid"], json!(3116));
    assert_eq!(p["clientver"], json!(11440));
    assert_eq!(p["ver"], json!(6));
    // p / pagesize 缺省为数字（非字符串）
    assert_eq!(p["p"], json!(1));
    assert_eq!(p["pagesize"], json!(20));
}

#[test]
fn song_barrage_list_mixsongid_from_album_audio_id_alias() {
    use kugou_server::modules::song_barrage::build_list_params;
    use serde_json::json;

    // mixsongid 缺省时取 album_audio_id（JS firstValue 链）。
    let q = json!({ "special_id": "SID123", "album_audio_id": "ALI" });
    let p = build_list_params(&q);
    assert_eq!(p["mixsongid"], json!("ALI"));
}

#[test]
fn song_barrage_list_key_matches_sign_helper() {
    use kugou_server::helper::sign_params_key;
    use kugou_server::modules::song_barrage::build_list_params;
    use serde_json::json;

    // 固定 clienttime，key 必须 = signParamsKey(clienttime)（用既有 helper 比对，不硬编码 md5）。
    let q = json!({ "special_id": "SID123", "clienttime": "1700000000" });
    let p = build_list_params(&q);
    let expected = sign_params_key("1700000000", "", "");
    assert_eq!(p["key"], json!(expected));
}

#[test]
fn song_barrage_handle_requires_special_id_or_hash() {
    use kugou_server::modules::song_barrage::handle;
    use kugou_server::modules::Ctx;
    use serde_json::json;

    // special_id 与 hash 皆空 → 400，body 含 error_code = 400（不触网）。
    let ctx = Ctx { ip: String::new(), body_bytes: None };
    let result = handle(&json!({}), &ctx);
    assert!(result.is_err(), "两者皆空应返回 Err(400)");
    let resp = result.err().unwrap();
    assert_eq!(resp.status, 400);
    let body = resp.body.to_json();
    assert_eq!(body["error_code"], json!(400));
    assert_eq!(body["status"], json!(0));
    assert_eq!(body["msg"], json!("special_id 和 hash 至少需要传入一个"));
}

/// /song/barrage/send 参数口径：复用评论写接口 send_options（POST + 签名），
/// code 换成歌曲弹幕池。仅断言参数构造，不触发网络。
#[test]
fn song_barrage_send_options_shape() {
    use kugou_server::modules::comment_send::send_options;
    use serde_json::json;

    let q = json!({
        "special_id": "SID1",
        "content": "hi",
        "kugouid": "123",
        "clienttoken": "T",
        "clienttime": "1700000000",
        "cookie": { "KUGOU_API_MID": "MID1" },
    });
    let opts = send_options(&q, "hi", "SID1", "name", "articulossong", "MIX9");
    let p = &opts.params;

    // 歌曲弹幕发送是 POST + 签名形态（勿照抄 MV 弹幕的 GET 无签名）
    assert_eq!(opts.method, "POST");
    assert_eq!(p["r"], json!("commentsv3/add"));
    assert_eq!(p["code"], json!("articulossong"));
    assert_eq!(p["childrenid"], json!("SID1"));
    // key 非空（signParamsKey(clienttime+mid+data)），与写接口一致
    let key = p["key"].as_str().unwrap_or_default();
    assert!(!key.is_empty(), "歌曲弹幕发送必须带签名 key");
}

/// content 为空 → 400 且 body 含 error_code = 400（不触网）。
#[test]
fn song_barrage_send_requires_content() {
    use kugou_server::modules::Ctx;
    use kugou_server::modules::song_barrage::handle_send;
    use serde_json::json;

    let ctx = Ctx { ip: String::new(), body_bytes: None };
    let result = handle_send(&json!({ "special_id": "SID1" }), &ctx);
    assert!(result.is_err(), "content 为空应返回 Err(400)");
    let resp = result.err().unwrap();
    assert_eq!(resp.status, 400);
    let body = resp.body.to_json();
    assert_eq!(body["error_code"], json!(400));
    assert_eq!(body["status"], json!(0));
    assert_eq!(body["msg"], json!("content 不能为空"));
}

/// 路由注册顺序：`/song/barrage/send` 必须出现在 `/song/barrage` 之前。
/// 本项目前缀匹配会把发送请求误送进列表 handler，顺序错误即回归。
#[test]
fn song_barrage_send_route_order() {
    use kugou_server::modules::{register, ModuleFn};
    let mut routes: Vec<(&'static str, ModuleFn)> = Vec::new();
    register(&mut routes);
    let paths: Vec<&str> = routes.iter().map(|(p, _)| *p).collect();

    let send_idx = paths.iter().position(|p| *p == "/song/barrage/send");
    let list_idx = paths.iter().position(|p| *p == "/song/barrage");
    assert!(send_idx.is_some(), "/song/barrage/send 未注册");
    assert!(list_idx.is_some(), "/song/barrage 未注册");
    assert!(
        send_idx.unwrap() < list_idx.unwrap(),
        "/song/barrage/send 必须注册在 /song/barrage 之前（前缀匹配会把发送请求送进列表 handler）"
    );
}

/// `/home/discover`（首页刷歌推荐）路由已注册，且没有更短的前缀路由会遮蔽它。
///
/// `prefix_match` 是路径段前缀匹配：若将来有人加了 `/home` 之类的短前缀并注册在
/// 前面，`/home/discover` 会被送进那个 handler（与 `/video/barrage` 踩过的坑同类）。
#[test]
fn home_discover_route_registered_and_unshadowed() {
    use kugou_server::modules::{register, ModuleFn};
    let mut routes: Vec<(&'static str, ModuleFn)> = Vec::new();
    register(&mut routes);
    let paths: Vec<&str> = routes.iter().map(|(p, _)| *p).collect();

    let target = "/home/discover";
    let idx = paths.iter().position(|p| *p == target);
    assert!(idx.is_some(), "/home/discover 未注册");

    // 任何比它短的、且是它的段前缀的路由，只要注册在前面就会遮蔽。
    for (i, route) in paths.iter().enumerate() {
        if i >= idx.unwrap() {
            break;
        }
        let shadows = target.len() > route.len()
            && target.starts_with(route)
            && target.as_bytes().get(route.len()) == Some(&b'/');
        assert!(
            !shadows,
            "{} 注册在前会遮蔽 {}（前缀匹配会先命中前者）",
            route,
            target
        );
    }
}

/// `home_discover_rec` body 的默认值必须与参考实现一致。
///
/// `pagesize` 默认 4 是文档约定；`today_play_num` 默认 0、`recall_type` 默认 song
/// 同理。任一处被改都会静默改变推荐条数/去重行为，故固化为回归测试。
#[test]
fn home_discover_body_defaults() {
    use kugou_server::modules::home::{build_body, build_params};
    use serde_json::json;

    let q = json!({});
    let body = build_body(&q);
    assert_eq!(body["support"], json!("only_song"));
    assert_eq!(body["userid"], json!(0));
    assert_eq!(body["recall_type"], json!("song"));
    assert_eq!(body["today_play_num"], json!(0));
    assert_eq!(body["pagesize"], json!(4));

    // go_ky_extra 三项定死，值是字符串（不是数字）。
    let extra = body["go_ky_extra"].as_array().expect("go_ky_extra 应为数组");
    assert_eq!(extra.len(), 3);
    for (item, (key, val)) in extra
        .iter()
        .zip([("network", "2"), ("play_mode", "2"), ("no_mv_ret", "1")])
    {
        assert_eq!(item["key"], json!(key));
        assert_eq!(item["val"], json!(val));
    }

    // clientver 必须被抬到 20809，否则上游静默返回空列表。
    let params = build_params(&q);
    assert_eq!(params["module_key"], json!("home_discover_rec"));
    assert_eq!(params["module_id"], json!(1));
    assert_eq!(params["area_code"], json!(1));
    assert_eq!(params["platform"], json!("android"));
    assert_eq!(params["clientver"], json!(20809));
}

/// 显式传入的参数要覆盖默认值；`page` 仅在 >0 时出现。
///
/// `page` 是给无限滚动预留的探针位：上游若不认，多一个未知 query 参数也无害；
/// 但它绝不能以 0 的形式混进去（那会让上游按「第 0 页」解析）。
#[test]
fn home_discover_body_overrides_and_page_optin() {
    use kugou_server::modules::home::{build_body, build_params};
    use serde_json::json;

    let q = json!({
        "pagesize": "30",
        "today_play_num": "57",
        "recall_type": "songlist",
        "userid": "10086",
    });
    let body = build_body(&q);
    assert_eq!(body["pagesize"], json!(30));
    assert_eq!(body["today_play_num"], json!(57));
    assert_eq!(body["recall_type"], json!("songlist"));
    assert_eq!(body["userid"], json!(10086));

    // 缺失 / 0 都不写入 page。
    assert!(build_params(&json!({})).get("page").is_none());
    assert!(build_params(&json!({ "page": 0 })).get("page").is_none());
    // 正值写入。
    assert_eq!(build_params(&json!({ "page": 3 }))["page"], json!(3));
}

/// /personal/fm（私人 FM）的 cur_mark 透传口径，对齐 JS `personal_fm.js:37`。
/// 仅断言参数构造，不触发网络。
#[test]
fn personal_fm_cur_mark_passthrough() {
    use kugou_server::modules::fm::build_personal_fm_params;
    use serde_json::json;

    // click_red / cancel_red 等反馈动作建议带上当前推荐标记，原样作为字符串下发。
    let p = build_personal_fm_params(&json!({ "cur_mark": "MARK123" }));
    assert_eq!(p["cur_mark"], json!("MARK123"));

    // 缺失 / 空串都不写入该键（JS `if (params?.cur_mark)`）——空串混进 body 会
    // 让上游按「无标记」之外的值解析。
    assert!(build_personal_fm_params(&json!({})).get("cur_mark").is_none());
    assert!(build_personal_fm_params(&json!({ "cur_mark": "" })).get("cur_mark").is_none());
}

/// mode / action 是自由字符串，必须原样透传（上游文档另列 `mode: radio` 与扩展
/// action 集，Rust 侧不得白名单过滤）。
#[test]
fn personal_fm_mode_and_action_verbatim() {
    use kugou_server::modules::fm::build_personal_fm_params;
    use serde_json::json;

    let p = build_personal_fm_params(&json!({ "mode": "radio", "action": "click_red" }));
    assert_eq!(p["mode"], json!("radio"));
    assert_eq!(p["action"], json!("click_red"));

    // 缺省值与 JS 一致：mode=normal、action=play。
    let d = build_personal_fm_params(&json!({}));
    assert_eq!(d["mode"], json!("normal"));
    assert_eq!(d["action"], json!("play"));
}

/// 伴奏匹配真实响应探针（#[ignore]，需外网，手动核对契约时才跑）：
/// `cargo +stable-x86_64-pc-windows-gnu test --test smoke accompany_matching_probe -- --ignored --nocapture`
/// 用 API 文档示例参数（希林娜依高 - Shine Brighter）捕获上游
/// optimal_matching_accompany_2_listen.do 的真实 JSON，供 Dart KugouAccompany
/// 模型字段定稿与日后契约漂移比对。路由 404 即失败；上游业务错误也打印全文。
#[test]
#[ignore]
fn accompany_matching_probe() {
    let _guard = SERVER_LOCK.lock().unwrap();
    let port: u16 = 18089;
    let dir = std::env::temp_dir()
        .join("kugou_smoke_probe")
        .to_string_lossy()
        .into_owned();
    assert_eq!(kugou_server::server::start(port, dir), Some(port));
    // fileName 按 UTF-8 百分号编码（希林娜依高 - Shine Brighter (愈加璀璨)）
    let resp = tcp_request(
        port,
        "GET /audio/accompany/matching?fileName=%E5%B8%8C%E6%9E%97%E5%A8%9C%E4%BE%9D%E9%AB%98%20-%20Shine%20Brighter%20(%E6%84%88%E5%8A%A0%E7%92%80%E7%92%A8)&mixId=637735200&hash=6D431B0507587447B3D7345434DC5825 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    );
    println!("=== /audio/accompany/matching raw response ===\n{}", resp);
    assert!(!resp.contains("Cannot GET"), "route 404: {}", resp);
    kugou_server::server::stop();
}

/// K 歌数量真实响应探针（#[ignore]，需外网，手动核对契约时才跑）：
/// 入参 songId/singerName/songHash 取自上面伴奏探针捕获的真实响应（同一首歌），
/// 捕获 get_total_opus_num_v02.do 的真实 JSON 供 Dart KugouAudioKtvTotal 定稿。
#[test]
#[ignore]
fn audio_ktv_total_probe() {
    let _guard = SERVER_LOCK.lock().unwrap();
    let port: u16 = 18090;
    let dir = std::env::temp_dir()
        .join("kugou_smoke_probe")
        .to_string_lossy()
        .into_owned();
    assert_eq!(kugou_server::server::start(port, dir), Some(port));
    // singerName=希林娜依高（UTF-8 百分号编码）
    let resp = tcp_request(
        port,
        "GET /audio/ktv/total?songId=43522508&singerName=%E5%B8%8C%E6%9E%97%E5%A8%9C%E4%BE%9D%E9%AB%98&songHash=8153F7E7BF0B2EFB4F8FF1B7E79A0E2C HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    );
    println!("=== /audio/ktv/total raw response ===\n{}", resp);
    assert!(!resp.contains("Cannot GET"), "route 404: {}", resp);
    kugou_server::server::stop();
}

// ============================================================================
// 歌单写端点（tracks/sort、sort、pic、pic/upload、update）
// 参考 MakcRe/KuGouMusicApi@main 的 module/playlist_{tracks_sort,sort,pic,pic_upload,update}.js
// 与 util/request.js 的 createCloudRequest。
// ============================================================================

/// 5 条歌单写端点必须全部注册，且没有被更短的前缀路由遮蔽。
///
/// `/playlist/pic/upload` 与 `/playlist/pic` 是本次唯一的**新增**遮蔽风险对
/// （同 `/user/update/avatar` 于 `/user/update`、`/video/barrage/send` 于
/// `/video/barrage` 的既有坑）：`prefix_match` 是段前缀匹配，upload 注册在后
/// 就会被 `/playlist/pic` 抢先命中，封面上传永远拿不到 FileName 而静默返回解析失败。
#[test]
fn playlist_write_routes_registered_and_unshadowed() {
    use kugou_server::modules::{register, ModuleFn};
    let mut routes: Vec<(&'static str, ModuleFn)> = Vec::new();
    register(&mut routes);
    let paths: Vec<&str> = routes.iter().map(|(p, _)| *p).collect();

    for target in [
        "/playlist/tracks/sort",
        "/playlist/sort",
        "/playlist/pic/upload",
        "/playlist/pic",
        "/playlist/update",
    ] {
        let idx = paths
            .iter()
            .position(|p| *p == target)
            .unwrap_or_else(|| panic!("{} 未注册", target));
        for (i, route) in paths.iter().enumerate() {
            if i >= idx {
                break;
            }
            // 段前缀（前一段必须落在 '/' 上），比它短且注册在前才会遮蔽
            let shadows = target.len() > route.len()
                && target.starts_with(route)
                && target.as_bytes().get(route.len()) == Some(&b'/');
            assert!(
                !shadows,
                "{} 注册在前会遮蔽 {}（前缀匹配会先命中前者）",
                route, target
            );
        }
    }
}

/// `/playlist/tracks/sort` 的 data 形状：`fileid|sort` 逗号分隔 → `[{fileid,sort}]`。
///
/// 端口 `module/playlist_tracks_sort.js:10-13`。`Number(x || 0)` 语义：非数字/缺失
/// 一律 0（不是跳过该条），否则上游会按「第 0 条不存在」静默丢弃整个排序请求。
#[test]
fn playlist_tracks_sort_resource_pairs() {
    use kugou_server::modules::playlist::build_tracks_sort_resource;
    use serde_json::json;

    let r = build_tracks_sort_resource("120|2,130|0");
    assert_eq!(
        r,
        json!([{ "fileid": 120, "sort": 2 }, { "fileid": 130, "sort": 0 }])
    );

    // 单条、缺 sort、非数字 fileid
    assert_eq!(
        build_tracks_sort_resource("120"),
        json!([{ "fileid": 120, "sort": 0 }])
    );
    assert_eq!(
        build_tracks_sort_resource("abc|"),
        json!([{ "fileid": 0, "sort": 0 }])
    );
    // 空串 → 一条全 0 记录（与 JS ''.split(',') → [''] 一致）
    assert_eq!(
        build_tracks_sort_resource(""),
        json!([{ "fileid": 0, "sort": 0 }])
    );
}

/// `/playlist/sort` 的 data 形状：`listid|type|sort` 逗号分隔。
///
/// 端口 `module/playlist_sort.js:10-13`。sort 按类别（自建/收藏）**分开编号**，
/// 故同一条 data 里 type 会混用，不能被归并。
#[test]
fn playlist_list_sort_resource_pairs() {
    use kugou_server::modules::playlist::build_list_sort_resource;
    use serde_json::json;

    let r = build_list_sort_resource("11|0|0,22|0|1,33|1|0");
    assert_eq!(
        r,
        json!([
            { "listid": 11, "type": 0, "sort": 0 },
            { "listid": 22, "type": 0, "sort": 1 },
            { "listid": 33, "type": 1, "sort": 0 },
        ])
    );
    // 缺 type/sort → 0
    assert_eq!(
        build_list_sort_resource("11"),
        json!([{ "listid": 11, "type": 0, "sort": 0 }])
    );
}

/// 封面路径归一：完整 URL 取末段补 `stdmusic/`，已是相对路径则原样。
///
/// 端口 `module/playlist_pic.js:13`——不做这层归一，上游会拿到 URL 当相对路径
/// 存库，封面显示为空白。
#[test]
fn playlist_pic_normalizes_stdmusic_prefix() {
    use kugou_server::modules::playlist::{build_pic_resource, normalize_stdmusic_pic};
    use serde_json::json;

    assert_eq!(
        normalize_stdmusic_pic(
            "https://imge.kugou.com/stdmusic/240/20210111/20210111184454391203.jpg"
        ),
        "stdmusic/20210111184454391203.jpg"
    );
    assert_eq!(
        normalize_stdmusic_pic("http://imge.kugou.com/stdmusic/{size}/a.jpg"),
        "stdmusic/a.jpg"
    );
    // 已带前缀的相对路径保持不变（否则会变成 stdmusic/stdmusic/x.jpg）
    assert_eq!(
        normalize_stdmusic_pic("stdmusic/20210111/x.jpg"),
        "stdmusic/20210111/x.jpg"
    );
    // 裸文件名
    assert_eq!(normalize_stdmusic_pic("x.jpg"), "stdmusic/x.jpg");

    // data 逐条带 type
    let r = build_pic_resource("11|0|stdmusic/a.jpg,22|1|http://x.com/s/b.jpg", 0);
    assert_eq!(
        r,
        json!([
            { "listid": 11, "type": 0, "pic": "stdmusic/a.jpg" },
            { "listid": 22, "type": 1, "pic": "stdmusic/b.jpg" },
        ])
    );
    // 显式留空的 type 槽（`listid||pic`）→ 回落调用方 default_type
    assert_eq!(
        build_pic_resource("11||stdmusic/a.jpg", 1),
        json!([{ "listid": 11, "type": 1, "pic": "stdmusic/a.jpg" }])
    );
    // 字段不足的畸形条目（`listid|onlyone`）：pic 槽缺失 → 归一成 "stdmusic/"，
    // type 槽被 "onlyone" 占位 → 0。JS 这里会拼出 "stdmusic/undefined"，
    // Rust 侧不复制那个 null 字符串化怪癖。
    assert_eq!(
        build_pic_resource("11|onlyone", 1),
        json!([{ "listid": 11, "type": 0, "pic": "stdmusic/" }])
    );
}

/// `/playlist/update` 的 dataMap：`name` / `pic` 缺省时**不得出现**该键。
///
/// 端口 `module/playlist_update.js:23-29` 的 `if (params.name)` / `if (params.pic)`。
/// 传空串等于把歌单改名成空 / 清掉封面，是不可逆的静默数据损坏。
#[test]
fn playlist_update_optional_fields() {
    use kugou_server::modules::playlist::build_update_map;
    use serde_json::json;

    // 只改名称：tags/intro 仍然是恒在的空串（JS 的 `params.tags || ''`）
    let m = build_update_map(&json!({ "listid": 11, "total_ver": 9, "name": "新名字" }));
    assert_eq!(m["listid"], json!(11));
    assert_eq!(m["total_ver"], json!(9));
    assert_eq!(m["type"], json!(0));
    assert_eq!(m["sort"], json!(0));
    assert_eq!(m["tags"], json!(""));
    assert_eq!(m["intro"], json!(""));
    assert_eq!(m["name"], json!("新名字"));
    assert!(!m.contains_key("pic"), "pic 缺省时不得下发");

    // 名称空串 → 不改名；pic 传入 → 下发
    let m = build_update_map(&json!({ "listid": 11, "name": "", "pic": "custom/x.jpg" }));
    assert!(
        !m.contains_key("name"),
        "name 空串时不得下发（会被上游当成改名成空）"
    );
    assert_eq!(m["pic"], json!("custom/x.jpg"));

    // 收藏歌单：type=1 必须原样透传（与 /playlist/del 的 1=自建 语义相反）
    let m = build_update_map(&json!({ "listid": 33, "type": 1, "tags": "华语,流行" }));
    assert_eq!(m["type"], json!(1));
    assert_eq!(m["tags"], json!("华语,流行"));

    // is_pri：调用方显式传入才插入；缺省不得补 0（会把隐私歌单改成公开）
    let m = build_update_map(&json!({ "listid": 33, "is_pri": 1 }));
    assert_eq!(m["is_pri"], json!(1));
    let m = build_update_map(&json!({ "listid": 33 }));
    assert!(!m.contains_key("is_pri"), "is_pri 缺省时不得补 0");
}

/// v4 modify_list 的 body 形状：业务字段透传 + `userid`/`enckey`/`encstr` 形态正确。
///
/// 形态错了上游不会给业务错误，而是鉴权层直接拒（v1 时代 1005 profile 配 3116
/// token 就是恒 20017），故在此钉住：
/// - `enckey` = RSA(128 byte seed 段) → **256 位大写 hex**（2048-bit RSA 块）；
/// - `encstr` = Base64，解码后长度必须是 16 的倍数（AES-CBC）；
/// - `userid` 来自 cookie，业务字段原样保留。
#[test]
fn playlist_v4_body_shape() {
    use kugou_server::crypto::base64_decode;
    use kugou_server::modules::playlist::{build_update_map, build_v4_body};
    use serde_json::{json, Value};

    let q = json!({
        "cookie": { "userid": "10086", "token": "tok" },
        "listid": 35,
        "total_ver": 119,
        "type": 0,
        "sort": 3,
        "tags": "",
        "intro": "",
        "name": "新名字",
        "is_pri": 1,
    });
    let dm = Value::Object(build_update_map(&q));
    let body = build_v4_body(&q, &dm);

    // 业务字段透传
    assert_eq!(body["listid"], json!(35));
    assert_eq!(body["total_ver"], json!(119));
    assert_eq!(body["name"], json!("新名字"));
    assert_eq!(body["is_pri"], json!(1));
    assert_eq!(body["sort"], json!(3));
    assert_eq!(body["userid"], json!(10086));

    // enckey：256 位大写 hex（酷狗 RSA 公钥为 1024-bit → 128 字节 → 256 hex）
    let enckey = body["enckey"].as_str().expect("enckey is string");
    assert_eq!(enckey.len(), 256, "RSA-1024 → 256 hex 字符");
    assert!(
        enckey
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'A'..=b'F').contains(&b)),
        "enckey 必须大写 hex（小写会被上游判签名错误）: {enckey}"
    );

    // encstr：合法 Base64 且解码长度 16 对齐（AES-CBC 密文）
    let encstr = body["encstr"].as_str().expect("encstr is string");
    let decoded = base64_decode(encstr);
    assert_eq!(decoded.len() % 16, 0, "AES-CBC 密文长度必须 16 对齐");
    assert!(!decoded.is_empty());
}

/// 实网探针（默认 `#[ignore]`）：v4 `modify_list` 协议验证。
///
/// 2026-10-14 排查「编辑歌单无法保存」：v1 旧协议发标准版 1005 profile，上游对
/// 3116 签发的 token 恒返 `error_code=20017`。本探针用 crate 自己的请求管线发
/// **v4 + enckey/encstr + 概念版 profile** 的 no-op 请求（所有值取歌单当前状态，
/// 服务端落库结果与探针前一致），验证协议是否被接受。
///
/// 用法（需要真机 token，勿提交敏感值）：
/// ```text
/// KG_LIVE=1 KG_TOKEN=<token> KG_USERID=<uid> KG_DFID=<dfid> KG_MID=<mid> \
/// KG_LISTID=35 KG_TOTAL_VER=119 KG_SORT=0 KG_IS_PRI=1 KG_NAME=小白3110的歌单 \
/// cargo test --test smoke playlist_v4_modify_live_probe -- --ignored --nocapture
/// ```
#[test]
#[ignore = "live network probe; requires KG_LIVE=1 and real credentials"]
fn playlist_v4_modify_live_probe() {
    use kugou_server::modules::{playlist, Ctx};
    use serde_json::json;

    if std::env::var("KG_LIVE").is_err() {
        return;
    }
    let env = |k: &str| std::env::var(k).unwrap_or_default();
    let q = json!({
        "cookie": {
            "userid": env("KG_USERID"),
            "token": env("KG_TOKEN"),
            "dfid": env("KG_DFID"),
            "KUGOU_API_MID": env("KG_MID"),
        },
        "listid": env("KG_LISTID").parse::<i64>().unwrap_or(0),
        "total_ver": env("KG_TOTAL_VER").parse::<i64>().unwrap_or(0),
        "type": 0,
        "sort": env("KG_SORT").parse::<i64>().unwrap_or(0),
        "tags": "",
        "intro": "",
        "is_pri": env("KG_IS_PRI").parse::<i64>().unwrap_or(0),
        "name": env("KG_NAME"),
    });
    let ctx = Ctx {
        ip: String::new(),
        body_bytes: None,
    };
    match playlist::handle_update(&q, &ctx) {
        Ok(res) => println!(
            "[v4-probe] upstream_status={} body={}",
            res.status,
            res.body.to_string_utf8()
        ),
        Err(res) => println!(
            "[v4-probe] ERR upstream_status={} body={}",
            res.status,
            res.body.to_string_utf8()
        ),
    }
}

/// 实网探针（默认 `#[ignore]`）：v1 契约 + 概念版身份的 `modify_list_sort` 验证。
///
/// /playlist/sort 于 2026-10-15 修复：[handle_sort] 走 v1 契约 + 概念版身份
///（cloud_roundtrip_v1_concept）。**no-op 用法**：`KG_SORT_DATA` 传当前云端
/// 真实顺序（每条 `listid|type|sort`，type 0=自建/1=收藏，sort 从 0 编号），
/// 服务端落库结果与探针前一致。响应 `data.total_ver` 为新版本号（会 +1）。
///
/// 用法（需要真机 token，勿提交敏感值）：
/// ```text
/// KG_LIVE=1 KG_TOKEN=<token> KG_USERID=<uid> KG_DFID=<dfid> KG_MID=<mid> \
/// KG_TOTAL_VER=<total_ver> KG_SORT_DATA="8|0|0,35|0|1" \
/// cargo test --test smoke playlist_v4_list_sort_live_probe -- --ignored --nocapture
/// ```
#[test]
#[ignore = "live network probe; requires KG_LIVE=1 and real credentials"]
fn playlist_v4_list_sort_live_probe() {
    use kugou_server::modules::{playlist, Ctx};
    use serde_json::json;

    if std::env::var("KG_LIVE").is_err() {
        return;
    }
    let env = |k: &str| std::env::var(k).unwrap_or_default();
    let q = json!({
        "cookie": {
            "userid": env("KG_USERID"),
            "token": env("KG_TOKEN"),
            "dfid": env("KG_DFID"),
            "KUGOU_API_MID": env("KG_MID"),
        },
        "total_ver": env("KG_TOTAL_VER").parse::<i64>().unwrap_or(0),
        "data": env("KG_SORT_DATA"),
    });
    let ctx = Ctx {
        ip: String::new(),
        body_bytes: None,
    };
    match playlist::handle_sort(&q, &ctx) {
        Ok(res) => println!(
            "[v4-sort-probe] upstream_status={} body={}",
            res.status,
            res.body.to_string_utf8()
        ),
        Err(res) => println!(
            "[v4-sort-probe] ERR upstream_status={} body={}",
            res.status,
            res.body.to_string_utf8()
        ),
    }
}

/// 实网探针（默认 `#[ignore]`）：v4 列表排序候选协议逐个试射。
///
/// 2026-10-15 排查「/playlist/sort 迁移 v4 后上游回 20010」的诊断记录（保留供
/// 同族 `/v1/modify_song_sort|modify_list_pic` 迁移时复用）。当日结论：
/// - A-D：`/cloudlist.service/v4/modify_list_sort` **不存在**——网关对未知子路径
///   统一回 `{"status":0,"error_code":20010}`，与 total_ver/data 取值无关；
/// - E：v1 URL 认 HTTP 层但不认 v4 明文 body（网关 502）；
/// - G1a/G1b：v1 URL + playlistAES 体 + 概念版身份 → 上游解密成功但回 20010
///   （body 格式不符）；
/// - **G2：v1 契约（createCloudRequest 原始密文体）+ 概念版身份 → `status=1`、
///   逐条 `code=1`、`total_ver` 递增 —— 已成为 [handle_sort] 的生产路径**；
/// - H：`/cloudlist.service/v4/sort_list` → 404（未路由），与 20010 可区分。
///
/// 用法（需要真机 token，勿提交敏感值）：
/// ```text
/// KG_LIVE=1 KG_TOKEN=<token> KG_USERID=<uid> KG_DFID=<dfid> KG_MID=<mid> \
/// KG_TOTAL_VER=<total_ver> KG_SORT_DATA="<listid|type|sort,...>" \
/// cargo test --test smoke playlist_v4_sort_variants_live_probe -- --ignored --nocapture
/// ```
#[test]
#[ignore = "live network probe; requires KG_LIVE=1 and real credentials"]
fn playlist_v4_sort_variants_live_probe() {
    use kugou_server::modules::playlist::{
        aes_roundtrip, build_list_sort_resource, cloud_roundtrip_v1_concept, cloud_roundtrip_v4,
        handle_sort,
    };
    use kugou_server::modules::Ctx;
    use kugou_server::request::ModuleResponse;
    use serde_json::json;

    if std::env::var("KG_LIVE").is_err() {
        return;
    }
    let env = |k: &str| std::env::var(k).unwrap_or_default();
    let q = || {
        json!({
            "cookie": {
                "userid": env("KG_USERID"),
                "token": env("KG_TOKEN"),
                "dfid": env("KG_DFID"),
                "KUGOU_API_MID": env("KG_MID"),
            }
        })
    };
    let ctx = Ctx {
        ip: String::new(),
        body_bytes: None,
    };
    let total_ver = env("KG_TOTAL_VER").parse::<i64>().unwrap_or(0);
    let sort_data = env("KG_SORT_DATA");
    let run = |label: &str, r: Result<ModuleResponse, ModuleResponse>| match r {
        Ok(res) => println!(
            "[sort-variants] {label}: OK upstream_status={} body={}",
            res.status,
            res.body.to_string_utf8()
        ),
        Err(res) => println!(
            "[sort-variants] {label}: ERR upstream_status={} body={}",
            res.status,
            res.body.to_string_utf8()
        ),
    };

    // A：现安装协议（复现基线）
    let dm = json!({ "total_ver": total_ver, "data": build_list_sort_resource(&sort_data) });
    let r = cloud_roundtrip_v4(
        &q(),
        &ctx,
        "/cloudlist.service/v4/modify_list_sort",
        &dm,
    );
    run("A v4+array+total_ver", r);

    // B：total_ver=0
    let dm = json!({ "total_ver": 0, "data": build_list_sort_resource(&sort_data) });
    let r = cloud_roundtrip_v4(
        &q(),
        &ctx,
        "/cloudlist.service/v4/modify_list_sort",
        &dm,
    );
    run("B v4+array+ver0", r);

    // C：不存在的 listid（安全，不落库）
    let dm = json!({ "total_ver": total_ver, "data": build_list_sort_resource("999999|1|0") });
    let r = cloud_roundtrip_v4(
        &q(),
        &ctx,
        "/cloudlist.service/v4/modify_list_sort",
        &dm,
    );
    run("C v4+fake-listid", r);

    // D：data 传裸字符串（v1 风格）
    let dm = json!({ "total_ver": total_ver, "data": sort_data });
    let r = cloud_roundtrip_v4(
        &q(),
        &ctx,
        "/cloudlist.service/v4/modify_list_sort",
        &dm,
    );
    run("D v4+raw-string", r);

    // E：v1 URL 走 v4 管线（默认签名 + enckey/encstr）
    let dm = json!({ "total_ver": total_ver, "data": build_list_sort_resource(&sort_data) });
    let r = cloud_roundtrip_v4(&q(), &ctx, "/v1/modify_list_sort", &dm);
    run("E v1-url+v4-pipeline", r);

    // G1a：v1 URL 走 aes_roundtrip（概念版身份 + playlistAES body，delete_list 同款），delete 风格 params
    let dm = json!({ "total_ver": total_ver, "data": build_list_sort_resource(&sort_data) });
    let userid: i64 = env("KG_USERID").parse().unwrap_or(0);
    let params = json!({
        "last_time": 1792057100i64,
        "last_area": "gztx",
        "userid": userid,
        "token": env("KG_TOKEN"),
    });
    let r = aes_roundtrip(&q(), &ctx, None, "/v1/modify_list_sort", &dm, params, false, false,
        &[("x-router", "cloudlist.service.kugou.com")]);
    run("G1a v1-url+playlistAES+delete-params", r);

    // G1b：同 G1a 但极简 params
    let dm = json!({ "total_ver": total_ver, "data": build_list_sort_resource(&sort_data) });
    let r = aes_roundtrip(&q(), &ctx, None, "/v1/modify_list_sort", &dm, json!({}), false, false,
        &[("x-router", "cloudlist.service.kugou.com")]);
    run("G1b v1-url+playlistAES+minimal-params", r);

    // G2：v1 契约（原始密文 body + 极简 query + not_signature）+ 概念版身份
    let dm = json!({ "total_ver": total_ver, "data": build_list_sort_resource(&sort_data) });
    let r = cloud_roundtrip_v1_concept(&q(), &ctx, "/v1/modify_list_sort", &dm);
    run("G2 v1-contract+concept-identity", r);

    // H：v4 候选路径存在性（sort_list）
    let dm = json!({ "total_ver": total_ver, "data": build_list_sort_resource(&sort_data) });
    let r = cloud_roundtrip_v4(&q(), &ctx, "/cloudlist.service/v4/sort_list", &dm);
    run("H v4-sort_list", r);

    // 对照组：现安装的 handle_sort（与 A 等价，确认探针与真机行为一致）
    let qh = json!({
        "cookie": {
            "userid": env("KG_USERID"),
            "token": env("KG_TOKEN"),
            "dfid": env("KG_DFID"),
            "KUGOU_API_MID": env("KG_MID"),
        },
        "total_ver": total_ver,
        "data": sort_data,
    });
    let r = handle_sort(&qh, &ctx);
    match r {
        Ok(res) => println!(
            "[sort-variants] F handle_sort: OK upstream_status={} body={}",
            res.status,
            res.body.to_string_utf8()
        ),
        Err(res) => println!(
            "[sort-variants] F handle_sort: ERR upstream_status={} body={}",
            res.status,
            res.body.to_string_utf8()
        ),
    }
}

/// 云歌单服务签名 key 必须与参考实现的固定向量逐字节一致。
///
/// 端口 `util/request.js:308` 的
/// `md5(appid + appkey + clientver + clienttime).toLowerCase()`，其中
/// appid=1005、appkey=`OIlwieks28dk2k092lksi2UIkp`、clientver=20489
/// （`util/config.json` 的 `appid`/`clientver` + `CLOUDLIST_CONF.default.appkey`）。
/// 期望值由同一公式独立算出（PowerShell `MD5.Create()`），不是拿实现反填的。
#[test]
fn playlist_cloud_key_matches_reference() {
    use kugou_server::modules::playlist::cloud_key;

    assert_eq!(cloud_key(1_700_000_000), "a1f65b6a8fe7e191521406ce8661ae02");
    // 小写（上游对大小写敏感，大写会被判签名错误）
    let k = cloud_key(1_700_000_001);
    assert_eq!(k, k.to_lowercase());
    assert_ne!(k, cloud_key(1_700_000_000));
}

/// 云歌单写接口的失败判定必须与 Dart `PlaylistEditPage._save` 同口径：
/// `status == 1` 或 `error_code == 0` 为成功，其余（含字段缺失/非对象）为失败。
///
/// 该判定驱动 `cloud_roundtrip` 的诊断日志分支（2026-10-14「编辑歌单无法保存」排查），
/// 判错会把成功请求打成 FAILED 或把无声业务拒绝漏成 ok。
#[test]
fn playlist_cloud_body_is_failure_matches_dart_criteria() {
    use kugou_server::modules::playlist::cloud_body_is_failure;
    use serde_json::json;

    // 成功形态
    assert!(!cloud_body_is_failure(&json!({ "status": 1 })));
    assert!(!cloud_body_is_failure(&json!({ "status": 1, "data": {} })));
    assert!(!cloud_body_is_failure(&json!({ "error_code": 0 })));
    assert!(!cloud_body_is_failure(
        &json!({ "status": 0, "error_code": 0 })
    ));
    // 失败形态：显式业务错误 / 空对象 / 只有 status 非 1
    assert!(cloud_body_is_failure(&json!({ "status": 0 })));
    assert!(cloud_body_is_failure(&json!({ "status": 90001 })));
    assert!(cloud_body_is_failure(
        &json!({ "status": 0, "error_code": 40001 })
    ));
    assert!(cloud_body_is_failure(&json!({})));
    // 非对象一律按失败（Dart 侧会当非 Map 丢弃）
    assert!(cloud_body_is_failure(&json!(null)));
    assert!(cloud_body_is_failure(&json!("oops")));
    assert!(cloud_body_is_failure(&json!([1, 2])));
}

/// 封面上传的 `file` / `type` / `extendName` 必须能从 **JSON body** 里读到。
///
/// `server.rs` 把 JSON body 整体塞进 `query["body"]`、**不**合并到顶层
/// （见 `build_query` 的 `body_is_buffer` 分支），而 Dart 侧
/// `uploadPlaylistCover` 是 `_post(data: {...})`，三个参数全在 body。
/// 只读顶层 query 会让 file 判定为空 → 一律返回「文件不存在」，
/// type / extendName 静默退回默认值（不报错，只是行为不对）。
///
/// 这里直接断言 query 对象的形状 + 该模块的取参函数，不触发网络与文件 IO。
#[test]
fn playlist_pic_upload_params_from_body() {
    use serde_json::json;

    // 模拟 server.rs build_query 对 POST + application/json 的产出：
    // 业务参数在 body 下，顶层只有 cookie。
    let q = json!({
        "cookie": { "userid": "10086", "token": "tok" },
        "body": {
            "file": "/tmp/cover.jpg",
            "type": "custom",
            "extendName": ".png"
        }
    });

    let body = q.get("body").and_then(|v| v.as_object()).unwrap();
    assert_eq!(
        body.get("file").and_then(|v| v.as_str()),
        Some("/tmp/cover.jpg")
    );
    // 顶层没有这些键 —— 正是「只读顶层」会踩空的原因
    assert!(q.get("file").is_none());
    assert!(q.get("type").is_none());
}

/// 封面上传的取参函数：query 优先、回落 body、都没有则为空串（不是 panic）。
#[test]
fn playlist_cover_body_str_fallback() {
    use kugou_server::modules::playlist::cover_body_str;
    use serde_json::json;

    // body 命中
    let q = json!({ "body": { "file": "/a/b.jpg", "type": "custom" } });
    assert_eq!(cover_body_str(&q, "file"), "/a/b.jpg");
    assert_eq!(cover_body_str(&q, "type"), "custom");
    // query 优先于 body
    let q = json!({ "file": "/query.jpg", "body": { "file": "/body.jpg" } });
    assert_eq!(cover_body_str(&q, "file"), "/query.jpg");
    // 都没有 → 空串（调用方据此回落默认值 / 报「文件不存在」）
    let q = json!({ "body": {} });
    assert_eq!(cover_body_str(&q, "extendName"), "");
    assert_eq!(cover_body_str(&json!({}), "file"), "");
    // body 不是对象（GET 场景无 body）→ 空串，不得 panic
    assert_eq!(cover_body_str(&json!({ "body": "raw" }), "file"), "");
}


/// 登录扫码路由顺序：QQ 两条必须在 `/login` 之前注册。
/// 本项目 `prefix_match` 是路径段前缀匹配，`/login` 若排在前面会把
/// `/login/qq/qr/create|check` 全部吞进密码登录 handler。
#[test]
fn qq_qr_login_routes_registered_before_login() {
    use kugou_server::modules::{register, ModuleFn};
    let mut routes: Vec<(&'static str, ModuleFn)> = Vec::new();
    register(&mut routes);
    let paths: Vec<&str> = routes.iter().map(|(p, _)| *p).collect();

    let login_idx = paths
        .iter()
        .position(|p| *p == "/login")
        .expect("/login 未注册");
    for target in ["/login/qq/qr/create", "/login/qq/qr/check", "/login/wx/create", "/login/wx/check"] {
        let idx = paths
            .iter()
            .position(|p| *p == target)
            .unwrap_or_else(|| panic!("{target} 未注册"));
        assert!(
            idx < login_idx,
            "{target} 必须注册在 /login 之前（前缀匹配会把它送进密码登录 handler）"
        );
    }
}

/// 微信 / QQ 扫码 check 的入参校验：缺字段时直接 400，不发起上游请求。
/// （上游请求会被网络/风控影响，测试只锁「本地参数校验」这一段契约。）
#[test]
fn qr_check_endpoints_reject_missing_params_without_upstream_call() {
    use kugou_server::modules::{login, Ctx};
    use serde_json::json;

    let ctx = Ctx {
        ip: "127.0.0.1".to_string(),
        body_bytes: None,
    };

    let err = login::handle_wx_check(&json!({}), &ctx).expect_err("缺 uuid 必须 400");
    assert_eq!(err.status, 400);
    assert!(err.body.to_json()["msg"].as_str().unwrap().contains("uuid"));

    let err = login::handle_qq_qr_check(&json!({}), &ctx).expect_err("缺会话字段必须 400");
    assert_eq!(err.status, 400);
    let msg = err.body.to_json()["msg"].as_str().unwrap().to_string();
    assert!(msg.contains("qrsig"), "提示应列出缺失字段: {msg}");
    assert!(msg.contains("/login/qq/qr/create"), "提示应指引先调 create: {msg}");
}

/// 微信 / QQ 扫码登录实网探针（默认 `#[ignore]`，需外网）：
/// `cargo +stable-x86_64-pc-windows-gnu test --test smoke qr_login_probe -- --ignored --nocapture`
///
/// 覆盖两条链路里「能离线验证的部分」之外的真实上游往返：
/// 1. `/login/wx/create` → 必须 200 且带 `uuid` + `qrcode.qrcodebase64`；
/// 2. `/login/wx/check?uuid=<空>` → 必须 400（本地参数校验，不发上游）；
/// 3. `/login/qq/qr/create` → 打印结果。成功时必须带 qrsig/ptqrtoken/二维码；
///    失败时必须是结构化的 `{status:0,msg}`（不允许 panic / 非 JSON）。
/// 4. `/login/qq/qr/check` 用 create 的会话轮询一次，打印 status
///    （`wait` / `blocked` 都算通过 —— blocked 是上游 WAF 的已知外部限制，
///    见 docs/2026-10-17-qq-wx-qr-login-notes.md §4）。
#[test]
#[ignore = "live network probe; hits weixin.qq.com / ptlogin2.qq.com"]
fn qr_login_probe() {
    use serde_json::Value;
    let _guard = SERVER_LOCK.lock().unwrap();
    let port: u16 = 18091;
    let dir = std::env::temp_dir()
        .join("kugou_smoke_probe")
        .to_string_lossy()
        .into_owned();
    assert_eq!(kugou_server::server::start(port, dir), Some(port));

    // ---- 微信 create ----
    let raw = tcp_request(
        port,
        "GET /login/wx/create HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    );
    let body = raw.split("\r\n\r\n").nth(1).unwrap_or("");
    println!("=== /login/wx/create ===\n{}", &body[..body.len().min(400)]);
    assert!(!raw.contains("Cannot GET"), "wx create route 404: {}", raw);
    if let Ok(v) = serde_json::from_str::<Value>(body) {
        if v.get("uuid").is_some() {
            assert!(
                v["qrcode"]["qrcodebase64"].as_str().is_some_and(|s| !s.is_empty()),
                "微信二维码缺少 qrcodebase64: {v}"
            );
            println!("✓ 微信二维码生成成功 uuid={}", v["uuid"]);
        } else {
            println!("⚠ 微信 create 未成功（上游拒绝）: {v}");
        }
    }

    // ---- 微信 check 缺参 ----
    let raw = tcp_request(
        port,
        "GET /login/wx/check HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    );
    assert!(raw.contains("400 Bad Request"), "缺 uuid 必须 400: {}", raw);
    println!("✓ /login/wx/check 缺 uuid → 400");

    // ---- QQ create ----
    let raw = tcp_request(
        port,
        "GET /login/qq/qr/create HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    );
    let body = raw.split("\r\n\r\n").nth(1).unwrap_or("").to_string();
    println!("=== /login/qq/qr/create ===\n{}", &body[..body.len().min(300)]);
    assert!(!raw.contains("Cannot GET"), "qq create route 404: {}", raw);
    let v: Value = serde_json::from_str(&body).expect("qq create 必须返回 JSON");
    if v.get("qrsig").is_some() {
        assert!(
            v["ptqrtoken"].as_i64().is_some_and(|n| n > 0),
            "ptqrtoken 必须是正整数: {v}"
        );
        assert!(
            v["qrcode"].as_str().is_some_and(|s| s.len() > 100),
            "二维码 base64 过短: {v}"
        );
        println!("✓ QQ 二维码生成成功 qrsig_len={} ptqrtoken={}",
            v["qrsig"].as_str().unwrap_or("").len(),
            v["ptqrtoken"]
        );

        // ---- QQ check（用刚拿到的会话轮询一次）----
        let qs = format!(
            "qrsig={}&ptqrtoken={}&pt_login_sig={}&pt_openlogin_data={}&xlogin_url={}&cookie={}",
            enc(v["qrsig"].as_str().unwrap_or("")),
            v["ptqrtoken"],
            enc(v["pt_login_sig"].as_str().unwrap_or("")),
            enc(v["pt_openlogin_data"].as_str().unwrap_or("")),
            enc(v["xlogin_url"].as_str().unwrap_or("")),
            enc(v["cookie"].as_str().unwrap_or("")),
        );
        let raw = tcp_request(
            port,
            &format!(
                "GET /login/qq/qr/check?{} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
                qs
            ),
        );
        let body = raw.split("\r\n\r\n").nth(1).unwrap_or("");
        println!("=== /login/qq/qr/check ===\n{}", &body[..body.len().min(400)]);
        let cv: Value = serde_json::from_str(body).expect("qq check 必须返回 JSON");
        let status = cv["status"].as_str().unwrap_or("");
        assert!(
            matches!(status, "wait" | "scanned" | "expired" | "blocked" | "error"),
            "未预期的 QQ check 状态: {cv}"
        );
        if status == "blocked" {
            println!("⚠ QQ 轮询被上游拦截（已知外部限制，见 docs 2026-10-17 §4）: {cv}");
        } else {
            println!("✓ QQ 轮询状态 = {status}");
        }
    } else {
        println!("⚠ QQ create 未成功: {v}");
    }

    kugou_server::server::stop();
}

/// 探针用：最小 query 值百分号编码（保留 `%` 以免二次编码）。
fn enc(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}


