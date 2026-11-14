//! comment 扩展系列：album / count / floor / music_classify / music_hotword /
//! music_topliked / playlist
//! 对应 JS module/{comment_album,comment_count,comment_floor,comment_music_classify,comment_music_hotword,comment_music_topliked,comment_playlist}.js

use crate::modules::{forward, q_num, q_str, Ctx};
use crate::request::ModuleResponse;
use serde_json::{json, Value};

const SONG_CODE: &str = "fc4be23b4e972707f36b8a828a93ba8a";
const PLAYLIST_CODE: &str = "ca53b96fe5a1d9c22d71c8f522ef7c4f";
const ALBUM_CODE: &str = "94f1792ced1df89aa68a7939eaf2efca";

/// comment_album.js → /comment/album（专辑评论）。
pub fn handle_album(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params_map = json!({
        "childrenid": q.get("id").cloned().unwrap_or(Value::Null),
        "need_show_image": 1,
        "p": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
        "show_classify": q_num(q, "show_classify", 1),
        "show_hotword_list": q_num(q, "show_hotword_list", 1),
        "code": ALBUM_CODE,
    });
    forward(
        q, ctx, "POST", "/m.comment.service/v1/cmtlist", None,
        Some(params_map), None, "android", &[], false, false,
    )
}

/// comment_count.js → /comment/count（评论数）。
pub fn handle_count(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let mut params_map = serde_json::Map::new();
    params_map.insert("r".to_string(), json!("comments/getcommentsnum"));
    params_map.insert("code".to_string(), json!(SONG_CODE));
    if q_has(q, "hash") {
        params_map.insert("hash".to_string(), q.get("hash").cloned().unwrap_or(Value::Null));
    } else if q_has(q, "special_id") {
        params_map.insert("childrenid".to_string(), q.get("special_id").cloned().unwrap_or(Value::Null));
    }
    forward(
        q, ctx, "GET", "/index.php", None,
        Some(json!(params_map)), None, "web",
        &[("x-router", "sum.comment.service.kugou.com")], false, false,
    )
}

fn q_has(q: &Value, key: &str) -> bool {
    match q.get(key) {
        None | Some(Value::Null) => false,
        Some(Value::String(s)) => {
            let t = s.trim();
            !t.is_empty() && t != "null" && t != "undefined"
        }
        Some(_) => true,
    }
}

/// comment_floor.js → /comment/floor（楼层评论）。
///
/// 走 replylist（按时间倒序）而非 hot_replylist（按点赞降序）：楼中楼是对话，
/// 需要时间顺序；且 hot_replylist 分页不可靠，同一 id 会在多个非相邻页重复
/// 出现并漏掉部分回复，返回的 id 集合还随 pagesize 变化。
pub fn handle_floor(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let resource_type = {
        let a = q_str(q, "resource_type", "");
        let b = q_str(q, "resourceType", "");
        let v = if !a.is_empty() { a } else { b };
        v.to_lowercase()
    };
    let code = {
        if q_has(q, "code") {
            q_str(q, "code", "")
        } else if resource_type == "playlist" {
            PLAYLIST_CODE.to_string()
        } else if resource_type == "album" {
            ALBUM_CODE.to_string()
        } else {
            SONG_CODE.to_string()
        }
    };
    let use_service_endpoint = resource_type == "playlist"
        || resource_type == "album"
        || code == PLAYLIST_CODE
        || code == ALBUM_CODE;

    let show_classify = match q.get("show_classify") {
        Some(v) if !v.is_null() => crate::util::js_string(Some(v)),
        _ => "1".to_string(),
    };
    let show_hotword_list = match q.get("show_hotword_list") {
        Some(v) if !v.is_null() => crate::util::js_string(Some(v)),
        _ => "1".to_string(),
    };

    let mut params_map = serde_json::Map::new();
    params_map.insert("childrenid".to_string(), q.get("special_id").cloned().unwrap_or(Value::Null));
    params_map.insert("need_show_image".to_string(), json!(1));
    params_map.insert("p".to_string(), json!(q_num(q, "page", 1)));
    params_map.insert("pagesize".to_string(), json!(q_num(q, "pagesize", 30)));
    params_map.insert("show_classify".to_string(), json!(show_classify));
    params_map.insert("show_hotword_list".to_string(), json!(show_hotword_list));
    params_map.insert("code".to_string(), json!(code));
    params_map.insert("tid".to_string(), q.get("tid").cloned().unwrap_or(Value::Null));
    if q_has(q, "mixsongid") {
        params_map.insert("mixsongid".to_string(), q.get("mixsongid").cloned().unwrap_or(Value::Null));
    }

    let url = if use_service_endpoint {
        "/m.comment.service/v1/replylist"
    } else {
        "/mcomment/v1/replylist"
    };
    forward(
        q, ctx, "POST", url, None,
        Some(json!(params_map)), None, "android", &[], false, false,
    )
}

