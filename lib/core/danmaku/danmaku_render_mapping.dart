import 'package:canvas_danmaku/canvas_danmaku.dart';

import 'danmaku_entry.dart';

/// 本项目模型 → 渲染库类型的**唯一**映射点。
///
/// 泛型固定为 `String`：`extra` 承载弹幕 id，为未来的点击互动预留通道
/// （PiliPlus 以 `DanmakuExtra` 泛型实现 `findSingleDanmaku` → 悬浮操作条，
/// 见其 `lib/plugin/pl_player/view/view.dart:1164,2213`）。
DanmakuItemType toItemType(DanmakuMode mode) => switch (mode) {
      DanmakuMode.scroll => DanmakuItemType.scroll,
      DanmakuMode.top => DanmakuItemType.top,
      DanmakuMode.bottom => DanmakuItemType.bottom,
    };

DanmakuContentItem<String> toContentItem(DanmakuEntry entry) =>
    DanmakuContentItem<String>(
      entry.text,
      color: entry.color,
      type: toItemType(entry.mode),
      selfSend: entry.selfSend,
      extra: entry.id,
    );
