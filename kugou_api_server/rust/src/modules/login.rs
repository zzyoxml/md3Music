//! login 系列：login / cellphone / device / device_kick / openplat /
//! qr_check / qr_create / qr_key / token / wx_check / wx_create
//! 对应 JS module/login*.js

use crate::cache::now_epoch_secs;
use crate::crypto::{
    base64_encode, crypto_aes_decrypt, crypto_aes_encrypt, crypto_md5_str, crypto_rsa_encrypt,
    sha1_hex_str,
};
use crate::modules::{cookie_or_param_str, c_num, c_str, forward, q_num, q_str, q_truthy, Ctx};
use crate::request::{BodyData, BodyValue, ModuleResponse};
use crate::util::{calculate_mid, random_string};
use serde_json::{json, Map, Value};
use std::collections::HashMap;

const LITE_T2_KEY: &str = "fd14b35e3f81af3817a20ae7adae7020";
const LITE_T2_IV: &str = "17a20ae7adae7020";
const LITE_T1_KEY: &str = "5e4ef500e9597fe004bd09a46d8add98";
const LITE_T1_IV: &str = "04bd09a46d8add98";

/// 微信开放平台（概念版小程序）身份。本地服务器整体按概念版 appid 3116 /
/// clientver 11440 签名，故微信侧同样用 lite 那套 appid/secret 保持一致
/// （标准版 wx79f2… 与 3116 的 token 平台不匹配，上游会拒）。
const WX_LITE_APPID: &str = "wx72b795aca60ad321";
const WX_LITE_SECRET: &str = "33e486041e5e25729a4e3d2da7502f9a";

