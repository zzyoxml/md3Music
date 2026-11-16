//! verify 系列：/get/verify/info + /verify/user/info
//! 签到/登录等接口返回错误码 20028（需二次安全验证）时使用：
//! 1. /get/verify/info  ← 获取验证码格式（eventid 来自 20028 响应）
//! 2. 前端完成腾讯滑块验证码，得到 verifycode
//! 3. /verify/user/info ← 提交验证码完成二次验证
//! 对应 JS module/get_verify_info.js、module/verify_user_info.js、module/sidedt.js

use crate::crypto::{crypto_aes_encrypt, crypto_rsa_encrypt};
use crate::modules::{c_str, forward, param_or_cookie_num, q_num, q_str, Ctx};
use crate::request::ModuleResponse;
use crate::simulate::generate_simulate;
use crate::util::{json_stringify, percent_decode};
use serde_json::{json, Value};

/// get_verify_info.js → /get/verify/info（获取验证码格式）。
/// 上游：POST https://gateway.kugou.com/verifyservice/v3/get_verify_info（android 加密）。
pub fn handle_get_verify_info(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let dm = json!({
        "eventid": q.get("eventid").cloned().unwrap_or(Value::Null),
        "userid": param_or_cookie_num(q, "userid", 0),
        "platid": q_num(q, "platid", 2),
        "rtype": 1,
        "wasm": 1,
        "i": "",
        "sid": "",
        "edt": "",
    });
    forward(
        q, ctx, "POST", "/verifyservice/v3/get_verify_info", None,
        None, Some(dm), "android", &[], false, false,
    )
}

/// sidedt.js 逻辑：请求未带 sid/edt 时，用行为指纹模拟生成
/// （等价 WASM 的 EData，Android App 内无法跑 WASM，统一在服务端生成）。
fn gen_sid_edt(q: &Value, userid: i64) -> (String, String) {
    let mid = c_str(q, "KUGOU_API_MID");
    let dfid = c_str(q, "dfid");
    let webgl = c_str(q, "KUGOU_API_WEBGL");
    let sim = generate_simulate(
        if mid.is_empty() { "0" } else { &mid },
        &userid.to_string(),
        if dfid.is_empty() { "0" } else { &dfid },
        if webgl.is_empty() { None } else { Some(&webgl) },
    );
    (sim.sid, sim.edt)
}

/// verify_user_info.js → /verify/user/info（提交验证码完成二次验证）。
/// 上游：POST https://verifyservice.kugou.com/v4/verify_user_info?clientver=11510（android 加密）。
/// v_type=23（腾讯滑块）：AES 加密 "{}" 得 params，RSA 加密 AES 密钥得 pk；
/// v_type=32（短信）：AES 加密 {"code": verifycode}。
pub fn handle_verify_user_info(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let v_type = q_num(q, "v_type", 23);
    let userid = param_or_cookie_num(q, "userid", 0);
    let eventid = q.get("eventid").cloned().unwrap_or(Value::Null);
    let verifycode = percent_decode(&q_str(q, "verifycode", ""));

    // sid/edt：请求已带则透传（JS 用 decodeURIComponent 二次解码），否则服务端生成。
    let (sid, edt) = {
        let s = percent_decode(&q_str(q, "sid", ""));
        let e = percent_decode(&q_str(q, "edt", ""));
        if s.is_empty() || e.is_empty() {
            gen_sid_edt(q, userid)
        } else {
            (s, e)
        }
    };

    let mut dm = json!({
        "eventid": eventid,
        "userid": userid,
        "platid": q_num(q, "platid", 2),
        "v_type": v_type,
        "wasm": 1,
        "i": "",
        "sid": sid,
        "edt": edt,
    });

    if v_type == 23 {
        // JS: cryptoAesEncrypt({}) → {str, key}；cryptoRSAEncrypt({key}) → pk
        let encrypt = crypto_aes_encrypt("{}", None, None);
        let key = encrypt.1.unwrap_or_default();
        dm["verifycode"] = json!(verifycode);
        dm["pk"] = json!(crypto_rsa_encrypt(&json_stringify(&json!({ "key": key })), None));
        dm["params"] = json!(encrypt.0);
    }
    if v_type == 32 {
        // JS: cryptoAesEncrypt({ code: verifycode })；额外提交 code 字段
        let encrypt =
            crypto_aes_encrypt(&json_stringify(&json!({ "code": verifycode })), None, None);
        let key = encrypt.1.unwrap_or_default();
        dm["code"] = json!(verifycode);
        dm["pk"] = json!(crypto_rsa_encrypt(&json_stringify(&json!({ "key": key })), None));
        dm["params"] = json!(encrypt.0);
    }

    forward(
        q, ctx, "POST", "/v4/verify_user_info", Some("https://verifyservice.kugou.com"),
        Some(json!({ "clientver": 11510 })), Some(dm), "android", &[], false, false,
    )
}
