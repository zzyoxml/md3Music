//! lyric.js → /lyric（歌词）。

use crate::crypto::base64_decode;
use crate::modules::{q_str, q_truthy, Ctx};
use crate::request::{BodyValue, ModuleResponse};
use crate::util::decode_lyrics;
use serde_json::{json, Value};

pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let data_map = json!({
        "ver": 1,
        "client": q_str(q, "client", "android"),
        "id": q.get("id").cloned().unwrap_or(Value::Null),
        "accesskey": q.get("accesskey").cloned().unwrap_or(Value::Null),
        "fmt": q_str(q, "fmt", "lrc"),
        "charset": "utf8",
    });

    let mut res = match ctx.raw_get("https://lyrics.kugou.com/download", &data_map) {
        Ok(r) => r,
        Err(_) => {
            return Err(ModuleResponse {
                status: 502,
                body: BodyValue::Json(json!({ "status": 400, "error_code": 20010, "info": "Bad Request" })),
                cookie: Vec::new(),
                headers: std::collections::HashMap::new(),
            });
        }
    };

    let body = res.body.to_json();
    if q_truthy(q, "decode") && body.get("content").is_some() {
        let content = body.get("content").and_then(Value::as_str).unwrap_or("");
        let use_base64 = q_str(q, "fmt", "lrc") == "lrc"
            || {
                // Number(body.contenttype) !== 0（缺省视为 NaN，NaN !== 0 为 true）
                match body.get("contenttype") {
                    Some(Value::Number(n)) => n.as_f64().unwrap_or(f64::NAN) != 0.0,
                    Some(Value::String(s)) => s.trim().parse::<f64>().unwrap_or(f64::NAN) != 0.0,
                    _ => true,
                }
            };
        let decode_content = if use_base64 {
            String::from_utf8_lossy(&base64_decode(content)).into_owned()
        } else {
            decode_lyrics(content)
        };
        if let Some(obj) = res.body.as_mut_json() {
            if let Some(m) = obj.as_object_mut() {
                m.insert("decodeContent".to_string(), json!(decode_content));
            }
        }
    }
    Ok(res)
}