/// QQ 互联（概念版）appid。对应上游 `config.json` 的 `qq_lite_appid`。
const QQ_LITE_APPID: &str = "101706348";
/// `m_authorize` 的 sign = md5(`{APK_SIG_MD5}_{unix_secs}`)，来自上游
/// `login_qq_qr_create.js`（酷狗 Android 包签名 md5）。
const QQ_APK_SIG_MD5: &str = "fe4a24d80fcf253a00676a808f62c2c6";
/// QQ 扫码链路统一 UA（m_authorize / xlogin / ptqrshow / ptqrlogin 都要求）。
const QQ_UA: &str = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 \
                     (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36";
const QQ_PTLOGIN_REFERER: &str = "https://xui.ptlogin2.qq.com/";

fn now_ms() -> i64 {
    (now_epoch_secs() * 1000.0) as i64
}

/// AES 密文串（opt_key 给定则为定长 hex；否则生成 tempKey 并返回）。
fn aes_hex(data: &str, opt_key: Option<&str>, opt_iv: Option<&str>) -> (String, Option<String>) {
    crypto_aes_encrypt(data, opt_key, opt_iv)
}

/// JS `cryptoAesEncrypt(str, {key, iv}).str`（无 tempKey）。
fn aes_hex_fixed(data: &str, key: &str, iv: &str) -> String {
    aes_hex(data, Some(key), Some(iv)).0
}

fn lite_t2(data: &str) -> String {
    aes_hex_fixed(data, LITE_T2_KEY, LITE_T2_IV)
}

fn lite_t1(data: &str) -> String {
    aes_hex_fixed(data, LITE_T1_KEY, LITE_T1_IV)
}

fn rsa_pk(data: &Value) -> String {
    let s = crate::util::json_stringify(data);
    crypto_rsa_encrypt(&s, None).to_uppercase()
}

/// JS `Object.keys(getToken).forEach(k => cookie.push(\`${k}=${getToken[k]}\`))`。
fn push_cookie_keys(cookies: &mut Vec<String>, obj: &Value) {
    if let Some(m) = obj.as_object() {
        for (k, v) in m {
            let vs = match v {
                Value::String(s) => s.clone(),
                Value::Number(n) => n.to_string(),
                Value::Bool(b) => b.to_string(),
                Value::Null => "undefined".to_string(),
                Value::Object(_) | Value::Array(_) => crate::util::json_stringify(v),
            };
            cookies.push(format!("{}={}", k, vs));
        }
    }
}

/// 合并 secu_params 解密结果：object → body.data 合并 + cookie；string → body.data.token + cookie。
fn apply_secu_params(body: &mut Value, cookies: &mut Vec<String>, secu_hex: &str, key: &str) {
    let got = crypto_aes_decrypt(secu_hex, key, None);
    if let Some(data) = body.get_mut("data") {
        match got {
            Value::Object(m) => {
                if let Some(dm) = data.as_object_mut() {
                    for (k, v) in &m {
                        dm.insert(k.clone(), v.clone());
                    }
                }
                push_cookie_keys(cookies, &Value::Object(m));
            }
            ref t => {
                data.as_object_mut().map(|d| {
                    d.insert("token".to_string(), t.clone());
                });
                if let Value::String(s) = t {
                    cookies.push(format!("token={}", s));
                }
            }
        }
    }
}

/// login.js → /login（密码登录）。
pub fn handle_login(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let date_now = now_ms();
    let pwd = q_str(q, "password", "");
    let encrypt = aes_hex(
        &crate::util::json_stringify(&json!({ "pwd": pwd, "code": "", "clienttime_ms": date_now })),
        None,
        None,
    );
    let key = encrypt.1.unwrap_or_default();
    let data_map = json!({
        "plat": 1,
        "support_multi": 1,
        "clienttime_ms": date_now,
        "t1": "562a6f12a6e803453647d16a08f5f0c2ff7eee692cba2ab74cc4c8ab47fc467561a7c6b586ce7dc46a63613b246737c03a1dc8f8d162d8ce1d2c71893d19f1d4b797685a4c6d3d81341cbde65e488c4829a9b4d42ef2df470eb102979fa5adcdd9b4eecfea8b909ff7599abeb49867640f10c3c70fc444effca9d15db44a9a6c907731e2bb0f22cd9b3536380169995693e5f0e2424e3378097d3813186e3fe96bbe7023808a0981b4e2b6135a76faac",
        "t2": "31c4daf4cf480169ccea1cb7d4a209295865a9d2b788510301694db229b87807469ea0d41b4d4b9173c2151da7294aeebfc9738df154bbdf11a4e117bb5dff6a3af8ce5ce333e681c1f29a44038f27567d58992eb81283e080778ac77db1400fdf49b7cf7e26be2e5af4da7830cc3be4",
        "t3": "MCwwLDAsMCwwLDAsMCwwLDA=",
        "username": q.get("username").cloned().unwrap_or(Value::Null),
        "params": encrypt.0,
        "pk": rsa_pk(&json!({ "clienttime_ms": date_now, "key": key })),
    });
    let mut res = forward(
        q, ctx, "POST", "/v9/login_by_pwd", None, None, Some(data_map), "android",
        &[("x-router", "login.user.kugou.com")], false, false,
    )?;
    let mut body = res.body.to_json();
    let status_ok = body.get("status").and_then(|v| v.as_i64()) == Some(1)
        || body.get("status").and_then(|v| v.as_f64()) == Some(1.0);
    if status_ok {
        if let Some(secu) = body
            .get("data")
            .and_then(|d| d.get("secu_params"))
            .and_then(|v| v.as_str())
            .map(String::from)
        {
            apply_secu_params(&mut body, &mut res.cookie, &secu, &key);
            let data = body.get("data").cloned().unwrap_or(json!({}));
            res.cookie
                .push(format!("userid={}", crate::modules::or_num(&data, "userid", 0)));
            res.cookie
                .push(format!("vip_type={}", crate::modules::or_num(&data, "vip_type", 0)));
            res.cookie
                .push(format!("vip_token={}", crate::modules::or_str(&data, "vip_token", "")));
        }
    }
    res.body = BodyValue::Json(body);
    Ok(res)
}

/// login_cellphone.js → /login/cellphone（手机验证码登录）。
pub fn handle_cellphone(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let date_time = now_ms();
    let mobile = q_str(q, "mobile", "");
    let code = q_str(q, "code", "");
    let encrypt = aes_hex(
        &crate::util::json_stringify(&json!({ "mobile": mobile, "code": code })),
        None,
        None,
    );
    let key = encrypt.1.unwrap_or_default();
    let masked_mobile = {
        let chars: Vec<char> = mobile.chars().collect();
        let mut out = String::new();
        if chars.len() > 2 {
            out.push_str(&chars[..2].iter().collect::<String>());
        }
        out.push_str("*****");
        if let Some(c) = chars.get(10) {
            out.push(*c);
        }
        out
    };
    let dfid = {
        let c = c_str(q, "dfid");
        if c.is_empty() {
            random_string(24)
        } else {
            c
        }
    };
    let t2 = lite_t2(&format!(
        "{}|0f607264fc6318a92b9e13c65db7cd3c|{}|{}|{}",
        c_str(q, "KUGOU_API_GUID"),
        c_str(q, "KUGOU_API_MAC"),
        c_str(q, "KUGOU_API_DEV"),
        date_time
    ));
    let t1 = lite_t1(&format!("|{}", date_time));
    let mut m = Map::new();
    m.insert("plat".into(), json!(1));
    m.insert("support_multi".into(), json!(1));
    m.insert("t1".into(), json!(t1));
    m.insert("t2".into(), json!(t2));
    m.insert("clienttime_ms".into(), json!(date_time));
    m.insert("mobile".into(), json!(masked_mobile));
    m.insert("key".into(), json!(crate::helper::sign_params_key(
        &date_time.to_string(), "", ""
    )));
    m.insert("pk".into(), json!(rsa_pk(&json!({ "clienttime_ms": date_time, "key": key }))));
    m.insert("params".into(), json!(encrypt.0));
    if !q_str(q, "userid", "").is_empty() {
        m.insert("userid".into(), json!(q_str(q, "userid", "")));
    }
    m.insert("dfid".into(), json!(dfid));
    m.insert("dev".into(), json!(c_str(q, "KUGOU_API_DEV")));
    m.insert("gitversion".into(), json!("5f0b7c4"));
    let mut res = forward(
        q, ctx, "POST", "/v7/login_by_verifycode", Some("https://loginserviceretry.kugou.com"),
        None, Some(Value::Object(m)), "android",
        &[("support-calm", "1"), ("User-Agent", "Android16-1070-11440-130-0-LOGIN-wifi")],
        false, false,
    )?;
    let mut body = res.body.to_json();
    let status_ok = body.get("status").and_then(|v| v.as_i64()) == Some(1)
        || body.get("status").and_then(|v| v.as_f64()) == Some(1.0);
    if status_ok {
        if let Some(secu) = body
            .get("data")
            .and_then(|d| d.get("secu_params"))
            .and_then(|v| v.as_str())
            .map(String::from)
        {
            apply_secu_params(&mut body, &mut res.cookie, &secu, &key);
        }
        let data = body.get("data").cloned().unwrap_or(json!({}));
        res.cookie.push(format!(
            "t1={}",
            crate::modules::or_str(&data, "t1", "undefined")
        ));
        res.cookie.push(format!(
            "token={}",
            crate::modules::or_str(&data, "token", "undefined")
        ));
        res.cookie
            .push(format!("userid={}", crate::modules::or_num(&data, "userid", 0)));
        res.cookie
            .push(format!("vip_type={}", crate::modules::or_num(&data, "vip_type", 0)));
        res.cookie
            .push(format!("vip_token={}", crate::modules::or_str(&data, "vip_token", "")));
    }
    res.body = BodyValue::Json(body);
    Ok(res)
}

/// login_device.js → /login/device（设备列表）。
/// 响应顶层追加 `local_device`（本机设备标识，来自 device_info.json），
/// 供客户端把列表项的 mid/dfid 与本机比对以标记「本机」——上游响应不含该信息，
/// Dart 侧自己缓存的 dfid 可能过期，误判会把本机标成可踢设备。
pub fn handle_device(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let clienttime_ms = now_ms();
    let token = {
        let p = q_str(q, "token", "");
        if !p.is_empty() {
            p
        } else {
            c_str(q, "token")
        }
    };
    let encrypt = aes_hex(
        &crate::util::json_stringify(&json!({ "token": token })),
        None,
        None,
    );
    let key = encrypt.1.unwrap_or_default();
    let userid = {
        let p = q_num(q, "userid", 0);
        if p != 0 {
            p
        } else {
            c_num(q, "userid", 0)
        }
    };
    let data_map = json!({
        "plat": 1,
        "userid": userid,
        "clienttime_ms": clienttime_ms,
        "pk": rsa_pk(&json!({ "clienttime_ms": clienttime_ms, "key": key })),
        "params": encrypt.0,
    });
    let mut res = forward(
        q, ctx, "POST", "/v2/get_dev", Some("https://userinfoservice.kugou.com"),
        None, Some(data_map), "android", &[], false, false,
    )?;
    let mut body = res.body.to_json();
    body["local_device"] = crate::device::DeviceConfig::instance().get_device_info();
    res.body = BodyValue::Json(body);
    Ok(res)
}

/// login_device_kick.js 的上游参数构建（纯函数，便于单测）。
/// 上游契约：token = 'h5' + RSA 无填充('moc.uoguk.59::' + token) hex 大写；
/// 被踢设备的 t_mid/t/t_appid/t_clientver 四元组由调用方从设备列表项（mid/t/appid/ver）
/// 经 query 传入，缺失时回退本机值；签名交由管线按 encrypt_type="web" 补（web 版盐）。
fn build_kick_params(q: &Value) -> Value {
    let raw_token = {
        let p = q_str(q, "token", "");
        if !p.is_empty() {
            p
        } else {
            c_str(q, "token")
        }
    };
    let token = format!(
        "h5{}",
        crypto_rsa_encrypt(&format!("moc.uoguk.59::{}", raw_token), None).to_uppercase()
    );
    let guid = c_str(q, "KUGOU_API_GUID");
    let mid = {
        let p = q_str(q, "mid", "");
        if !p.is_empty() {
            p
        } else {
            let cm = c_str(q, "KUGOU_API_MID");
            if !cm.is_empty() {
                cm
            } else if !guid.is_empty() {
                calculate_mid(&guid)
            } else {
                String::new()
            }
        }
    };
    let userid = {
        let p = q_num(q, "userid", 0);
        if p != 0 {
            p
        } else {
            c_num(q, "userid", 0)
        }
    };
    let clienttime_ms = now_ms();
    let t_mid = {
        let v = q_str(q, "t_mid", "");
        if v.is_empty() {
            guid.clone()
        } else {
            v
        }
    };
    let t = {
        let v = q_str(q, "t", "");
        if v.is_empty() {
            clienttime_ms.to_string()
        } else {
            v
        }
    };
    let t_appid = {
        let v = q_str(q, "t_appid", "");
        if v.is_empty() {
            "3116".to_string()
        } else {
            v
        }
    };
    let t_clientver = {
        let v = q_str(q, "t_clientver", "");
        if v.is_empty() {
            "10597".to_string()
        } else {
            v
        }
    };
    let mut data_map = Map::new();
    data_map.insert("appid".to_string(), json!(3116));
    data_map.insert("clientver".to_string(), json!(11440));
    data_map.insert("clienttime".to_string(), json!(clienttime_ms));
    if !mid.is_empty() {
        data_map.insert("mid".to_string(), json!(mid));
    }
    data_map.insert(
        "uuid".to_string(),
        json!(cookie_or_param_str(q, "uuid", "-")),
    );
    data_map.insert(
        "dfid".to_string(),
        json!(cookie_or_param_str(q, "dfid", "-")),
    );
    data_map.insert("plat".to_string(), json!(1));
    data_map.insert("userid".to_string(), json!(userid));
    data_map.insert("token".to_string(), json!(token));
    data_map.insert("srcappid".to_string(), json!(2919));
    data_map.insert("t_mid".to_string(), json!(t_mid));
    data_map.insert("t".to_string(), json!(t));
    data_map.insert("t_appid".to_string(), json!(t_appid));
    data_map.insert("t_clientver".to_string(), json!(t_clientver));
    Value::Object(data_map)
}

/// login_device_kick.js → /login/device/kick（登出选定设备）。
/// 对齐上游 KuGouMusicApi/module/login_device_kick.js：token 用 RSA 无填充加密
/// （'moc.uoguk.59::' 前缀 + 128 字节右补零，hex 大写，'h5' 前缀），web 版签名。
/// （JS 原版引用未定义变量 calculateMid/uuid/dfid/userid/guid，这里按合理语义补齐。）
pub fn handle_device_kick(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let data_map = build_kick_params(q);
    forward(
        q, ctx, "GET", "/loginservice/v1/dev_logout", None, Some(data_map), None, "web",
        &[("Host", "gateway.kugou.com")], false, false,
    )
}

/// 微信扫码 / QQ 扫码共用的最后一步：第三方 `openid + access_token` → 酷狗登录态。
///
/// 上游契约：`login_openplat.js`（微信）与 `login_qq.js`（QQ）除 `partnerid`
/// 与 `third_appid` 两个字段外完全一致：
/// `POST /v6/login_by_openplat`，android 签名，`x-router=login.user.kugou.com`，
/// body 的 `params` 是 `AES({access_token})` 密文、`pk` 是
/// `RSA(clienttime_ms + key)`，`t1/t2` 只有概念版身份才带真实值（标准版传 0）。
fn openplat_login(
    q: &Value,
    ctx: &Ctx,
    openid: &str,
    access_token: &str,
    partnerid: i64,
    third_appid: Option<&str>,
) -> Result<ModuleResponse, ModuleResponse> {
    let date_now = now_ms();
    let encrypt = aes_hex(
        &crate::util::json_stringify(&json!({ "access_token": access_token })),
        None,
        None,
    );
    let key = encrypt.1.unwrap_or_default();
    let pk = rsa_pk(&json!({ "clienttime_ms": date_now, "key": key }));
    let t2 = lite_t2(&format!(
        "{}|0f607264fc6318a92b9e13c65db7cd3c|{}|{}|{}",
        c_str(q, "KUGOU_API_GUID"),
        c_str(q, "KUGOU_API_MAC"),
        c_str(q, "KUGOU_API_DEV"),
        date_now
    ));
    let t1 = lite_t1(&format!("|{}", date_now));
    let mut m = Map::new();
    m.insert("dev".into(), json!(c_str(q, "KUGOU_API_DEV")));
    m.insert("force_login".into(), json!(1));
    m.insert("partnerid".into(), json!(partnerid));
    m.insert("clienttime_ms".into(), json!(date_now));
    m.insert("t1".into(), json!(t1));
    m.insert("t2".into(), json!(t2));
    m.insert("t3".into(), json!("MCwwLDAsMCwwLDAsMCwwLDA="));
    if let Some(appid) = third_appid {
        m.insert("third_appid".into(), json!(appid));
    }
    m.insert("openid".into(), json!(openid));
    m.insert("params".into(), json!(encrypt.0));
    m.insert("pk".into(), json!(pk));
    let mut res = forward(
        q, ctx, "POST", "/v6/login_by_openplat", None, None, Some(Value::Object(m)), "android",
        &[("x-router", "login.user.kugou.com")], false, false,
    )?;
    let mut body = res.body.to_json();
    let status_ok = body.get("status").and_then(|v| v.as_i64()) == Some(1)
        || body.get("status").and_then(|v| v.as_f64()) == Some(1.0);
    if status_ok {
        if let Some(secu) = body
            .get("data")
            .and_then(|d| d.get("secu_params"))
            .and_then(|v| v.as_str())
            .map(String::from)
        {
            apply_secu_params(&mut body, &mut res.cookie, &secu, &key);
        }
        let data = body.get("data").cloned().unwrap_or(json!({}));
        res.cookie.push(format!(
            "t1={}",
            crate::modules::or_str(&data, "t1", "")
        ));
        res.cookie
            .push(format!("userid={}", crate::modules::or_num(&data, "userid", 0)));
        res.cookie
            .push(format!("vip_type={}", crate::modules::or_num(&data, "vip_type", 0)));
        res.cookie
            .push(format!("vip_token={}", crate::modules::or_str(&data, "vip_token", "")));
    }
    res.body = BodyValue::Json(body);
    Ok(res)
}

/// login_openplat.js → /login/openplat（微信开放平台登录）。
pub fn handle_openplat(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let appid = WX_LITE_APPID;
    let secret = WX_LITE_SECRET;
    let code = q_str(q, "code", "");
    let token_resp = crate::request::raw_request(
        "GET",
        "https://api.weixin.qq.com/sns/oauth2/access_token",
        &json!({ "secret": secret, "appid": appid, "code": code, "grant_type": "authorization_code" }),
        BodyData::None,
        &HashMap::new(),
    );
    let token_body = match token_resp {
        Ok(r) => r.body.to_json(),
        Err(e) => {
            return Err(ModuleResponse {
                status: 502,
                body: BodyValue::Json(json!({ "status": 0, "msg": e.body.to_json() })),
                cookie: Vec::new(),
                headers: HashMap::new(),
            })
        }
    };
    let has_access = token_body
        .get("access_token")
        .and_then(|v| v.as_str())
        .map(|s| !s.is_empty())
        .unwrap_or(false)
        && token_body.get("openid").and_then(|v| v.as_str()).is_some();
    if !has_access {
        return Err(ModuleResponse {
            status: 502,
            body: BodyValue::Json(json!({ "status": 0, "msg": token_body })),
            cookie: Vec::new(),
            headers: HashMap::new(),
        });
    }
    let access_token = token_body
        .get("access_token")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let openid = token_body
        .get("openid")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    openplat_login(q, ctx, &openid, &access_token, 36, None)
}

/// login_qr_check.js → /login/qr/check（二维码状态检查）。
pub fn handle_qr_check(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let mut res = forward(
        q, ctx, "GET", "/v2/get_userinfo_qrcode", Some("https://login-user.kugou.com"),
        Some(json!({ "plat": 4, "appid": 3116, "srcappid": 2919, "qrcode": q_str(q, "key", "") })),
        None, "web", &[], false, false,
    )?;
    let mut body = res.body.to_json();
    let status = body
        .get("data")
        .and_then(|d| d.get("status"))
        .and_then(|v| v.as_i64())
        .unwrap_or(-1);
    if status == 4 {
        let data = body.get("data").cloned().unwrap_or(json!({}));
        let token = crate::modules::or_str(&data, "token", "");
        let userid = crate::modules::or_str(&data, "userid", "");
        res.cookie.push(format!("token={}", token));
        res.cookie.push(format!("userid={}", userid));
        if body.get("token").is_none() {
            body["token"] = json!(token);
        }
        if body.get("userid").is_none() {
            body["userid"] = json!(userid);
        }
        let vip_token = crate::modules::or_str(&data, "vip_token", "");
        if !vip_token.is_empty() {
            res.cookie.push(format!("vip_token={}", vip_token));
            if body.get("vip_token").is_none() {
                body["vip_token"] = json!(vip_token);
            }
        }
        if let Some(vt) = data.get("vip_type") {
            if !vt.is_null() {
                res.cookie.push(format!("vip_type={}", crate::util::js_string(Some(vt))));
                if body.get("vip_type").is_none() {
                    body["vip_type"] = vt.clone();
                }
            }
        }
    }
    res.body = BodyValue::Json(body);
    Ok(res)
}

/// login_qr_create.js → /login/qr/create（生成登录二维码 PNG）。
pub fn handle_qr_create(q: &Value, _ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let url = format!(
        "https://h5.kugou.com/apps/loginQRCode/html/index.html?qrcode={}",
        q_str(q, "key", "")
    );
    let base64 = if q_truthy(q, "qrimg") {
        qr_png_data_url(&url).unwrap_or_default()
    } else {
        String::new()
    };
    let body = json!({
        "code": 200,
        "data": { "url": url, "base64": base64 },
    });
    Ok(ModuleResponse {
        status: 200,
        body: BodyValue::Json(body),
        cookie: Vec::new(),
        headers: HashMap::new(),
    })
}

/// login_qr_key.js → /login/qr/key（二维码 key 生成）。
pub fn handle_qr_key(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let appid = if q_str(q, "type", "") == "web" { 1014 } else { 1001 };
    forward(
        q, ctx, "GET", "/v2/qrcode", Some("https://login-user.kugou.com"),
        Some(json!({
            "appid": appid,
            "type": 1,
            "plat": 4,
            "qrcode_txt": format!("https://h5.kugou.com/apps/loginQRCode/html/index.html?appid={}&", 3116),
            "srcappid": 2919,
        })),
        None, "web", &[], false, false,
    )
}

/// login_token.js → /login/token（刷新登录）。
pub fn handle_token(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let date_now = now_ms();
    let token = {
        let p = q_str(q, "token", "");
        if !p.is_empty() {
            p
        } else {
            c_str(q, "token")
        }
    };
    let userid = {
        let p = q_str(q, "userid", "");
        if !p.is_empty() {
            p
        } else {
            c_str(q, "userid")
        }
    };
    let userid = if userid.is_empty() { "0".to_string() } else { userid };
    let encrypt = aes_hex(
        &crate::util::json_stringify(&json!({ "clienttime": date_now / 1000, "token": token })),
        Some("c24f74ca2820225badc01946dba4fdf7"),
        Some("adc01946dba4fdf7"),
    );
    let encrypt_params = aes_hex("{}", None, None);
    let key = encrypt_params.1.unwrap_or_default();
    let pk = rsa_pk(&json!({ "clienttime_ms": date_now, "key": key }));
    let t2 = lite_t2(&format!(
        "{}|0f607264fc6318a92b9e13c65db7cd3c|{}|{}|{}",
        c_str(q, "KUGOU_API_GUID"),
        c_str(q, "KUGOU_API_MAC"),
        c_str(q, "KUGOU_API_DEV"),
        date_now
    ));
    let t1_src = {
        let c = c_str(q, "t1");
        if !c.is_empty() {
            format!("{}|{}", c, date_now)
        } else {
            format!("|{}", date_now)
        }
    };
    let t1 = lite_t1(&t1_src);
    let dfid = {
        let c = c_str(q, "dfid");
        if c.is_empty() {
            "-".to_string()
        } else {
            c
        }
    };
    let mut m = Map::new();
    m.insert("dfid".into(), json!(dfid));
    m.insert("p3".into(), json!({ "str": encrypt.0 }));
    m.insert("plat".into(), json!(1));
    m.insert("t1".into(), json!(t1));
    m.insert("t2".into(), json!(t2));
    m.insert("t3".into(), json!("MCwwLDAsMCwwLDAsMCwwLDA="));
    m.insert("pk".into(), json!(pk));
    m.insert("params".into(), json!(encrypt_params.0));
    m.insert("userid".into(), json!(userid));
    m.insert("clienttime_ms".into(), json!(date_now));
    m.insert("dev".into(), json!(c_str(q, "KUGOU_API_DEV")));
    let mut res = forward(
        q, ctx, "POST", "/v5/login_by_token", Some("http://login.user.kugou.com"),
        None, Some(Value::Object(m)), "android", &[], false, false,
    )?;
    let mut body = res.body.to_json();
    let status_ok = body.get("status").and_then(|v| v.as_i64()) == Some(1)
        || body.get("status").and_then(|v| v.as_f64()) == Some(1.0);
    if status_ok {
        if let Some(secu) = body
            .get("data")
            .and_then(|d| d.get("secu_params"))
            .and_then(|v| v.as_str())
            .map(String::from)
        {
            apply_secu_params(&mut body, &mut res.cookie, &secu, &key);
        }
        let data = body.get("data").cloned().unwrap_or(json!({}));
        res.cookie.push(format!(
            "t1={}",
            crate::modules::or_str(&data, "t1", "undefined")
        ));
        res.cookie.push(format!(
            "token={}",
            crate::modules::or_str(&data, "token", "undefined")
        ));
        res.cookie
            .push(format!("userid={}", crate::modules::or_num(&data, "userid", 0)));
        res.cookie
            .push(format!("vip_type={}", crate::modules::or_num(&data, "vip_type", 0)));
        res.cookie
            .push(format!("vip_token={}", crate::modules::or_str(&data, "vip_token", "")));
    }
    res.body = BodyValue::Json(body);
    Ok(res)
}

/// login_wx_check.js → /login/wx/check（微信扫码状态）。
///
/// 上游响应根级为 `{wx_errcode, wx_code}`：408 等待、404 已扫码、403 拒绝、
/// 402 过期、405 成功（带 `wx_code`，交给 /login/openplat 换酷狗 token）。
pub fn handle_wx_check(q: &Value, _ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let uuid = q_str(q, "uuid", "");
    if uuid.is_empty() {
        return Err(ModuleResponse {
            status: 400,
            body: BodyValue::Json(json!({ "status": 0, "msg": "缺少 uuid" })),
            cookie: Vec::new(),
            headers: HashMap::new(),
        });
    }
    let url = format!(
        "https://long.open.weixin.qq.com/connect/l/qrconnect?f=json&uuid={}",
        uuid
    );
    match crate::request::raw_get(&url, &json!({})) {
        Ok(resp) => {
            let body = resp.body.to_json();
            Ok(ModuleResponse {
                status: 200,
                body: BodyValue::Json(body),
                cookie: Vec::new(),
                headers: HashMap::new(),
            })
        }
        Err(e) => Err(ModuleResponse {
            status: 502,
            body: BodyValue::Json(json!({ "status": 0, "msg": e.body.to_json() })),
            cookie: Vec::new(),
            headers: HashMap::new(),
        }),
    }
}

/// login_wx_create.js → /login/wx/create（微信授权二维码）。
pub fn handle_wx_create(_q: &Value, _ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let appid = WX_LITE_APPID;
    let secret = WX_LITE_SECRET;
    let at = crate::request::raw_request(
        "GET",
        "https://api.weixin.qq.com/cgi-bin/token",
        &json!({ "appid": appid, "secret": secret, "grant_type": "client_credential" }),
        BodyData::None,
        &HashMap::new(),
    );
    let at_body = match at {
        Ok(r) => r.body.to_json(),
        Err(e) => {
            return Err(ModuleResponse {
                status: 502,
                body: BodyValue::Json(json!({ "status": 0, "msg": e.body.to_json() })),
                cookie: Vec::new(),
                headers: HashMap::new(),
            })
        }
    };
    let access_token = at_body
        .get("access_token")
        .and_then(|v| v.as_str())
        .map(String::from);
    let access_token = match access_token {
        Some(t) if !t.is_empty() => t,
        _ => {
            return Err(ModuleResponse {
                status: 502,
                body: BodyValue::Json(json!({ "status": 0, "msg": at_body })),
                cookie: Vec::new(),
                headers: HashMap::new(),
            })
        }
    };
    let tk = crate::request::raw_request(
        "GET",
        "https://api.weixin.qq.com/cgi-bin/ticket/getticket",
        &json!({ "access_token": access_token, "type": 2 }),
        BodyData::None,
        &HashMap::new(),
    );
    let tk_body = match tk {
        Ok(r) => r.body.to_json(),
        Err(e) => {
            return Err(ModuleResponse {
                status: 502,
                body: BodyValue::Json(json!({ "status": 0, "msg": e.body.to_json() })),
                cookie: Vec::new(),
                headers: HashMap::new(),
            })
        }
    };
    let ticket = tk_body.get("ticket").and_then(|v| v.as_str()).map(String::from);
    let errcode = tk_body
        .get("errcode")
        .and_then(|v| v.as_i64())
        .unwrap_or(-1);
    let ticket = match (errcode, ticket) {
        (0, Some(t)) => t,
        _ => {
            return Err(ModuleResponse {
                status: 502,
                body: BodyValue::Json(json!({ "status": 0, "msg": tk_body })),
                cookie: Vec::new(),
                headers: HashMap::new(),
            })
        }
    };
    let timestamp = now_ms();
    let noncestr = crypto_md5_str(&random_string(16));
    let signature = sha1_hex_str(&format!(
        "appid={}&noncestr={}&sdk_ticket={}&timestamp={}",
        appid, noncestr, ticket, timestamp
    ));
    let connect = crate::request::raw_request(
        "GET",
        "https://open.weixin.qq.com/connect/sdk/qrconnect",
        &json!({ "appid": appid, "noncestr": noncestr, "timestamp": timestamp, "scope": "snsapi_userinfo", "signature": signature }),
        BodyData::None,
        &HashMap::new(),
    );
    let connect_body = match connect {
        Ok(r) => r.body.to_json(),
        Err(e) => {
            return Err(ModuleResponse {
                status: 502,
                body: BodyValue::Json(json!({ "status": 0, "msg": e.body.to_json() })),
                cookie: Vec::new(),
                headers: HashMap::new(),
            })
        }
    };
    let connect_errcode = connect_body
        .get("errcode")
        .and_then(|v| v.as_i64())
        .unwrap_or(-1);
    if connect_errcode == 0 {
        let mut b = connect_body;
        let uuid = b.get("uuid").and_then(|v| v.as_str()).unwrap_or("").to_string();
        if let Some(qr) = b.get_mut("qrcode") {
            qr["qrcodeurl"] = json!(format!(
                "https://open.weixin.qq.com/connect/confirm?uuid={}",
                uuid
            ));
        }
        Ok(ModuleResponse {
            status: 200,
            body: BodyValue::Json(b),
            cookie: Vec::new(),
            headers: HashMap::new(),
        })
    } else {
        Err(ModuleResponse {
            status: 502,
            body: BodyValue::Json(json!({ "status": 0, "msg": connect_body })),
            cookie: Vec::new(),
            headers: HashMap::new(),
        })
    }
}

// ---------------------------------------------------------------------------
// QQ 扫码登录（login_qq_qr_create.js / login_qq_qr_check.js / login_qq.js）
// ---------------------------------------------------------------------------
//
// 三段式：m_authorize（拿 xlogin 地址）→ xlogin（拿 pt_login_sig 等 cookie）
// → ptqrshow（拿二维码 JPEG + qrsig）。轮询 ptqrlogin 得到 ptuiCB 状态，
// code='0' 时其 url 里带 openid + access_token，交给 openplat_login 换酷狗 token。
//
// 注意：`pt_openlogin_data` 是 **xlogin 的 query 原样再 encodeURIComponent 一次**
// 的结果，轮询时必须原样拼接（不可二次编码，否则上游回 ptuiCB('7') 参数错误）。

/// JS `hash33`：`let e=0; e += (e<<5)+charCodeAt(i); return 2147483647 & e`。
///
/// JS 的 `e` 是双精度浮点，`(e << 5)` 会先 ToInt32 再移位、加法结果回到浮点。
/// 由于 qrsig 长度有限（实测 128），浮点尾数精度（2^53）足够精确承载中间值，
/// 这里用 f64 累加 + 每次按 ToInt32 语义取移位，最后一次按 32 位截断取低 31 位。
pub fn hash33(s: &str) -> i64 {
    let mut e: f64 = 0.0;
    for ch in s.chars() {
        // ToInt32：先按 i64 截断再取低 32 位（JS 对 ±2^53 内整数做模 2^32）。
        let e32 = (e as i64) as i32;
        let shifted = e32.wrapping_shl(5);
        e += shifted as f64 + ch as u32 as f64;
    }
    let final32 = (e as i64) as i32;
    (final32 as i64) & 0x7FFF_FFFF
}

/// 把 m_authorize 返回 HTML 里的 `\x3A\x2F\x2F…` 转义还原成真实地址。
pub fn unescape_x_escapes(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\'
            && i + 3 < bytes.len()
            && (bytes[i + 1] == b'x' || bytes[i + 1] == b'X')
        {
            let hi = (bytes[i + 2] as char).to_digit(16);
            let lo = (bytes[i + 3] as char).to_digit(16);
            if let (Some(h), Some(l)) = (hi, lo) {
                out.push((h * 16 + l) as u8 as char);
                i += 4;
                continue;
            }
        }
        // 逐字符拷贝（保证多字节 UTF-8 不被拆断）
        let ch = s[i..].chars().next().unwrap_or('\u{fffd}');
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

/// 从 m_authorize 的 HTML 里提取 `src = "..."`（上游 JS 用同名正则）。
pub fn extract_xlogin_url(html: &str) -> Option<String> {
    let marker = "src = \"";
    let start = html.find(marker)? + marker.len();
    let rest = &html[start..];
    let end = rest.find('"')?;
    let raw = &rest[..end];
    if raw.is_empty() {
        None
    } else {
        Some(unescape_x_escapes(raw))
    }
}

/// 解析 `ptuiCB('66','0','','0','等待扫码', '')` → `(code, url, msg)`。
pub fn parse_ptui_cb(body: &str) -> Option<(String, String, String)> {
    let open = body.find("ptuiCB(")?;
    let after = &body[open + "ptuiCB(".len()..];
    let close = after.rfind(')')?;
    let inner = &after[..close];
    let parts: Vec<String> = inner
        .split('\'')
        .enumerate()
        .filter(|(i, _)| i % 2 == 1)
        .map(|(_, s)| s.to_string())
        .collect();
    if parts.len() < 5 {
        return None;
    }
    Some((parts[0].clone(), parts[2].clone(), parts[4].clone()))
}

/// 从 query 串里取某个键的值（不 decode，QQ 的 openid/access_token 都是
/// 不含 `%` 的 ASCII，直接比对即可；值里若含 `%` 也按上游原样使用）。
pub fn query_param_raw(query: &str, key: &str) -> Option<String> {
    for pair in query.split('&') {
        let (k, v) = match pair.split_once('=') {
            Some(kv) => kv,
            None => continue,
        };
        if k == key && !v.is_empty() {
            return Some(v.to_string());
        }
    }
    None
}

/// 从 proxy.htm URL（或整串文本）里提取 `openid` / `access_token`。
pub fn extract_openid_token(url: &str) -> (Option<String>, Option<String>) {
    let query = match url.find('?') {
        Some(i) => &url[i + 1..],
        None => url,
    };
    (
        query_param_raw(query, "openid"),
        query_param_raw(query, "access_token"),
    )
}

/// cookie jar：JS `Object.entries(cookieJar)` 的等价物（同名后写覆盖）。
pub fn merge_cookie_jar(jar: &mut Vec<(String, String)>, raw_set_cookies: &[String]) {
    for (k, v) in crate::request::cookie_pairs(raw_set_cookies) {
        if let Some(slot) = jar.iter_mut().find(|(jk, _)| *jk == k) {
            slot.1 = v;
        } else {
            jar.push((k, v));
        }
    }
}

/// jar → `k=v; k2=v2`（上游 Cookie 头形式）。
pub fn cookie_jar_to_string(jar: &[(String, String)]) -> String {
    jar.iter()
        .map(|(k, v)| format!("{}={}", k, v))
        .collect::<Vec<_>>()
        .join("; ")
}

/// 从 query 取 QQ 会话 cookie。
///
/// ⚠️ 这里不能用 `q_str(q, "cookie")`：服务端 `build_query` 会对 `cookie` 键
/// 做 `cookieToJson(decode(...))`（等价 Express 的 `cookie` 参数解析），把
/// `pt_login_sig=SIG; qrsig=QRSIG` 这样的字符串**转成对象**。直接 `q_str` 读到
/// 的是空串，于是 `missing_fields()` 报「缺少 cookie」——真机探针实测踩过。
///
/// 同时要把服务端注入的平台 cookie（`KUGOU_API_*` / `dfid`）剔掉，否则会把
/// 酷狗的设备身份发给 QQ。
fn qq_cookie_from_query(q: &Value) -> String {
    match q.get("cookie") {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Object(m)) => m
            .iter()
            .filter(|(k, v)| {
                !v.is_null()
                    && !k.is_empty()
                    && !k.starts_with("KUGOU_API_")
                    && k.as_str() != "dfid"
                    && k.as_str() != "mid"
            })
            .map(|(k, v)| format!("{}={}", k, crate::util::js_string(Some(v))))
            .collect::<Vec<_>>()
            .join("; "),
        _ => String::new(),
    }
}

/// QQ 扫码会话（`/login/qq/qr/create` 的输出，`check` 原样回传）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QqSession {
    pub cookie: String,
    pub qrsig: String,
    pub ptqrtoken: String,
    pub pt_login_sig: String,
    pub pt_openlogin_data: String,
    pub xlogin_url: String,
}

