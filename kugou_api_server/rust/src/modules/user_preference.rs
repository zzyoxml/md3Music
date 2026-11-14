//! user_preference 系列：听歌偏好设置（获取 / 更新）
//! 对应上游 JS module/user_preference.js（/user/preference）、
//! user_preference_update.js（/user/preference/update）。
//!
//! 上游 gateway.kugou.com（默认网关）：/userpreferservice/v1/get_user_conf（获取）、
//! /userpreferservice/v1/update_user_conf（更新）。两者均需登录态：
//!   - token 放 AES-CBC 密文（body.params，hex），AES 密钥为 16 位随机 hex 串的
//!     md5（key/iv 由 md5 派生，crypto_aes_encrypt 内对齐 JS cryptoAesEncrypt），
//!     该随机串经 RSA-PKCS1v15（概念版公钥）加密进 body.p（明文 {key, clienttime}，
//!     key 在前）——与 artist.rs::handle_follow 同款信封；
//!   - query 固定 6 项 {appid, clientver, clienttime, mid, dfid, uuid}
//!     （clear_default_params，对齐 JS clearDefaultParams），参与 android（概念版
//!     lite）签名；token/userid 不进 query（与 JS 一致，token 只走密文）。
//!
//! ⚠️ 身份必须留在概念版（默认 lite 签名 appid=3116/clientver=11440 + lite RSA
//! 公钥）：本 App 的登录 token 全部由概念版身份签发，上游按 token 的签发身份
//! 校验 appid——换标准版 1005 一律回 error_code=20018（同 blacklist.rs 注释）。
//! 更新接口的 10 个偏好字段放明文 body.data（逐个字符串化，字段序 data 在 params
//! 之前），空字符串=清除该字段（上游语义，透传即可）。

use crate::cache::now_epoch_secs;
use crate::config::{APP_ID, CLIENT_VER};
use crate::crypto::{crypto_aes_encrypt, hex_encode, rsa_encrypt2};
use crate::modules::comment_send::bad_request;
use crate::modules::{
    c_str, forward, param_or_cookie_num, param_or_cookie_str, q_str, Ctx,
};
use crate::request::ModuleResponse;
use crate::util::json_stringify;
use serde_json::{json, Map, Value};

/// update 允许透传的偏好字段白名单（与文档/上游 JS 的 10 个字段一致）。
const UPDATE_FIELDS: [&str; 10] = [
    "mode",
    "gender",
    "age",
    "lang",
    "style",
    "song_lang",
    "stylerec_taglist",
    "wish_taglist",
    "inactive_taglist",
    "inactive_singerlist",
];

/// JS `crypto.randomBytes(8).toString('hex')`：8 随机字节 → 16 位小写 hex。
fn random_hex_16() -> String {
    let bytes: Vec<u8> = (0..8).map(|_| rand::random::<u8>()).collect();
    hex_encode(&bytes)
}

/// 设备参数：显式 query 参数优先，其次 cookie（server.rs build_query 注入
/// KUGOU_API_MID / KUGOU_API_GUID / dfid），都缺省为 "-"（JS 的 `|| '-'`）。
/// 与 request.rs::create_request 的 mid/dfid 推导保持一致。
fn device_param(q: &Value, param_key: &str, cookie_key: &str) -> String {
    let p = q_str(q, param_key, "");
    if !p.is_empty() {
        return p;
    }
    let c = c_str(q, cookie_key);
    if !c.is_empty() {
        return c;
    }
    "-".to_string()
}

/// JS 从合并后的 params 对象读字段（query + body 合一）：POST JSON body 落在
/// q["body"]，GET query 在顶层，body 优先（同 user.rs 的 update_body_or_param）。
fn body_or_param(q: &Value, key: &str) -> Option<Value> {
    if let Some(b) = q.get("body") {
        if let Some(v) = b.get(key) {
            if !v.is_null() {
                return Some(v.clone());
            }
        }
    }
    match q.get(key) {
        Some(v) if !v.is_null() => Some(v.clone()),
        _ => None,
    }
}

/// JS `typeof params[k] === 'object' ? JSON.stringify(params[k]) : String(params[k])`。
/// 调用方保证 v 非 Null（body_or_param 已过滤）。
fn stringify_pref(v: &Value) -> String {
    match v {
        Value::Object(_) | Value::Array(_) => json_stringify(v),
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Null => String::new(),
    }
}

/// RSA `p` 字段：rsaEncrypt2(JSON.stringify({ key, clienttime: String(clienttime) }))。
/// ⚠️ 字段序 key 在前（serde_json preserve_order 下逐字节对齐 JS）。
fn encrypted_p(key: &str, clienttime: i64) -> String {
    rsa_encrypt2(&json_stringify(&json!({
        "key": key,
        "clienttime": clienttime.to_string(),
    })))
}

