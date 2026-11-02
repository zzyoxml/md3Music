//! playlist 系列：add / del / detail / effect / similar / tags /
//! track_all / track_all_new / tracks_add / tracks_del /
//! tracks_sort / sort / pic / pic_upload / update
//! 对应 JS module/playlist*.js

use crate::cache::now_epoch_secs;
use crate::config::{APP_ID, CLIENT_VER};
use crate::crypto::{
    aes_cbc_encrypt, base64_encode, hex_encode, md5_hex, md5_hex_str, playlist_aes_decrypt,
    playlist_aes_encrypt, rsa_encrypt2, rsa_pkcs1v15_encrypt, PUBLIC_LITE_RAS_KEY, PUBLIC_RAS_KEY,
};
use crate::helper::sign_params_key;
use crate::modules::user::{beijing_ymd, image_mime, UPLOAD_SALT};
use crate::modules::{
    c_str, cookie_or_param_str, forward, param_or_cookie_str, q_cookie, q_num, q_str, Ctx,
};
use crate::request::{BodyValue, ModuleResponse, RequestOptions};
use crate::util::{json_stringify, random_string_lower};
use serde_json::{json, Map, Value};

/// 云歌单服务（cloudlist）写接口的 appid / clientver / 签名盐。
///
/// 三方对照（参考 MakcRe/KuGouMusicApi@main `util/request.js:34` 的 `CLOUDLIST_CONF.default`
/// 与 `util/config.json`）：这 5 个 `/v1/modify_*` 端点与 `/playlist/del` 的 `/v2/delete_list`
/// **不是同一套协议**，参考仓库为它们单独写了 `createCloudRequest`（标准版 appid 1005 /
/// clientver 20489 / 标准盐 / 标准 RSA 公钥 / 原始密文字节），而旧的 `playlistAesEncrypt`
/// 那套（概念版 3116/11440 + lite 盐 + base64 body）只服务 `/playlist/add|del` 等老端点。
/// 故本文件的写端点走 [cloud_roundtrip]，既有 [aes_roundtrip] 保持原样不动。
const CLOUD_APP_ID: &str = "1005";
const CLOUD_CLIENT_VER: &str = "20489";
const CLOUD_APP_KEY: &str = "OIlwieks28dk2k092lksi2UIkp";

/// 封面上传文件大小上限（5 MB）。图片经相册选图后已压缩到 1024px，5MB 很宽松；
/// 上限的意义是挡住误传的视频/大图把请求体撑爆。
const MAX_COVER_UPLOAD_BYTES: u64 = 5 * 1024 * 1024;

fn now_secs() -> i64 {
    now_epoch_secs() as i64
}

/// JS `params.x || default`（0 → default）。
fn or_num(q: &Value, key: &str, default: i64) -> i64 {
    q_num(q, key, default)
}

/// JS `params.x ?? default`（仅 null/undefined → default，0 保留）。
fn or_num_nullish(q: &Value, key: &str, default: i64) -> i64 {
    match q.get(key) {
        None | Some(Value::Null) => default,
        Some(Value::Number(n)) => n.as_i64().unwrap_or(default),
        Some(Value::String(s)) => {
            if s.trim().is_empty() {
                default
            } else {
                s.trim().parse().unwrap_or(default)
            }
        }
        Some(Value::Bool(b)) => {
            if *b {
                1
            } else {
                default
            }
        }
        _ => default,
    }
}

/// JS `params.source === 0 ? 0 : params.source || 1`。
fn source_0_or_1(q: &Value) -> i64 {
    match q.get("source") {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(1),
        Some(Value::String(s)) => {
            if s.trim().is_empty() {
                1
            } else {
                s.trim().parse().unwrap_or(1)
            }
        }
        _ => 1,
    }
}

/// 通用 playlistAES + rsaEncrypt2 加密后的 arraybuffer 请求，解密回 JSON。
pub fn aes_roundtrip(
    q: &Value,
    ctx: &Ctx,
    base_url: Option<&str>,
    url: &str,
    data_obj: &Value,
    params: Value,
    clear_default_params: bool,
    not_signature: bool,
    headers: &[(&str, &str)],
) -> Result<ModuleResponse, ModuleResponse> {
    let userid: i64 = param_or_cookie_str(q, "userid", "0")
        .trim()
        .parse()
        .unwrap_or(0);
    let token = param_or_cookie_str(q, "token", "");
    let (key, aes_str) = playlist_aes_encrypt(&json_stringify(data_obj));
    let p = rsa_encrypt2(&json_stringify(&json!({ "aes": key, "uid": userid, "token": token })))
        .to_uppercase();
    let clienttime = now_secs();
    let mut pm: Map<String, Value> = Map::new();
    if let Some(om) = params.as_object() {
        for (k, v) in om {
            pm.insert(k.clone(), v.clone());
        }
    }
    pm.insert("clienttime".to_string(), json!(clienttime));
    pm.insert(
        "key".to_string(),
        json!(sign_params_key(&clienttime.to_string(), APP_ID, "")),
    );
    pm.insert("clientver".to_string(), json!(CLIENT_VER));
    pm.insert("appid".to_string(), json!(APP_ID));
    pm.insert("p".to_string(), json!(p));

    let mut opts = RequestOptions::new(url);
    if let Some(b) = base_url {
        opts = opts.base_url(b);
    }
    opts = opts
        .post(url)
        .params(Value::Object(pm))
        .string_body(aes_str)
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .response_type("arraybuffer");
    // 酷狗网关 gateway.kugou.com 靠 x-router 头把请求分发到后端服务，
    // 缺失时网关无法路由直接回显 URL 拒绝（502）。与 playlist_del.js 对齐。
    for (k, v) in headers {
        opts = opts.header(k, v);
    }
    if clear_default_params {
        opts = opts.clear_default_params(true);
    }
    if not_signature {
        opts = opts.not_signature(true);
    }

    let res = ctx.send(&opts)?;
    let dec = playlist_aes_decrypt(&key, &res.body.to_base64());
    Ok(ModuleResponse {
        status: res.status,
        body: BodyValue::Json(dec),
        cookie: res.cookie,
        headers: res.headers,
    })
}

/// 云歌单服务签名 key：`md5(appid + appkey + clientver + clienttime)`，小写 hex。
///
/// 参考 `util/request.js:308` 的 `cryptoMd5(`${conf.appid}${conf.appkey}${conf.clientver}${clienttime}`).toLowerCase()`。
/// 与 [aes_roundtrip] 用的 `sign_params_key`（概念版盐）是两套，见 [CLOUD_APP_ID] 注释。
pub fn cloud_key(clienttime: i64) -> String {
    md5_hex(
        format!(
            "{}{}{}{}",
            CLOUD_APP_ID, CLOUD_APP_KEY, CLOUD_CLIENT_VER, clienttime
        )
        .as_bytes(),
    )
}

