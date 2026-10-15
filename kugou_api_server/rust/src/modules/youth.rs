//! youth 系列：channel_all / channel_amway / channel_detail / channel_similar /
//! channel_song / channel_song_detail / day_vip / day_vip_upgrade / dynamic /
//! dynamic_recent / listen_song / month_vip_record / union_vip / user_song / vip
//! 对应 JS module/youth*.js

use crate::cache::now_epoch_secs;
use crate::modules::{c_str, forward, q_num, q_str, Ctx};
use crate::request::ModuleResponse;
use serde_json::{json, Value};

/// 从 query 的 body 子对象取值：JS `params?.body?.x || params?.x`。
fn body_or_param(q: &Value, key: &str) -> Value {
    if let Some(b) = q.get("body") {
        if let Some(v) = b.get(key) {
            return v.clone();
        }
    }
    q.get(key).cloned().unwrap_or(Value::Null)
}

/// youth_channel_all.js → /youth/channel/all。
pub fn handle_channel_all(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let pm = json!({
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
        "type": 1,
    });
    forward(
        q, ctx, "get", "/youth/v2/channel/channel_all_list", None,
        Some(pm), None, "android", &[], false, false,
    )
}

/// youth_channel_amway.js → /youth/channel/amway。
pub fn handle_channel_amway(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let pm = json!({
        "global_collection_id": q_str(q, "global_collection_id", ""),
    });
    forward(
        q, ctx, "get", "/youth/api/amway/v2/index", None,
        Some(pm), None, "android", &[], false, false,
    )
}

/// youth_channel_detail.js → /youth/channel/detail。
pub fn handle_channel_detail(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let ids = q_str(q, "global_collection_id", "");
    let data: Vec<Value> = ids
        .split(',')
        .map(|s| json!({ "global_collection_id": s }))
        .collect();
    let dm = json!({ "data": data });
    forward(
        q, ctx, "post", "/youth/api/channel/v1/channel_list_by_id", None, None,
        Some(dm), "android", &[], false, false,
    )
}

/// youth_channel_similar.js → /youth/channel/similar。
pub fn handle_channel_similar(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let vip_type: i64 = {
        let vp = q_str(q, "vip_type", "");
        let cv = c_str(q, "vip_type");
        if !vp.is_empty() {
            vp.trim().parse().unwrap_or(0)
        } else if !cv.is_empty() {
            cv.trim().parse().unwrap_or(0)
        } else {
            0
        }
    };
    let dm = json!({
        "area_code": 1,
        "playlist_ver": 2,
        "vip_type": vip_type,
        "platform": "ios",
    });
    forward(
        q, ctx, "post", "/youth/v1/channel/get_friendly_channel", None,
        Some(json!({ "channel_id": q_str(q, "channel_id", "") })), Some(dm), "android", &[], false, false,
    )
}

/// youth_channel_song.js → /youth/channel/song。
pub fn handle_channel_song(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let pm = json!({
        "global_collection_id": q_str(q, "global_collection_id", ""),
        "pagesize": q_num(q, "pagesize", 30),
        "page": q_num(q, "page", 1),
        "is_filter": 0,
    });
    forward(
        q, ctx, "get", "/youth/api/channel/v1/channel_get_song_audit_passed", None,
        Some(pm), None, "android", &[], false, false,
    )
}

/// youth_channel_song_detail.js → /youth/channel/song/detail。
pub fn handle_channel_song_detail(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let pm = json!({
        "global_collection_id": q_str(q, "global_collection_id", ""),
        "fileid": q_str(q, "fileid", ""),
    });
    forward(
        q, ctx, "get", "/youth/v2/post/get_song_detail", None,
        Some(pm), None, "android", &[], false, false,
    )
}

/// youth_channel_sub.js → /youth/channel/sub（t=0 取消订阅，默认订阅）。
pub fn handle_channel_sub(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let t = if q_num(q, "t", 1) == 0 { 0 } else { 1 };
    let pm = json!({
        "global_collection_id": q_str(q, "global_collection_id", ""),
        "source": 1,
    });
    if t == 0 {
        forward(
            q, ctx, "delete", "/youth/v1/channel_un_subscribe", None,
            Some(pm), None, "android", &[], false, false,
        )
    } else {
        forward(
            q, ctx, "post", "/youth/v1/channel_subscribe", None,
            Some(pm), None, "android", &[], false, false,
        )
    }
}

