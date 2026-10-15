import 'dart:ui' show Color;

/// 弹幕显示模式。
///
/// 与 Bilibili 弹幕 `p` 属性第 2 位（1=滚动 / 4=底部 / 5=顶部）以及
/// canvas_danmaku 的 `DanmakuItemType` 一一对应，映射见
/// `danmaku_render_mapping.dart`。
enum DanmakuMode { scroll, top, bottom }

/// 一条弹幕。
///
/// 刻意与数据源（酷狗 / 本地文件）和渲染库（canvas_danmaku）双向解耦：
/// 解析、排序、时间轴调度、持久化都只依赖本类型，渲染映射单独收口。
class DanmakuEntry {
  /// 相对视频起点的出现时间。
  final Duration time;

  final String text;

  /// 十进制 RGB（`0xRRGGBB`，与 Bilibili 弹幕格式一致）。
  final int colorValue;

  final DanmakuMode mode;

  /// 视频内的唯一 id；本地发送的弹幕形如 `local-<epochMs>`。
  final String id;

  /// 是否为自己发送（渲染为高亮描边）。
  final bool selfSend;

  const DanmakuEntry({
    required this.time,
    required this.text,
    this.colorValue = 0xFFFFFF,
    this.mode = DanmakuMode.scroll,
    this.id = '',
    this.selfSend = false,
  });

  /// 合成不透明颜色。`colorValue` 按 24 位处理，忽略其中的 alpha 位。
  Color get color => Color(0xFF000000 | (colorValue & 0xFFFFFF));

  Map<String, dynamic> toJson() => {
        'time': time.inMilliseconds,
        'text': text,
        'color': colorValue,
        'mode': mode.name,
        'id': id,
        'self': selfSend,
      };

  factory DanmakuEntry.fromJson(Map<String, dynamic> json) {
    final rawTime = json['time'];
    final ms = rawTime is num
        ? rawTime.toInt()
        : (rawTime is String ? (int.tryParse(rawTime) ?? 0) : 0);
    final rawColor = json['color'];
    final colorValue = rawColor is num
        ? rawColor.toInt() & 0xFFFFFF
        : (rawColor is String ? (int.tryParse(rawColor) ?? 0xFFFFFF) & 0xFFFFFF : 0xFFFFFF);
    final rawMode = json['mode'];
    final mode = DanmakuMode.values.firstWhere(
      (m) => m.name == rawMode,
      orElse: () => DanmakuMode.scroll,
    );
    return DanmakuEntry(
      time: Duration(milliseconds: ms),
      text: (json['text'] ?? '').toString(),
      colorValue: colorValue,
      mode: mode,
      id: (json['id'] ?? '').toString(),
      selfSend: json['self'] == true,
    );
  }
}