/// 云歌单写接口响应判定：`status != 1` 且 `error_code != 0` 即失败。
///
/// 与 Dart 侧 `PlaylistEditPage._save` 的 `status == 1 || error_code == 0`
/// 成功判定保持同口径；非对象（数组/标量/null）一律按失败处理——那种形态
/// 本来就会被 Dart 当非 Map 丢弃。
pub fn cloud_body_is_failure(body: &Value) -> bool {
    match body {
        Value::Object(m) => {
            m.get("status").and_then(Value::as_i64) != Some(1)
                && m.get("error_code").and_then(Value::as_i64) != Some(0)
        }
        _ => true,
    }
}

/// 诊断用：原始响应前 256 字节的可读化。全可打印 → 原样文本；否则转 hex，
/// 避免把二进制密文/乱码刷进 logcat。
fn diag_raw_prefix(bytes: &[u8]) -> String {
    const LIMIT: usize = 256;
    let slice = &bytes[..bytes.len().min(LIMIT)];
    let printable = slice
        .iter()
        .all(|b| matches!(b, b'\n' | b'\r' | b'\t') || (0x20..0x7f).contains(b));
    if printable {
        String::from_utf8_lossy(slice).into_owned()
    } else {
        hex_encode(slice)
    }
}

/// 诊断用：按字符截断（中文等多字节字符不截碎）。
fn diag_truncate(s: &str, limit: usize) -> String {
    if s.chars().count() <= limit {
        return s.to_string();
    }
    s.chars().take(limit).collect::<String>() + "…"
}

/// 云歌单（cloudlist）写接口的 playlistAES + rsaEncrypt2 加密往返。
///
/// 端口对应参考 `util/request.js:286` 的 `createCloudRequest`，服务
/// `/v1/modify_list_pic` 端点（歌曲及歌单排序已迁 [cloud_roundtrip_v1_concept]，
/// `/v1/modify_list` 已迁 [cloud_roundtrip_v4]）。
/// 与 [aes_roundtrip] 的差异（全部来自
/// `createCloudRequest`，见 [CLOUD_APP_ID] 注释）：
/// - appid/clientver/盐走标准版（1005/20489/`OIlwieks…`），`p` 用标准 RSA 公钥；
///   ⚠️ 与本 App 概念版 token 冲突（恒 20017），仅因同族端点尚未逐个迁移而保留；
/// - 请求体是**原始 AES-CBC 密文字节**，不是 base64 字符串；
/// - query 只有 `{appid, clientver, mid, clienttime, key, dfid, p}`，
///   故 `clear_default_params` + `not_signature`（不注入 uuid/token/userid/signature）；
/// - `dfid/mid/clienttime/kg-rc/kg-thash/kg-rec/kg-rf` 头由 `request.rs` 的
///   `base_headers` 统一补，这里只需 `x-router` 与 Content-Type。
fn cloud_roundtrip(
    q: &Value,
    ctx: &Ctx,
    url: &str,
    data_obj: &Value,
) -> Result<ModuleResponse, ModuleResponse> {
    let userid: i64 = cookie_or_param_str(q, "userid", "0")
        .trim()
        .parse()
        .unwrap_or(0);
    let token = cookie_or_param_str(q, "token", "");
    let mid = c_str(q, "KUGOU_API_MID");
    let dfid = cookie_or_param_str(q, "dfid", "-");

    // 会话串 6 字符 → md5 前 16 位作 key、后 16 位作 iv（与 playlistAesEncrypt 同推导）。
    // md5_hex_str 产出纯 ASCII hex，直接切字节避免非边界切片。
    let aes = random_string_lower(6);
    let md = md5_hex_str(&aes).into_bytes();
    let cipher = aes_cbc_encrypt(
        &md[..16],
        &md[16..32],
        json_stringify(data_obj).as_bytes(),
    );

    let clienttime = now_secs();
    let portrait = json!({ "aes": aes, "uid": userid, "token": token });
    let p = hex_encode(&crate::crypto::rsa_pkcs1v15_encrypt(
        PUBLIC_RAS_KEY,
        json_stringify(&portrait).as_bytes(),
    ))
    .to_uppercase();

    let params = json!({
        "appid": CLOUD_APP_ID,
        "clientver": CLOUD_CLIENT_VER,
        "mid": mid,
        "clienttime": clienttime,
        "key": cloud_key(clienttime),
        "dfid": dfid,
        "p": p,
    });

    let opts = RequestOptions::new(url)
        .post(url)
        .params(params)
        .bytes_body(cipher)
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .header("x-router", "cloudlist.service.kugou.com")
        .header("Content-Type", "application/json;charset=utf-8")
        .clear_default_params(true)
        .not_signature(true)
        .response_type("arraybuffer");

    let res = ctx.send(&opts)?;
    // 诊断插桩（2026-10-14「编辑歌单无法保存」排查）：写接口低频，成功只打一行、
    // 失败打详情，用于区分「上游业务拒绝（可解密）」与「解密/网络异常（归一文案）」。
    // 请求侧 data 不含 token（token 在 RSA 密文 p 内），可安全打印。
    log::info!("[playlist/cloud] data={}", json_stringify(data_obj));
    let raw_bytes = res.body.to_bytes();
    let content_type = res
        .headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("content-type"))
        .map(|(_, v)| v.clone());
    let dec = playlist_aes_decrypt(&aes, &res.body.to_base64());
    // 解密结果归一（对齐 createCloudRequest 的 text 回落语义）：
    // - String：上游未加密，按纯文本当失败原因；
    // - Null：密文长度不齐（网关错误页/HTML/非 base64），解密没发生；
    // - 其余：正常 JSON 业务响应，原样透传。
    // 两种失败都不抛异常，而是给 {status:0,...}，让 Dart 侧按业务失败提示，
    // 而不是把 null 当响应体返回。
    let body = match dec {
        Value::String(text) => json!({ "status": 0, "msg": text }),
        Value::Null => json!({
            "status": 0,
            "msg": "歌单服务响应解析失败（上游可能返回了非加密内容）"
        }),
        other => other,
    };
    if cloud_body_is_failure(&body) {
        log::warn!(
            "[playlist/cloud] FAILED url={} upstream_status={} ct={:?} raw_len={} raw_prefix={} body={}",
            url,
            res.status,
            content_type,
            raw_bytes.len(),
            diag_raw_prefix(&raw_bytes),
            diag_truncate(&json_stringify(&body), 400),
        );
    } else {
        log::info!(
            "[playlist/cloud] ok url={} upstream_status={} raw_len={}",
            url,
            res.status,
            raw_bytes.len(),
        );
    }
    Ok(ModuleResponse {
        status: res.status,
        body: BodyValue::Json(body),
        cookie: res.cookie,
        headers: res.headers,
    })
}

