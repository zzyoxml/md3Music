//! listen_together 系列：酷狗「一起听」（众乐房 biz=1009 / 自习室 biz=1000）。
//! 对应 JS：
//!   module/_listen_together_common.js
//!   module/listen_together_{room,music,study,chat,discovery}.js
//!
//! 5 个路由，均以 `operation` 区分领域内操作；body（POST JSON）字段展开覆盖
//! URL query 顶层（JS `{ ...params, ...body }`）。全部请求 android 签名。
//! 客户端（Flutter）统一发平铺参数（room_id/hash/mixsongid），本模块负责
//! 鉴权注入与上游需要的嵌套/别名形式补齐。

use crate::modules::q_cookie;
use crate::request::{BodyData, BodyValue, ModuleResponse, RequestOptions};
use serde_json::{json, Map, Value};
use std::collections::HashMap;

pub const YOUTH_BASE: &str = "https://youth.kugou.com";
pub const GATEWAY_BASE: &str = "https://gateway.kugou.com";
pub const CONCEPTS_BASE: &str = "https://concepts.kugou.com";
pub const SELF_STUDY_BIZ: i64 = 1000;
pub const MUSIC_ROOM_BIZ: i64 = 1009;
pub const DEFAULT_MUSIC_ROOM_BG: &str =
    "https://youthimgbssdl.kugou.com/6e9cdcef8d163d06225d8cbeaa2f1ece.JPEG";

// ---------------------------------------------------------------------------
// 纯函数（单测覆盖，与 JS _listen_together_common.js 逐行对齐）
// ---------------------------------------------------------------------------

/// JS parseJsonValue：字符串尝试 JSON.parse；对象/数组/数字原样返回；失败/空 → fallback。
pub fn parse_json_value(v: Option<&Value>, fallback: Value) -> Value {
    match v {
        None | Some(Value::Null) => fallback,
        Some(Value::String(s)) => {
            if s.is_empty() {
                fallback
            } else {
                serde_json::from_str(s).unwrap_or(fallback)
            }
        }
        Some(other) => other.clone(),
    }
}

/// JS parseObject：结果必须是 JSON 对象，否则空对象。
fn parse_object(v: Option<&Value>) -> Value {
    let parsed = parse_json_value(v, json!({}));
    match parsed {
        Value::Object(_) => parsed,
        _ => json!({}),
    }
}

/// JS parseArray：结果必须是数组，否则空数组。
pub fn parse_array(v: Option<&Value>) -> Vec<Value> {
    let parsed = parse_json_value(v, json!([]));
    match parsed {
        Value::Array(a) => a,
        _ => Vec::new(),
    }
}

/// JS `{ ...params, ...body }`，但不携带 cookie（cookie 始终从原始 q 取）。
/// body 中的键覆盖顶层同名键。
pub fn merge_input(q: &Value) -> Value {
    let mut merged = Map::new();
    if let Some(obj) = q.as_object() {
        for (k, v) in obj {
            if k == "cookie" || k == "body" {
                continue;
            }
            merged.insert(k.clone(), v.clone());
        }
    }
    if let Some(Value::Object(bm)) = q.get("body") {
        for (k, v) in bm {
            merged.insert(k.clone(), v.clone());
        }
    }
    Value::Object(merged)
}

fn value_to_uid_string(v: &Value) -> Option<String> {
    v.as_str()
        .map(|s| s.to_string())
        .or_else(|| v.as_i64().map(|n| n.to_string()))
}

/// JS authBody：userid 强转数字（param 优先于 cookie），token 为字符串。
pub fn auth_body(q: &Value) -> Value {
    let input = merge_input(q);
    let uid_str = input
        .get("userid")
        .and_then(value_to_uid_string)
        .or_else(|| q.get("cookie").and_then(|c| c.get("userid")).and_then(value_to_uid_string))
        .unwrap_or_default();
    let token = input
        .get("token")
        .and_then(|v| v.as_str())
        .or_else(|| q.get("cookie").and_then(|c| c.get("token")).and_then(|v| v.as_str()))
        .unwrap_or("")
        .to_string();
    json!({ "userid": uid_str.trim().parse::<i64>().unwrap_or(0), "token": token })
}

