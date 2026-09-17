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
    forward(
        q, ctx, "POST", "/v2/get_dev", Some("https://userinfoservice.kugou.com"),
        None, Some(data_map), "android", &[], false, false,
    )
}

/// login_device_kick.js → /login/device/kick（登出选定设备）。
/// 注：JS 原版引用未定义变量（calculateMid/uuid/dfid/userid/guid），这里按合理语义实现。
pub fn handle_device_kick(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
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
    let guid = c_str(q, "KUGOU_API_GUID");
    let mid = {
        let p = q_str(q, "mid", "");
        if !p.is_empty() {
            p
        } else if !guid.is_empty() {
            calculate_mid(&guid)
        } else {
            "".to_string()
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
    let date_time = now_ms();
    let data_map = json!({
        "appid": 3116,
        "clientver": 11440,
        "clienttime": clienttime_ms,
        "mid": mid,
        "uuid": cookie_or_param_str(q, "uuid", "-"),
        "dfid": cookie_or_param_str(q, "dfid", "-"),
        "plat": 1,
        "userid": userid,
        "token": encrypt.0,
        "t_mid": guid,
        "t": date_time,
        "t_appid": 3116,
        "t_clientver": 10597,
        "srcappid": 2919,
        "signature": crate::helper::sign_params_key(&date_time.to_string(), "", ""),
    });
    forward(
        q, ctx, "GET", "/loginservice/v1/dev_logout", None, None, Some(data_map), "android",
        &[("Host", "gateway.kugou.com")], false, false,
    )
}

/// login_openplat.js → /login/openplat（微信开放平台登录）。
pub fn handle_openplat(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let appid = "wx72b795aca60ad321";
    let secret = "33e486041e5e25729a4e3d2da7502f9a";
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
    let date_now = now_ms();
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
    let data_map = json!({
        "dev": c_str(q, "KUGOU_API_DEV"),
        "force_login": 1,
        "partnerid": 36,
        "clienttime_ms": date_now,
        "t1": t1,
        "t2": t2,
        "t3": "MCwwLDAsMCwwLDAsMCwwLDA=",
        "openid": openid,
        "params": encrypt.0,
        "pk": pk,
    });
    let mut res = forward(
        q, ctx, "POST", "/v6/login_by_openplat", None, None, Some(data_map), "android",
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
pub fn handle_wx_check(q: &Value, _ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let uuid = q_str(q, "uuid", "");
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
    let appid = "wx72b795aca60ad321";
    let secret = "33e486041e5e25729a4e3d2da7502f9a";
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