/// v4 云歌单写接口（`/cloudlist.service/v4/modify_list`）的明文 JSON + enckey/encstr 往返。
///
/// 端口对应 kugou_sdk（zephyrixel/kugou_sdk）`playlist/api.rs::modify_raw`——
/// 该实现经**实网验证**（Lite 会话 listid=8 → `status=1`）。与 [cloud_roundtrip]
///（v1 + 整体 AES 密文 body + 标准版 1005 profile）的差异：
///
/// 1. **平台 profile 必须与本 App 一致**。App 全程跑概念版（appid 3116 / Lite 盐 /
///    [PUBLIC_LITE_RAS_KEY]），而 v1 实现发的是标准版 1005 协议——上游对「3116
///    签发的 token + 1005 请求」恒返回 `error_code=20017`（登录信息过期类）。
///    2026-10-14 真机实测：自建歌单改名、系统歌单原值 no-op、各种 total_ver
///    （1/15/118/119/0）全部 20017，与歌单、参数无关，是系统性鉴权失败。
/// 2. body 是**明文 JSON**（不再整体 AES 加密）：业务字段 + `enckey`/`encstr`。
/// 3. `enckey` = RSA PKCS#1 v1.5 加密 **6 字符 AES seed 原文** → **大写** hex
///    （v1 的 `p` 包的是 `{aes,uid,token}` JSON 且小写，两者不通用）。
/// 4. `encstr` = Base64(AES-128-CBC of `{"token":…}`)，key/iv 取 MD5(seed) hex
///    的 UTF-8 前/后 16 字节（与 register_dev 的 DevicePayloadCipher 同推导）。
/// 5. query 走**默认管线**（3116/11440 + Lite 盐 Android 签名，签名覆盖 body），
///    故不 `clear_default_params`、不 `not_signature`。
/// 6. 响应是明文 JSON，直接透传（只有 v1 才需要 [playlist_aes_decrypt]）。
///
/// 同族迁移状态：`modify_list`（v4，2026-10-14 实网验证）与 `modify_list_sort`
///（v1 契约 + 概念版身份，2026-10-15 实网验证，见 [cloud_roundtrip_v1_concept]）
/// 已修复；`modify_song_sort` 已迁概念版身份并验证写入后回读顺序。
/// `modify_list_pic` 仍走 [cloud_roundtrip] 标准版身份，待独立验证。
/// v4 modify_list 的完整 body：业务字段（[build_update_map] 产物）+ `userid` +
/// `enckey` + `encstr`。seed 每次随机，故 enckey/encstr 不可复现（单测只验形状）。
pub fn build_v4_body(q: &Value, data_obj: &Value) -> Map<String, Value> {
    let userid: i64 = cookie_or_param_str(q, "userid", "0")
        .trim()
        .parse()
        .unwrap_or(0);
    let token = cookie_or_param_str(q, "token", "");

    // 6 字符 seed → MD5 hex 前 16 位作 key、后 16 位作 iv（UTF-8 字节）。
    let seed = random_string_lower(6);
    let md = md5_hex_str(&seed).into_bytes();
    let token_json = json_stringify(&json!(token)); // JSON 字符串字面量（带引号）
    let encstr = base64_encode(&aes_cbc_encrypt(
        &md[..16],
        &md[16..32],
        format!(r#"{{"token":{token_json}}}"#).as_bytes(),
    ));
    let enckey = hex_encode(&rsa_pkcs1v15_encrypt(PUBLIC_LITE_RAS_KEY, seed.as_bytes()))
        .to_uppercase();

    let mut body = data_obj.as_object().cloned().unwrap_or_default();
    body.insert("userid".to_string(), json!(userid));
    body.insert("enckey".to_string(), json!(enckey));
    body.insert("encstr".to_string(), json!(encstr));
    body
}

/// v4 云歌单写接口失败时，上游业务错误体会被 request.rs 管线转成
/// `Err(ModuleResponse)`（`response_is_error`：非 arraybuffer 且 status=0 或
/// error_code≠0）——调用方的 `?` 把它原样透传给 Dart（HTTP 502 + 错误体）。
/// Ok/Err 两分支的诊断日志都在本函数内补齐，调用方无需重复。
pub fn cloud_roundtrip_v4(
    q: &Value,
    ctx: &Ctx,
    url: &str,
    data_obj: &Value,
) -> Result<ModuleResponse, ModuleResponse> {
    let body = build_v4_body(q, data_obj);

    let opts = RequestOptions::new(url)
        .post(url)
        .json_body(Value::Object(body))
        .encrypt_type("android")
        .cookie(q_cookie(q));

    let res = match ctx.send(&opts) {
        Ok(r) => r,
        // 上游业务错误体（status=0 / error_code≠0）会被管线转成 Err 提前返回，
        // `?` 会绕过下面的诊断日志——在透传前补一条，保证失败可见（2026-10-15
        // 排查「排序同步 20010」时正是这个缺口让 logcat 只剩 [playlist/sort] 一行）。
        Err(e) => {
            log::warn!(
                "[playlist/cloud-v4] REJECTED url={} upstream_status={} body={}",
                url,
                e.status,
                diag_truncate(&json_stringify(&e.body.to_json()), 400),
            );
            return Err(e);
        }
    };
    let raw_bytes = res.body.to_bytes();
    let content_type = res
        .headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("content-type"))
        .map(|(_, v)| v.clone());
    let body = res.body.to_json();
    if cloud_body_is_failure(&body) {
        log::warn!(
            "[playlist/cloud-v4] FAILED url={} upstream_status={} ct={:?} raw_len={} raw_prefix={} body={}",
            url,
            res.status,
            content_type,
            raw_bytes.len(),
            diag_raw_prefix(&raw_bytes),
            diag_truncate(&json_stringify(&body), 400),
        );
    } else {
        log::info!(
            "[playlist/cloud-v4] ok url={} upstream_status={} raw_len={} data={}",
            url,
            res.status,
            raw_bytes.len(),
            json_stringify(data_obj),
        );
    }
    Ok(ModuleResponse {
        status: res.status,
        body: BodyValue::Json(body),
        cookie: res.cookie,
        headers: res.headers,
    })
}