/// biz 参数：JS `p.biz || 1000`。
pub fn resolve_biz(q: &Value) -> i64 {
    let input = merge_input(q);
    match input.get("biz") {
        Some(Value::String(s)) if !s.is_empty() => s.trim().parse().unwrap_or(SELF_STUDY_BIZ),
        Some(Value::Number(n)) => n.as_i64().unwrap_or(SELF_STUDY_BIZ),
        _ => SELF_STUDY_BIZ,
    }
}

/// groupid：JS `p.groupid || p.room_id`（EchoMusic 平铺 room_id，一并兼容）。
pub fn group_id(q: &Value) -> String {
    let input = merge_input(q);
    ["groupid", "room_id"]
        .iter()
        .find_map(|k| input.get(*k).and_then(|v| v.as_str()).filter(|s| !s.is_empty()))
        .unwrap_or("")
        .to_string()
}

/// roomid：JS `p.roomid || p.room_id`。
pub fn room_id(q: &Value) -> String {
    let input = merge_input(q);
    ["roomid", "room_id"]
        .iter()
        .find_map(|k| input.get(*k).and_then(|v| v.as_str()).filter(|s| !s.is_empty()))
        .unwrap_or("")
        .to_string()
}

/// JS musicRoomAudios：数组（兼容 JSON 字符串）→ 截断 50 → 三字段映射 → 过滤空 hash。
pub fn music_room_audios(q: &Value) -> Value {
    let input = merge_input(q);
    let arr = parse_array(input.get("audios"));
    Value::Array(
        arr.into_iter()
            .take(50)
            .filter_map(|a| {
                let obj = a.as_object()?;
                let hash = obj.get("hash").and_then(|v| v.as_str()).unwrap_or("").to_string();
                if hash.is_empty() {
                    return None;
                }
                let mix = obj
                    .get("mixsongid")
                    .or_else(|| obj.get("mixSongId"))
                    .map(|v| match v {
                        Value::String(s) => s.clone(),
                        other => other.to_string().trim_matches('"').to_string(),
                    })
                    .unwrap_or_default();
                let fid = obj.get("fid").and_then(|v| v.as_i64()).unwrap_or(0);
                Some(json!({ "hash": hash, "mixsongid": mix, "fid": fid }))
            })
            .collect(),
    )
}

// ---------------------------------------------------------------------------
// 请求转发辅助
// ---------------------------------------------------------------------------

/// 未知 operation 的 400 响应（与 JS createDomainHandler 的 reject 对齐）。
fn unsupported_operation(operation: &str) -> Result<ModuleResponse, ModuleResponse> {
    Err(ModuleResponse {
        status: 400,
        body: BodyValue::Json(json!({
            "status": 0,
            "error_code": 400,
            "error_msg": format!("不支持的操作: {}", operation)
        })),
        cookie: Vec::new(),
        headers: HashMap::new(),
    })
}

/// 统一转发：method 任意（GET/POST/DELETE）、可带 params 与任意 body。
/// cookie 固定取请求合并 cookie，android 签名。
fn send(
    ctx: &crate::modules::Ctx,
    q: &Value,
    method: &str,
    base: &str,
    url: &str,
    params: Value,
    data: BodyData,
) -> Result<ModuleResponse, ModuleResponse> {
    let mut o = RequestOptions::new(url)
        .base_url(base)
        .params(params)
        .encrypt_type("android")
        .cookie(q_cookie(q));
    o.method = method.to_string();
    o.data = data;
    ctx.send(&o)
}

fn get_str(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(|x| x.as_str()).filter(|s| !s.is_empty()).map(|s| s.to_string())
}

// ---------------------------------------------------------------------------
// /listen/together/room：create/join/state/heartbeat/status/leave/dismiss/
//                        update_chat/check_minor
// ---------------------------------------------------------------------------

/// rmservice 组操作的通用 body：{...auth, biz, groupid}。
fn group_operation_body(q: &Value) -> Value {
    let mut m = auth_body(q).as_object().unwrap().clone();
    m.insert("biz".into(), json!(resolve_biz(q)));
    m.insert("groupid".into(), json!(group_id(q)));
    Value::Object(m)
}

/// 从 input 中读取整数值（参数可能以字符串形式传入）。
fn input_i64(input: &Value, key: &str, default: i64) -> i64 {
    match input.get(key) {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(default),
        Some(Value::String(s)) if !s.trim().is_empty() => s.trim().parse().unwrap_or(default),
        Some(Value::Bool(b)) => *b as i64,
        _ => default,
    }
}

