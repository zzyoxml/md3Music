use crate::crypto::{md5_hex, md5_hex_4};
use serde_json::Value;

pub const ROUTE: &str = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA";
pub const ROUTE_WEB: &str = "NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt";
pub const SIGN_KEY_STR: &str = "185672dd44712f60bb1736df5a377e82";
pub const SIGN_CLOUD_STR: &str = "ebd1ac3134c880bda6a2194537843caa0162e2e7";
pub const SIGN_PARAMS_STR: &str = "R6snCXJgbCaj9WFRJKefTMIFp0ey6Gza";
pub const SIGN_PARAMS_KEY_STR: &str = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA";
pub const SIGN_PASSWORD_STR: &str = "NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt";

/// format params as `key=value` joined, sorted by key. object values JSON.stringify'd.
pub fn params_joined_sorted(params: &Value) -> String {
    let mut keys: Vec<&String> = match params.as_object() {
        Some(m) => m.keys().collect(),
        None => return String::new(),
    };
    keys.sort();
    keys.iter()
        .map(|k| {
            let v = params.get(*k).unwrap_or(&Value::Null);
            let vs = match v {
                Value::Object(_) | Value::Array(_) => crate::util::json_stringify(v),
                Value::String(s) => s.clone(),
                Value::Number(n) => n.to_string(),
                Value::Bool(b) => b.to_string(),
                Value::Null => "null".to_string(),
            };
            format!("{}={}", k, vs)
        })
        .collect::<Vec<_>>()
        .join("")
}

pub fn signature_android_params(params: &Value, data: &[u8], is_buffer: bool) -> String {
    let params_string = params_joined_sorted(params);
    if is_buffer {
        md5_hex_4(ROUTE.as_bytes(), params_string.as_bytes(), data, ROUTE.as_bytes())
    } else {
        let data_str = std::str::from_utf8(data).unwrap_or("");
        md5_hex(format!("{}{}{}{}", ROUTE, params_string, data_str, ROUTE).as_bytes())
    }
}

/// 标准版(非概念版) Android signature：盐用 OIlwieks28dk2k092lksi2UIkp。
/// 刷刷(brush) feed 接口 appid=1005 需要，否则上游报 20006 签名错误。
pub fn signature_android_params_standard(params: &Value, data: &[u8], is_buffer: bool) -> String {
    const STANDARD_ROUTE: &str = "OIlwieks28dk2k092lksi2UIkp";
    let params_string = params_joined_sorted(params);
    if is_buffer {
        md5_hex_4(
            STANDARD_ROUTE.as_bytes(),
            params_string.as_bytes(),
            data,
            STANDARD_ROUTE.as_bytes(),
        )
    } else {
        let data_str = std::str::from_utf8(data).unwrap_or("");
        md5_hex(format!("{}{}{}{}", STANDARD_ROUTE, params_string, data_str, STANDARD_ROUTE).as_bytes())
    }
}

pub fn signature_web_params(params: &Value) -> String {
    let mut parts: Vec<String> = match params.as_object() {
        Some(m) => m
            .iter()
            .map(|(k, v)| format!("{}={}", k, js_coerce(v)))
            .collect(),
        None => return String::new(),
    };
    parts.sort();
    let params_string = parts.join("");
    md5_hex(format!("{}{}{}", ROUTE_WEB, params_string, ROUTE_WEB).as_bytes())
}

/// JS template-string coercion for a value inside a signature map.
pub fn js_coerce(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Null => "null".to_string(),
        Value::Object(_) | Value::Array(_) => crate::util::json_stringify(v),
    }
}

pub fn signature_register_params(params: &Value) -> String {
    let mut values: Vec<String> = match params.as_object() {
        Some(m) => m.values().map(js_coerce).collect(),
        None => return String::new(),
    };
    values.sort();
    let params_string = values.join("");
    md5_hex(format!("1014{}1014", params_string).as_bytes())
}

pub fn sign_key(hash: &str, mid: &str, userid: &str, appid: &str) -> String {
    let appid = if appid.is_empty() { "3116" } else { appid };
    let uid = if userid.is_empty() { "0" } else { userid };
    md5_hex(format!("{}{}{}{}{}", hash, SIGN_KEY_STR, appid, mid, uid).as_bytes())
}

pub fn sign_cloud_key(hash: &str, pid: &str) -> String {
    md5_hex(format!("musicclound{}{}{}", hash, pid, SIGN_CLOUD_STR).as_bytes())
}

pub fn sign_params_key(data: &str, appid: &str, clientver: &str) -> String {
    let appid = if appid.is_empty() { "3116" } else { appid };
    let clientver = if clientver.is_empty() { "11440" } else { clientver };
    md5_hex(format!("{}{}{}{}", appid, SIGN_PARAMS_KEY_STR, clientver, data).as_bytes())
}

/// 刷刷(brush) feed 接口只认标准版(非概念版)签名：
/// key = md5(1005 + 标准盐 + 20489 + data)，与 JS 标准版 signParamsKey(dateTime) 对齐。
pub fn sign_params_key_standard(data: &str) -> String {
    md5_hex(format!("1005{}20489{}", "OIlwieks28dk2k092lksi2UIkp", data).as_bytes())
}

/// signParams used by user_cloud etc.
pub fn sign_params(params: &Value, data: &str) -> String {
    let mut keys: Vec<&String> = match params.as_object() {
        Some(m) => m.keys().collect(),
        None => return String::new(),
    };
    keys.sort();
    let params_string: String = keys
        .iter()
        .map(|k| {
            let v = params.get(*k).unwrap_or(&Value::Null);
            let vs = match v {
                Value::String(s) => s.clone(),
                Value::Number(n) => n.to_string(),
                Value::Bool(b) => b.to_string(),
                Value::Null => "null".to_string(),
                Value::Object(_) | Value::Array(_) => crate::util::json_stringify(v),
            };
            format!("{}{}", k, vs)
        })
        .collect();
    md5_hex(format!("{}{}{}", params_string, data, SIGN_PARAMS_STR).as_bytes())
}