/// v1 云歌单契约 + **概念版身份**的加密往返（/playlist/sort 生产路径）。
///
/// [cloud_roundtrip] 照搬 JS 参考实现时连身份参数（1005/20489/标准盐/标准公钥）
/// 一起搬了，与本 App 的概念版 token 冲突 → 恒 20017。本函数保持 v1 契约不变
///（原始 AES-CBC 密文 body、`p` 包 `{aes,uid,token}`、极简 query、not_signature、
/// x-router），仅把身份换成概念版：appid=3116 / clientver=11440 / 概念版盐
///（[sign_params_key] 即 `md5(3116+盐+11440+clienttime)`）/ [PUBLIC_LITE_RAS_KEY]。
/// 与已在生产验证的 `/v2/delete_list`（[aes_roundtrip]）同一身份体系。
/// 2026-10-15 实网验证：`/v1/modify_list_sort` → `status=1`、逐条 `code=1`、
/// `total_ver` 正常递增（响应 `data.total_ver` 是新版本号，Dart 侧应回写乐观锁）。
/// 注意该端点对 body 格式挑剔：playlistAES 风格（[aes_roundtrip]）会被回
/// `error_code=20010`，必须用本函数的 createCloudRequest 原始密文体。
pub fn cloud_roundtrip_v1_concept(
    q: &Value,
    ctx: &Ctx,
    url: &str,
    data_obj: &Value,
) -> Result<ModuleResponse, ModuleResponse> {
    let userid: i64 = cookie_or_param_str(q, "userid", "0")
        .trim()
        .parse()
        .unwrap_or(0);
    let token = cookie_or_param_str(q, "token", "");
    let mid = c_str(q, "KUGOU_API_MID");
    let dfid = cookie_or_param_str(q, "dfid", "-");

    let aes = random_string_lower(6);
    let md = md5_hex_str(&aes).into_bytes();
    let cipher = aes_cbc_encrypt(
        &md[..16],
        &md[16..32],
        json_stringify(data_obj).as_bytes(),
    );

    let clienttime = now_secs();
    let portrait = json!({ "aes": aes, "uid": userid, "token": token });
    let p = hex_encode(&crate::crypto::rsa_pkcs1v15_encrypt(
        PUBLIC_LITE_RAS_KEY,
        json_stringify(&portrait).as_bytes(),
    ))
    .to_uppercase();

    let params = json!({
        "appid": APP_ID,
        "clientver": CLIENT_VER,
        "mid": mid,
        "clienttime": clienttime,
        "key": sign_params_key(&clienttime.to_string(), APP_ID, CLIENT_VER),
        "dfid": dfid,
        "p": p,
    });

    let opts = RequestOptions::new(url)
        .post(url)
        .params(params)
        .bytes_body(cipher)
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .header("x-router", "cloudlist.service.kugou.com")
        .header("Content-Type", "application/json;charset=utf-8")
        .clear_default_params(true)
        .not_signature(true)
        .response_type("arraybuffer");

    let res = match ctx.send(&opts) {
        Ok(r) => r,
        Err(e) => {
            log::warn!(
                "[playlist/cloud-v1c] REJECTED url={} upstream_status={} body={}",
                url,
                e.status,
                diag_truncate(&json_stringify(&e.body.to_json()), 400),
            );
            return Err(e);
        }
    };
    let dec = playlist_aes_decrypt(&aes, &res.body.to_base64());
    let body = match dec {
        Value::String(text) => json!({ "status": 0, "msg": text }),
        Value::Null => json!({
            "status": 0,
            "msg": "歌单服务响应解析失败（上游可能返回了非加密内容）"
        }),
        other => other,
    };
    if cloud_body_is_failure(&body) {
        log::warn!(
            "[playlist/cloud-v1c] FAILED url={} upstream_status={} body={}",
            url,
            res.status,
            diag_truncate(&json_stringify(&body), 400),
        );
    } else {
        log::info!(
            "[playlist/cloud-v1c] ok url={} upstream_status={} data={}",
            url,
            res.status,
            json_stringify(data_obj),
        );
    }
    Ok(ModuleResponse {
        status: res.status,
        body: BodyValue::Json(body),
        cookie: res.cookie,
        headers: res.headers,
    })
}

/// JS `Number(x || 0)`：非数字/空 → 0。
fn num_or_zero(s: &str) -> i64 {
    s.trim().parse::<i64>().unwrap_or(0)
}

/// `fileid|sort` 逗号分隔 → `[{fileid, sort}…]`（/playlist/tracks/sort 的 data）。
///
/// 端口对应 `module/playlist_tracks_sort.js:10-13` 的
/// `s.split('|')` + `Number(fileid)` / `Number(sort || 0)`。
pub fn build_tracks_sort_resource(data: &str) -> Value {
    let items: Vec<Value> = data
        .split(',')
        .map(|s| {
            let parts: Vec<&str> = s.split('|').collect();
            json!({
                "fileid": num_or_zero(parts.first().copied().unwrap_or("")),
                "sort": num_or_zero(parts.get(1).copied().unwrap_or("")),
            })
        })
        .collect();
    Value::Array(items)
}

/// `listid|type|sort` 逗号分隔 → `[{listid, type, sort}…]`（/playlist/sort 的 data）。
///
/// 端口对应 `module/playlist_sort.js:10-13`。
pub fn build_list_sort_resource(data: &str) -> Value {
    let items: Vec<Value> = data
        .split(',')
        .map(|s| {
            let parts: Vec<&str> = s.split('|').collect();
            json!({
                "listid": num_or_zero(parts.first().copied().unwrap_or("")),
                "type": num_or_zero(parts.get(1).copied().unwrap_or("")),
                "sort": num_or_zero(parts.get(2).copied().unwrap_or("")),
            })
        })
        .collect();
    Value::Array(items)
}

/// 封面路径归一：完整 URL 取末段并补 `stdmusic/` 前缀，已是相对路径则原样。
///
/// 端口对应 `module/playlist_pic.js:13` 的
/// `!String(pic).startsWith('stdmusic/') ? 'stdmusic/' + String(pic).split('/').pop() : pic`。
pub fn normalize_stdmusic_pic(pic: &str) -> String {
    if pic.starts_with("stdmusic/") {
        return pic.to_string();
    }
    let last = pic.rsplit('/').next().unwrap_or(pic);
    format!("stdmusic/{}", last)
}