/// POST /listen/together/room
pub fn handle_room(q: &Value, ctx: &crate::modules::Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let input = merge_input(q);
    let op = input.get("operation").and_then(|v| v.as_str()).unwrap_or("");
    match op {
        "create" => {
            let biz = resolve_biz(q);
            // 众乐房房型：1 = 公开房（携带 global_collection_id 挂频道歌单），
            // 2 = 私密房（携带 capacity 限制人数）。自习室沿用 JS 默认 3。
            let default_privacy = if biz == MUSIC_ROOM_BIZ { 2 } else { 3 };
            let privacy = match input.get("room_privacy") {
                Some(Value::Number(n)) => n.as_i64().unwrap_or(default_privacy),
                Some(Value::String(s)) => s.trim().parse().unwrap_or(default_privacy),
                _ => default_privacy,
            };
            // pass_through_data：解析为对象后强制合并 room_privacy / cp_notice
            let mut pass = parse_object(input.get("pass_through_data")).as_object().unwrap().clone();
            pass.insert("room_privacy".into(), json!(privacy));
            pass.insert("cp_notice".into(), json!(1));

            let mut body = Map::new();
            for (k, v) in auth_body(q).as_object().unwrap() {
                body.insert(k.clone(), v.clone());
            }
            body.insert("biz".into(), json!(biz));

            if biz == MUSIC_ROOM_BIZ {
                let intro = get_str(&input, "introduction")
                    .or_else(|| get_str(&input, "room_name"))
                    .unwrap_or_default();
                body.insert("introduction".into(), json!(intro));
                // room_bg_content 是 JSON 字符串
                let bg = get_str(&input, "background_url")
                    .unwrap_or_else(|| DEFAULT_MUSIC_ROOM_BG.to_string());
                let bg_type = get_str(&input, "room_bg_type").unwrap_or_else(|| "2".into());
                pass.insert(
                    "room_bg_content".into(),
                    json!(crate::util::json_stringify(
                        &json!({ "bg_img": bg, "room_bg_type": bg_type })
                    )),
                );
                if privacy == 1 {
                    pass.insert(
                        "global_collection_id".into(),
                        json!(get_str(&input, "global_collection_id").unwrap_or_default()),
                    );
                } else {
                    body.insert("capacity".into(), json!(input_i64(&input, "capacity", 5)));
                }
                body.insert("pass_through_data".into(), Value::Object(pass));
            } else {
                // 自习室：biz_defined_data 数组，默认歌词开关
                let mut defined = parse_array(input.get("biz_defined_data"));
                if defined.is_empty() {
                    defined = vec![json!({ "key": "lyric_switch", "value": 1 })];
                }
                body.insert("pass_through_data".into(), Value::Object(pass));
                body.insert("biz_defined_data".into(), Value::Array(defined));
            }
            send(
                ctx, q, "POST", GATEWAY_BASE, "/rmservice/v1/group/create",
                json!({}), BodyData::Json(Value::Object(body)),
            )
        }
        "join" => {
            // JS join 的 pass_through_data 未做 parseObject：传了就用，否则 {cp_notice:1}
            let pass = match input.get("pass_through_data") {
                Some(Value::Object(_)) => input["pass_through_data"].clone(),
                _ => json!({ "cp_notice": 1 }),
            };
            let mut body = group_operation_body(q).as_object().unwrap().clone();
            body.insert("pass_through_data".into(), pass);
            send(
                ctx, q, "POST", GATEWAY_BASE, "/rmservice/v1/group/join",
                json!({}), BodyData::Json(Value::Object(body)),
            )
        }
        "state" => send(
            ctx, q, "POST", GATEWAY_BASE, "/rmservice/v1/group/info",
            json!({ "biz": resolve_biz(q) }),
            BodyData::Json(json!({ "groupid": group_id(q) })),
        ),
        "heartbeat" => send(
            ctx, q, "POST", GATEWAY_BASE, "/rmservice/v1/group/heartbeat",
            json!({}), BodyData::Json(group_operation_body(q)),
        ),
        "status" => {
            // 概念版查账号会话用 room_id（可空）而非 groupid：
            // EchoMusic 发 {room_id, biz}，只发 groupid 会被上游以 40007 拒绝
            let mut body = group_operation_body(q).as_object().unwrap().clone();
            body.insert("room_id".into(), json!(group_id(q)));
            send(
                ctx, q, "POST", GATEWAY_BASE, "/rmservice/v1/user/get_status",
                json!({}), BodyData::Json(Value::Object(body)),
            )
        }
        "leave" => send(
            ctx, q, "POST", GATEWAY_BASE, "/rmservice/v1/group/leave",
            json!({}), BodyData::Json(group_operation_body(q)),
        ),
        "dismiss" => send(
            ctx, q, "POST", GATEWAY_BASE, "/rmservice/v1/group/dismiss",
            json!({}), BodyData::Json(group_operation_body(q)),
        ),
        "update_chat" => {
            let chat = input_i64(&input, "chat", 2);
            let body = json!({
                "groupid": group_id(q),
                "biz": MUSIC_ROOM_BIZ,
                "switch": { "chat": if chat == 1 { 1 } else { 2 } }
            });
            send(
                ctx, q, "POST", GATEWAY_BASE, "/rmservice/v1/group/update_info",
                json!({}), BodyData::Json(body),
            )
        }
        "check_minor" => send(
            ctx, q, "GET", YOUTH_BASE, "/v1/risk/check_minor",
            json!({}), BodyData::None,
        ),
        other => unsupported_operation(other),
    }
}