/// query 6 项：appid/clientver 用概念版数字值（上游 JS util/config.json 的
/// liteAppid/liteClientver 为数字类型）。
fn gateway_params(clienttime: i64, mid: &str, dfid: &str, uuid: &str) -> Value {
    json!({
        "appid": APP_ID.parse::<i64>().unwrap_or(3116),
        "clientver": CLIENT_VER.parse::<i64>().unwrap_or(11440),
        "clienttime": clienttime,
        "mid": mid,
        "dfid": dfid,
        "uuid": uuid,
    })
}

/// user_preference.js → /user/preference（获取听歌偏好：性别/年龄段/语言/风格/
/// 推荐模式/推荐强度等）。
pub fn handle_get(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let token = param_or_cookie_str(q, "token", "");
    let userid = param_or_cookie_num(q, "userid", 0);
    let clienttime = now_epoch_secs() as i64;
    let mid = device_param(q, "mid", "KUGOU_API_MID");
    let dfid = device_param(q, "dfid", "dfid");
    let uuid = device_param(q, "uuid", "KUGOU_API_GUID");

    log::info!("[USER_PREF] get userid={}", userid);

    let str_g2 = random_hex_16();
    // JS cryptoAesEncrypt(JSON.stringify({token}), {key: strG2})：给了 key 时直接
    // 返回 hex 串（tempKey 不回传，密钥只经 RSA p 字段传递）。
    let (aes_hex, _) =
        crypto_aes_encrypt(&json_stringify(&json!({ "token": token })), Some(&str_g2), None);
    let body = json!({
        "plat": 1,
        "userid": userid,
        "p": encrypted_p(&str_g2, clienttime),
        "params": aes_hex,
    });

    // UA 模板对齐 JS：Android15-1070-<clientver>-201-0-get_user_conf-wifi。
    // KG-Rec/KG-RC 已由 request.rs base_headers 统一带上，无需重复。
    let ua = format!("Android15-1070-{}-201-0-get_user_conf-wifi", CLIENT_VER);
    forward(
        q,
        ctx,
        "POST",
        "/userpreferservice/v1/get_user_conf",
        None,
        Some(gateway_params(clienttime, &mid, &dfid, &uuid)),
        Some(body),
        "android",
        &[("User-Agent", ua.as_str())],
        true,
        false,
    )
}

/// user_preference_update.js → /user/preference/update（更新听歌偏好）。
/// 至少一个白名单字段，否则 400；字段值逐个字符串化后放明文 body.data。
pub fn handle_update(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let mut data = Map::new();
    for key in UPDATE_FIELDS {
        if let Some(v) = body_or_param(q, key) {
            data.insert(key.to_string(), json!(stringify_pref(&v)));
        }
    }
    if data.is_empty() {
        return Err(bad_request("至少需要提供 gender/age/lang/style 等偏好字段之一"));
    }
    log::info!(
        "[USER_PREF] update fields={} mode={} gender={} age={}",
        data.len(),
        data.get("mode").map(|v| v.as_str().unwrap_or("")).unwrap_or(""),
        data.get("gender").map(|v| v.as_str().unwrap_or("")).unwrap_or(""),
        data.get("age").map(|v| v.as_str().unwrap_or("")).unwrap_or(""),
    );

    let token = param_or_cookie_str(q, "token", "");
    let userid = param_or_cookie_num(q, "userid", 0);
    let clienttime = now_epoch_secs() as i64;
    let mid = device_param(q, "mid", "KUGOU_API_MID");
    let dfid = device_param(q, "dfid", "dfid");
    let uuid = device_param(q, "uuid", "KUGOU_API_GUID");

    let str_g2 = random_hex_16();
    let (aes_hex, _) =
        crypto_aes_encrypt(&json_stringify(&json!({ "token": token })), Some(&str_g2), None);

    // body 字段序对齐 JS：{plat, userid, p, data, params}（data 在 params 前）。
    let mut body = Map::new();
    body.insert("plat".to_string(), json!(1));
    body.insert("userid".to_string(), json!(userid));
    body.insert("p".to_string(), json!(encrypted_p(&str_g2, clienttime)));
    body.insert("data".to_string(), Value::Object(data));
    body.insert("params".to_string(), json!(aes_hex));

    let ua = format!("Android15-1070-{}-201-0-update_user_conf-wifi", CLIENT_VER);
    forward(
        q,
        ctx,
        "POST",
        "/userpreferservice/v1/update_user_conf",
        None,
        Some(gateway_params(clienttime, &mid, &dfid, &uuid)),
        Some(Value::Object(body)),
        "android",
        &[("User-Agent", ua.as_str())],
        true,
        false,
    )
}