/// `listid|type|pic` 逗号分隔 → `[{listid, type, pic}…]`（/playlist/pic 的 data）。
///
/// `type` 缺省时用调用方传入的 [default_type]（对应 JS `Number(type || 0)`，
/// data 内逐条指定的 type 优先）。
pub fn build_pic_resource(data: &str, default_type: i64) -> Value {
    let items: Vec<Value> = data
        .split(',')
        .map(|s| {
            let parts: Vec<&str> = s.split('|').collect();
            let raw_type = parts.get(1).copied().unwrap_or("");
            let ty = if raw_type.trim().is_empty() {
                default_type
            } else {
                num_or_zero(raw_type)
            };
            json!({
                "listid": num_or_zero(parts.first().copied().unwrap_or("")),
                "type": ty,
                "pic": normalize_stdmusic_pic(parts.get(2).copied().unwrap_or("")),
            })
        })
        .collect();
    Value::Array(items)
}

/// /playlist/update 的 dataMap（`name` 缺省不改名、`pic` 缺省不换封面）。
///
/// 端口对应 `module/playlist_update.js:14-30`：`total_ver/listid/type/sort/tags/intro`
/// 恒在，`name` 仅 `if (params.name)` 时插入，`pic` 仅传入时插入。
/// v4 协议（见 [cloud_roundtrip_v4]）额外认 `is_pri`：仅调用方显式传入才插入——
/// 擅自补 0 会把隐私歌单悄悄改成公开。
pub fn build_update_map(q: &Value) -> Map<String, Value> {
    let mut dm = Map::new();
    dm.insert(
        "total_ver".to_string(),
        json!(q_num(q, "total_ver", 0)),
    );
    dm.insert("listid".to_string(), json!(q_num(q, "listid", 0)));
    // ⚠️ type 语义与 /playlist/add|del 相反：这里 0=自建/我喜欢，1=收藏
    // （参考 playlist_update.js 头部注释）。删除类端点才是 1=自建、0=收藏。
    dm.insert("type".to_string(), json!(q_num(q, "type", 0)));
    dm.insert("sort".to_string(), json!(q_num(q, "sort", 0)));
    dm.insert("tags".to_string(), json!(q_str(q, "tags", "")));
    dm.insert("intro".to_string(), json!(q_str(q, "intro", "")));
    let name = q_str(q, "name", "");
    if !name.is_empty() {
        dm.insert("name".to_string(), json!(name));
    }
    let pic = q_str(q, "pic", "");
    if !pic.is_empty() {
        dm.insert("pic".to_string(), json!(pic));
    }
    if q.get("is_pri").is_some() {
        dm.insert("is_pri".to_string(), json!(q_num(q, "is_pri", 0)));
    }
    dm
}

/// playlist_tracks_sort.js → /playlist/tracks/sort（歌单内歌曲排序，需登录）。
///
/// data 入参 `fileid|sort` 逗号分隔；`type` 0=自建/我喜欢、1=收藏（默认 0）。
pub fn handle_tracks_sort(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    // 完整歌单可能超过 URL 长度限制，兼容 JSON POST 与原有 GET。
    let input = q.get("body").filter(|body| body.is_object()).unwrap_or(q);
    let dm = json!({
        "listid": q_num(input, "listid", 0),
        "list_ver": q_num(input, "list_ver", 0),
        "type": q_num(input, "type", 0),
        "data": build_tracks_sort_resource(&q_str(input, "data", "")),
    });
    log::info!(
        "[playlist/tracks/sort] listid={}, list_ver={}, type={}",
        q_num(input, "listid", 0),
        q_num(input, "list_ver", 0),
        q_num(input, "type", 0),
    );
    cloud_roundtrip_v1_concept(q, ctx, "/v1/modify_song_sort", &dm)
}

/// playlist_sort.js → /playlist/sort（「我的歌单」列表排序，需登录）。
///
/// data 入参 `listid|type|sort` 逗号分隔；`type` 0=自建、1=收藏。
///
/// 走 [cloud_roundtrip_v1_concept]（v1 契约 + 概念版身份）：URL 本身没有问题，
/// 问题出在 [cloud_roundtrip] 照搬 JS 参考时把**标准版身份**（1005/20489/标准盐/
/// 标准公钥）一起搬了——概念版 3116 签发的 token 配 1005 请求恒 20017。
/// 2026-10-15 实网探针确认：同一 v1 契约换概念版身份后 `status=1`，逐条
/// `code=1`、total_ver 正常递增；而推测的 `/cloudlist.service/v4/modify_list_sort`
/// 实际不存在（网关对未知子路径统一回 20010，与 total_ver/data 取值无关）。
pub fn handle_sort(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let dm = json!({
        "total_ver": q_num(q, "total_ver", 0),
        "data": build_list_sort_resource(&q_str(q, "data", "")),
    });
    log::info!(
        "[playlist/sort] total_ver={}",
        q_num(q, "total_ver", 0),
    );
    cloud_roundtrip_v1_concept(q, ctx, "/v1/modify_list_sort", &dm)
}

/// playlist_pic.js → /playlist/pic（修改歌单封面为系统内置封面，需登录）。
///
/// data 入参 `listid|type|pic` 逗号分隔；pic 支持完整 URL 或 `stdmusic/xxx.jpg`。
pub fn handle_pic(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let dm = json!({
        "total_ver": q_num(q, "total_ver", 0),
        "data": build_pic_resource(&q_str(q, "data", ""), q_num(q, "type", 0)),
    });
    log::info!("[playlist/pic] total_ver={}", q_num(q, "total_ver", 0));
    cloud_roundtrip(q, ctx, "/v1/modify_list_pic", &dm)
}

/// playlist_update.js → /playlist/update（修改歌单名称/排序/标签/简介/自定义封面，需登录）。
///
/// 走 v4（`/cloudlist.service/v4/modify_list` + enckey/encstr + 概念版 profile）：
/// v1 旧协议发标准版 1005 会被上游以 20017（登录信息过期类）拒绝，详见
/// [cloud_roundtrip_v4] 注释。2026-10-14 真机验证迁移后自建歌单改名可用。
pub fn handle_update(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let dm = Value::Object(build_update_map(q));
    log::info!(
        "[playlist/update] listid={}, total_ver={}, type={}",
        q_num(q, "listid", 0),
        q_num(q, "total_ver", 0),
        q_num(q, "type", 0),
    );
    cloud_roundtrip_v4(q, ctx, "/cloudlist.service/v4/modify_list", &dm)
}

