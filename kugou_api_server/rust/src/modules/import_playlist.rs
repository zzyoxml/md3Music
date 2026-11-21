//! import_playlist: 导入外部平台歌单（酷狗云端导入任务）。对应 JS module/import_playlist.js → POST /import/playlist
//! 通过 body.operation 区分 5 种操作：
//!   add_task（task_type=0 链接导入 / task_type=1 截图导入）、
//!   submit_img（上传截图）、task_count、query_task_status、query_task。
//! 上游 gateway.kugou.com，android 签名，clearDefaultParams（query 全字符串手工构造）。
//! 注意：服务器存在 2 分钟响应缓存，调用方应附加变化的 timestamp 查询参数。

use crate::cache::now_epoch_secs;
use crate::config::{APP_ID, CLIENT_VER};
use crate::helper::js_coerce;
use crate::modules::{or_num, or_str, q_cookie, Ctx};
use crate::request::{BodyValue, ModuleResponse, RequestOptions};
use serde_json::{json, Value};
use std::collections::HashMap;

const GATEWAY_BASE: &str = "https://gateway.kugou.com";

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// JS truthiness：null/""/0/NaN/false → false，对象/数组恒真。
fn js_truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::String(s) => !s.is_empty(),
        Value::Number(n) => n.as_f64().map(|f| f != 0.0 && !f.is_nan()).unwrap_or(false),
        Value::Array(_) | Value::Object(_) => true,
    }
}

/// JS `obj[key] ||`：truthy 时取原值引用，否则 None。
fn truthy_get<'a>(obj: &'a Value, key: &str) -> Option<&'a Value> {
    obj.get(key).filter(|v| js_truthy(v))
}

/// JS Number() 强转；NaN/Infinity/不可转换 → None。
fn js_number(v: &Value) -> Option<f64> {
    let f = match v {
        Value::Number(n) => n.as_f64()?,
        Value::String(s) => s.trim().parse::<f64>().ok()?,
        Value::Bool(b) => {
            if *b {
                1.0
            } else {
                0.0
            }
        }
        Value::Null => 0.0,
        Value::Array(_) | Value::Object(_) => return None,
    };
    if f.is_finite() {
        Some(f)
    } else {
        None
    }
}

/// JS Number 序列化：整数不带小数点。
fn num_json(f: f64) -> Value {
    if f.fract() == 0.0 && f.abs() <= 9.0e15 {
        json!(f as i64)
    } else {
        json!(f)
    }
}

/// JS parseIds：数组 / JSON 数组字符串 / 逗号分隔字符串 / 单值 → Number[]。
fn parse_ids(value: Option<&Value>) -> Value {
    let to_nums = |arr: &[Value]| -> Value {
        Value::Array(arr.iter().filter_map(js_number).map(num_json).collect())
    };
    match value {
        Some(Value::Array(arr)) => to_nums(arr),
        Some(Value::String(s)) => {
            if let Ok(Value::Array(arr)) = serde_json::from_str::<Value>(s) {
                return to_nums(&arr);
            }
            let parts: Vec<Value> = s
                .split(',')
                .filter_map(|p| js_number(&Value::String(p.to_string())).map(num_json))
                .collect();
            Value::Array(parts)
        }
        Some(v) => match js_number(v) {
            Some(n) => Value::Array(vec![num_json(n)]),
            None => Value::Array(vec![]),
        },
        None => Value::Array(vec![]),
    }
}

/// 去掉 JS `/^data:image\/[^;]+;base64,/` 形式的 data-URI 前缀。
fn strip_data_uri(s: &str) -> String {
    if let Some(rest) = s.strip_prefix("data:image/") {
        if let Some(pos) = rest.find(";base64,") {
            if !rest[..pos].contains(';') {
                return rest[pos + 8..].to_string();
            }
        }
    }
    s.to_string()
}

