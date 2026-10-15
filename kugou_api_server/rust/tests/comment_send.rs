//! 评论写接口（/comment/{music,floor,playlist,album}/send）纯函数回归。
//!
//! 黄金值由参考实现 KuGouMusicApi（platform=lite）实测产出，生成命令见
//! docs/superpowers/plans/2026-09-18-comment-send.md 第 0 节。
//! 任何签名/参数改动都必须能解释这些值为何不变。

use kugou_server::modules::comment_send::{
    del_options, extract_resolved_resource, floor_tid, identity, reply_options,
    reply_quote_fields, resolve_code, send_options, with_quote_suffix, ALBUM_CODE, PLAYLIST_CODE,
    SONG_CODE,
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
fn del_options_matches_reference() {
    let opts = del_options(&fixture_query(), "123", "100285259", SONG_CODE, "678433417");

    assert_eq!(opts.method, "GET", "commentsv2/delcomment 是 GET，无请求体");
    assert_eq!(opts.url, "/index.php");
    assert!(opts.data.is_none(), "删除接口无请求体");
    assert_eq!(
        opts.headers.get("Content-Type").map(String::as_str),
        None,
        "无 body 时不下发 Content-Type"
    );
    assert_eq!(
        opts.headers.get("x-router").map(String::as_str),
        Some("m.comment.service.kugou.com")
    );
    assert!(opts.not_signature, "写接口必须跳过 signature");
    assert!(opts.clear_default_params, "写接口必须清空默认参数");
    assert_eq!(opts.base_url, None);

    let p = &opts.params;
    assert_eq!(p["r"], json!("commentsv2/delcomment"));
    assert_eq!(p["code"], json!(SONG_CODE));
    assert_eq!(p["childrenid"], json!("100285259"));
    assert_eq!(p["cid"], json!("123"));
    assert_eq!(p["tid"], json!("678433417"));
    assert_eq!(p["kugouid"], json!(12345));
    assert_eq!(p["ver"], json!(6));
    assert_eq!(p["clienttoken"], json!("TOK"));
    assert_eq!(p["appid"], json!(3116));
    assert_eq!(p["clientver"], json!(11440));
    assert_eq!(p["mid"], json!("abcdef1234567890"));
    assert_eq!(p["clienttime"], json!(1758182400));
    assert_eq!(p["uuid"], json!("-"));
    assert_eq!(p["dfid"], json!("-"));
    assert_eq!(
        p["key"],
        json!("4045fee0201228de18b625ff1499aed0"),
        "key = signParamsKey(clienttime+mid)，与 commentsv2/reply 同源"
    );
    assert!(p.get("signature").is_none(), "跳过签名后不得带 signature");
}

#[test]
fn del_options_omits_empty_tid() {
    let opts = del_options(&fixture_query(), "123", "100285259", ALBUM_CODE, "");
    assert!(
        opts.params.get("tid").is_none(),
        "空 tid 必须被 compact 掉（删除顶层评论场景）"
    );
    assert_eq!(opts.params["code"], json!(ALBUM_CODE));
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

// ---------------------------------------------------------------------------
// 镜像修正回归（对照 KuGouMusicApi module/_comment.js / comment_floor_send.js）
// ---------------------------------------------------------------------------

/// 空 cookie 样本（未登录/缺字段时验证 compact 行为）。
fn bare_query() -> serde_json::Value {
    json!({ "clienttime": 1758182400 })
}

#[test]
fn reply_options_passes_extdata_and_source() {
    let q = json!({
        "clienttime": 1758182400,
        "extdata": "ext-1",
        "source": "android",
        "cookie": { "KUGOU_API_MID": "abcdef1234567890", "userid": 1 }
    });
    let p = reply_options(&q, "x", "1", "n", SONG_CODE, "2").params;
    assert_eq!(p["extdata"], json!("ext-1"), "extdata 原样透传");
    assert_eq!(p["source"], json!("android"), "source 原样透传");

    // 缺省时两个键都不出现（JS compact 语义）
    let p2 = reply_options(&fixture_query(), "x", "1", "n", SONG_CODE, "2").params;
    assert!(p2.get("extdata").is_none(), "缺省 extdata 不下发");
    assert!(p2.get("source").is_none(), "缺省 source 不下发");
}

#[test]
fn reply_options_accepts_is_t_alias() {
    // JS firstValue(params.is_t, params.isT, ...)：isT 别名同样生效
    let q = json!({
        "clienttime": 1758182400,
        "pid": "678433417",
        "isT": "1",
        "cookie": { "KUGOU_API_MID": "abcdef1234567890", "userid": 1 }
    });
    let p = reply_options(&q, "x", "1", "", SONG_CODE, "2").params;
    assert_eq!(p["is_t"], json!("1"));
}

#[test]
fn reply_options_empty_pid_becomes_zero() {
    // JS firstValue(params.pid, 0)：空串 → 0（is_t 自动推断随之取 1）
    let q = json!({
        "clienttime": 1758182400,
        "pid": "",
        "cookie": { "KUGOU_API_MID": "abcdef1234567890", "userid": 1 }
    });
    let p = reply_options(&q, "x", "1", "", SONG_CODE, "2").params;
    assert_eq!(p["pid"], json!(0));
    assert_eq!(p["is_t"], json!(1));
}

#[test]
fn identity_prefers_params_mid_over_cookie() {
    let q = json!({
        "mid": "M1",
        "cookie": { "KUGOU_API_MID": "abcdef1234567890", "userid": 1 }
    });
    assert_eq!(identity(&q).mid, "M1");
    // 未传 mid 参数时回落 cookie；再无则用 "-"（request.rs 默认口径）
    assert_eq!(identity(&fixture_query()).mid, "abcdef1234567890");
    assert_eq!(identity(&json!({})).mid, "-");
}

#[test]
fn auth_params_drop_empty_clienttoken_but_keep_zero_kugouid() {
    let p = reply_options(&bare_query(), "x", "1", "", SONG_CODE, "2").params;
    assert!(
        p.get("clienttoken").is_none(),
        "空 token 必须被 compact 丢弃（JS compact 语义）"
    );
    assert_eq!(p["kugouid"], json!(0), "kugouid=0 是数字，compact 保留");
}

#[test]
fn auth_params_allow_ver_override() {
    let q = json!({ "clienttime": 1758182400, "ver": 7, "userid": 1 });
    let p = reply_options(&q, "x", "1", "", SONG_CODE, "2").params;
    assert_eq!(p["ver"], json!(7), "显式 ver 原样透传");

    let p2 = reply_options(&fixture_query(), "x", "1", "", SONG_CODE, "2").params;
    assert_eq!(p2["ver"], json!(6), "缺省 ver = 6");
}

#[test]
fn reply_quote_fields_support_puser_pcontent_aliases() {
    let q = json!({ "puser": "小明", "pcontent": "原评论" });
    assert_eq!(reply_quote_fields(&q), ("小明".to_string(), "原评论".to_string()));

    // 显式参数优先于别名
    let q2 = json!({
        "reply_user_name": "小红",
        "reply_content": "内容",
        "puser": "小明",
        "pcontent": "原评论"
    });
    assert_eq!(reply_quote_fields(&q2), ("小红".to_string(), "内容".to_string()));

    // 都缺省 → 空串（不拼引用后缀）
    assert_eq!(reply_quote_fields(&json!({})), (String::new(), String::new()));
}

#[test]
fn floor_tid_accepts_string_zero_and_rejects_empty() {
    // JS "0" 是真值：放行转发上游
    assert_eq!(floor_tid(&json!({ "tid": "0" })).unwrap(), "0");
    assert_eq!(floor_tid(&json!({ "tid": "678433417" })).unwrap(), "678433417");
    // 缺失/空串拒绝
    assert!(floor_tid(&json!({})).is_err());
    assert!(floor_tid(&json!({ "tid": "" })).is_err());
    // JSON body 数字 0 → q_str 归空 → 拒绝（与 JS !firstValue(0) 一致）
    assert!(floor_tid(&json!({ "tid": 0 })).is_err());
}

#[test]
fn send_options_passes_title_extdata_images_source() {
    let q = json!({
        "clienttime": 1758182400,
        "title": "歌名",
        "content_extdata": "ed",
        "images": ["https://img/1.png"],
        "source": "app",
        "cookie": { "KUGOU_API_MID": "abcdef1234567890", "userid": 1 }
    });
    let opts = send_options(&q, "评", "1", "n", SONG_CODE, "302362878");
    let (body, is_buffer) = opts.data.sig_data();
    assert!(!is_buffer);
    assert_eq!(
        String::from_utf8(body).unwrap(),
        r#"{"data":{"content":"评","album_audio_id":"302362878","title":"歌名","extdata":"ed","images":["https://img/1.png"]}}"#,
        "body 键序与 JS JSON.stringify 一致，title/extdata 透传"
    );
    assert_eq!(opts.params["source"], json!("app"));

    // 缺省时 body 与旧黄金值形态一致（title/extdata 不出现、images 归 []）、source 不下发
    let opts2 = send_options(&bare_query(), "评", "1", "n", SONG_CODE, "302362878");
    let (body2, _) = opts2.data.sig_data();
    assert_eq!(
        String::from_utf8(body2).unwrap(),
        r#"{"data":{"content":"评","album_audio_id":"302362878","images":[]"#.to_string() + "}}"
    );
    assert!(opts2.params.get("source").is_none());
}
