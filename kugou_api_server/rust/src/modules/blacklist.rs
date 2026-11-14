//! blacklist 系列：内容黑名单编辑 / 查询
//! 对应 JS module/blacklist.js（/blacklist）、blacklist_list.js（/blacklist/list）
//!
//! 上游 relationuser.kugou.com：/v1/edit_list_items（编辑）、/v2/get_list_items（查询）。
//! 两者均需登录态：token/userid 经 cookie 进 query 参与签名（request.rs 注入），
//! 明文 `{clienttime, token}` 用 RSA 无填充加密为 `p` 字段。
//! KG-TID 为场景标识：473 黑名单管理（默认）、474 猜你喜欢、18 每日推荐、30 主题歌单。
//!
//! ⚠️ 身份必须留在概念版（默认 lite 签名 appid=3116/clientver=11440 + lite 盐 +
//! lite RSA 公钥）：本 App 的登录 token 全部由概念版身份签发，上游按 token 的
//! 签发身份校验 appid——换标准版 1005 一律回 error_code=20018（登录已过期），
//! 与 user.rs::handle_purchased_songs 的既有教训一致。JS KuGouMusicApi 参考实现
//! 是标准版服务端（appid 1005），其「标准公钥/标准盐」不可照搬。
//! 大上行请求走小-MSS 传输（mss_clamp），规避 PMTU 黑洞网络下的挂死。

