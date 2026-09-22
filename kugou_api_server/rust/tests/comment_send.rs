//! 评论写接口（/comment/{music,floor,playlist,album}/send）纯函数回归。
//!
//! 黄金值由参考实现 KuGouMusicApi（platform=lite）实测产出，生成命令见
//! docs/superpowers/plans/2026-09-18-comment-send.md 第 0 节。
//! 任何签名/参数改动都必须能解释这些值为何不变。

use kugou_server::modules::comment_send::{
    extract_resolved_resource, identity, reply_options, resolve_code, send_options, with_quote_suffix,
    ALBUM_CODE, PLAYLIST_CODE, SONG_CODE,
};
use serde_json::json;

/// 固定 clienttime + mid 的查询样本（clienttime 可显式传入，等价 JS
/// `firstValue(params.clienttime, now)`，因此黄金值可复现）。
fn fixture_query() -> serde_json::Value {
    json!({
        "clienttime": 1758182400,
        "cookie": { "KUGOU_API_MID": "abcdef1234567890", "token": "TOK", "userid": 12345 }
    })
}

#[test]
fn identity_reads_explicit_clienttime_and_cookie() {
    let id = identity(&fixture_query());
    assert_eq!(id.clienttime, 1758182400);
    assert_eq!(id.mid, "abcdef1234567890");
    assert_eq!(id.token, "TOK");
    assert_eq!(id.userid, 12345);
    assert_eq!(id.dfid, "-");
    assert_eq!(id.uuid, "-");
}

#[test]
fn send_options_matches_reference() {
    let opts = send_options(
        &fixture_query(),
        "测试评论",
        "100285259",
        "测试歌曲",
        SONG_CODE,
        "302362878",
    );

    assert_eq!(opts.method, "POST");
    assert_eq!(opts.url, "/index.php");
    assert_eq!(opts.base_url, None, "默认 gateway.kugou.com，与 JS 一致");
    assert!(opts.not_signature, "写接口必须跳过 signature");
    assert!(opts.clear_default_params, "写接口必须清空默认参数");
    assert_eq!(
        opts.headers.get("x-router").map(String::as_str),
        Some("m.comment.service.kugou.com")
    );
    assert_eq!(
        opts.headers.get("Content-Type").map(String::as_str),
        Some("application/json; charset=UTF-8")
    );

    // body 必须与 JS JSON.stringify 逐字节一致（key 的签名输入包含它）
    let (body, is_buffer) = opts.data.sig_data();
    assert!(!is_buffer);
    assert_eq!(
        String::from_utf8(body).unwrap(),
        r#"{"data":{"content":"测试评论","album_audio_id":"302362878","images":[]}}"#
    );

    let p = &opts.params;
    assert_eq!(p["r"], json!("commentsv3/add"));
    assert_eq!(p["code"], json!(SONG_CODE));
    assert_eq!(p["childrenid"], json!("100285259"));
    assert_eq!(p["childrenname"], json!("测试歌曲"));
    assert_eq!(p["kugouid"], json!(12345));
    assert_eq!(p["ver"], json!(6));
    assert_eq!(p["clienttoken"], json!("TOK"));
    assert_eq!(p["appid"], json!(3116));
    assert_eq!(p["clientver"], json!(11440));
    assert_eq!(p["mid"], json!("abcdef1234567890"));
    assert_eq!(p["clienttime"], json!(1758182400));
    assert_eq!(p["uuid"], json!("-"));
    assert_eq!(p["dfid"], json!("-"));
    assert_eq!(p["key"], json!("69c0d6331f5f09ce820bb5458656ccf1"));
    assert!(p.get("signature").is_none(), "跳过签名后不得带 signature");
}

#[test]
fn send_options_omits_album_audio_id_without_mixsongid() {
    let opts = send_options(&fixture_query(), "测试评论", "100285259", "", PLAYLIST_CODE, "");
    let (body, _) = opts.data.sig_data();
    assert_eq!(
        String::from_utf8(body).unwrap(),
        r#"{"data":{"content":"测试评论","images":[]}}"#
    );
    assert!(opts.params.get("childrenname").is_none(), "空 childrenname 不下发");
}

