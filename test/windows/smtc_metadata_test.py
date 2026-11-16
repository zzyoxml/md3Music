"""在 VS x64 开发环境运行：python test/windows/smtc_metadata_test.py。

两段断言：

1. **纯函数探针**：把 `windows/runner/smtc_metadata.h` 编进一个小 harness，
   逐条断言占位符清洗 / 倍速夹取 / 时间轴夹取 / 播放状态映射。
   这些都是「改错了不会报错、只会让第三方歌词工具静默失效」的规则：
   中文占位符漏清洗 → 外部工具把「未知歌手」当真实歌手，歌词匹配跌出门槛；
   倍速不发布 / 夹错 → 1.25x 播放时歌词持续漂移。

2. **源码结构断言**：钉住 `media_controls.cpp` / `flutter_window.cpp` 的接线。
   删掉 `AlbumTitle(` / `PlaybackRate(` / `ClearAll(` / `ThumbnailMode_MusicView`
   任何一条，编译和普通测试都不会报错，只有第三方工具那边静默失效。

不启动 Flutter、不初始化 SMTC、不碰用户的播控中心。
"""

import argparse
from pathlib import Path
import subprocess

# 与 winrt::Windows::Media::MediaPlaybackStatus 对齐的期望值。
STATUS_CLOSED = 0
STATUS_CHANGING = 1
STATUS_STOPPED = 2
STATUS_PLAYING = 3
STATUS_PAUSED = 4