// ---------------------------------------------------------------------------
// /listen/together/music：众乐房（biz 固定 1009）
// list/detail/members/initialize/sync_player/playback_url/switch_song/
// player_operation/playlist/recent_playlist/order_song/song_order_list/
// remove_song/music_add/history
// ---------------------------------------------------------------------------

/// 从 input 提取 audio 身份（顶层平铺 hash/mixsongid 优先，兼容嵌套 audio 对象）。
fn audio_identity(input: &Value) -> (String, String) {
    let hash = get_str(input, "hash")
        .or_else(|| {
            input
                .get("audio")
                .and_then(|a| a.get("hash"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
        })
        .unwrap_or_default();
    let mix = get_str(input, "mixsongid")
        .or_else(|| get_str(input, "mixSongId"))
        .or_else(|| {
            input
                .get("audio")
                .and_then(|a| a.get("mixsongid").or_else(|| a.get("mixSongId")))
                .and_then(|v| {
                    v.as_str()
                        .map(|s| s.to_string())
                        .or_else(|| v.as_i64().map(|n| n.to_string()))
                })
        })
        .unwrap_or_default();
    (hash, mix)
}

/// POST /listen/together/music
pub fn handle_music(q: &Value, ctx: &crate::modules::Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let input = merge_input(q);
    let op = input.get("operation").and_then(|v| v.as_str()).unwrap_or("");
    let rid = room_id(q);
    match op {
        "history" => send(
            ctx, q, "GET", GATEWAY_BASE, "/youth/v1/genting/history",
            json!({ "last_id": input_i64(&input, "last_id", 0) }),
            BodyData::None,
        ),
        "list" => {
            // JS page 从 1 起，上游从 0 起
            let page = (input_i64(&input, "page", 1) - 1).max(0);
            let mut params = Map::new();
            params.insert("page".into(), json!(page));
            params.insert("pagesize".into(), json!(input_i64(&input, "pagesize", 20)));
            params.insert("loop_pick".into(), json!(input_i64(&input, "loop_pick", 0)));
            params.insert("tags".into(), json!(get_str(&input, "tags").unwrap_or_default()));
            params.insert("room_biz".into(), json!(MUSIC_ROOM_BIZ));
            if let Some(m) = get_str(&input, "mixsongid") {
                params.insert("mixsongid".into(), json!(m));
            }
            let behaviors = parse_array(input.get("behaviors"));
            send(
                ctx, q, "POST", GATEWAY_BASE, "/youth/v2/genting/recommend",
                Value::Object(params), BodyData::Json(json!({ "data": behaviors })),
            )
        }
        "detail" => send(
            ctx, q, "GET", GATEWAY_BASE, "/youth/v1/genting/get_musicroom_info",
            json!({ "roomid": rid, "biz": MUSIC_ROOM_BIZ }), BodyData::None,
        ),
        "members" => send(
            ctx, q, "GET", GATEWAY_BASE, "/youth/v1/genting/get_musicroom_member",
            json!({
                "roomid": rid,
                "page": input_i64(&input, "page", 1).max(1),
                "pagesize": input_i64(&input, "pagesize", 100),
                "apiver": "3"
            }),
            BodyData::None,
        ),
        "initialize" => {
            let mut body = Map::new();
            body.insert("sendall".into(), json!(input_i64(&input, "sendall", 1)));
            body.insert("audios".into(), music_room_audios(q));
            // progress_info 透传对象（兼容 JSON 字符串）
            if input.get("progress_info").is_some() {
                body.insert("progress_info".into(), parse_object(input.get("progress_info")));
            }
            send(
                ctx, q, "POST", GATEWAY_BASE, "/youth/v1/genting/init_musicroom",
                json!({ "roomid": rid }), BodyData::Json(Value::Object(body)),
            )
        }
        "sync_player" => send(
            ctx, q, "POST", GATEWAY_BASE, "/youth/v1/genting/music_sync_player",
            json!({ "roomid": rid, "frm": input_i64(&input, "frm", 2) }),
            BodyData::Json(json!({})),
        ),
        "playback_url" => {
            let (hash, mix) = audio_identity(&input);
            let mut body = auth_body(q).as_object().unwrap().clone();
            body.insert("roomid".into(), json!(rid));
            // 双形式：顶层平铺（概念版 APP 形式）+ 嵌套 audio
            body.insert("hash".into(), json!(hash.clone()));
            body.insert("mixsongid".into(), json!(mix.clone()));
            body.insert("audio".into(), json!({ "hash": hash, "mixsongid": mix }));
            // 固定页面链路，缺失时上游 404
            send(
                ctx, q, "POST", GATEWAY_BASE, "/youth/v1/genting/music_reqcmd",
                json!({ "page_id": 147780134i64, "ppage_id": "356753938" }),
                BodyData::Json(Value::Object(body)),
            )
        }
        "switch_song" => {
            let (hash, mix) = audio_identity(&input);
            let is_auto = if input_i64(&input, "is_auto", 0) != 0 { "1" } else { "0" };
            let mut body = Map::new();
            body.insert("act_type".into(), json!(input_i64(&input, "act_type", 1)));
            body.insert(
                "list_version".into(),
                json!(get_str(&input, "list_version").unwrap_or_default()),
            );
            body.insert("is_auto".into(), json!(is_auto));
            body.insert("hash".into(), json!(hash.clone()));
            body.insert("mixsongid".into(), json!(mix.clone()));
            body.insert("audio".into(), json!({ "hash": hash, "mixsongid": mix }));
            send(
                ctx, q, "POST", GATEWAY_BASE, "/youth/v1/genting/music_sw",
                json!({ "roomid": rid }), BodyData::Json(Value::Object(body)),
            )
        }
        "player_operation" => {
            let action = input_i64(&input, "action", 3);
            let mut body = Map::new();
            body.insert("action".into(), json!(action));
            if action == 1 {
                body.insert("play_mode".into(), json!(input_i64(&input, "play_mode", 1)));
            }
            if action == 2 {
                let progress = input_i64(&input, "progress", 0).max(0);
                body.insert("progress".into(), json!(progress));
            }
            if action == 3 {
                let pause = if input_i64(&input, "pause", 2) == 1 { "1" } else { "2" };
                body.insert("pause".into(), json!(pause));
            }
            send(
                ctx, q, "POST", GATEWAY_BASE, "/youth/v1/genting/music_player_opr",
                json!({ "roomid": rid }), BodyData::Json(Value::Object(body)),
            )
        }
        "playlist" => {
            let mut body = Map::new();
            body.insert("pagesize".into(), json!(input_i64(&input, "pagesize", 50)));
            // audio 游标透传对象，仅当含 hash（以最后一首作为翻页游标）
            if let Some(Value::Object(a)) = input.get("audio") {
                let hash = a.get("hash").and_then(|v| v.as_str()).unwrap_or("");
                if !hash.is_empty() {
                    let mix = a
                        .get("mixsongid")
                        .or_else(|| a.get("mixSongId"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    body.insert("audio".into(), json!({ "hash": hash, "mixsongid": mix }));
                }
            }
            send(
                ctx, q, "POST", GATEWAY_BASE, "/youth/v1/genting/music_fetch_list",
                json!({ "roomid": rid }), BodyData::Json(Value::Object(body)),
            )
        }
        "recent_playlist" => {
            // JS 为该接口签名并发送空请求体（非 JSON 对象）
            send(
                ctx, q, "POST", GATEWAY_BASE, "/youth/v1/genting/music_recent_list",
                json!({ "roomid": rid }), BodyData::String(String::new()),
            )
        }
        "order_song" => {
            let (hash, mix) = audio_identity(&input);
            send(
                ctx, q, "POST", GATEWAY_BASE, "/youth/v1/genting/order_song",
                json!({ "roomid": rid }),
                BodyData::Json(json!({ "mixsongid": mix, "hash": hash })),
            )
        }
        "song_order_list" => send(
            ctx, q, "GET", GATEWAY_BASE, "/youth/v1/genting/song_order_list",
            json!({ "roomid": rid }), BodyData::None,
        ),
        "remove_song" => {
            let (hash, mix) = audio_identity(&input);
            send(
                ctx, q, "POST", GATEWAY_BASE, "/youth/v1/genting/remove_song",
                json!({ "roomid": rid }),
                BodyData::Json(json!({
                    "mixsongid": mix,
                    "hash": hash,
                    "order_userid": get_str(&input, "order_userid").unwrap_or_default()
                })),
            )
        }
        "music_add" => {
            let mut params = Map::new();
            params.insert("roomid".into(), json!(rid));
            if let Some(ou) = get_str(&input, "order_userid") {
                params.insert("order_userid".into(), json!(ou));
                params.insert(
                    "source".into(),
                    json!(get_str(&input, "source").unwrap_or_else(|| "1".into())),
                );
            }
            let mut body = Map::new();
            body.insert("action".into(), json!(input_i64(&input, "action", 4)));
            body.insert(
                "list_version".into(),
                json!(get_str(&input, "list_version").unwrap_or_default()),
            );
            body.insert("sendall".into(), json!(input_i64(&input, "sendall", 1)));
            body.insert("audios".into(), music_room_audios(q));
            if input.get("progress_info").is_some() {
                body.insert("progress_info".into(), parse_object(input.get("progress_info")));
            }
            send(
                ctx, q, "POST", GATEWAY_BASE, "/youth/v1/genting/music_add",
                Value::Object(params), BodyData::Json(Value::Object(body)),
            )
        }
        other => unsupported_operation(other),
    }
}

// ---------------------------------------------------------------------------
// /listen/together/chat：send/history
// ---------------------------------------------------------------------------

/// POST /listen/together/chat
pub fn handle_chat(q: &Value, ctx: &crate::modules::Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let input = merge_input(q);
    let op = input.get("operation").and_then(|v| v.as_str()).unwrap_or("");
    // 聊天 biz 跟随房间（众乐房 1009），默认自习室 1000（JS 默认值）
    let biz = resolve_biz(q);
    let gid = group_id(q);
    match op {
        "send" => {
            // 与 JS listen_together_chat.js 对齐：上游把聊天体存成
            // {msgtype, nickname, img, alert} 对象并挂在 message 键下——
            // msg_history 返回的消息结构正是这个嵌套形式。此前把 message
            // 当字符串平铺上报，上游按「非法请求」（30002）拒绝。
            // room_id 与 groupid 双写：rmservice 部分校验按 room_id 取房间。
            let alert = get_str(&input, "alert")
                .or_else(|| get_str(&input, "message"))
                .unwrap_or_default();
            let nickname = get_str(&input, "nickname").unwrap_or_default();
            let img = get_str(&input, "img").unwrap_or_default();
            let msg_type = input_i64(&input, "msgtype", 801);
            let mut body = auth_body(q).as_object().unwrap().clone();
            body.insert("biz".into(), json!(biz));
            body.insert("groupid".into(), json!(gid.clone()));
            body.insert("room_id".into(), json!(gid));
            body.insert(
                "message".into(),
                json!({
                    "msgtype": msg_type,
                    "nickname": nickname,
                    "img": img,
                    "alert": alert,
                }),
            );
            send(
                ctx, q, "POST", GATEWAY_BASE, "/rmservice/v1/group/chat",
                json!({}), BodyData::Json(Value::Object(body)),
            )
        }
        "history" => {
            let mut body = auth_body(q).as_object().unwrap().clone();
            body.insert("biz".into(), json!(biz));
            body.insert("groupid".into(), json!(gid));
            body.insert(
                "maxid".into(),
                json!(get_str(&input, "maxid").unwrap_or_else(|| "0".into())),
            );
            body.insert(
                "pagesize".into(),
                json!(get_str(&input, "pagesize").unwrap_or_else(|| "50".into())),
            );
            send(
                ctx, q, "POST", GATEWAY_BASE, "/rmservice/v1/group/msg_history",
                json!({}), BodyData::Json(Value::Object(body)),
            )
        }
        other => unsupported_operation(other),
    }
}

// ---------------------------------------------------------------------------
// /listen/together/study：自习室（本期仅 API，不做 Flutter UI）
// ---------------------------------------------------------------------------

const STUDY_PAGE_ID: i64 = 711586122;
const STUDY_PARENT_PAGE_ID: &str = "356753938";

/// POST/GET /listen/together/study
pub fn handle_study(q: &Value, ctx: &crate::modules::Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let input = merge_input(q);
    let op = input.get("operation").and_then(|v| v.as_str()).unwrap_or("");
    match op {
        "created_rooms" => send(
            ctx, q, "GET", YOUTH_BASE, "/v1/study/user_create_room_list",
            json!({}), BodyData::None,
        ),
        "delete_created_room" => send(
            ctx, q, "DELETE", GATEWAY_BASE, "/youth/v1/room/delete_room",
            json!({
                "global_collection_id": get_str(&input, "global_collection_id")
                    .or_else(|| get_str(&input, "channel_id")).unwrap_or_default(),
                "roomid": room_id(q)
            }),
            BodyData::None,
        ),
        "list" => send(
            ctx, q, "GET", YOUTH_BASE, "/v1/room/get_room_list_by_tag",
            json!({
                "page": input_i64(&input, "page", 1),
                "pagesize": input_i64(&input, "pagesize", 20),
                "sort": input_i64(&input, "sort", 0),
                "page_id": input_i64(&input, "page_id", 191708212),
                "ppage_id": STUDY_PARENT_PAGE_ID,
                "tag_id": get_str(&input, "tag_id").unwrap_or_default()
            }),
            BodyData::None,
        ),
        "detail" => send(
            ctx, q, "GET", YOUTH_BASE, "/v1/room/get_room_detail",
            json!({ "room_id": room_id(q) }), BodyData::None,
        ),
        "members" => send(
            ctx, q, "GET", YOUTH_BASE, "/v1/room/get_member_list",
            json!({
                "room_id": room_id(q),
                "page": input_i64(&input, "page", 1),
                "pagesize": input_i64(&input, "pagesize", 20),
                "member_type": input_i64(&input, "member_type", 1)
            }),
            BodyData::None,
        ),
        "configure" => {
            let music_type = input_i64(&input, "music_type", 1);
            let page_id = match input.get("page_id").and_then(|v| v.as_i64()) {
                Some(v) => v,
                None => match music_type {
                    2 => 971343961,
                    3 => 711357575,
                    _ => STUDY_PAGE_ID,
                },
            };
            let mut body = Map::new();
            body.insert("room_id".into(), json!(room_id(q)));
            body.insert(
                "room_name".into(),
                json!(get_str(&input, "room_name").unwrap_or_default()),
            );
            body.insert(
                "global_collection_id".into(),
                json!(get_str(&input, "global_collection_id").unwrap_or_default()),
            );
            body.insert(
                "room_notice".into(),
                json!(get_str(&input, "room_notice").unwrap_or_default()),
            );
            body.insert("allow_chat".into(), json!(input_i64(&input, "allow_chat", 1)));
            body.insert(
                "room_tag".into(),
                json!(get_str(&input, "room_tag").unwrap_or_else(|| "2".into())),
            );
            body.insert("music_type".into(), json!(music_type));
            if music_type == 1 || music_type == 2 {
                if let Some(style) = get_str(&input, "music_style") {
                    body.insert("music_style".into(), json!(style));
                }
                let audios = parse_array(input.get("audios"));
                if !audios.is_empty() {
                    body.insert("audios".into(), Value::Array(audios));
                }
            } else if music_type == 3 {
                body.insert(
                    "white_noise_type".into(),
                    json!(input_i64(&input, "white_noise_type", 1)),
                );
            }
            send(
                ctx, q, "POST", YOUTH_BASE, "/v1/user/make_room",
                json!({
                    "page_id": page_id,
                    "ppage_id": STUDY_PARENT_PAGE_ID,
                    "type": input_i64(&input, "type", 1)
                }),
                BodyData::Json(Value::Object(body)),
            )
        }
        "sync_player" => {
            let mut b = auth_body(q).as_object().unwrap().clone();
            b.insert("roomid".into(), json!(room_id(q)));
            b.insert("frm".into(), json!(input_i64(&input, "frm", 2)));
            send(
                ctx, q, "POST", YOUTH_BASE, "/v1/music/sync_player",
                json!({ "page_id": STUDY_PAGE_ID, "ppage_id": STUDY_PARENT_PAGE_ID }),
                BodyData::Json(Value::Object(b)),
            )
        }
        "playlist" => {
            let mut b = auth_body(q).as_object().unwrap().clone();
            b.insert("roomid".into(), json!(room_id(q)));
            b.insert("frm".into(), json!(input_i64(&input, "frm", 2)));
            b.insert("pagesize".into(), json!(input_i64(&input, "pagesize", 50)));
            send(
                ctx, q, "POST", YOUTH_BASE, "/v1/music/fetch_list",
                json!({ "page_id": STUDY_PAGE_ID, "ppage_id": STUDY_PARENT_PAGE_ID }),
                BodyData::Json(Value::Object(b)),
            )
        }
        other => unsupported_operation(other),
    }
}

// ---------------------------------------------------------------------------
// /listen/together/discovery：channel_search / 广场 / 主播 / 最近房间 / 特权
// ---------------------------------------------------------------------------

/// GET/POST /listen/together/discovery
pub fn handle_discovery(q: &Value, ctx: &crate::modules::Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let input = merge_input(q);
    let op = input.get("operation").and_then(|v| v.as_str()).unwrap_or("");
    match op {
        "channel_search" => send(
            ctx, q, "GET", YOUTH_BASE, "/v1/search/channel",
            json!({
                "keyword": get_str(&input, "keyword").unwrap_or_default(),
                "page": input_i64(&input, "page", 1),
                "position": input_i64(&input, "position", 1)
            }),
            BodyData::None,
        ),
        "kugroup_square" => send(
            ctx, q, "GET", YOUTH_BASE, "/v1/kugroup/square",
            json!({
                "page": input_i64(&input, "page", 1),
                "pagesize": input_i64(&input, "pagesize", 20),
                "order_type": input_i64(&input, "order_type", 1)
            }),
            BodyData::None,
        ),
        "genting_square" => send(
            ctx, q, "GET", YOUTH_BASE, "/v1/genting/square",
            json!({
                "page": input_i64(&input, "page", 1),
                "pagesize": input_i64(&input, "pagesize", 20),
                "order_type": input_i64(&input, "order_type", 1)
            }),
            BodyData::None,
        ),
        "kugroup_streamers" => send(
            ctx, q, "GET", YOUTH_BASE, "/v1/kugroup/get_streamer_list",
            json!({
                "longitude": input_i64(&input, "longitude", 0),
                "latitude": input_i64(&input, "latitude", 0)
            }),
            BodyData::None,
        ),
        "genting_streamers" => send(
            ctx, q, "GET", YOUTH_BASE, "/v1/genting/get_streamer_list",
            json!({
                "page": input_i64(&input, "page", 1),
                "pagesize": input_i64(&input, "pagesize", 20)
            }),
            BodyData::None,
        ),
        "recent_rooms" => send(
            ctx, q, "GET", YOUTH_BASE, "/v3/user/recent_room_dynamic",
            json!({}), BodyData::None,
        ),
        "privilege" => send(
            ctx, q, "GET", YOUTH_BASE, "/v1/privilege/operate",
            json!({ "event_type": input_i64(&input, "event_type", 4) }),
            BodyData::None,
        ),
        "genting_recommend" => send(
            ctx, q, "POST", CONCEPTS_BASE, "/v1/genting/recommend",
            json!({
                "page": input_i64(&input, "page", 1),
                "pagesize": input_i64(&input, "pagesize", 20),
                "room_biz": input_i64(&input, "room_biz", 1006)
            }),
            BodyData::None,
        ),
        other => unsupported_operation(other),
    }
}