/// comment_music_classify.js → /comment/music/classify（分类评论）。
pub fn handle_music_classify(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let sort_method = if q_num(q, "sort", 0) == 2 { 2 } else { 1 };
    let params_map = json!({
        "mixsongid": q.get("mixsongid").cloned().unwrap_or(Value::Null),
        "need_show_image": 1,
        "page": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
        "type_id": q.get("type_id").cloned().unwrap_or(Value::Null),
        "extdata": "0",
        "code": SONG_CODE,
        "sort_method": sort_method,
    });
    forward(
        q, ctx, "POST", "/mcomment/v1/cmt_classify_list", None,
        Some(params_map), None, "android", &[], false, false,
    )
}

/// comment_music_hotword.js → /comment/music/hotword（热词评论）。
pub fn handle_music_hotword(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params_map = json!({
        "mixsongid": q.get("mixsongid").cloned().unwrap_or(Value::Null),
        "need_show_image": 1,
        "p": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
        "hot_word": q.get("hot_word").cloned().unwrap_or(Value::Null),
        "extdata": "0",
        "code": SONG_CODE,
    });
    forward(
        q, ctx, "POST", "/mcomment/v1/get_hot_word", None,
        Some(params_map), None, "android", &[], false, false,
    )
}

/// comment_music_topliked.js → /comment/music/topliked（歌曲评论-最热）。
///
/// 上游 /mcomment/r/v1/rank/topliked 是「最热」标签页背后的接口，返回全局按点赞数
/// 降序的评论排名；/comment/music（cmtlist）返回的是加权混排，与点赞数无关。
/// 必传 childrenid（评论区 id，即 cmtlist 响应顶层的 childrenid / 评论项的
/// special_child_id），上游不接受用 mixsongid 代替。
pub fn handle_music_topliked(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let childrenid = if q_has(q, "childrenid") {
        q.get("childrenid").cloned().unwrap_or(Value::Null)
    } else if q_has(q, "special_id") {
        q.get("special_id").cloned().unwrap_or(Value::Null)
    } else {
        q.get("id").cloned().unwrap_or(Value::Null)
    };
    let params_map = json!({
        "childrenid": childrenid,
        "need_show_image": 1,
        "p": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
        "extdata": "0",
        "code": SONG_CODE,
    });
    forward(
        q, ctx, "POST", "/mcomment/r/v1/rank/topliked", None,
        Some(params_map), None, "android", &[], false, false,
    )
}

/// comment_playlist.js → /comment/playlist（歌单评论）。
pub fn handle_playlist(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let params_map = json!({
        "childrenid": q.get("id").cloned().unwrap_or(Value::Null),
        "need_show_image": 1,
        "p": q_num(q, "page", 1),
        "pagesize": q_num(q, "pagesize", 30),
        "show_classify": q_num(q, "show_classify", 1),
        "show_hotword_list": q_num(q, "show_hotword_list", 1),
        "code": PLAYLIST_CODE,
        "content_type": 0,
        "tag": 5,
    });
    forward(
        q, ctx, "POST", "/m.comment.service/v1/cmtlist", None,
        Some(params_map), None, "android", &[], false, false,
    )
}