#[test]
fn reply_options_matches_reference() {
    let opts = reply_options(&fixture_query(), "回复内容", "100285259", "测试歌曲", SONG_CODE, "678433417");

    assert_eq!(opts.url, "/index.php");
    assert!(opts.data.is_none(), "commentsv2/reply 无请求体");
    assert_eq!(
        opts.headers.get("Content-Type").map(String::as_str),
        None,
        "无 body 时不下发 Content-Type"
    );

    let p = &opts.params;
    assert_eq!(p["r"], json!("commentsv2/reply"));
    assert_eq!(p["content"], json!("回复内容"));
    assert_eq!(p["tid"], json!("678433417"));
    assert_eq!(p["is_t"], json!(1), "pid 缺省为 0 → is_t = 1");
    assert_eq!(p["pid"], json!(0));
    assert_eq!(p["key"], json!("4045fee0201228de18b625ff1499aed0"));
}

#[test]
fn reply_options_respects_explicit_pid_and_is_t() {
    let q = json!({
        "clienttime": 1758182400,
        "pid": "678433417",
        "is_t": "0",
        "cookie": { "KUGOU_API_MID": "abcdef1234567890", "userid": 1 }
    });
    let p = reply_options(&q, "x", "1", "", SONG_CODE, "2").params;
    assert_eq!(p["pid"], json!("678433417"));
    assert_eq!(p["is_t"], json!("0"));

    // 只传 pid 不传 is_t 时，pid 非 0 → is_t = 0
    let q2 = json!({
        "clienttime": 1758182400,
        "pid": "678433417",
        "cookie": { "KUGOU_API_MID": "abcdef1234567890", "userid": 1 }
    });
    let p2 = reply_options(&q2, "x", "1", "", SONG_CODE, "2").params;
    assert_eq!(p2["is_t"], json!(0));
}

#[test]
fn resolve_code_by_resource_type_and_explicit_code() {
    assert_eq!(resolve_code(&json!({})), SONG_CODE);
    assert_eq!(resolve_code(&json!({ "resource_type": "song" })), SONG_CODE);
    assert_eq!(resolve_code(&json!({ "resource_type": "ALBUM" })), ALBUM_CODE);
    assert_eq!(resolve_code(&json!({ "resourceType": "playlist" })), PLAYLIST_CODE);
    assert_eq!(
        resolve_code(&json!({ "resource_type": "album", "code": "explicit" })),
        "explicit",
        "显式 code 优先级最高"
    );
}

#[test]
fn extract_resolved_resource_prefers_top_level_childrenid() {
    let body = json!({
        "status": 1,
        "childrenid": "100285259",
        "list": [{ "special_child_id": "999", "special_child_name": "另一首歌" }]
    });
    assert_eq!(
        extract_resolved_resource(&body),
        ("100285259".to_string(), "另一首歌".to_string())
    );

    // 顶层缺 childrenid → 退回列表项 special_child_id；名称退回 song_show_text
    let body2 = json!({ "list": [{ "special_child_id": 999, "song_show_text": "歌曲名" }] });
    assert_eq!(
        extract_resolved_resource(&body2),
        ("999".to_string(), "歌曲名".to_string())
    );

    // 空列表 / 缺字段 → 空串（不 panic）
    assert_eq!(extract_resolved_resource(&json!({})), (String::new(), String::new()));
}

#[test]
fn with_quote_suffix_appends_once() {
    assert_eq!(with_quote_suffix("收到", "小明", "原评论"), "收到//@小明:原评论");
    // 已经带引用后缀（客户端已拼好）时不再追加
    assert_eq!(with_quote_suffix("收到//@小明:原评论", "小明", "原评论"), "收到//@小明:原评论");
    // 缺任一字段 → 原样返回
    assert_eq!(with_quote_suffix("收到", "", "原评论"), "收到");
    assert_eq!(with_quote_suffix("收到", "小明", ""), "收到");
}
