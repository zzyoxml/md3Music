//! API 模块注册表（等价 server_bundle.js 中 `toe` 的模块表）。
//!
//! 每个模块与 JS `module/<name>.js` 一一对应，签名与 server.js 路由处理器
//! 的 `module(query, requestFactory)` 对齐：`fn(&Value, &Ctx)`。

use crate::request::{ModuleResponse, RequestOptions};
use serde_json::{json, Value};

pub mod album;
pub mod artist;
pub mod audio;
pub mod audio_match;
pub mod audio_more;
pub mod comment_more;
pub mod comment_music;
pub mod everyday;
pub mod extras;
pub mod fm;
pub mod images;
pub mod ip;
pub mod ip_more;
pub mod login;
pub mod longaudio;
pub mod lyric;
pub mod misc;
pub mod pcm;
pub mod playlist;
pub mod rank;
pub mod register_dev;
pub mod scene;
pub mod search;
pub mod search_mixed;
pub mod search_more;
pub mod search_suggest;
pub mod server_now;
pub mod sheet;
pub mod song_url;
pub mod song_url_new;
pub mod theme;
pub mod top;
pub mod user;
pub mod verify;
pub mod video;
pub mod youth;
pub mod yueku;

/// 模块调用上下文。`send` 等价 server.js 中工厂函数 `(config) => { config.ip = ip; return createRequest(config); }`。
pub struct Ctx {
    pub ip: String,
    /// 原始二进制请求体（octet-stream，如 /audio/match 的 PCM 数据）。
    pub body_bytes: Option<Vec<u8>>,
}

impl Ctx {
    pub fn send(&self, opts: &RequestOptions) -> Result<ModuleResponse, ModuleResponse> {
        let mut o = opts.clone();
        o.ip = self.ip.clone();
        crate::request::create_request(&o)
    }

    /// 直连 GET（lyric.js 不走工厂）。
    pub fn raw_get(&self, url: &str, params: &Value) -> Result<ModuleResponse, ModuleResponse> {
        crate::request::raw_get(url, params)
    }
}

pub type ModuleFn = fn(&Value, &Ctx) -> Result<ModuleResponse, ModuleResponse>;