/// 上游图床 `IsSuccess` 真值判定。
///
/// ⚠️ 上游 `imgphp.kugou.com/imageupload/stream.php` 返回的是 **JSON 布尔**
/// （实测恒为 `"IsSuccess":true` / `false`），**不是数字 1**。照 JS 参考实现
/// （`playlist_pic_upload.js` 里的 `if (body?.IsSuccess)`，靠 JS 真值语义）移植时
/// 若写成 `Value::as_i64() == Some(1)`，`Value::Bool(true).as_i64()` 恒为 `None`
/// → **所有真正成功的上传都被判为失败**；而成功响应 `Message` 是空串，于是
/// 兜底文案「上传失败」被当成业务失败展示（2026-10-16 经 App 内嵌服务器的
/// `[playlist/pic/upload] upstream status=200 resp=...` 日志取证定案：
/// 上游明明回了 `{"IsSuccess":true,...,"FileName":"2026...jpg"}`，界面却报「上传失败」）。
///
/// 判定口径与头像图床上传（`user.rs` 的 `handle_update_avatar`）保持一致：
/// 布尔 / 数字 / 字符串三种真值都算成功。
fn upstream_is_success(body: &Value) -> bool {
    match body.get("IsSuccess") {
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0) != 0,
        Some(Value::String(s)) => s == "true" || s == "1",
        _ => false,
    }
}

/// 上传图片失败（业务/网络）的统一 502 响应。
fn upload_error(msg: &str) -> ModuleResponse {
    ModuleResponse {
        status: 502,
        body: BodyValue::Json(json!({ "status": 0, "msg": msg })),
        cookie: Vec::new(),
        headers: Default::default(),
    }
}

/// 封面文件路径/参数：query 优先，回落 JSON body。
///
/// `server.rs` 把 JSON body 整体放在 `query["body"]` 而不合并到顶层
/// （与 `import_playlist.rs` 的读法一致），POST 场景必须回落一层。
/// 本端点 Dart 侧是 `_post(data: {...})`，三个参数都在 body 里，
/// 只读 query 会让 type / extendName 静默退回默认值。
pub fn cover_body_str(q: &Value, key: &str) -> String {
    let from_query = q_str(q, key, "");
    if !from_query.is_empty() {
        return from_query;
    }
    match q.get("body") {
        Some(Value::Object(b)) => b
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        _ => String::new(),
    }
}

/// playlist_pic_upload.js → POST /playlist/pic/upload（上传歌单自定义封面，需登录）。
///
/// 与头像上传（/user/update/avatar）不同：这里读**设备本地文件路径**并原样上传原始字节，
/// 客户端不传 base64，避免大图在 Dart/Rust 之间多一次编解码。上游是
/// `http://imgphp.kugou.com/imageupload/stream.php`（HTTP，非 HTTPS）。
/// 成功后由调用方把返回的 FileName 以 `pic=custom/<FileName>` 交给 /playlist/update。
pub fn handle_pic_upload(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let path = cover_body_str(q, "file");
    if path.is_empty() {
        return Ok(upload_error("文件不存在"));
    }

    let bytes = match std::fs::metadata(&path) {
        Ok(meta) if meta.is_file() && meta.len() <= MAX_COVER_UPLOAD_BYTES => {
            match std::fs::read(&path) {
                Ok(b) => b,
                Err(e) => return Ok(upload_error(&format!("读取文件失败: {e}"))),
            }
        }
        Ok(meta) if meta.is_dir() => return Ok(upload_error("路径是目录，不是图片文件")),
        Ok(_) => {
            return Ok(upload_error(&format!(
                "文件超过 {}MB 上限",
                MAX_COVER_UPLOAD_BYTES / (1024 * 1024)
            )))
        }
        Err(_) => return Ok(upload_error("文件不存在")),
    };

    // 只认扩展名不够：魔数判定复用头像上传同一份实现
    if image_mime(&bytes).is_none() {
        return Ok(upload_error("不是有效的图片文件（支持 JPEG/PNG/GIF/BMP/WEBP）"));
    }

    let type_param = cover_body_str(q, "type");
    let extend_param = cover_body_str(q, "extendName");
    // 取证日志：上游对封面的尺寸/格式/体积约束（Bad width/height、
    // Bad image format、Too big）只体现在响应体里；本地零日志时，
    // 「上传失败」兜底文案（见下方 Message 为空分支）无法排查——
    // 2026-10-15 真机排查即因缺少该日志只能靠上游探测还原规则。
    log::info!(
        "[playlist/pic/upload] file={} bytes={} type={} extend={}",
        path,
        bytes.len(),
        type_param,
        extend_param
    );

    // md5(北京时间 yyyyMMdd + 盐)，与头像图床上传的防盗链 token 同口径
    let md5 = md5_hex_str(&format!("{}{}", beijing_ymd(), UPLOAD_SALT));
    let params = json!({
        "type": if type_param.is_empty() { "custom".to_string() } else { type_param },
        "extendName": if extend_param.is_empty() { ".jpg".to_string() } else { extend_param },
        "md5": md5,
        "jsonResponse": 1,
    });

    let opts = RequestOptions::new("/stream.php")
        .base_url("http://imgphp.kugou.com/imageupload")
        .post("/stream.php")
        .params(params)
        .bytes_body(bytes)
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .header("Content-Type", "application/octet-stream")
        .clear_default_params(true)
        .not_signature(true)
        .timeout_secs(30);

    let res = match ctx.send(&opts) {
        Ok(r) => r,
        Err(e) => {
            log::warn!(
                "[playlist/pic/upload] transport error: {}",
                e.body.to_string_utf8()
            );
            return Ok(upload_error(&e.body.to_string_utf8()));
        }
    };
    let body = res.body.to_json();
    // 上游响应原文（截断 300 字符）：区分「带 Message 的业务拒绝」与
    // 「无 Message 的非 JSON 响应」（后者会走下方「上传失败」兜底）。
    let resp_preview: String = res.body.to_string_utf8().chars().take(300).collect();
    log::info!(
        "[playlist/pic/upload] upstream status={} resp={}",
        res.status,
        resp_preview
    );
    if upstream_is_success(&body) {
        let file_name = body
            .get("FileName")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        log::info!("[playlist/pic/upload] success FileName={}", file_name);
        return Ok(ModuleResponse {
            status: res.status,
            body: BodyValue::Json(json!({ "status": 1, "FileName": file_name })),
            cookie: res.cookie,
            headers: res.headers,
        });
    }
    let msg = body
        .get("Message")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .unwrap_or("上传失败")
        .to_string();
    Ok(upload_error(&msg))
}

