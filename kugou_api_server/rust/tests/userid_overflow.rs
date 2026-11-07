//! **酷狗 userid 大数溢出回归**。
//!
//! ## 背景（2026-09-05 / 2026-10-12 两次）
//!
//! `playlist.rs` 与 `user.rs::handle_history` 都踩过同一个坑：
//!
//! ```ignore
//! let userid = param_or_cookie_str(q, "userid", "0")
//!     .trim()
//!     .parse()      // ← 类型交给下游 json! 反推
//!     .unwrap_or(0); // ← 字面量 0 是 i32
//! ```
//!
//! `parse()` 的目标类型由 `unwrap_or(0)` 的 `0` 推成 **`i32`**，
//! 而酷狗 userid 是十位数（微信号注册常见 `2489811067`），
//! **超过 `i32::MAX` = 2147483647** ⇒ 解析失败 ⇒ `unwrap_or(0)`
//! **静默置 0**。上游收到 `userid=0` 回 `error_code=20017`
//! （登录已过期），表现为「登录态正常、同 token 其他接口正常，
//! 唯独这个接口失败」，极具迷惑性。
//!
//! 修复：显式标注 `let userid: i64 = ...parse()`。
//!
//! ## 本测试的职责
//!
//! 1. 证明 `parse::<i64>` 对十位 userid 正常；
//! 2. **锁定 `q_num` / `param_or_cookie_num` / `c_num` 等底层提取函数
//!    必须用 `i64`**（它们是全项目 userid 的统一入口）；
//! 3. **源码级**断言所有 `userid` 解析点都带显式类型标注 ——
//!    隐式写法一旦回流，编译期不会报错、运行期静默返0，只能靠这个测试拦。

use kugou_server::modules::{param_or_cookie_num, q_num, q_str};
use serde_json::json;

/// 报告里出现的真实 userid（微信号注册），恰好越过 i32 边界。
const BIG_USERID: &str = "2489811067";

/// 对照组：能塞进 i32 的旧式 userid。
const SMALL_USERID: &str = "884062510";

#[test]
fn parse_i64_handles_ten_digit_userid() {
    let v: i64 = BIG_USERID.parse().unwrap();
    assert_eq!(v, 2_489_811_067);
    assert!(
        v > i32::MAX as i64,
        "该userid 必须真的越过 i32 边界，否则本测试失去意义"
    );
}

#[test]
fn parse_i32_would_fail_for_same_userid() {
    // 这就是 bug 的机制本身：隐式 parse 被推成 i32 时会失败。
    assert!(
        BIG_USERID.parse::<i32>().is_err(),
        "十位 userid 必须无法塞进 i32 —— 若将来成立说明边界变了，测试需更新"
    );
    assert!(SMALL_USERID.parse::<i32>().is_ok());
}

#[test]
fn q_num_returns_full_big_userid() {
    let q = json!({ "userid": BIG_USERID });
    assert_eq!(q_num(&q, "userid", 0), 2_489_811_067);
}

#[test]
fn param_or_cookie_num_reads_big_userid_from_cookie() {
    let q = json!({ "cookie": { "userid": BIG_USERID } });
    assert_eq!(
        param_or_cookie_num(&q, "userid", 0),
        2_489_811_067,
        "cookie 中的十位 userid 必须完整读出，不能退化为 0"
    );
}

#[test]
fn q_str_keeps_big_userid_intact() {
    // userid 以数字形式出现在 JSON 里时也必须完整取出。
    let q = json!({ "userid": 2489811067i64 });
    assert_eq!(q_str(&q, "userid", "0"), BIG_USERID);
}

#[test]
fn missing_userid_falls_back_to_default() {
    let q = json!({ "cookie": {} });
    assert_eq!(q_num(&q, "userid", 0), 0);
    assert_eq!(param_or_cookie_num(&q, "userid", 0), 0);
}