/// 注册已实现模块。顺序保持「更具体的路由在前」，与 bundled_entry.js 的 reverse 排序一致。
pub fn register(routes: &mut Vec<(&'static str, ModuleFn)>) {
    routes.push(("/login/wx/create", login::handle_wx_create));
    routes.push(("/login/wx/check", login::handle_wx_check));
    routes.push(("/login/qr/create", login::handle_qr_create));
    routes.push(("/login/qr/check", login::handle_qr_check));
    routes.push(("/login/qr/key", login::handle_qr_key));
    routes.push(("/login/token", login::handle_token));
    routes.push(("/login/device/kick", login::handle_device_kick));
    routes.push(("/login/device", login::handle_device));
    routes.push(("/login/openplat", login::handle_openplat));
    routes.push(("/login/cellphone", login::handle_cellphone));
    routes.push(("/login", login::handle_login));
    routes.push(("/get/verify/info", verify::handle_get_verify_info));
    routes.push(("/verify/user/info", verify::handle_verify_user_info));
    routes.push(("/ai/recommend", extras::handle_ai_recommend));
    routes.push(("/playlist/track/all/new", playlist::handle_track_all_new));
    routes.push(("/playlist/track/all", playlist::handle_track_all));
    routes.push(("/playlist/tracks/add", playlist::handle_tracks_add));
    routes.push(("/playlist/tracks/del", playlist::handle_tracks_del));
    routes.push(("/playlist/tags", playlist::handle_tags));
    routes.push(("/playlist/similar", playlist::handle_similar));
    routes.push(("/playlist/effect", playlist::handle_effect));
    routes.push(("/playlist/detail", playlist::handle_detail));
    routes.push(("/playlist/del", playlist::handle_del));
    routes.push(("/playlist/add", playlist::handle_add));
    routes.push(("/user/video/collect", user::handle_video_collect));
    routes.push(("/user/video/love", user::handle_video_love));
    routes.push(("/user/vip/detail", user::handle_vip_detail));
    routes.push(("/user/playlist", user::handle_playlist));
    routes.push(("/user/purchased/songs", user::handle_purchased_songs));
    routes.push(("/user/purchased/albums", user::handle_purchased_albums));
    routes.push(("/user/listen", user::handle_listen));
    routes.push(("/user/history", user::handle_history));
    routes.push(("/user/follow/message", user::handle_follow_message));
    routes.push(("/user/follow", user::handle_follow));
    routes.push(("/user/grade/info", user::handle_grade_info));
    routes.push(("/user/detail", user::handle_detail));
    routes.push(("/user/cloud/upload", user::handle_cloud_upload));
    routes.push(("/user/cloud/del", user::handle_cloud_del));
    routes.push(("/user/cloud/url", user::handle_cloud_url));
    routes.push(("/user/cloud", user::handle_cloud));
    routes.push(("/youth/channel/song/detail", youth::handle_channel_song_detail));
    routes.push(("/youth/channel/song", youth::handle_channel_song));
    routes.push(("/youth/channel/similar", youth::handle_channel_similar));
    routes.push(("/youth/channel/detail", youth::handle_channel_detail));
    routes.push(("/youth/channel/amway", youth::handle_channel_amway));
    routes.push(("/youth/channel/sub", youth::handle_channel_sub));
    routes.push(("/youth/channel/all", youth::handle_channel_all));
    routes.push(("/youth/day/vip/upgrade", youth::handle_day_vip_upgrade));
    routes.push(("/youth/day/vip", youth::handle_day_vip));
    routes.push(("/youth/dynamic/recent", youth::handle_dynamic_recent));
    routes.push(("/youth/dynamic", youth::handle_dynamic));
    routes.push(("/youth/listen/song", youth::handle_listen_song));
    routes.push(("/youth/month/vip/record", youth::handle_month_vip_record));
    routes.push(("/youth/union/vip", youth::handle_union_vip));
    routes.push(("/youth/user/song", youth::handle_user_song));
    routes.push(("/youth/vip", youth::handle_vip));
    routes.push(("/brush", extras::handle_brush));
    routes.push(("/everyday/style/recommend", everyday::handle_style_recommend));
    routes.push(("/everyday/recommend", everyday::handle_recommend));
    routes.push(("/everyday/history", everyday::handle_history));
    routes.push(("/everyday/friend", everyday::handle_friend));
    routes.push(("/fm/class", fm::handle_class));
    routes.push(("/fm/image", fm::handle_image));
    routes.push(("/fm/recommend", fm::handle_recommend));
    routes.push(("/fm/songs", fm::handle_songs));
    routes.push(("/images/audio", images::handle_images_audio));
    routes.push(("/images", images::handle_images));
    routes.push(("/ip/zone/home", ip_more::handle_zone_home));
    routes.push(("/ip/zone", ip_more::handle_zone));
    routes.push(("/ip/playlist", ip_more::handle_playlist));
    routes.push(("/ip/dateil", ip_more::handle_dateil));
    routes.push(("/longaudio/week/recommend", longaudio::handle_week_recommend));
    routes.push(("/longaudio/vip/recommend", longaudio::handle_vip_recommend));
    routes.push(("/longaudio/rank/recommend", longaudio::handle_rank_recommend));
    routes.push(("/longaudio/daily/recommend", longaudio::handle_daily_recommend));
    routes.push(("/longaudio/album/detail", longaudio::handle_album_detail));
    routes.push(("/longaudio/album/audios", longaudio::handle_album_audios));
    routes.push(("/longaudio/album/list", longaudio::handle_album_list));
    routes.push(("/longaudio/tag/list", longaudio::handle_tag_list));
    routes.push(("/pc/diantai", fm::handle_pc_diantai));
    routes.push(("/personal/fm", fm::handle_personal_fm));
    routes.push(("/playhistory/upload", extras::handle_playhistory_upload));
    routes.push(("/recommend/songs", everyday::handle_recommend_songs));
    routes.push(("/video/url", video::handle_url));
    routes.push(("/video/privilege", video::handle_privilege));
    routes.push(("/video/detail", video::handle_detail));
    routes.push(("/yueku/banner", yueku::handle_banner));
    routes.push(("/yueku/fm", fm::handle_yueku_fm));
    routes.push(("/yueku", yueku::handle_yueku));
    routes.push(("/register/dev", register_dev::handle));
    routes.push(("/comment/music/hotword", comment_more::handle_music_hotword));
    routes.push(("/comment/music/classify", comment_more::handle_music_classify));
    routes.push(("/comment/music/topliked", comment_more::handle_music_topliked));
    routes.push(("/comment/playlist", comment_more::handle_playlist));
    routes.push(("/comment/floor", comment_more::handle_floor));
    routes.push(("/comment/count", comment_more::handle_count));
    routes.push(("/comment/album", comment_more::handle_album));
    routes.push(("/theme/playlist/track", theme::handle_playlist_track));
    routes.push(("/theme/playlist", theme::handle_playlist));
    routes.push(("/theme/music/detail", theme::handle_music_detail));
    routes.push(("/theme/music", theme::handle_music));
    routes.push(("/sheet/song", sheet::handle_song));
    routes.push(("/sheet/detail", sheet::handle_detail));
    routes.push(("/sheet/explore", sheet::handle_explore));
    routes.push(("/sheet/rank", sheet::handle_rank));
    routes.push(("/sheet/tags", sheet::handle_tags));
    routes.push(("/sheet/collection", sheet::handle_collection));
    routes.push(("/search/lyric", search_more::handle_lyric));
    routes.push(("/search/hot", search_more::handle_hot));
    routes.push(("/search/album", search_more::handle_album));
    routes.push(("/search/artist", search_more::handle_artist));
    routes.push(("/search/special", search_more::handle_special));
    routes.push(("/search/default", search_more::handle_default));
    routes.push(("/search/complex", search_more::handle_complex));
    routes.push(("/rank/audio", rank::handle_audio));
    routes.push(("/rank/vol", rank::handle_vol));
    routes.push(("/rank/info", rank::handle_info));
    routes.push(("/rank/list", rank::handle_list));
    routes.push(("/rank/top", rank::handle_top));
    routes.push(("/scene/video/list", scene::handle_video_list));
    routes.push(("/scene/collection/list", scene::handle_collection_list));
    routes.push(("/scene/audio/list", scene::handle_audio_list));
    routes.push(("/scene/lists/v2", scene::handle_lists_v2));
    routes.push(("/scene/lists", scene::handle_lists));
    routes.push(("/scene/module/info", scene::handle_module_info));
    routes.push(("/scene/module", scene::handle_module));
    routes.push(("/scene/music", scene::handle_music));
    routes.push(("/top/card/youth", top::handle_card_youth));
    routes.push(("/top/playlist", top::handle_playlist));
    routes.push(("/top/album", top::handle_album));
    routes.push(("/top/card", top::handle_card));
    routes.push(("/top/song", top::handle_song));
    routes.push(("/top/ip", top::handle_ip));
    routes.push(("/audio/accompany/matching", audio_more::handle_accompany_matching));
    routes.push(("/audio/ktv/total", audio_more::handle_ktv_total));
    routes.push(("/audio/related", audio_more::handle_related));
    routes.push(("/album/detail", album::handle_album_detail));
    routes.push(("/album/songs", album::handle_album_songs));
    routes.push(("/album/shop", album::handle_album_shop));
    routes.push(("/album", album::handle_album));
    routes.push(("/captcha/sent", misc::handle_captcha_sent));
    routes.push(("/favorite/count", misc::handle_favorite_count));
    routes.push(("/lastest/songs/listen", misc::handle_lastest_songs_listen));
    routes.push(("/privilege/lite", misc::handle_privilege_lite));
    routes.push(("/singer/list", misc::handle_singer_list));
    routes.push(("/song/climax", misc::handle_song_climax));
    routes.push(("/song/ranking/filter", misc::handle_song_ranking_filter));
    routes.push(("/song/ranking", misc::handle_song_ranking));
    routes.push(("/songlist/add", misc::handle_songlist_add));
    routes.push(("/kmr/audio/mv", audio_more::handle_kmr_audio_mv));
    routes.push(("/krm/audio", audio_more::handle_krm_audio));
    routes.push(("/artist/follow/newsongs", artist::handle_follow_newsongs));
    routes.push(("/artist/honour", artist::handle_honour));
    routes.push(("/artist/albums", artist::handle_albums));
    routes.push(("/artist/audios", artist::handle_audios));
    routes.push(("/artist/videos", artist::handle_videos));
    routes.push(("/artist/lists", artist::handle_lists));
    routes.push(("/artist/follow", artist::handle_follow));
    routes.push(("/artist/unfollow", artist::handle_unfollow));
    routes.push(("/artist/detail", artist::handle_detail));
    routes.push(("/search/suggest", search_suggest::handle));
    routes.push(("/search/mixed", search_mixed::handle));
    routes.push(("/search/audiobook", search_mixed::handle_audiobook));
    routes.push(("/search", search::handle));
    routes.push(("/song/url/new", song_url_new::handle));
    routes.push(("/song/url", song_url::handle));
    routes.push(("/server/now", server_now::handle));
    routes.push(("/lyric", lyric::handle));
    routes.push(("/comment/music", comment_music::handle));
    routes.push(("/audio/match", audio_match::handle));
    routes.push(("/extras/pcm-process", pcm::handle));
    routes.push(("/audio", audio::handle));
    routes.push(("/ip", ip::handle));
}

// ---------------------------------------------------------------------------
// query 取值辅助（复刻 JS 的 `params?.x || params?.cookie?.y || default` 语义）
// ---------------------------------------------------------------------------

/// query 参数值；空串/0/缺失 → default。
pub fn q_str(q: &Value, key: &str, default: &str) -> String {
    match q.get(key) {
        Some(Value::String(s)) if !s.is_empty() => s.clone(),
        Some(Value::String(_)) => default.to_string(),
        Some(Value::Number(n)) => {
            let v = n.to_string();
            if v == "0" {
                default.to_string()
            } else {
                v
            }
        }
        Some(Value::Bool(b)) => b.to_string(),
        _ => default.to_string(),
    }
}

/// query 数值参数；空串 → default；字符串 "0" 保持为 0（JS 中 "0" 为真值）。
pub fn q_num(q: &Value, key: &str, default: i64) -> i64 {
    match q.get(key) {
        Some(Value::String(s)) => {
            if s.trim().is_empty() {
                default
            } else {
                s.trim().parse::<i64>().unwrap_or(default)
            }
        }
        Some(Value::Number(n)) => {
            let v = n.as_i64().unwrap_or_default();
            if v == 0 {
                default
            } else {
                v
            }
        }
        Some(Value::Bool(b)) => {
            if *b {
                1
            } else {
                default
            }
        }
        _ => default,
    }
}

pub fn cookie_obj(q: &Value) -> &Value {
    q.get("cookie").unwrap_or(&Value::Null)
}

pub fn c_str(q: &Value, key: &str) -> String {
    match cookie_obj(q).get(key) {
        Some(Value::String(s)) if !s.is_empty() => s.clone(),
        Some(Value::String(_)) => String::new(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        _ => String::new(),
    }
}

pub fn c_num(q: &Value, key: &str, default: i64) -> i64 {
    match cookie_obj(q).get(key) {
        Some(Value::String(s)) => s.trim().parse::<i64>().unwrap_or(default),
        Some(Value::Number(n)) => n.as_i64().unwrap_or(default),
        Some(Value::Bool(b)) => {
            if *b {
                1
            } else {
                default
            }
        }
        _ => default,
    }
}

pub fn param_or_cookie_str(q: &Value, key: &str, default: &str) -> String {
    let pv = q_str(q, key, "");
    if !pv.is_empty() {
        return pv;
    }
    let cv = c_str(q, key);
    if !cv.is_empty() {
        cv
    } else {
        default.to_string()
    }
}

pub fn cookie_or_param_str(q: &Value, key: &str, default: &str) -> String {
    let cv = c_str(q, key);
    if !cv.is_empty() {
        return cv;
    }
    q_str(q, key, default)
}

pub fn param_or_cookie_num(q: &Value, key: &str, default: i64) -> i64 {
    let pv = q_str(q, key, "");
    if !pv.is_empty() {
        return pv.trim().parse::<i64>().unwrap_or(default);
    }
    let cv = c_str(q, key);
    if !cv.is_empty() {
        cv.trim().parse::<i64>().unwrap_or(default)
    } else {
        default
    }
}

pub fn cookie_or_param_num(q: &Value, key: &str, default: i64) -> i64 {
    let cv = c_str(q, key);
    if !cv.is_empty() {
        return cv.trim().parse::<i64>().unwrap_or(default);
    }
    let pv = q_str(q, key, "");
    if !pv.is_empty() {
        pv.trim().parse::<i64>().unwrap_or(default)
    } else {
        default
    }
}

/// JS truthiness for query values (absent → false, non-empty anything → true).
pub fn q_truthy(q: &Value, key: &str) -> bool {
    match q.get(key) {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(Value::String(s)) => !s.is_empty(),
        Some(_) => true,
    }
}

/// JS `obj?.[key] ?? default`：缺失/null → default（原样，保持数字/字符串类型）；
/// 其他 → 原值（URL query 下通常为字符串，不做任何类型转换）。
/// 用于云盘等需要与 JS `JSON.stringify` 明文逐字节一致的模块。
pub fn q_raw_or(q: &Value, key: &str, default: Value) -> Value {
    match q.get(key) {
        None | Some(Value::Null) => default,
        Some(v) => v.clone(),
    }
}

/// 提取 query cookie 对象（深拷贝，供模块作为 `cookie` 传入）。
pub fn q_cookie(q: &Value) -> Value {
    q.get("cookie").cloned().unwrap_or_else(|| json!({}))
}

/// JS `obj?.[key] || default`（字符串空串/数字 0/缺失 → default）。
pub fn or_str(obj: &Value, key: &str, default: &str) -> String {
    match obj.get(key) {
        Some(Value::String(s)) if !s.is_empty() => s.clone(),
        Some(Value::String(_)) => default.to_string(),
        Some(Value::Number(n)) => {
            let v = n.to_string();
            if v == "0" {
                default.to_string()
            } else {
                v
            }
        }
        Some(Value::Bool(b)) => b.to_string(),
        _ => default.to_string(),
    }
}

/// JS `obj?.[key] || default`（数字 0/缺失 → default；字符串 "0" 保持为 0）。
pub fn or_num(obj: &Value, key: &str, default: i64) -> i64 {
    match obj.get(key) {
        Some(Value::Number(n)) => {
            let v = n.as_i64().unwrap_or_default();
            if v == 0 {
                default
            } else {
                v
            }
        }
        Some(Value::String(s)) => s.trim().parse::<i64>().unwrap_or(default),
        Some(Value::Bool(b)) => {
            if *b {
                1
            } else {
                default
            }
        }
        _ => default,
    }
}

/// 通用转发：等价 server.js 中
/// `module(query, requestFactory)` → `requestFactory({ method, url, params/data, encryptType, cookie, headers, ... })`。
/// 简单模块（无响应重塑/加密）全部走这里，减少样板代码。
#[allow(clippy::too_many_arguments)]
pub fn forward(
    q: &Value,
    ctx: &Ctx,
    method: &str,
    url: &str,
    base_url: Option<&str>,
    params: Option<Value>,
    json: Option<Value>,
    encrypt_type: &str,
    headers: &[(&str, &str)],
    clear_default_params: bool,
    not_signature: bool,
) -> Result<ModuleResponse, ModuleResponse> {
    let mut o = RequestOptions::new(url);
    // 大小写不敏感比较：兼容调用方误传小写 "get"/"post"，
    // 否则 "get" 会走 post 分支导致上游 405（云盘 URL 曾踩坑）。
    if method.eq_ignore_ascii_case("GET") {
        o = o.get(url);
    } else {
        o = o.post(url);
    }
    if let Some(b) = base_url {
        o = o.base_url(b);
    }
    if let Some(p) = params {
        o = o.params(p);
    }
    if let Some(j) = json {
        o = o.json_body(j);
    }
    o = o.encrypt_type(encrypt_type).cookie(q_cookie(q));
    for (k, v) in headers {
        o = o.header(k, v);
    }
    if clear_default_params {
        o = o.clear_default_params(true);
    }
    if not_signature {
        o = o.not_signature(true);
    }
    ctx.send(&o)
}

/// JS `Object.keys(obj).sort().map(k => `${k}=${typeof v==='object' ? JSON.stringify(v) : v}`).join(sep)`
/// —— audio_related / audio_accompany_matching / audio_ktv_total 的自定义签名用。
pub fn sorted_kv_joined(params: &Value, sep: &str) -> String {
    let mut keys: Vec<&String> = match params.as_object() {
        Some(m) => m.keys().collect(),
        None => return String::new(),
    };
    keys.sort();
    keys.iter()
        .map(|k| {
            let v = params.get(*k).unwrap_or(&Value::Null);
            let vs = match v {
                Value::Object(_) | Value::Array(_) => crate::util::json_stringify(v),
                Value::String(s) => s.clone(),
                Value::Number(n) => n.to_string(),
                Value::Bool(b) => b.to_string(),
                Value::Null => "null".to_string(),
            };
            format!("{}={}", k, vs)
        })
        .collect::<Vec<_>>()
        .join(sep)
}