HARNESS = r'''
#include <iostream>
#include <string>

#include "smtc_metadata.h"

namespace m = smtc_metadata;

int failures = 0;

void check(const char* name, bool ok, const char* detail = "") {
  std::cout << name << ": " << (ok ? "PASS" : "FAIL");
  if (!ok && detail[0] != '\0') std::cout << " " << detail;
  std::cout << "\n";
  if (!ok) ++failures;
}

void check_str(const char* name, const std::wstring& actual,
               const wchar_t* expected) {
  const bool ok = actual == expected;
  std::cout << name << ": " << (ok ? "PASS" : "FAIL");
  if (!ok) {
    std::wcout << L" actual='" << actual << L"' expected='" << expected << L"'";
  }
  std::cout << "\n";
  if (!ok) ++failures;
}

void check_rate(const char* name, double actual, double expected) {
  const bool ok = actual == expected;
  std::cout << name << ": " << (ok ? "PASS" : "FAIL");
  if (!ok) std::cout << " actual=" << actual << " expected=" << expected;
  std::cout << "\n";
  if (!ok) ++failures;
}

int main() {
  // ---- 1. 状态常量与 SDK 对齐（漏改一处，播控中心卡片就挂错态） ----
  {
    volatile int stopped = m::kStatusStopped;
    volatile int playing = m::kStatusPlaying;
    volatile int paused = m::kStatusPaused;
    check("kStatusStopped == 2", stopped == 2);
    check("kStatusPlaying == 3", playing == 3);
    check("kStatusPaused == 4", paused == 4);
    check("Stopped 不等于 Closed", stopped != 0);
  }

  // ---- 2. 占位符清洗 ----
  check_str("空串保持空", m::SanitizeText(L""), L"");
  check_str("纯空白清空", m::SanitizeText(L"   \t\r\n"), L"");
  check_str("未知歌手清空", m::SanitizeText(L"未知歌手"), L"");
  check_str("未知艺术家清空", m::SanitizeText(L"未知艺术家"), L"");
  check_str("未知艺人清空", m::SanitizeText(L"未知艺人"), L"");
  check_str("未知歌曲清空", m::SanitizeText(L"未知歌曲"), L"");
  check_str("未知专辑清空", m::SanitizeText(L"未知专辑"), L"");
  check_str("裸未知清空", m::SanitizeText(L"未知"), L"");
  check_str("Unknown Title 清空", m::SanitizeText(L"Unknown Title"), L"");
  check_str("unknown artist 小写清空", m::SanitizeText(L"unknown artist"), L"");
  check_str("UNKNOWN ALBUM 大写清空", m::SanitizeText(L"UNKNOWN ALBUM"), L"");
  check_str("全角空格包裹清空", m::SanitizeText(L"　未知歌手　"), L"");
  check_str("ASCII 空格包裹清空", m::SanitizeText(L"  未知歌手  "), L"");
  // 真实值必须原样（只 trim 首尾，不动内容）
  check_str("真实歌名保留", m::SanitizeText(L"晴天"), L"晴天");
  check_str("真实歌名 trim 首尾", m::SanitizeText(L"  晴天  "), L"晴天");
  check_str("真实歌手保留", m::SanitizeText(L"周杰伦"), L"周杰伦");
  check_str("英文歌名保留", m::SanitizeText(L"Bohemian Rhapsody"),
            L"Bohemian Rhapsody");
  // 只清「整体等于占位符」，不做包含匹配：真实歌名带「未知」二字不能被吞
  check_str("歌名含未知二字保留", m::SanitizeText(L"未知的旅途"), L"未知的旅途");
  check_str("歌手含 Unknown 保留", m::SanitizeText(L"Unknown Mortal Orchestra"),
            L"Unknown Mortal Orchestra");

  // ---- 3. 倍速 ----
  check_rate("1.0x 原样", m::ResolvePlaybackRate(1.0), 1.0);
  check_rate("1.5x 原样", m::ResolvePlaybackRate(1.5), 1.5);
  check_rate("1.25x 原样", m::ResolvePlaybackRate(1.25), 1.25);
  check_rate("下界 0.25 保留", m::ResolvePlaybackRate(0.25), 0.25);
  check_rate("上界 4.0 保留", m::ResolvePlaybackRate(4.0), 4.0);
  check_rate("0 回 1.0", m::ResolvePlaybackRate(0.0), 1.0);
  check_rate("负数回 1.0", m::ResolvePlaybackRate(-2.0), 1.0);
  check_rate("超上界回 1.0", m::ResolvePlaybackRate(9.0), 1.0);
  check_rate("低于下界回 1.0", m::ResolvePlaybackRate(0.1), 1.0);
  check_rate("NaN 回 1.0", m::ResolvePlaybackRate(std::nan("")), 1.0);
  check_rate("inf 回 1.0", m::ResolvePlaybackRate(HUGE_VAL), 1.0);

  // ---- 4. 时间轴 ----
  {
    int64_t pos = -1;
    int64_t dur = -1;
    check("duration=0 不推时间轴", !m::ResolveTimeline(1000, 0, &pos, &dur));
    check("duration<0 不推时间轴", !m::ResolveTimeline(1000, -5, &pos, &dur));
    check("正常值原样", m::ResolveTimeline(30000, 240000, &pos, &dur) &&
                           pos == 30000 && dur == 240000);
    check("负位置夹到 0", m::ResolveTimeline(-5000, 240000, &pos, &dur) &&
                              pos == 0 && dur == 240000);
    check("越界位置夹到 duration",
          m::ResolveTimeline(999999, 240000, &pos, &dur) && pos == 240000);
    check("位置等于 duration 保留",
          m::ResolveTimeline(240000, 240000, &pos, &dur) && pos == 240000);
    check("nullptr 输出不崩", m::ResolveTimeline(1000, 2000, nullptr, nullptr));
  }

  // ---- 5. 播放状态 ----
  check("播放中 → Playing", m::ResolvePlaybackStatus(true, false) == 3);
  check("暂停 → Paused", m::ResolvePlaybackStatus(false, false) == 4);
  check("主动停止优先于播放态", m::ResolvePlaybackStatus(true, true) == 2);
  check("停止且未播放 → Stopped", m::ResolvePlaybackStatus(false, true) == 2);

  return failures ? 1 : 0;
}
'''


def build_and_run_probe(root: Path, out: Path) -> int:
    header = root / "windows/runner/smtc_metadata.h"
    cpp = out / "smtc_metadata_test.cpp"
    cpp.write_text(HARNESS, encoding="utf-8")
    exe = out / "smtc_metadata_test.exe"
    compile_cmd = [
        "cl",
        "/nologo",
        "/std:c++17",
        "/EHsc",
        "/utf-8",
        "/W4",
        "/WX",
        "/wd4100",
        "/DUNICODE",
        "/D_UNICODE",
        f"/I{header.parent}",
        str(cpp),
        f"/Fo{out / 'smtc_metadata_test.obj'}",
        f"/Fe{exe}",
        "user32.lib",
        "ole32.lib",
    ]
    result = subprocess.run(compile_cmd, cwd=out)
    if result.returncode:
        return result.returncode
    return subprocess.run([str(exe)], cwd=out).returncode