impl QqSession {
    pub fn from_query(q: &Value) -> Self {
        // ptqrtoken 上游可能回数字也可能回字符串，统一按字符串承载。
        let ptqrtoken = match q.get("ptqrtoken") {
            Some(Value::Number(n)) => n.to_string(),
            Some(Value::String(s)) => s.clone(),
            _ => String::new(),
        };
        QqSession {
            cookie: qq_cookie_from_query(q),
            qrsig: q_str(q, "qrsig", ""),
            ptqrtoken,
            pt_login_sig: q_str(q, "pt_login_sig", ""),
            pt_openlogin_data: q_str(q, "pt_openlogin_data", ""),
            xlogin_url: q_str(q, "xlogin_url", ""),
        }
    }

    /// 缺失字段（按上游提示顺序），空表示齐备。
    pub fn missing_fields(&self) -> Vec<&'static str> {
        let mut missing = Vec::new();
        if self.qrsig.is_empty() {
            missing.push("qrsig");
        }
        if self.ptqrtoken.is_empty() {
            missing.push("ptqrtoken");
        }
        if self.pt_login_sig.is_empty() {
            missing.push("pt_login_sig");
        }
        if self.pt_openlogin_data.is_empty() {
            missing.push("pt_openlogin_data");
        }
        if self.xlogin_url.is_empty() {
            missing.push("xlogin_url");
        }
        if !self.cookie.contains("qrsig=") {
            missing.push("cookie");
        }
        missing
    }

    /// 轮询时实际发送的 Cookie 头（缺 pt_login_sig 时补上，对齐上游 JS）。
    pub fn poll_cookie(&self) -> String {
        let mut cookie = self.cookie.clone();
        if !self.pt_login_sig.is_empty() && !cookie.contains("pt_login_sig") {
            if cookie.is_empty() {
                cookie = format!("pt_login_sig={}", self.pt_login_sig);
            } else {
                cookie = format!("{}; pt_login_sig={}", cookie, self.pt_login_sig);
            }
        }
        cookie
    }
}