/// POST /import/playlist（body 中 operation 分发）。
pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    // JS `input = { ...params, ...parseBody(params?.body) }`：body 字段覆盖顶层。
    let mut input = q.clone();
    if let (Some(obj), Some(Value::Object(bm))) = (input.as_object_mut(), q.get("body")) {
        for (k, v) in bm {
            obj.insert(k.clone(), v.clone());
        }
    }
    let cookie = q_cookie(q);

    // JS `String(input.userid || cookie.userid || '')`
    let userid = truthy_get(&input, "userid")
        .or_else(|| truthy_get(&cookie, "userid"))
        .map(js_coerce)
        .unwrap_or_default();
    // JS `input.token || cookie.token || ''`（保留原类型）
    let token = truthy_get(&input, "token")
        .or_else(|| truthy_get(&cookie, "token"))
        .cloned()
        .unwrap_or_else(|| json!(""));

    let clienttime = now_epoch_secs() as i64;
    let query = json!({
        "appid": APP_ID,
        "clientver": CLIENT_VER,
        "clienttime": clienttime.to_string(),
        "mid": or_str(&input, "mid", &or_str(&cookie, "KUGOU_API_MID", "-")),
        "uuid": or_str(&input, "uuid", &or_str(&cookie, "uuid", "-")),
        "dfid": or_str(&input, "dfid", &or_str(&cookie, "dfid", "-")),
    });

    let send = |url: &str, data: Value| -> Result<ModuleResponse, ModuleResponse> {
        let opts = RequestOptions::new(url)
            .base_url(GATEWAY_BASE)
            .post(url)
            .params(query.clone())
            .json_body(data)
            .encrypt_type("android")
            .cookie(cookie.clone())
            .header("Content-Type", "application/json;charset=utf-8")
            .clear_default_params(true);
        ctx.send(&opts)
    };

    let operation = or_str(&input, "operation", "");
    match operation.as_str() {
        "add_task" => {
            let task_type = or_num(&input, "task_type", 0);
            let mut data = json!({
                "userid": userid,
                "token": token,
                "source": or_num(&input, "source", 3),
                "task_type": task_type,
            });
            let obj = data.as_object_mut().unwrap();
            if task_type == 0 {
                obj.insert("url".to_string(), json!(or_str(&input, "url", "")));
            } else {
                obj.insert("listid".to_string(), json!(or_num(&input, "listid", 0)));
                if let Some(ln) = truthy_get(&input, "list_name") {
                    obj.insert("list_name".to_string(), json!(js_coerce(ln)));
                }
                let task_sn = or_str(&input, "task_sn", "");
                obj.insert(
                    "task_sn".to_string(),
                    json!(if task_sn.is_empty() {
                        format!("{}{}", userid, now_ms())
                    } else {
                        task_sn
                    }),
                );
            }
            send("/assetservice/import/v1/add_task", data)
        }
        "submit_img" => {
            let img_base64 = strip_data_uri(&or_str(&input, "img_base64", ""));
            let data = json!({
                "userid": userid,
                "token": token,
                "img_base64": img_base64,
                "task_sn": or_str(&input, "task_sn", ""),
            });
            send("/assetservice/import/v1/submit_img", data)
        }
        "task_count" => {
            let data = json!({
                "userid": userid,
                "token": token,
                "classify": or_num(&input, "classify", 1),
            });
            send("/assetservice/import/v1/task_count", data)
        }
        "query_task_status" => {
            let data = json!({
                "userid": userid,
                "token": token,
                "ids": parse_ids(input.get("ids")),
            });
            send("/assetservice/import/v1/query_task_status", data)
        }
        "query_task" => {
            // JS `Number(input.show_missed ?? 1) ? 1 : 0`
            let show_missed = match input.get("show_missed") {
                None | Some(Value::Null) => 1,
                Some(v) => {
                    if js_number(v).map(|n| n != 0.0).unwrap_or(false) {
                        1
                    } else {
                        0
                    }
                }
            };
            let data = json!({
                "userid": userid,
                "token": token,
                "listid": or_str(&input, "listid", ""),
                "page": or_num(&input, "page", 1).max(1),
                "pagesize": or_num(&input, "pagesize", 30).max(1),
                "show_missed": show_missed,
            });
            send("/pubsongs/v1/query_task", data)
        }
        _ => Err(ModuleResponse {
            status: 400,
            body: BodyValue::Json(json!({
                "status": 0,
                "error_code": 400,
                "error_msg": format!("不支持的操作: {}", operation),
            })),
            cookie: Vec::new(),
            headers: HashMap::new(),
        }),
    }
}
