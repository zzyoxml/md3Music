//! server_now.js → /server/now（获取服务器时间）。

use crate::modules::{q_cookie, param_or_cookie_num, param_or_cookie_str, Ctx};
use crate::request::{ModuleResponse, RequestOptions};
use serde_json::{json, Value};

pub fn handle(q: &Value, ctx: &Ctx) -> Result<ModuleResponse, ModuleResponse> {
    let userid = param_or_cookie_num(q, "userid", 0);
    let token = param_or_cookie_str(q, "token", "");

    let opts = RequestOptions::new("/v1/server_now")
        .post("/v1/server_now")
        .json_body(json!({ "token": token, "userid": userid }))
        .params(json!({ "plat": 3 }))
        .encrypt_type("android")
        .cookie(q_cookie(q))
        .header("x-router", "usercenter.kugou.com");
    ctx.send(&opts)
}