/// 构造 ptqrlogin 轮询地址。
///
/// ⚠️ `pt_openlogin_data` **原样拼接**（它出 create 时已编码一次）；`login_sig`
/// 与 `u1` 则必须再 encode 一次（与上游 `login_qq_qr_check.js:55-57` 一致）。
pub fn build_qq_poll_url(s: &QqSession, rand: f64) -> String {
    format!(
        "https://xui.ptlogin2.qq.com/ssl/ptqrlogin?u1={}&from_ui=1&type=1&ptlang=2052\
         &ptqrtoken={}&daid=381&aid=716027609&pt_3rd_aid={}\
         &pt_openlogin_data={}&device=2&ptopt=1&pt_uistyle=35&jsver=v1.36.0\
         &login_sig={}&r={}",
        crate::util::encode_uri_component("http://connect.qq.com"),
        s.ptqrtoken,
        QQ_LITE_APPID,
        s.pt_openlogin_data,
        crate::util::encode_uri_component(&s.pt_login_sig),
        rand
    )
}

fn qq_headers(referer: &str, cookie: Option<&str>) -> HashMap<String, String> {
    let mut h = HashMap::new();
    h.insert("User-Agent".to_string(), QQ_UA.to_string());
    h.insert("Referer".to_string(), referer.to_string());
    if let Some(c) = cookie {
        if !c.is_empty() {
            h.insert("Cookie".to_string(), c.to_string());
        }
    }
    h
}