/// youth_day_vip.js → /youth/day/vip（领取一天 VIP）。
pub fn handle_day_vip(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let receive_day = body_or_param(q, "receive_day");
    let pm = json!({
        "source_id": 90139,
        "receive_day": receive_day,
    });
    let dm = json!({
        "receive_day": receive_day,
    });
    forward(
        q, ctx, "post", "/youth/v1/recharge/receive_vip_listen_song", None,
        Some(pm), Some(dm), "android", &[], false, false,
    )
}

/// youth_day_vip_upgrade.js → /youth/day/vip/upgrade（升级 VIP）。
pub fn handle_day_vip_upgrade(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid: i64 = {
        let pv = q_str(q, "userid", "");
        if !pv.is_empty() {
            pv.trim().parse().unwrap_or(0)
        } else {
            let cv = c_str(q, "userid");
            if !cv.is_empty() {
                cv.trim().parse().unwrap_or(0)
            } else {
                0
            }
        }
    };
    let pm = json!({
        "kugouid": userid,
        "ad_type": 1,
    });
    forward(
        q, ctx, "post", "/youth/v1/listen_song/upgrade_vip_reward", None,
        Some(pm), None, "android", &[], false, false,
    )
}

/// youth_dynamic.js → /youth/dynamic。
pub fn handle_dynamic(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q, ctx, "get", "/youth/v3/user/get_dynamic", None, None, None, "android", &[], false, false,
    )
}

/// youth_dynamic_recent.js → /youth/dynamic/recent。
pub fn handle_dynamic_recent(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q, ctx, "get", "/youth/v3/user/recent_dynamic", None, None, None, "android", &[], false, false,
    )
}

/// youth_listen_song.js → /youth/listen/song（听歌领取 VIP 上报）。
pub fn handle_listen_song(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let dm = json!({
        "mixsongid": q_num(q, "mixsongid", 666075191),
    });
    forward(
        q, ctx, "POST", "/youth/v2/report/listen_song", None,
        Some(json!({ "clientver": 10566 })), Some(dm), "android",
        &[
            ("user-agent", "Android13-1070-10566-201-0-ReportPlaySongToServerProtocol-wifi"),
            ("content-type", "application/json; charset=utf-8"),
        ],
        false, false,
    )
}

/// youth_month_vip_record.js → /youth/month/vip/record。
pub fn handle_month_vip_record(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let pm = json!({ "latest_limit": 100 });
    forward(
        q, ctx, "get", "/youth/v1/activity/get_month_vip_record", None,
        Some(pm), None, "android", &[], false, false,
    )
}

/// youth_union_vip.js → /youth/union/vip。
pub fn handle_union_vip(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let pm = json!({
        "busi_type": "concept",
        "opt_product_types": "dvip,qvip",
        "product_type": "svip",
    });
    forward(
        q, ctx, "get", "/v1/get_union_vip", Some("https://kugouvip.kugou.com"),
        Some(pm), None, "android", &[], false, false,
    )
}

/// youth_user_song.js → /youth/user/song。
pub fn handle_user_song(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let pm = json!({
        "filter_video": 0,
        "type": q_num(q, "type", 0),
        "userid": q_str(q, "userid", ""),
        "pagesize": q_num(q, "pagesize", 30),
        "page": q_num(q, "page", 1),
        "is_filter": 0,
    });
    forward(
        q, ctx, "get", "/youth/v1/get_user_song_public", None,
        Some(pm), None, "android", &[], false, false,
    )
}

/// youth_vip.js → /youth/vip（广告播放上报领 VIP）。
pub fn handle_vip(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let now_ms = (now_epoch_secs() * 1000.0) as i64;
    let dm = json!({
        "ad_id": 12307537187i64,
        "play_end": now_ms,
        "play_start": now_ms - 30000,
    });
    forward(
        q, ctx, "post", "/youth/v1/ad/play_report", None, None,
        Some(dm), "android", &[], false, false,
    )
}