use crate::cache::now_epoch_secs;
use crate::crypto::crypto_rsa_encrypt;
use crate::modules::{c_str, param_or_cookie_num, q_cookie, q_num, q_str, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use crate::util::json_stringify;
use serde_json::{json, Value};

const UPSTREAM: &str = "https://relationuser.kugou.com";
const DEFAULT_MODULE_ID: &str = "473";

/// JS `SOURCE_MAP`：song→3 / singer→4（黑名单条目来源，非 "singer" 一律按 song）。
fn source_for(label: &str) -> i64 {
    if label == "singer" {
        4
    } else {
        3
    }
}

/// JS `params?.token || params?.cookie?.token || ''`。
fn token_of(q: &Value) -> String {
    let p = q_str(q, "token", "");
    if !p.is_empty() {
        p
    } else {
        c_str(q, "token")
    }
}

/// `p` 字段：cryptoRSAEncrypt(JSON.stringify({ clienttime, token }))，
/// 明文固定这两个字段（多传上游不认）。公钥必须用概念版（lite）公钥
/// ——与 token 的签发身份一致（见模块注释，20018 教训）。
fn encrypted_p(token: &str, clienttime: i64) -> String {
    crypto_rsa_encrypt(
        &json_stringify(&json!({ "clienttime": clienttime, "token": token })),
        None,
    )
}

/// blacklists.js 的 items 构建（纯函数，便于单测）。
/// `items` 参数（JSON 数组字符串）优先；解析失败/非数组/为空时回退单条：
/// song → `{k: hash 小写, v: JSON串{"n","m","t"}}`；singer → `{k: singerid, v: JSON串{"n","t"}}`。
/// t 为秒级时间戳字符串，与 JS `String(clienttime)` 对齐。
pub fn build_items(q: &Value, label: &str, clienttime: i64) -> Value {
    if let Some(Value::String(s)) = q.get("items") {
        if let Ok(v) = serde_json::from_str::<Value>(s) {
            if v.is_array() && !v.as_array().unwrap().is_empty() {
                return v;
            }
        }
    }
    let t = clienttime.to_string();
    // dio 把空格编码为 '+'，server.rs 按约定解码时保留 '+'（percent_decode_preserve_plus），
    // 显示名里的 '+' 在此处还原为空格（与 JS qs 语义一致；字面 '+' 由客户端编码为 %2B）。
    let name = q_str(q, "name", "").replace('+', " ");
    let entry = if label == "singer" {
        json!({
            "k": q_str(q, "singerid", ""),
            "v": json_stringify(&json!({ "n": name, "t": t })),
        })
    } else {
        json!({
            "k": q_str(q, "hash", "").to_lowercase(),
            "v": json_stringify(&json!({
                "n": name,
                "m": q_str(q, "mixsongid", ""),
                "t": t,
            })),
        })
    };
    json!([entry])
}

/// blacklist.js → /blacklist（编辑内容黑名单：添加 / isDelete=1 移除）。
pub fn handle_edit(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let label = {
        let l = q_str(q, "label", "song");
        if l == "singer" {
            "singer"
        } else {
            "song"
        }
    };
    log::info!(
        "[BLACKLIST] edit label={label} isDelete={} hash={} singerid={} name={} mixsongid={}",
        q_num(q, "isDelete", 0),
        q_str(q, "hash", ""),
        q_str(q, "singerid", ""),
        q_str(q, "name", ""),
        q_str(q, "mixsongid", ""),
    );
    let clienttime = now_epoch_secs() as i64;
    let token = token_of(q);
    let userid = param_or_cookie_num(q, "userid", 0);
    // JS `params?.isDelete ? 'delete' : 'add'`；按接口约定 0/不传为添加、1 为移除。
    let action = if q_num(q, "isDelete", 0) != 0 {
        "delete"
    } else {
        "add"
    };
    let body = json!({
        "userid": userid,
        "source": q_num(q, "source", source_for(label)),
        "label": label,
        "items": build_items(q, label, clienttime),
        "action": action,
        "p": encrypted_p(&token, clienttime),
    });
    let opts = RequestOptions::new("/v1/edit_list_items")
        .post("/v1/edit_list_items")
        .base_url(UPSTREAM)
        .json_body(body)
        .encrypt_type("android")
        // 概念版身份（默认 lite 签名）：标准版 1005 会 20018，见模块注释
        .cookie(q_cookie(q))
        .header("KG-TID", &q_str(q, "moduleId", DEFAULT_MODULE_ID))
        // 大上行请求（p 字段 256 hex + items JSON，~1.9KB）：PMTU 黑洞网络
        // （校园网/VPN 隧道）下 1460B TCP 段被丢导致永久挂死，改走小-MSS 传输。
        .mss_clamp(1240);
    ctx.send(&opts)
}

/// blacklist_list.js → /blacklist/list（获取内容黑名单，分页）。
pub fn handle_list(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let label = {
        let l = q_str(q, "label", "song");
        if l == "singer" {
            "singer"
        } else {
            "song"
        }
    };
    log::info!(
        "[BLACKLIST] list label={label} page={} pagesize={}",
        q_num(q, "page", 1),
        q_num(q, "pagesize", 30),
    );
    let clienttime = now_epoch_secs() as i64;
    let token = token_of(q);
    let userid = param_or_cookie_num(q, "userid", 0);
    let mut page = q_num(q, "page", 1);
    if page < 1 {
        page = 1;
    }
    let mut pagesize = q_num(q, "pagesize", 30);
    if pagesize < 1 {
        pagesize = 30;
    }
    let body = json!({
        "userid": userid,
        "source": q_num(q, "source", source_for(label)),
        "label": label,
        "p": encrypted_p(&token, clienttime),
        "page": page,
        "pagesize": pagesize.min(500),
    });
    let opts = RequestOptions::new("/v2/get_list_items")
        .post("/v2/get_list_items")
        .base_url(UPSTREAM)
        .json_body(body)
        .encrypt_type("android")
        // 概念版身份（默认 lite 签名）：标准版 1005 会 20018，见模块注释
        .cookie(q_cookie(q))
        .header("KG-TID", &q_str(q, "moduleId", DEFAULT_MODULE_ID))
        // 与 edit 同因：真实 token 下 GET 请求头也在 PMTU 黑洞阈值边缘
        .mss_clamp(1240);
    ctx.send(&opts)
}