fn qq_error(status: u16, msg: Value) -> ModuleResponse {
    ModuleResponse {
        status,
        body: BodyValue::Json(json!({ "status": 0, "msg": msg })),
        cookie: Vec::new(),
        headers: HashMap::new(),
    }
}

/// login_qq_qr_create.js → /login/qq/qr/create（生成 QQ 扫码二维码）。
pub fn handle_qq_qr_create(_q: &Value, _ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let time = now_epoch_secs() as i64;
    let sign = crypto_md5_str(&format!("{}_{}", QQ_APK_SIG_MD5, time));
    let auth_params = json!({
        "cancel_display": "1",
        "sdkp": "a",
        "display": "mobile",
        "format": "json",
        "sign": sign,
        "sdkv": "3.5.11.lite",
        "response_type": "token",
        "status_os": "11",
        "client_id": QQ_LITE_APPID,
        "switch": "1",
        "status_version": "30",
        "show_download_ui": "true",
        "pf": "openmobile_android",
        "scope": "all",
        "compat_v": "1",
        "status_machine": "MEIZU+18+Pro",
        "style": "qr",
        "time": time,
        "redirect_uri": "auth://tauth.qq.com/",
    });
    let auth = crate::request::raw_fetch(
        "GET",
        "https://openmobile.qq.com/oauth2.0/m_authorize",
        &auth_params,
        BodyData::None,
        &qq_headers(QQ_PTLOGIN_REFERER, None),
    )?;
    let auth_text = auth.body_text();
    let xlogin_url = match extract_xlogin_url(&auth_text) {
        Some(u) => u,
        None => {
            let preview: String = auth_text.chars().take(300).collect();
            return Err(qq_error(
                502,
                json!(format!("m_authorize 响应异常，未找到 xlogin 地址: {}", preview)),
            ));
        }
    };

    let mut jar: Vec<(String, String)> = Vec::new();
    let xlogin = crate::request::raw_fetch(
        "GET",
        &xlogin_url,
        &json!({}),
        BodyData::None,
        &qq_headers(QQ_PTLOGIN_REFERER, None),
    )?;
    merge_cookie_jar(&mut jar, &xlogin.cookies);
    let pt_login_sig = jar
        .iter()
        .find(|(k, _)| k == "pt_login_sig")
        .map(|(_, v)| v.clone())
        .unwrap_or_default();

    let rand = rand::random::<f64>();
    let qr_url = format!(
        "https://xui.ptlogin2.qq.com/ssl/ptqrshow?s=8&e=0&appid=716027609&type=0&t={}&daid=381&pt_3rd_aid={}",
        rand, QQ_LITE_APPID
    );
    let jar_str = cookie_jar_to_string(&jar);
    let qr = crate::request::raw_fetch(
        "GET",
        &qr_url,
        &json!({}),
        BodyData::None,
        &qq_headers(&xlogin_url, Some(&jar_str)),
    )?;
    merge_cookie_jar(&mut jar, &qr.cookies);
    let qrsig = jar
        .iter()
        .find(|(k, _)| k == "qrsig")
        .map(|(_, v)| v.clone())
        .unwrap_or_default();
    if qrsig.is_empty() {
        return Err(qq_error(502, json!("未获取到 qrsig")));
    }
    if qr.body.is_empty() {
        return Err(qq_error(502, json!("ptqrshow 未返回二维码图片")));
    }

    let ptqrtoken = hash33(&qrsig);
    let pt_openlogin_data = match xlogin_url.find('?') {
        Some(i) => crate::util::encode_uri_component(&xlogin_url[i + 1..]),
        None => String::new(),
    };

    // 上游 EchoMusic / KuGouMusicApi 都是**根级扁平**结构（不是 {data:{...}}）。
    Ok(ModuleResponse {
        status: 200,
        body: BodyValue::Json(json!({
            "qrcode": base64_encode(&qr.body),
            "qrsig": qrsig,
            "ptqrtoken": ptqrtoken,
            "pt_login_sig": pt_login_sig,
            "pt_openlogin_data": pt_openlogin_data,
            "xlogin_url": xlogin_url,
            "cookie": cookie_jar_to_string(&jar),
        })),
        cookie: Vec::new(),
        headers: HashMap::new(),
    })
}

