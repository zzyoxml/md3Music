//! ip 扩展：dateil / playlist / zone / zone/home
//! 对应 JS module/{ip_dateil,ip_playlist,ip_zone,ip_zone_home}.js

use crate::modules::{forward, q_num, q_str, Ctx};
use crate::request::{BodyValue, ModuleResponse};
use crate::util::query_string_to_json;
use serde_json::{json, Value};

/// ip_dateil.js → /ip/dateil（ip 详情）。
pub fn handle_dateil(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let data: Value = q_str(q, "id", "")
        .split(',')
        .map(|s| json!({ "ip_id": s }))
        .collect::<Vec<_>>()
        .into();
    let body = json!({ "data": data, "is_publish": 1 });
    forward(q, ctx, "POST", "/openapi/v1/ip", None, None, Some(body), "android", &[], false, false)
}

/// ip_playlist.js → /ip/playlist（ip 相关歌单）。
pub fn handle_playlist(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params = json!({
        "ip": q.get("id").cloned().unwrap_or(Value::Null),
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
    });
    forward(
        q, ctx, "POST", "/ocean/v6/pubsongs/list_info_for_ip", None,
        Some(params), None, "android", &[], false, false,
    )
}

/// ip_zone.js → /ip/zone（ip 专区，响应重塑：special_link 解析出 ip_id）。
pub fn handle_zone(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let mut res = forward(
        q, ctx, "GET", "/v1/zone/index", None, None, None, "android",
        &[("x-router", "yuekucategory.kugou.com")], false, false,
    )?;
    let mut body = res.body.to_json();
    let status_ok = match body.get("status").and_then(|v| v.as_i64()) {
        Some(1) => true,
        _ => match body.get("status").and_then(|v| v.as_f64()) {
            Some(1.0) => true,
            _ => false,
        },
    };
    if status_ok {
        if let Some(data) = body.get_mut("data") {
            let has_list = data.get("list").map(|v| !v.is_null()).unwrap_or(false);
            if has_list {
                let mut list: Vec<Value> = match data.get("list") {
                    Some(Value::Array(a)) => a.clone(),
                    _ => vec![],
                };
                for item in list.iter_mut() {
                    let sl = item
                        .get("special_link")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    if !sl.is_empty() {
                        let urls = query_string_to_json(&sl);
                        if urls.get("path").is_some() {
                            let path = urls
                                .get("path")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string();
                            let path_urls = query_string_to_json(&path);
                            let ip_id = path_urls
                                .get("ip_id")
                                .and_then(|v| v.as_str())
                                .unwrap_or("");
                            let n = ip_id.parse::<i64>().unwrap_or(0);
                            item["ip_id"] = json!(n);
                        }
                    }
                }
                data["list"] = json!(list);
            }
        }
    }
    res.body = BodyValue::Json(body);
    Ok(res)
}

/// ip_zone_home.js → /ip/zone/home（今日推荐）。
pub fn handle_zone_home(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params = json!({
        "id": q.get("id").cloned().unwrap_or(Value::Null),
        "share": 0,
    });
    forward(
        q, ctx, "GET", "/v1/zone/home", None, Some(params), None, "android",
        &[("x-router", "yuekucategory.kugou.com")], false, false,
    )
}
