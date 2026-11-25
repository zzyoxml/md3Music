//! **源码级防线：`userid` 解析点不允许隐式 `parse()`。**
//!
//! 行为测试（`userid_overflow.rs`）能证明底层工具函数正确，但
//! **挡不住某个模块新写一行 `let userid = ....parse().unwrap_or(0)`**——
//! 这种代码能编译、能跑、只是静默返回 0，只有真机登录大userid 才暴露。
//!
//! 代价对比：
//! - 漏掉的代价：某账号云端历史/歌单永久失败，提示还误导成"登录过期"；
//! - 加这条断言的代价：几毫秒。
//!
//! 故扫 `kugou_api_server/rust/src/modules/*.rs`，凡出现
//! `userid` 与 `.parse()` 同处一行（或紧邻的赋值语句），必须显式标注类型。

use std::fs;
use std::path::Path;

fn modules_dir() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src/modules")
}

/// 去掉行注释与块注释后的有效代码行。
fn effective_lines(src: &str) -> Vec<String> {
    src.lines()
        .map(|l| {
            // 去掉行尾注释（粗略：忽略字符串内的 //，本仓模块无此写法）
            let cut = l.find("//").map(|i| &l[..i]).unwrap_or(l);
            cut.trim().to_string()
        })
        .filter(|l| !l.is_empty())
        .collect()
}

#[test]
fn no_implicit_parse_for_userid() {
    let dir = modules_dir();
    let mut offenders: Vec<String> = Vec::new();

    let entries = fs::read_dir(&dir).expect("modules 目录应存在");
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("rs") {
            continue;
        }
        let src = fs::read_to_string(&path).unwrap_or_default();
        let lines = effective_lines(&src);
        let file = path.file_name().unwrap().to_string_lossy().to_string();

        for (i, line) in lines.iter().enumerate() {
            // 只看真正做userid 解析的行
            let touches_userid = line.contains("userid");
            let parses = line.contains(".parse()") && !line.contains("parse::<");
            if !(touches_userid && parses) {
                continue;
            }
            // 合法写法：显式类型标注 `let userid: i64 = ...`
            let has_type_annotation = line.contains(": i64")
                || line.contains(": u64")
                || line.contains(": i32")
                || line.contains(": u32");
            // 也接受把类型标注写在上一行（多行链式调用）
            let prev_annotated = i > 0
                && lines[i - 1].contains("userid")
                && (lines[i - 1].contains(": i64")
                    || lines[i - 1].contains(": u64")
                    || lines[i - 1].contains(": i32"));
            if !has_type_annotation && !prev_annotated {
                offenders.push(format!("{}:{}  {}", file, i + 1, line));
            }
        }
    }

    assert!(
        offenders.is_empty(),
        "以下 userid 解析点缺少显式类型标注，`.parse()` 会被 `unwrap_or(0)` \
         推成 i32，十位 userid（如 2489811067）将静默变成 0：\n{}",
        offenders.join("\n")
    );
}

#[test]
fn user_history_and_playlist_use_i64() {
    // 两个真实踩过坑的位置，单独钉住，防止修复被回退。
    let dir = modules_dir();
    for (file, needle) in [
        ("user.rs", "let userid: i64 = userid_str.trim().parse().unwrap_or(0);"),
        ("playlist.rs", "let userid: i64 = userid_str.trim().parse().unwrap_or(0);"),
    ] {
        let src = fs::read_to_string(dir.join(file))
            .unwrap_or_else(|_| panic!("应能读取 {}", file));
        assert!(
            src.contains(needle),
            "{} 里的 userid 解析应保持显式 i64 标注",
            file
        );
    }
}