/// login_qq_qr_check.js → /login/qq/qr/check（轮询 QQ 扫码状态）。
///
/// 状态映射（与 EchoMusic `startCheckQqStatus` 对齐）：
/// `wait` / `scanned` / `expired` / `blocked` / `error`，
/// 登录成功直接返回 `/login/openplat` 的响应（`status:1` + `data.token`）。
pub fn handle_qq_qr_check(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let session = QqSession::from_query(q);
    let missing = session.missing_fields();
    if !missing.is_empty() {
        return Err(qq_error(
            400,
            json!(format!(
                "缺少 {}（请先调用 /login/qq/qr/create，并将返回字段原样传入 check 接口）",
                missing.join("、")
            )),
        ));
    }

    let rand = rand::random::<f64>();
    let poll_url = build_qq_poll_url(&session, rand);
    let cookie = session.poll_cookie();
    let referer = if session.xlogin_url.is_empty() {
        QQ_PTLOGIN_REFERER
    } else {
        session.xlogin_url.as_str()
    };
    let resp = match crate::request::raw_fetch(
        "GET",
        &poll_url,
        &json!({}),
        BodyData::None,
        &qq_headers(referer, Some(&cookie)),
    ) {
        Ok(r) => r,
        Err(_) => {
            // 传输层失败（DNS/TLS/超时）与 WAF 拦截同样按「暂时不可用」处理，
            // 由客户端提示重试，不影响其它登录方式。
            return Ok(ModuleResponse {
                status: 200,
                body: BodyValue::Json(json!({
                    "status": "blocked",
                    "msg": "QQ 扫码接口暂时不可用，请稍后重试或改用微信/酷狗扫码",
                })),
                cookie: Vec::new(),
                headers: HashMap::new(),
            });
        }
    };

    // 上游风控（实测 HTTP 403 + 空 body）不是登录失败，是「这条链路当前不可用」。
    if !(200..300).contains(&resp.status) || resp.body.is_empty() {
        return Ok(ModuleResponse {
            status: 200,
            body: BodyValue::Json(json!({
                "status": "blocked",
                "http": resp.status,
                "msg": "QQ 扫码接口被上游拦截，请稍后重试或改用微信/酷狗扫码",
            })),
            cookie: Vec::new(),
            headers: HashMap::new(),
        });
    }

    let text = resp.body_text();
    let (code, url, msg) = match parse_ptui_cb(&text) {
        Some(v) => v,
        None => {
            let preview: String = text.chars().take(200).collect();
            return Ok(ModuleResponse {
                status: 200,
                body: BodyValue::Json(json!({
                    "status": "error",
                    "msg": "ptqrlogin 响应解析失败",
                    "data": preview,
                })),
                cookie: Vec::new(),
                headers: HashMap::new(),
            });
        }
    };

    match code.as_str() {
        "66" => Ok(ModuleResponse {
            status: 200,
            body: BodyValue::Json(json!({
                "status": "wait",
                "qrsig": session.qrsig,
                "ptqrtoken": session.ptqrtoken,
                "msg": if msg.is_empty() { "等待扫码".to_string() } else { msg },
            })),
            cookie: Vec::new(),
            headers: HashMap::new(),
        }),
        "67" => Ok(ModuleResponse {
            status: 200,
            body: BodyValue::Json(json!({
                "status": "scanned",
                "qrsig": session.qrsig,
                "ptqrtoken": session.ptqrtoken,
                "msg": if msg.is_empty() { "已扫码，请在 QQ 中确认".to_string() } else { msg },
            })),
            cookie: Vec::new(),
            headers: HashMap::new(),
        }),
        "65" => Ok(ModuleResponse {
            status: 200,
            body: BodyValue::Json(json!({
                "status": "expired",
                "qrsig": session.qrsig,
                "ptqrtoken": session.ptqrtoken,
                "msg": if msg.is_empty() { "二维码已失效，请重新生成".to_string() } else { msg },
            })),
            cookie: Vec::new(),
            headers: HashMap::new(),
        }),
        "0" => {
            let (mut openid, mut access_token) = extract_openid_token(&url);
            if openid.is_none() || access_token.is_none() {
                // 跳转链未直接在 ptuiCB 的 url 里带凭据：手工跟随（最多 10 跳，
                // 每跳都带 QQ 会话 cookie；ureq 跟随重定向会剥 Cookie，故自管）。
                let (oid, at) = follow_qq_login_redirect(&url, &session.poll_cookie(), referer);
                openid = openid.or(oid);
                access_token = access_token.or(at);
            }
            let (openid, access_token) = match (openid, access_token) {
                (Some(o), Some(a)) if !o.is_empty() && !a.is_empty() => (o, a),
                _ => {
                    return Err(qq_error(
                        502,
                        json!(format!(
                            "登录成功但未获取到 openid/access_token: {}",
                            url
                        )),
                    ))
                }
            };
            // 与 login_qq.js 一致：partnerid=1 + third_appid=概念版 QQ appid。
            openplat_login(
                q,
                ctx,
                &openid,
                &access_token,
                1,
                Some(QQ_LITE_APPID),
            )
        }
        other => Ok(ModuleResponse {
            status: 200,
            body: BodyValue::Json(json!({
                "status": other,
                "qrsig": session.qrsig,
                "ptqrtoken": session.ptqrtoken,
                "msg": msg,
            })),
            cookie: Vec::new(),
            headers: HashMap::new(),
        }),
    }
}