def check_source(root: Path) -> int:
    controls = (root / "windows/runner/media_controls.cpp").read_text(encoding="utf-8")
    controls_header = (root / "windows/runner/media_controls.h").read_text(
        encoding="utf-8"
    )
    window = (root / "windows/runner/flutter_window.cpp").read_text(encoding="utf-8")

    failures = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        print(f"{name}: {'PASS' if ok else 'FAIL'}{(' ' + detail) if detail and not ok else ''}")
        if not ok:
            failures += 1

    # 1. 元数据：专辑必须发布（AF Media Bar 的 MediaSnapshotBuilder 读 AlbumTitle，
    #    TaskbarLyrics 的 CoverIdentity / LyricMatcher 也用它做身份与评分维度）
    check("发布 AlbumTitle", "AlbumTitle(" in controls)
    check("发布 AlbumArtist", "AlbumArtist(" in controls)
    # 2. 倍速与随机：ISystemMediaTransportControls2 可选接口
    check("获取 SMTC2 接口", "ISystemMediaTransportControls2" in controls)
    check("发布 PlaybackRate", "PlaybackRate(" in controls)
    check("发布 ShuffleEnabled", "ShuffleEnabled(" in controls)
    check("注册随机态变更事件", "ShuffleEnabledChangeRequested" in controls)
    check("注册倍速变更事件", "PlaybackRateChangeRequested" in controls)
    # 3. 本地封面：local:// 必须能被解析，且走系统缩略图（内嵌 ID3/FLAC 图）
    check("支持 local:// 前缀", "local://" in controls)
    check("走系统缩略图取内嵌封面", "ThumbnailMode::MusicView" in controls)
    # 4. 停止：退出/空闲停播要清卡片，不能只置 Paused
    check("主动停止走 Stopped", "kStatusStopped" in controls)
    check("停止时清空显示", "ClearAll(" in controls)
    # 时长未知时必须把时间轴收成 0，而不是保留上一首的 EndTime。
    # 第三方歌词工具按 EndTime-StartTime 取曲长做候选打分，残留旧值 = 取不到词。
    #
    # 顺序：正常分支（EndTime(clamped_duration)）在 if 里先出现，收零分支
    # （EndTime(ToTimeSpan(0))）在 else 里后出现 —— 断言用「两者都存在」即可，
    # 不锚定先后（源码结构调整不该误伤这条）。
    check(
        "时长未知时清时间轴 EndTime",
        "timeline.EndTime(ToTimeSpan(0))" in controls
        and "timeline.EndTime(ToTimeSpan(clamped_duration))" in controls,
    )
    # 5. 占位符清洗走纯函数头
    check("使用 smtc_metadata.h", '#include "smtc_metadata.h"' in controls)
    check("清洗 Title", "SanitizeText" in controls)
    # 6. 事件 token 必须成对移除（漏一个就是关窗时回调悬空）
    for token in ("shuffle_token_", "rate_token_"):
        check(
            f"{token} 成对移除",
            token in controls_header
            and controls.count(token) >= 2,
            f"count={controls.count(token)}",
        )
    # 7. flutter_window 接线：通道把 album / playbackRate 传下去
    check("通道传 album", '"album"' in window)
    check("通道传 playbackRate", '"playbackRate"' in window)
    check("通道传 albumArtist", '"albumArtist"' in window)
    # 8. 新 action code 的 Dart 回传（复用既有 lyric 通道，不新建通道）
    check("回传 setShuffle", '"setShuffle"' in controls)
    check("回传 setPlaybackSpeed", '"setPlaybackSpeed"' in controls)
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--out", type=Path)
    parser.add_argument(
        "--source-only",
        action="store_true",
        help="只跑源码结构断言（没有 VS 开发环境时用）",
    )
    args = parser.parse_args()
    root = args.root.resolve()
    out = (args.out or root / "tmp/smtc-metadata-test").resolve()
    out.mkdir(parents=True, exist_ok=True)

    failures = 0
    if not args.source_only:
        failures += build_and_run_probe(root, out)
    failures += check_source(root)
    print(f"\n{'FAILED' if failures else 'OK'}: {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
