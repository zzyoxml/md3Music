//! home_discover.js → /home/discover
//!
//! 首页「刷歌」（发现页沉浸式）推荐流。上游端点是
//! `POST /homediscoverrec/v1/client/home_discover_rec`（真实入口 papi.kugou.com，
//! 但与 JS 一样走默认网关 gateway.kugou.com，因此不需要 base_url，也不要加
//! `x-router`——该模块在参考实现里就没声明，加了反而会改路由到别的服务）。
//!
//! 与参考实现的三处刻意差异：
//!
//! 1. `go_ky_extra` 写死默认值，不接受 query 覆盖。JS 允许
//!    `params?.go_ky_extra`，但本地服务把 URL query 与 JSON body 合并成同一个
//!    模块查询对象，数组型参数经 URL 传来只剩字符串，覆盖只会引入类型歧义。
//! 2. 额外接受可选 `page`，仅在 >0 时写进 query。参考实现没有这个参数，
//!    属于为「详情页无限滚动」预留的探针位：上游若认 page，就按页翻；
//!    不认也不影响——`q_num` 取不到值时该键根本不会出现在 params 里。
//! 3. 不重塑响应（JS 直接返回 `useAxios` 的结果），解析交给 Dart 侧做。

use crate::modules::{cookie_or_param_num, forward, q_num, q_str, Ctx};
use crate::request::ModuleResponse;
use serde_json::{json, Value};

/// 上游路径。
pub const HOME_DISCOVER_PATH: &str = "/homediscoverrec/v1/client/home_discover_rec";

/// query 侧的 module_key。
const MODULE_KEY: &str = "home_discover_rec";

/// 客户端版本号。必须显式覆盖概念版的 11440，否则上游静默返回空列表。
///
/// 参考实现的注释记录了这条约束：服务端不下发版本低于约 20489 的内容，
/// 且 lite 模式（appid=3116）下必须覆盖 liteClientver，否则拿不到数据。
/// 因此这里 appid 沿用概念版 3116（由 `create_request` 的默认参数注入），
/// 只把 clientver 抬到 20809——与 JS 在 `platform=lite` 下的组合完全一致。
const CLIENT_VER: i64 = 20809;

/// 推荐内容的支撑类型，只有 `only_song` 有效。
const SUPPORT_ONLY_SONG: &str = "only_song";

/// 客户端环境附加信息。三个 key 的取值含义：
///   network    网络类型：0=无网络/未知、1=4G、2=WIFI、3=3G、4=2G、5=5G
///   play_mode  播放模式：0/1=顺序播放、2=单曲循环、3=随机播放
///   no_mv_ret  是否屏蔽 MV 类内容：1=不返回 MV、0=允许返回
///
/// 参考实现实测任意取值均不影响可用性，这里保持其默认值。
fn default_go_ky_extra() -> Value {
    json!([
        { "key": "network",   "val": "2" },
        { "key": "play_mode", "val": "2" },
        { "key": "no_mv_ret", "val": "1" },
    ])
}

/// 构造 POST body。抽出来是为了让单测能直接断言参数默认值与覆盖行为。
pub fn build_body(q: &Value) -> Value {
    let userid = cookie_or_param_num(q, "userid", 0);
    json!({
        "support": SUPPORT_ONLY_SONG,
        "userid": userid,
        // 召回类型：song/mv/album/songlist/radio/anchor
        "recall_type": q_str(q, "recall_type", "song"),
        // 今日已播放歌曲数，影响服务端的推荐去重与排序，也是本项目滑动/补货
        // 唯一的翻页依据（上游没有 page/offset，见模块头注释）。
        "today_play_num": q_num(q, "today_play_num", 0),
        "pagesize": q_num(q, "pagesize", 4),
        "go_ky_extra": default_go_ky_extra(),
    })
}

/// 构造 query 参数。`page` 为 0/缺失时不写入。
pub fn build_params(q: &Value) -> Value {
    let userid = cookie_or_param_num(q, "userid", 0);
    let mut params = json!({
        "module_key": MODULE_KEY,
        "module_id": 1,
        "area_code": 1,
        "platform": "android",
        "userid": userid,
        "clientver": CLIENT_VER,
    });
    let page = q_num(q, "page", 0);
    if let Some(obj) = params.as_object_mut() {
        if page > 0 {
            obj.insert("page".to_string(), json!(page));
        }
    }
    params
}

/// home_discover.js → /home/discover
pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    forward(
        q,
        ctx,
        "POST",
        HOME_DISCOVER_PATH,
        None,
        Some(build_params(q)),
        Some(build_body(q)),
        "android",
        &[],
        false,
        false,
    )
}