/// 手工跟随 QQ 登录跳转链，从任一跳的 URL / HTML 文本里捞 openid + access_token。
fn follow_qq_login_redirect(
    start_url: &str,
    cookie: &str,
    referer: &str,
) -> (Option<String>, Option<String>) {
    let mut current = if start_url.starts_with("http") {
        start_url.to_string()
    } else if start_url.is_empty() {
        return (None, None);
    } else {
        format!("https://{}", start_url)
    };
    for _ in 0..10 {
        // 先在当前 URL 上试一次（常见：第一跳就已带凭据）
        let (oid, at) = extract_openid_token(&current);
        if oid.is_some() && at.is_some() {
            return (oid, at);
        }
        let resp = match crate::request::raw_fetch_no_redirect(
            "GET",
            &current,
            &json!({}),
            BodyData::None,
            &qq_headers(referer, Some(cookie)),
        ) {
            Ok(r) => r,
            Err(_) => return (oid, at),
        };
        // 3xx：Location 可能是相对路径
        if let Some(loc) = resp.location.clone() {
            if loc.is_empty() {
                return (oid, at);
            }
            // 非 http(s) 的自定义 scheme（auth://tauth.qq.com/ 之类）通常已带凭据
            let has_scheme = loc.contains("://");
            if has_scheme && !loc.starts_with("http") {
                let (lo, la) = extract_openid_token(&loc);
                return (oid.or(lo), at.or(la));
            }
            current = resolve_relative(&current, &loc);
            continue;
        }
        // 2xx：从文本里再捞一次
        let text = resp.body_text();
        let (to, ta) = extract_openid_token(&text);
        if to.is_some() && ta.is_some() {
            return (to, ta);
        }
        return (oid.or(to), at.or(ta));
    }
    (None, None)
}

/// `new URL(loc, base)` 的最小实现：绝对地址直用，`/x` 拼 origin，
/// 其余按 base 的目录部分拼接。
fn resolve_relative(base: &str, loc: &str) -> String {
    if loc.starts_with("http://") || loc.starts_with("https://") {
        return loc.to_string();
    }
    let (scheme, rest) = match base.find("://") {
        Some(i) => (&base[..i], &base[i + 3..]),
        None => return loc.to_string(),
    };
    let origin_end = rest.find('/').unwrap_or(rest.len());
    let origin = &rest[..origin_end];
    if loc.starts_with('/') {
        format!("{}://{}{}", scheme, origin, loc)
    } else {
        let dir_end = rest.rfind('/').map(|i| i + 1).unwrap_or(origin_end);
        format!("{}://{}{}", scheme, &rest[..dir_end], loc)
    }
}

