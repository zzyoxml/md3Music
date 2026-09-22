use crate::crypto::md5_hex_to_decimal_str;
use serde_json::{json, Value};

/// JS `Math.ceil((keyStringArr.length - 1) * Math.random())` index picker.
fn ceil_random_idx(max_idx: usize) -> usize {
    let r: f64 = rand::random();
    ((max_idx as f64) * r).ceil() as usize
}

/// JS randomString(len) over '1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ'.
pub fn random_string(len: usize) -> String {
    let chars: Vec<char> = "1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ".chars().collect();
    let max_idx = chars.len() - 1;
    (0..len).map(|_| chars[ceil_random_idx(max_idx)]).collect()
}

/// randomString(16).toLowerCase() — used as AES tempKey.
pub fn random_string_lower_16() -> String {
    random_string_lower(16)
}

/// randomString(len).toLowerCase() — digits + lowercase letters.
pub fn random_string_lower(len: usize) -> String {
    random_string(len).to_lowercase()
}

/// JS randomNumber(len) over '1234567890'.
pub fn random_number() -> String {
    let chars: Vec<char> = "1234567890".chars().collect();
    let max_idx = chars.len() - 1;
    (0..16).map(|_| chars[ceil_random_idx(max_idx)]).collect()
}

/// JS `((65536*(1+Math.random()))|0).toString(16).substring(1)`
pub fn random_guid_part() -> String {
    let r: f64 = rand::random();
    let v = (65536.0 * (1.0 + r)).floor() as u64;
    let hex = format!("{:x}", v);
    hex.chars().skip(1).collect()
}

/// parse cookie string to JSON object.
pub fn cookie_string_to_json(s: &str) -> Value {
    let mut obj = serde_json::Map::new();
    for part in s.split(';') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        if let Some((k, v)) = part.split_once('=') {
            obj.insert(k.trim().to_string(), json!(v.trim()));
        }
    }
    Value::Object(obj)
}

/// join a JSON object to cookie string (replicating cookieToJson usage).
pub fn cookie_json_to_string(obj: &Value) -> String {
    let mut parts = Vec::new();
    if let Some(map) = obj.as_object() {
        for (k, v) in map {
            if k.is_empty() {
                continue;
            }
            if let Value::String(s) = v {
                if s == "undefined" {
                    continue;
                }
                parts.push(format!("{}={}", k, s));
            } else if !v.is_null() {
                parts.push(format!("{}={}", k, v));
            }
        }
    }
    parts.join("; ")
}

/// JS parseCookieString: strip `\s*(Domain|domain|path|expires)=[^(;|$)]+;*` then `/;HttpOnly/g`.
pub fn parse_cookie_string(cookie: &str) -> String {
    let bytes = cookie.as_bytes();
    let mut out = String::new();
    let mut i = 0;
    let keys = ["Domain=", "domain=", "path=", "expires="];
    while i < bytes.len() {
        if bytes[i].is_ascii_whitespace() {
            let mut j = i;
            while j < bytes.len() && bytes[j].is_ascii_whitespace() {
                j += 1;
            }
            let rest = &cookie[j..];
            if keys.iter().any(|k| rest.starts_with(k)) {
                i = j;
                continue;
            }
            out.push(' ');
            i = j;
            continue;
        }
        let rest = &cookie[i..];
        if let Some(k) = keys.iter().find(|k| rest.starts_with(**k)) {
            let mut j = i + k.len();
            while j < bytes.len() && !matches!(bytes[j], b'(' | b';' | b'|' | b'$') {
                j += 1;
            }
            while j < bytes.len() && bytes[j] == b';' {
                j += 1;
            }
            i = j;
        } else {
            out.push(bytes[i] as char);
            i += 1;
        }
    }
    out.replace(";HttpOnly", "")
}

/// Number(x) coercion like JS.
pub fn to_number(v: Option<&Value>) -> i64 {
    match v {
        None => 0,
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
        Some(Value::String(s)) => {
            let t = s.trim();
            if t.is_empty() {
                0
            } else {
                t.parse::<i64>().unwrap_or(0)
            }
        }
        Some(Value::Bool(b)) => {
            if *b {
                1
            } else {
                0
            }
        }
        _ => 0,
    }
}

pub fn to_f64(v: Option<&Value>) -> f64 {
    match v {
        None => 0.0,
        Some(Value::Number(n)) => n.as_f64().unwrap_or(0.0),
        Some(Value::String(s)) => s.trim().parse::<f64>().unwrap_or(0.0),
        _ => 0.0,
    }
}

/// get first value as string (params values may be arrays).
pub fn first_str(v: Option<&Value>) -> Option<String> {
    match v {
        None => None,
        Some(Value::String(s)) => Some(s.clone()),
        Some(Value::Number(n)) => Some(n.to_string()),
        Some(Value::Bool(b)) => Some(b.to_string()),
        Some(Value::Array(a)) => {
            let v = a.first();
            match v {
                None => None,
                Some(Value::String(s)) => Some(s.clone()),
                Some(Value::Number(n)) => Some(n.to_string()),
                Some(Value::Bool(b)) => Some(b.to_string()),
                _ => None,
            }
        }
        _ => None,
    }
}

