//! register_dev.js → /register/dev（设备注册，获取 dfid）。

use crate::crypto::{playlist_aes_decrypt, playlist_aes_encrypt, rsa_encrypt2};
use crate::modules::{c_str, param_or_cookie_num, param_or_cookie_str, q_cookie, q_num, q_str, Ctx};
use crate::request::{BodyValue, ModuleResponse, RequestOptions};
use crate::util::json_stringify;
use serde_json::{json, Map, Value};

pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = param_or_cookie_num(q, "userid", 0);
    let token = param_or_cookie_str(q, "token", "");
    let guid = c_str(q, "KUGOU_API_GUID");

    let mut dm: Map<String, Value> = Map::new();
    dm.insert("availableRamSize".to_string(), json!(q_num(q, "availableRamSize", 4983533568)));
    dm.insert("availableRomSize".to_string(), json!(q_num(q, "availableRomSize", 48114719)));
    dm.insert("availableSDSize".to_string(), json!(q_num(q, "availableSDSize", 48114717)));
    dm.insert("basebandVer".to_string(), json!(q_str(q, "basebandVer", "")));
    dm.insert("batteryLevel".to_string(), json!(q_num(q, "batteryLevel", 100)));
    dm.insert("batteryStatus".to_string(), json!(q_num(q, "batteryStatus", 3)));
    dm.insert("brand".to_string(), json!(q_str(q, "brand", "Redmi")));
    dm.insert("buildSerial".to_string(), json!(q_str(q, "buildSerial", "unknown")));
    dm.insert("device".to_string(), json!(q_str(q, "device", "marble")));
    dm.insert("manufacturer".to_string(), json!(q_str(q, "manufacturer", "Xiaomi")));
    dm.insert("imsi".to_string(), json!(q_str(q, "imsi", "")));
    dm.insert("accelerometer".to_string(), json!(q_bool(q, "accelerometer", false)));
    dm.insert("accelerometerValue".to_string(), json!(q_str(q, "accelerometerValue", "")));
    dm.insert("gravity".to_string(), json!(q_bool(q, "gravity", false)));
    dm.insert("gravityValue".to_string(), json!(q_str(q, "gravityValue", "")));
    dm.insert("gyroscope".to_string(), json!(q_bool(q, "gyroscope", false)));
    dm.insert("gyroscopeValue".to_string(), json!(q_str(q, "gyroscopeValue", "")));
    dm.insert("light".to_string(), json!(q_bool(q, "light", false)));
    dm.insert("lightValue".to_string(), json!(q_str(q, "lightValue", "")));
    dm.insert("magnetic".to_string(), json!(q_bool(q, "magnetic", false)));
    dm.insert("magneticValue".to_string(), json!(q_str(q, "magneticValue", "")));
    dm.insert("orientation".to_string(), json!(q_bool(q, "orientation", false)));
    dm.insert("orientationValue".to_string(), json!(q_str(q, "orientationValue", "")));
    dm.insert("pressure".to_string(), json!(q_bool(q, "pressure", false)));
    dm.insert("pressureValue".to_string(), json!(q_str(q, "pressureValue", "")));
    dm.insert("step_counter".to_string(), json!(q_bool(q, "step_counter", false)));
    dm.insert("step_counterValue".to_string(), json!(q_str(q, "step_counterValue", "")));
    dm.insert("temperature".to_string(), json!(q_bool(q, "temperature", false)));
    dm.insert("temperatureValue".to_string(), json!(q_str(q, "temperatureValue", "")));

    // imei/uuid：JS 中 undefined 值会被 JSON.stringify 省略
    if let Some(v) = param_or_cookie_guid(q, "imei", &guid) {
        dm.insert("imei".to_string(), json!(v));
    }
    if let Some(v) = param_or_cookie_guid(q, "uuid", &guid) {
        dm.insert("uuid".to_string(), json!(v));
    }

    let data_json = json_stringify(&Value::Object(dm));
    let (key, aes_str) = playlist_aes_encrypt(&data_json);
    let p_body = json_stringify(&json!({ "aes": key, "uid": userid, "token": token }));
    let p = rsa_encrypt2(&p_body);

    let opts = RequestOptions::new("/risk/v2/r_register_dev")
        .base_url("https://userservice.kugou.com")
        .post("/risk/v2/r_register_dev")
        .params(json!({ "part": 1, "platid": 1, "p": p }))
        .string_body(aes_str)
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .response_type("arraybuffer");

    let res = ctx.send(&opts)?;
    let b64 = res.body.to_base64();
    let dec = playlist_aes_decrypt(&key, &b64);

    let status = dec.get("status").and_then(Value::as_i64).unwrap_or(0);
    let mut answer = ModuleResponse {
        status: res.status,
        body: BodyValue::Json(dec.clone()),
        cookie: res.cookie,
        headers: res.headers,
    };
    if status == 1 {
        if let Some(dfid) = dec.get("data").and_then(|d| d.get("dfid")).and_then(Value::as_str) {
            answer.cookie.push(format!("dfid={}", dfid));
        }
    }
    Ok(answer)
}

fn q_bool(q: &Value, key: &str, default: bool) -> bool {
    match q.get(key) {
        None | Some(Value::Null) => default,
        Some(Value::Bool(b)) => *b,
        Some(Value::String(s)) => {
            if s.is_empty() {
                default
            } else {
                s != "false"
            }
        }
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0) != 0,
        _ => default,
    }
}

/// `params?.x || cookie.KUGOU_API_GUID`（两者皆缺则省略该键）。
fn param_or_cookie_guid(q: &Value, key: &str, guid: &str) -> Option<String> {
    let pv = q_str(q, key, "");
    if !pv.is_empty() {
        return Some(pv);
    }
    if !guid.is_empty() {
        return Some(guid.to_string());
    }
    None
}