/// playlist_add.js → /playlist/add（收藏歌单）。
pub fn handle_add(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid_str = param_or_cookie_str(q, "userid", "0");
    let userid: i64 = userid_str.trim().parse().unwrap_or(0);
    let token = param_or_cookie_str(q, "token", "");
    log::info!("[playlist/add] userid={}, token={}...", userid, if token.len() > 8 { &token[..8] } else { &token });
    let clienttime = now_secs();
    let ptype = q_num(q, "type", 0);

    let mut dm: Map<String, Value> = Map::new();
    dm.insert("userid".to_string(), json!(userid));
    dm.insert("token".to_string(), json!(token));
    dm.insert("total_ver".to_string(), json!(0));
    dm.insert("name".to_string(), json!(q_str(q, "name", "")));
    dm.insert("type".to_string(), json!(ptype));
    dm.insert("source".to_string(), json!(source_0_or_1(q)));
    dm.insert("is_pri".to_string(), json!(0));
    dm.insert(
        "list_create_userid".to_string(),
        json!(or_num(q, "list_create_userid", 0)),
    );
    dm.insert(
        "list_create_listid".to_string(),
        json!(or_num(q, "list_create_listid", 0)),
    );
    dm.insert(
        "list_create_gid".to_string(),
        json!(q_str(q, "list_create_gid", "")),
    );
    dm.insert("from_shupinmv".to_string(), json!(0));
    if ptype == 0 {
        dm.insert("is_pri".to_string(), json!(or_num(q, "is_pri", 0)));
    }

    let params = if ptype == 0 {
        json!({
            "last_time": clienttime,
            "last_area": "gztx",
            "userid": userid,
            "token": token,
        })
    } else {
        json!({})
    };

    forward(
        q, ctx, "post", "/cloudlist.service/v5/add_list", None,
        Some(params), Some(Value::Object(dm)), "android", &[], false, false,
    )
}

/// playlist_del.js → /playlist/del（取消收藏歌单）。
pub fn handle_del(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid_str = param_or_cookie_str(q, "userid", "0");
    let userid: i64 = userid_str.trim().parse().unwrap_or(0);
    let token = param_or_cookie_str(q, "token", "");
    log::info!("[playlist/del] userid={}, token={}..., listid={}", userid, if token.len() > 8 { &token[..8] } else { &token }, q_num(q, "listid", 0));
    let dm = json!({
        "listid": q_num(q, "listid", 0),
        "total_ver": 0,
        "type": or_num_nullish(q, "type", 1),
        "userid": userid,
        "token": token,
    });
    let params = json!({
        "last_area": "gztx",
        "last_time": now_secs(),
        "userid": userid,
        "token": token,
    });
    aes_roundtrip(
        q,
        ctx,
        None,
        "/v2/delete_list",
        &dm,
        params,
        false,
        false,
        // 网关分发头：与 playlist_del.js 一致，缺失返回 502
        &[("x-router", "cloudlist.service.kugou.com")],
    )
}

/// playlist_detail.js → /playlist/detail（获取歌单详情）。
pub fn handle_detail(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let ids = q_str(q, "ids", "");
    let data: Vec<Value> = ids
        .split(',')
        .map(|s| json!({ "global_collection_id": s }))
        .collect();
    let dm = json!({
        "data": data,
        "userid": param_or_cookie_str(q, "userid", "0").trim().parse::<i64>().unwrap_or(0),
        "token": param_or_cookie_str(q, "token", ""),
    });
    forward(
        q, ctx, "POST", "/v3/get_list_info", None, None,
        Some(dm), "android", &[("x-router", "pubsongs.kugou.com")], false, false,
    )
}

/// playlist_effect.js → /playlist/effect（获取音效歌单）。
pub fn handle_effect(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let dm = json!({
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
    });
    forward(
        q, ctx, "POST", "/pubsongs/v1/get_sound_effect_list", None, None,
        Some(dm), "android", &[], false, false,
    )
}

/// playlist_similar.js → /playlist/similar（相似歌单）。
pub fn handle_similar(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let ids = q_str(q, "ids", "");
    let data: Vec<Value> = ids
        .split(',')
        .map(|s| json!({ "global_collection_id": s }))
        .collect();
    let clienttime_ms = (now_epoch_secs() * 1000.0) as i64;
    let dm = json!({
        "appid": APP_ID,
        "clientver": CLIENT_VER,
        "clienttime": clienttime_ms,
        "key": sign_params_key(&clienttime_ms.to_string(), "", ""),
        "userid": param_or_cookie_str(q, "userid", "0").trim().parse::<i64>().unwrap_or(0),
        "ugc": 1,
        "show_list": 1,
        "need_songs": 1,
        "data": data,
    });
    forward(
        q, ctx, "POST", "/pubsongs/v1/kmr_get_similar_lists", None, None,
        Some(dm), "android", &[], false, false,
    )
}

/// playlist_tags.js → /playlist/tags（获取歌单分类）。
pub fn handle_tags(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let dm = json!({
        "tag_type": "collection",
        "tag_id": 0,
        "source": 3,
    });
    forward(
        q, ctx, "POST", "/pubsongs/v1/get_tags_by_type", None, None,
        Some(dm), "android", &[], false, false,
    )
}

/// playlist_track_all.js → /playlist/track/all（获取歌单所有歌曲）。
pub fn handle_track_all(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let pagesize = q_num(q, "pagesize", 30);
    let gcid = {
        let v = q_str(q, "global_collection_id", "");
        if !v.is_empty() {
            v
        } else {
            q_str(q, "id", "")
        }
    };
    let mut pm: Map<String, Value> = Map::new();
    pm.insert("area_code".to_string(), json!(1));
    pm.insert(
        "begin_idx".to_string(),
        json!((q_num(q, "page", 1) - 1) * pagesize),
    );
    pm.insert("plat".to_string(), json!(1));
    pm.insert("type".to_string(), json!(1));
    pm.insert("mode".to_string(), json!(1));
    pm.insert("personal_switch".to_string(), json!(1));
    pm.insert(
        "extend_fields".to_string(),
        json!("abtags,hot_cmt,popularization"),
    );
    pm.insert("pagesize".to_string(), json!(pagesize));
    pm.insert("global_collection_id".to_string(), json!(gcid));
    forward(
        q, ctx, "GET", "/pubsongs/v2/get_other_list_file_nofilt", None,
        Some(Value::Object(pm)), None, "android", &[], false, false,
    )
}