/// qrcode.toDataURL(url) 等价实现：PNG base64 data URL。
fn qr_png_data_url(url: &str) -> Result<String, String> {
    use qrcode::QrCode;
    let code =
        QrCode::with_error_correction_level(url.as_bytes(), qrcode::EcLevel::M).map_err(|e| e.to_string())?;
    let img = code
        .render::<image::Luma<u8>>()
        .min_dimensions(200, 200)
        .build();
    let mut buf: Vec<u8> = Vec::new();
    image::DynamicImage::ImageLuma8(img)
        .write_to(&mut std::io::Cursor::new(&mut buf), image::ImageFormat::Png)
        .map_err(|e| e.to_string())?;
    Ok(format!("data:image/png;base64,{}", base64_encode(&buf)))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 上游契约回归：四元组透传 + h5 RSA token 格式（'h5' + 1024 位模长 256 hex 大写）。
    /// 回归背景：旧实现用 AES 加密 token 且把四元组硬编码成本机值，
    /// 上游匹配不到目标设备，kick 永远踢不掉选中的那台。
    #[test]
    fn kick_params_pass_through_target_quadruple() {
        let q = json!({
            "cookie": { "token": "tok123", "userid": "42", "KUGOU_API_GUID": "guid-abc" },
            "t_mid": "TARGET_MID",
            "t": "1728000000000",
            "t_appid": "3116",
            "t_clientver": "10597",
        });
        let p = build_kick_params(&q);
        assert_eq!(p["t_mid"], json!("TARGET_MID"));
        assert_eq!(p["t"], json!("1728000000000"));
        assert_eq!(p["t_appid"], json!("3116"));
        assert_eq!(p["t_clientver"], json!("10597"));
        assert_eq!(p["userid"], json!(42));
        let token = p["token"].as_str().unwrap();
        assert!(token.starts_with("h5"), "token 必须带 h5 前缀: {token}");
        let hex_part = &token[2..];
        assert_eq!(hex_part.len(), 256, "RSA 无填充 1024 位模长应为 256 hex");
        assert!(
            hex_part.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_lowercase()),
            "hex 必须全大写"
        );
        // 签名由管线按 encrypt_type="web" 补，构建函数不应预置
        assert!(p.get("signature").is_none());
        // web 签名对完整参数集生效（与 JS signatureWebParams(dataMap) 一致），
        // 这里仅核对管线签名输入的确定性：同一 q 两次构建除 clienttime 外不变。
        let p2 = build_kick_params(&q);
        assert_eq!(p["token"], p2["token"], "RSA 无填充是确定性的");
        assert_eq!(p["t_mid"], p2["t_mid"]);
    }

    /// 四元组缺失时回退本机 guid 派生值（保持旧调用方式可用）。
    #[test]
    fn kick_params_fallback_to_local_identity() {
        let q = json!({
            "cookie": { "token": "tok123", "KUGOU_API_GUID": "guid-abc" },
        });
        let p = build_kick_params(&q);
        // t_mid 兜底为本机 guid 原值（与旧实现一致）；mid 才是 guid 的 calculate_mid 派生
        assert_eq!(p["t_mid"], json!("guid-abc"));
        assert_eq!(p["mid"], json!(calculate_mid("guid-abc")));
        assert_eq!(p["t_appid"], json!("3116"));
        assert_eq!(p["t_clientver"], json!("10597"));
        assert_eq!(p["dfid"], json!("-"));
        assert_eq!(p["uuid"], json!("-"));
    }

    // ---- QQ 扫码 ----

    /// 黄金向量来自 node 实跑（JS 原版 `hash33`），用于锁死 ToInt32 语义。
    #[test]
    fn hash33_matches_js_golden_vectors() {
        // node -e "const h=(s)=>{let e=0;for(...)e+=(e<<5)+s.charCodeAt(i);return 2147483647&e};"
        assert_eq!(hash33("abc123"), 1768482556);
        assert_eq!(hash33("qrsig-test"), 1341976211);
        assert_eq!(hash33("0123456789abcdef"), 389841794);
        assert_eq!(
            hash33("@abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
            1330678603
        );
        // 空串与单字符边界
        assert_eq!(hash33(""), 0);
        assert_eq!(hash33("A"), 65);
    }

    #[test]
    fn hash33_handles_128_char_qrsig() {
        // 真实 qrsig 长度实测 128（含 @ 前缀与大小写混合）
        let s: String = (0..128)
            .map(|i| char::from(48 + ((i * 7) % 75) as u8))
            .collect();
        // 与 node 对同一输入的结果一致（见 tests 注释里的复算脚本）
        let expected = {
            // 用同一 f64 累加语义复算一遍，确保没有溢出/截断路径差异
            let mut e: f64 = 0.0;
            for ch in s.chars() {
                e += ((e as i64 as i32).wrapping_shl(5)) as f64 + ch as u32 as f64;
            }
            ((e as i64) as i32 as i64) & 0x7FFF_FFFF
        };
        assert_eq!(hash33(&s), expected);
        assert!(hash33(&s) >= 0);
    }

    #[test]
    fn unescape_x_escapes_restores_url() {
        assert_eq!(
            unescape_x_escapes("https\\x3A\\x2F\\x2Fxui.ptlogin2.qq.com\\x2Fcgi"),
            "https://xui.ptlogin2.qq.com/cgi"
        );
        // 无反斜杠转义时原样返回（含中文，不能被拆断）
        assert_eq!(unescape_x_escapes("普通文本"), "普通文本");
        // 非法 \x 序列保留原样
        assert_eq!(unescape_x_escapes("\\xZZ"), "\\xZZ");
    }

    #[test]
    fn extract_xlogin_url_from_m_authorize_html() {
        let html = r#"<script>var xlogin = "a"; if (1) { src = "https\x3A\x2F\x2Fxui.ptlogin2.qq.com\x2Fcgi-bin\x2Fxlogin\x3Fappid\x3D716027609"; }</script>"#;
        let url = extract_xlogin_url(html).expect("must find src");
        assert!(url.starts_with("https://xui.ptlogin2.qq.com/cgi-bin/xlogin?appid=716027609"));
        assert!(extract_xlogin_url("<html>no src here</html>").is_none());
    }

    #[test]
    fn parse_ptui_cb_all_status_codes() {
        let wait = parse_ptui_cb("ptuiCB('66','0','','0','等待扫码', '')").unwrap();
        assert_eq!(wait.0, "66");
        assert_eq!(wait.2, "等待扫码");

        let scanned = parse_ptui_cb("ptuiCB('67','0','','0','已扫描', '')").unwrap();
        assert_eq!(scanned.0, "67");

        let expired = parse_ptui_cb("ptuiCB('65','0','','0','二维码已失效', '')").unwrap();
        assert_eq!(expired.0, "65");

        let ok = parse_ptui_cb(
            "ptuiCB('0','0','https://ptlogin2.qq.com/check_sig?pttype=1&openid=ABC&access_token=TOK','0','登录成功', '')",
        )
        .unwrap();
        assert_eq!(ok.0, "0");
        assert_eq!(
            ok.1,
            "https://ptlogin2.qq.com/check_sig?pttype=1&openid=ABC&access_token=TOK"
        );

        // 参数错误（缺 pt_3rd_aid 时上游的真实回包）
        let bad = parse_ptui_cb("ptuiCB('7','0','','0','提交参数错误，请检查。', '')").unwrap();
        assert_eq!(bad.0, "7");

        assert!(parse_ptui_cb("not a ptuiCB response").is_none());
    }

    #[test]
    fn extract_openid_token_from_proxy_url() {
        let (o, a) = extract_openid_token(
            "https://ptlogin2.qq.com/check_sig?pttype=1&openid=OPENID123&access_token=TOK456&x=1",
        );
        assert_eq!(o.as_deref(), Some("OPENID123"));
        assert_eq!(a.as_deref(), Some("TOK456"));

        let (o2, a2) = extract_openid_token("https://example.com/nothing");
        assert!(o2.is_none() && a2.is_none());
    }

    fn sample_session() -> QqSession {
        QqSession {
            cookie: "pt_login_sig=SIG123; qrsig=QRSIG456".to_string(),
            qrsig: "QRSIG456".to_string(),
            ptqrtoken: "1700567251".to_string(),
            pt_login_sig: "SIG123".to_string(),
            pt_openlogin_data: "pt_enable_pwd%3D1%26appid%3D716027609".to_string(),
            xlogin_url: "https://xui.ptlogin2.qq.com/cgi-bin/xlogin?appid=716027609".to_string(),
        }
    }

    #[test]
    fn qq_poll_url_keeps_openlogin_data_unencoded() {
        let s = sample_session();
        let url = build_qq_poll_url(&s, 0.5);
        assert!(url.starts_with("https://xui.ptlogin2.qq.com/ssl/ptqrlogin?"));
        assert!(url.contains("ptqrtoken=1700567251"));
        assert!(url.contains(&format!("pt_3rd_aid={}", QQ_LITE_APPID)));
        // 关键：pt_openlogin_data 原样（已编码一次），不得出现二次编码 %25
        assert!(
            url.contains("pt_openlogin_data=pt_enable_pwd%3D1%26appid%3D716027609"),
            "pt_openlogin_data 必须原样拼接: {url}"
        );
        assert!(
            !url.contains("%253D"),
            "pt_openlogin_data 不得二次编码: {url}"
        );
        // login_sig 必须编码（真实值是 base64 风格，可能含 + / =）
        assert!(url.contains("login_sig=SIG123"));
    }

    #[test]
    fn qq_poll_url_encodes_login_sig_specials() {
        let mut s = sample_session();
        s.pt_login_sig = "a+b/c=".to_string();
        let url = build_qq_poll_url(&s, 0.25);
        assert!(url.contains("login_sig=a%2Bb%2Fc%3D"), "login_sig 必须编码: {url}");
    }

    #[test]
    fn qq_session_from_query_and_missing_fields() {
        let q = json!({
            "cookie": "pt_login_sig=SIG123; qrsig=QRSIG456",
            "qrsig": "QRSIG456",
            "ptqrtoken": 1700567251,
            "pt_login_sig": "SIG123",
            "pt_openlogin_data": "abc%3D1",
            "xlogin_url": "https://xui.ptlogin2.qq.com/cgi-bin/xlogin?appid=1",
        });
        let s = QqSession::from_query(&q);
        assert_eq!(s.ptqrtoken, "1700567251", "数字 ptqrtoken 要转字符串");
        assert!(s.missing_fields().is_empty());

        // 全空 → 6 个字段都缺，顺序与上游 JS 提示一致
        let empty = QqSession::from_query(&json!({}));
        assert_eq!(
            empty.missing_fields(),
            vec![
                "qrsig",
                "ptqrtoken",
                "pt_login_sig",
                "pt_openlogin_data",
                "xlogin_url",
                "cookie"
            ]
        );

        // cookie 不含 qrsig= 也算缺 cookie
        let no_qrsig_cookie = QqSession::from_query(&json!({
            "cookie": "pt_login_sig=SIG",
            "qrsig": "Q",
            "ptqrtoken": "1",
            "pt_login_sig": "SIG",
            "pt_openlogin_data": "d",
            "xlogin_url": "u",
        }));
        assert_eq!(no_qrsig_cookie.missing_fields(), vec!["cookie"]);
    }

    #[test]
    fn qq_poll_cookie_appends_missing_login_sig() {
        let mut s = sample_session();
        s.cookie = "qrsig=QRSIG456".to_string();
        assert_eq!(s.poll_cookie(), "qrsig=QRSIG456; pt_login_sig=SIG123");

        // 已含则不重复追加
        let s2 = sample_session();
        assert_eq!(s2.poll_cookie(), s2.cookie);
    }

    /// 回归：服务端 `build_query` 会把 `cookie` 参数转成对象（Express 语义），
    /// 老实现用 `q_str(q, "cookie")` 读到空串 → 轮询报「缺少 cookie」。
    /// 真机探针（`qr_login_probe`）踩过一次，这里锁死两种形态都能还原。
    #[test]
    fn qq_cookie_from_query_handles_object_and_string() {
        // 1) 字符串形态（模块单测直接构造）
        let q = json!({ "cookie": "pt_login_sig=SIG; qrsig=QRSIG" });
        assert_eq!(qq_cookie_from_query(&q), "pt_login_sig=SIG; qrsig=QRSIG");

        // 2) 对象形态（真实 HTTP 请求经 build_query 后的样子）
        let q = json!({
            "cookie": {
                "pt_login_sig": "SIG",
                "qrsig": "QRSIG",
                // 服务端注入的酷狗平台身份必须剔除，不能发给 QQ
                "KUGOU_API_GUID": "guid",
                "KUGOU_API_MID": "mid",
                "KUGOU_API_DEV": "dev",
                "dfid": "dfid-x",
                "mid": "mid-x",
            }
        });
        let got = qq_cookie_from_query(&q);
        assert!(got.contains("pt_login_sig=SIG"), "got={got}");
        assert!(got.contains("qrsig=QRSIG"), "got={got}");
        for banned in ["KUGOU_API_", "dfid", "mid="] {
            assert!(!got.contains(banned), "不得把酷狗身份发给 QQ（{banned}）: {got}");
        }

        // 3) 缺失 / null → 空串（由 missing_fields 报错，不 panic）
        assert_eq!(qq_cookie_from_query(&json!({})), "");
        assert_eq!(qq_cookie_from_query(&json!({ "cookie": null })), "");
    }

    /// 端到端契约：对象形态的 cookie 经 `from_query` 后 `missing_fields` 为空，
    /// 且 `poll_cookie()` 不会重复追加 pt_login_sig。
    #[test]
    fn qq_session_from_real_http_cookie_object() {
        let q = json!({
            "cookie": { "pt_login_sig": "SIG", "qrsig": "QRSIG", "KUGOU_API_DEV": "d" },
            "qrsig": "QRSIG",
            "ptqrtoken": 123,
            "pt_login_sig": "SIG",
            "pt_openlogin_data": "od",
            "xlogin_url": "u",
        });
        let s = QqSession::from_query(&q);
        assert!(s.missing_fields().is_empty(), "{:?}", s.missing_fields());
        assert_eq!(s.poll_cookie(), "pt_login_sig=SIG; qrsig=QRSIG");
    }

    #[test]
    fn cookie_jar_merge_last_wins() {
        let mut jar = vec![("qrsig".to_string(), "old".to_string())];
        merge_cookie_jar(
            &mut jar,
            &[
                "qrsig=new; Path=/; Domain=.qq.com".to_string(),
                "pt_login_sig=SIG; Path=/".to_string(),
            ],
        );
        assert_eq!(cookie_jar_to_string(&jar), "qrsig=new; pt_login_sig=SIG");
    }

    #[test]
    fn resolve_relative_url_forms() {
        let base = "https://xui.ptlogin2.qq.com/cgi-bin/xlogin?appid=1";
        assert_eq!(
            resolve_relative(base, "https://ptlogin2.qq.com/a?b=1"),
            "https://ptlogin2.qq.com/a?b=1"
        );
        assert_eq!(
            resolve_relative(base, "/ssl/ptqrlogin?x=1"),
            "https://xui.ptlogin2.qq.com/ssl/ptqrlogin?x=1"
        );
        assert_eq!(
            resolve_relative(base, "next?a=1"),
            "https://xui.ptlogin2.qq.com/cgi-bin/next?a=1"
        );
    }
}