/// JS String(x) coercion.
pub fn js_string(v: Option<&Value>) -> String {
    match v {
        None => "undefined".to_string(),
        Some(Value::Null) => "null".to_string(),
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        Some(Value::Object(o)) => serde_json::to_string(o).unwrap_or_default(),
        Some(Value::Array(a)) => serde_json::to_string(a).unwrap_or_default(),
    }
}

/// decodeLyrics: base64 -> skip 4 bytes -> xor key -> zlib inflate -> string.
pub fn decode_lyrics(content: &str) -> String {
    let bytes = crate::crypto::base64_decode(content);
    if bytes.len() <= 4 {
        return String::new();
    }
    let key = [0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69];
    let data: Vec<u8> = bytes
        .iter()
        .skip(4)
        .enumerate()
        .map(|(i, b)| b ^ key[i % 16])
        .collect();
    use flate2::read::ZlibDecoder;
    use std::io::Read;
    let mut dec = ZlibDecoder::new(&data[..]);
    let mut out = String::new();
    let _ = dec.read_to_string(&mut out);
    out
}

/// zlib inflate bytes to bytes.
pub fn zlib_inflate(data: &[u8]) -> Vec<u8> {
    use flate2::read::ZlibDecoder;
    use std::io::Read;
    let mut dec = ZlibDecoder::new(data);
    let mut out = Vec::new();
    let _ = dec.read_to_end(&mut out);
    out
}

/// calculateMid: guid -> md5 hex -> decimal string.
pub fn calculate_mid(guid: &str) -> String {
    md5_hex_to_decimal_str(guid.as_bytes())
}

/// getGuid: JS `${e()}${e()}-${e()}-${e()}-${e()}-${e()}${e()}${e()}`
pub fn get_guid() -> String {
    let mut parts = Vec::with_capacity(8);
    for _ in 0..8 {
        parts.push(random_guid_part());
    }
    format!(
        "{}{}-{}-{}-{}-{}{}{}",
        parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], parts[6], parts[7]
    )
}

/// encodeURIComponent compatible (uses utf-8 percent encoding; keeps unreserved).
pub fn encode_uri_component(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'!' | b'~' | b'*' | b'\'' | b'(' | b')' => {
                out.push(b as char);
            }
            b' ' => out.push_str("%20"),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

/// JSON.stringify like for building data strings.
///
/// P0: 原实现每个对象/数组都 `collect::<Vec<String>>().join(",")`，产生大量中间
/// String 分配（全项目 51 处调用，处于签名热路径）。改为直接累积到单个 String，
/// 转义语义逐字符保持不变（签名 md5 原文依赖此处输出，不能切换到 serde_json——
/// 后者会把 0x08/0x0c 转成 \b/\f，与旧行为不一致）。
pub fn json_stringify(v: &Value) -> String {
    let mut out = String::new();
    json_stringify_into(v, &mut out);
    out
}

fn json_stringify_into(v: &Value, out: &mut String) {
    match v {
        Value::Object(m) => {
            out.push('{');
            let mut first = true;
            for (k, val) in m.iter() {
                if !first {
                    out.push(',');
                }
                first = false;
                // 与旧实现行为一致：key 不做转义（旧实现同样未转义）
                out.push('"');
                out.push_str(k);
                out.push('"');
                out.push(':');
                json_stringify_into(val, out);
            }
            out.push('}');
        }
        Value::Array(a) => {
            out.push('[');
            let mut first = true;
            for val in a {
                if !first {
                    out.push(',');
                }
                first = false;
                json_stringify_into(val, out);
            }
            out.push(']');
        }
        Value::String(s) => {
            out.push('"');
            for ch in s.chars() {
                match ch {
                    '"' => out.push_str("\\\""),
                    '\\' => out.push_str("\\\\"),
                    '\n' => out.push_str("\\n"),
                    '\r' => out.push_str("\\r"),
                    '\t' => out.push_str("\\t"),
                    c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
                    c => out.push(c),
                }
            }
            out.push('"');
        }
        Value::Number(n) => out.push_str(&n.to_string()),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Null => out.push_str("null"),
    }
}

/// 中文转拼音-ish? not needed; used for song name urlencoding in some modules. skip.

/// parse "key=value&key2=value2" into flat json object (querystring parse, extended:false).
pub fn query_string_to_json(s: &str) -> Value {
    let mut obj = serde_json::Map::new();
    for pair in s.split('&') {
        if pair.is_empty() {
            continue;
        }
        let (k, v) = match pair.split_once('=') {
            Some((k, v)) => (k, v),
            None => (pair, ""),
        };
        let k = percent_decode(k);
        let v = percent_decode(v);
        if !k.is_empty() {
            obj.insert(k, json!(v));
        }
    }
    Value::Object(obj)
}

pub fn percent_decode(s: &str) -> String {
    percent_decode_inner(s, true)
}

/// percent-decode without converting '+' to space (cookie decode).
pub fn percent_decode_preserve_plus(s: &str) -> String {
    percent_decode_inner(s, false)
}

fn percent_decode_inner(s: &str, plus_to_space: bool) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("00");
                if let Ok(v) = u8::from_str_radix(hex, 16) {
                    out.push(v);
                    i += 3;
                    continue;
                }
                out.push(b'%');
                i += 1;
            }
            b'+' if plus_to_space => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}