/// playlist_track_all_new.js → /playlist/track/all/new（获取自己歌单所有歌曲）。
pub fn handle_track_all_new(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = cookie_or_param_str(q, "userid", "0");
    let token = cookie_or_param_str(q, "token", "0");
    let mut dm: Map<String, Value> = Map::new();
    if let Some(v) = q.get("listid") {
        if !v.is_null() {
            dm.insert("listid".to_string(), v.clone());
        }
    }
    dm.insert("userid".to_string(), json!(userid));
    dm.insert("area_code".to_string(), json!(1));
    dm.insert("show_relate_goods".to_string(), json!(0));
    dm.insert("pagesize".to_string(), json!(q_num(q, "pagesize", 30)));
    dm.insert("allplatform".to_string(), json!(1));
    dm.insert("show_cover".to_string(), json!(1));
    dm.insert("type".to_string(), json!(0));
    dm.insert("token".to_string(), json!(token));
    dm.insert("page".to_string(), json!(q_num(q, "page", 1)));
    forward(
        q, ctx, "post", "/v4/get_list_all_file", None, None,
        Some(Value::Object(dm)), "android", &[("x-router", "cloudlist.service.kugou.com")], false, false,
    )
}

/// playlist_tracks_add.js → /playlist/tracks/add（对歌单添加歌曲）。
pub fn handle_tracks_add(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid_str = param_or_cookie_str(q, "userid", "0");
    let userid: i64 = userid_str.trim().parse().unwrap_or(0);
    let token = param_or_cookie_str(q, "token", "");
    log::info!("[playlist/tracks/add] userid={}, token={}..., listid={}", userid, if token.len() > 8 { &token[..8] } else { &token }, q_str(q, "listid", ""));
    let clienttime = now_secs();
    let resource: Vec<Value> = q_str(q, "data", "")
        .split(',')
        .map(|s| {
            let parts: Vec<&str> = s.split('|').collect();
            json!({
                "number": 1,
                "name": parts.get(0).copied().unwrap_or(""),
                "hash": parts.get(1).copied().unwrap_or(""),
                "size": 0,
                "sort": 0,
                "timelen": 0,
                "bitrate": 0,
                "album_id": parts.get(2).and_then(|v| v.parse::<i64>().ok()).unwrap_or(0),
                "mixsongid": parts.get(3).and_then(|v| v.parse::<i64>().ok()).unwrap_or(0),
            })
        })
        .collect();
    let mut dm: Map<String, Value> = Map::new();
    if let Some(v) = q.get("listid") {
        if !v.is_null() {
            dm.insert("listid".to_string(), v.clone());
        }
    }
    dm.insert("userid".to_string(), json!(userid));
    dm.insert("token".to_string(), json!(token));
    dm.insert("list_ver".to_string(), json!(0));
    dm.insert("type".to_string(), json!(0));
    dm.insert("slow_upload".to_string(), json!(1));
    dm.insert("scene".to_string(), json!("false;null"));
    dm.insert("data".to_string(), Value::Array(resource));
    let params = json!({
        "last_time": clienttime,
        "last_area": "gztx",
        "userid": userid,
        "token": token,
    });
    forward(
        q, ctx, "post", "/cloudlist.service/v6/add_song", None,
        Some(params), Some(Value::Object(dm)), "android", &[], false, false,
    )
}

/// playlist_tracks_del.js → /playlist/tracks/del（对歌单删除歌曲）。
pub fn handle_tracks_del(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid: i64 = param_or_cookie_str(q, "userid", "0")
        .trim()
        .parse()
        .unwrap_or(0);
    let token = param_or_cookie_str(q, "token", "");
    let clienttime = now_secs();
    let resource: Vec<Value> = q_str(q, "fileids", "")
        .split(',')
        .filter(|s| !s.is_empty())
        .map(|s| {
            match s.trim().parse::<i64>() {
                Ok(n) if n > 0 => json!({ "fileid": n }),
                _ => json!({ "fileid": 0, "hash": s }),
            }
        })
        .collect();
    let mut dm: Map<String, Value> = Map::new();
    if let Some(v) = q.get("listid") {
        if !v.is_null() {
            dm.insert("listid".to_string(), v.clone());
        }
    }
    dm.insert("userid".to_string(), json!(userid));
    dm.insert("data".to_string(), Value::Array(resource));
    dm.insert("type".to_string(), json!(0));
    dm.insert("token".to_string(), json!(token));
    dm.insert("list_ver".to_string(), json!(0));
    let params = json!({
        "last_time": clienttime,
        "last_area": "gztx",
        "userid": userid,
        "token": token,
    });
    forward(
        q, ctx, "post", "/cloudlist.service/v4/delete_songs", None,
        Some(params), Some(Value::Object(dm)), "android", &[], false, false,
    )
}

#[cfg(test)]
mod tests {
    use super::upstream_is_success;
    use serde_json::json;

    /// 上游图床 `IsSuccess` 是 **JSON 布尔**——回归钉死：布尔 true 必须判成功。
    ///
    /// 反例（2026-10-15 真机 bug）：写成 `as_i64() == Some(1)` 时，上游明明回
    /// `{"IsSuccess":true,"Message":"","FileName":"x.jpg"}`，却被判失败、
    /// `Message` 为空串 → 界面显示「上传失败」，用户以为上传失败但图床其实已收图。
    #[test]
    fn pic_upload_is_success_accepts_bool_true() {
        assert!(upstream_is_success(&json!({
            "IsSuccess": true, "Message": "", "FileName": "20261016xxxx.jpg"
        })));
        assert!(!upstream_is_success(&json!({
            "IsSuccess": false, "Message": "Bad width", "FileName": ""
        })));
    }

    /// 兼容数字/字符串真值（与头像图床上传 user.rs 的口径一致），并覆盖缺字段。
    #[test]
    fn pic_upload_is_success_accepts_number_and_string() {
        assert!(upstream_is_success(&json!({ "IsSuccess": 1 })));
        assert!(!upstream_is_success(&json!({ "IsSuccess": 0 })));
        assert!(upstream_is_success(&json!({ "IsSuccess": "1" })));
        assert!(upstream_is_success(&json!({ "IsSuccess": "true" })));
        assert!(!upstream_is_success(&json!({ "IsSuccess": "false" })));
        assert!(!upstream_is_success(&json!({ "Message": "Bad width" })));
        assert!(!upstream_is_success(&json!("不是对象")));
    }
}
