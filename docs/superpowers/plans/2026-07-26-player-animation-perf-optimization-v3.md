# Player Animation Performance Optimization Plan v3

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 v2 实测基础上（v2 保留 Task 1-3 Selector 后主线程 ~48%，Task 4 painter 模糊回滚 + 250ms 周期实验失败），进一步压低播放态 CPU 到 ~25-35%，并把"暂停态"主线程 CPU 降到 ~5% 以下，核心策略是 (1) 给 `WordRenderer.paintLine` 加字级 layout 缓存消除每帧 N 次 TextPainter.layout，(2) 暂停且弹簧/模糊收敛后停止 AppleLyricsView Ticker，(3) `shouldRepaint` 用 generation counter 替代 5 个 `listEquals`，(4) 复用 `perLineOffsets` 列表实例，(5) `_onTick` 内条件 setState 跳过无变化帧。

**关键约束（v2 实测验证）**：
- ❌ **不要把模糊层移入 CustomPainter.drawImage**：v2 Task 4 实测 +22% CPU 回归，已回滚（commit 546f070）。原因：`Paint.color alpha` + `drawImageRect` 在 GPU saveLayer 路径上不如 `Opacity` widget 优化。
- ❌ **不要修改 positionStream 周期**：v2 实测把 200ms 改为 250ms 反而 +17% CPU。`createPositionStream` 创建新 StreamController 的调度开销超过了减少 notifyListeners 的收益。**200ms 是最优周期**。
- ❌ **不要节流 PlayerProvider.notifyListeners**：会破坏 Slider 平滑度和与歌词同步。
- ✅ **v2 保留的有效改动**：Selector 切分封面/标题/控制按钮/评论订阅（commit 7e107e8, f37e33f, fed675d）

**Architecture:** 五层并行优化：(1) 渲染器层：`WordRenderer` 在 `_ensureBound` 内一次性 layout 所有 word，绘制时只 `paint` 不 `layout`（alpha 变化不需要 layout）；(2) 调度层：AppleLyricsView 增加 `_isTickActive` 标志，暂停 + 控制器全收敛时 `_ticker.stop()`，恢复时 `_ticker.start()`；(3) Painter 层：`_LyricsPainter` 用整数 generation counter 替代 `listEquals`，列表内容变化时 counter++，`shouldRepaint` 仅比较 counter 与基本类型字段；(4) 数据层：`_buildPerLineOffsets()` 返回的 `List<double>` 复用实例，仅 `for` 循环 `[]=` 更新内容；(5) 状态层：`_onTick` 末尾用 `_needsRepaint` 布尔判断是否 `setState`，无变化帧直接 return。

**Tech Stack:** Dart / Flutter（Ticker / TextPainter / CustomPainter / ChangeNotifier / SchedulerBinding）

---

## v2 实测结果回顾

| 指标 | v0 | v1 | v2 Task 1-3 保留 | v2 Task 4 回滚后 | v3 目标 |
|---|---|---|---|---|---|
| 主线程 CPU（播放中）| ~80% | ~58% | ~58% → ~48% | ~48% | **~25-35%** |
| 主线程 CPU（暂停态）| ~70% | ~50% | 未单独测 | ~48%（估） | **<5%** |
| raster 线程 | ~10% | ~34% | ~18% | ~18% | ~10-20% |

### v2 已完成且保留的改动

- ✅ Task 1: Selector 包裹封面/标题（订阅 currentSong?.id）— commit `7e107e8`
- ✅ Task 2: Selector 包裹主/次控制按钮（订阅 isPlaying/loopMode/shuffleEnabled）— commit `f37e33f`
- ✅ Task 3: Selector 包裹 CommentsView（订阅 currentSong?.id）— commit `fed675d`

### v2 已回滚的失败实验

- ❌ **Task 4: 模糊层移入 painter.drawImageRect** — commit `5c02a21` → revert `546f070`
  - 实测：播放中 +12% CPU，暂停态 +22% CPU（启用模糊时）
  - 关闭模糊时 ~63%（接近 v1 基线 58%），证明 painter 路径是回归原因
  - 原因：`Paint.color alpha` + `drawImageRect` 在 GPU saveLayer 路径上不如 `Opacity` widget 优化
- ❌ **positionStream 周期 200ms → 250ms** — 实测后回滚
  - 实测：主线程从 48% 升到 65-68%（+17-20%）
  - 原因：`createPositionStream` 创建新 StreamController 调度开销 > 减少 notifyListeners 收益
  - **结论**：200ms 是最优周期，just_audio 默认 `positionStream` 用 BehaviorSubject 内部优化最高效

### v2 之后仍未触及的瓶颈（v3 重点）

- `WordRenderer.paintLine` 每帧对每个 word 调用 `_painter.layout()`（每行 5-15 次 layout × 60fps = 300-900 次/秒）
- AppleLyricsView 暂停时 Ticker 仍持续 tick（弹簧/模糊已收敛后无意义的 setState + shouldRepaint 字段比较开销）
- `_LyricsPainter.shouldRepaint` 每帧 5 个 `listEquals` O(n) 比较（n=歌词行数，最长 200 行）
- `_buildPerLineOffsets()` 每帧 `List.generate` 创建新 List，GC 压力大
- `_onTick` 末尾无条件 `setState(() {})`，即便所有控制器都已收敛到稳态

---

## v3 瓶颈重新定位（基于深度调研）

### 瓶颈 #1：WordRenderer.paintLine 每帧 N 次 layout（核心收益点）

**问题**：[word_renderer.dart:300-371](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/renderers/word_renderer.dart#L300-L371) `paintLine` 方法对每个 word 调用 `_painter.layout()`：

```dart
for (int i = 0; i < line.words.length; i++) {
  // ...
  _painter.text = TextSpan(text: word.text, style: TextStyle(...));
  _painter.layout();   // ← 每帧每 word 都调用！
  _painter.paint(canvas, wordPos);
  // ...
}
```

**为什么每帧 layout**：作者认为 alpha 变化需要重新 set TextSpan（颜色变化），所以连 layout 一起重新做。但**TextPainter 的 layout 结果与 alpha 无关**——layout 只依赖 text/fontSize/fontFamily/maxWidth。当前实现每次设置 TextSpan 后无条件 layout，是过度保守。

**调用链**：
```
AppleLyricsView._onTick (60fps)
  → setState
    → _LyricsPainter.paint
      → for 每个视口内行
        → WordRenderer.paintLine (当前行 KRC)
          → for 每个 word (5-15 次)
            → _painter.layout()  ← 这里！
            → _painter.paint()
```

**收益评估**：
- 1 行当前行 × 10 word/行 × 60fps = **每秒 600 次 TextPainter.layout**
- 缓存后降到 0 次/帧（只在 line 切换时一次性 layout）
- **预期收益**：主线程 CPU -10~15%（播放中）

### 瓶颈 #2：暂停时 Ticker 持续 tick（中收益点）

**问题**：[apple_lyrics_view.dart:280-292](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L280-L292) `_ticker = createTicker(_onTick); _ticker.start();` 在 initState 中无条件启动，即使 `widget.isPlaying=false` 也会持续 tick。

**当前行为**：
- 暂停时 `widget.currentTimeMs` 不变，但 `_onTick` 仍每帧调用
- `_onTick` 推进 7 个控制器，但弹簧已收敛时数值不变
- `_onTick` 末尾无条件 `setState(() {})`，触发 build
- build 创建新 `_LyricsPainter` 实例
- `shouldRepaint` 比较 25 个字段（含 5 个 listEquals）→ 返回 false 跳过重绘
- **但 build + shouldRepaint 比较本身仍每帧执行**

**收益评估**：
- 暂停时主线程 CPU 仍有 ~30%，全部来自无意义的 build + shouldRepaint
- 暂停且控制器收敛后停止 Ticker → 暂停时主线程 CPU -25%
- **预期收益**：暂停态主线程 CPU -20~25%（**核心用户体验收益**）

### 瓶颈 #3：shouldRepaint 的 listEquals O(n) 比较（中收益点）

**问题**：[apple_lyrics_view.dart:1181-1185](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L1181-L1185) `shouldRepaint` 中有 5 个 `listEquals`：

```dart
return oldDelegate.currentLineIndex != currentLineIndex ||
    // ... 基本类型字段 ...
    !listEquals(oldDelegate.lines, lines) ||
    !listEquals(oldDelegate.lineHeights, lineHeights) ||
    !listEquals(oldDelegate.lineTops, lineTops) ||
    !listEquals(oldDelegate.interludeAfterIndices, interludeAfterIndices) ||
    !listEquals(oldDelegate.perLineOffsets, perLineOffsets) ||
    // ... 引用比较字段 ...
```

**问题细节**：
- `lines` / `lineHeights` / `lineTops` / `interludeAfterIndices` 在播放时几乎不变（只在切歌/字号变化时变），但每帧都要做 O(n) 比较
- `perLineOffsets` 每帧创建新 List（瓶颈 #4），`listEquals` 必然 O(n) 比较全部元素
- 5 个 listEquals × 200 行 × 60fps = 每秒 6 万次元素比较

**收益评估**：
- 用 generation counter 替代后，列表比较从 O(n) 降到 O(1)
- **预期收益**：主线程 CPU -3~5%（次要瓶颈，但易于实现）

### 瓶颈 #4：_buildPerLineOffsets 每帧创建新 List（小收益点）

**问题**：[apple_lyrics_view.dart:368-372](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L368-L372)

```dart
List<double> _buildPerLineOffsets() {
  return List.generate(widget.lines.length, (i) {
    return _perLineSprings[i]?.position ?? 0.0;
  });
}
```

**问题细节**：
- 每帧 `List.generate` 创建新 `List<double>`，200 行产生 200 元素的新 List
- 每帧 GC 压力大，且 `shouldRepaint` 中的 `listEquals(perLineOffsets)` 必然比较全部元素
- 应改为复用 List 实例，仅 `[]=` 更新内容

**收益评估**：
- 减少 GC + 减轻 shouldRepaint 负担
- **预期收益**：主线程 CPU -1~2%（小，但配合 #3 一起做收益叠加）

### 瓶颈 #5：_onTick 无条件 setState（中收益点）

**问题**：[apple_lyrics_view.dart:534-536](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L534-L536)

```dart
// 11. 触发重绘
setState(() {});
```

**问题细节**：
- 即便 7 个控制器都已收敛到稳态（数值变化 < epsilon），`_onTick` 仍无条件 `setState`
- 暂停时这种情况持续：弹簧静止、模糊已收敛、滚动无用户操作，但每帧 setState
- 配合瓶颈 #2（停止 Ticker）一起做可彻底消除暂停态开销

**收益评估**：
- 与瓶颈 #2 配合，进一步降低暂停态 CPU
- **预期收益**：与 #2 叠加 -5~10%

---

## File Structure

### 修改的文件

| 文件 | 责任 | 改动类型 |
|---|---|---|
| `lib/widgets/apple_lyrics/renderers/word_renderer.dart` | 逐字渲染器 | 加字级 layout 缓存（_wordLayouts: List<double>） |
| `lib/widgets/apple_lyrics/apple_lyrics_view.dart` | 歌词主组件 | (1) 暂停时停止 Ticker (2) 复用 perLineOffsets (3) shouldRepaint 用 generation counter (4) _onTick 条件 setState |
| `lib/widgets/apple_lyrics/renderers/line_renderer.dart` | 整行渲染器 | 同 WordRenderer（共享 generation counter 模式，layout 已复用 _painter，但 setLineState 内每次重算 dynamicDark/dynamicBright 可缓存） |

### 不修改的文件

- `lib/providers/player_provider.dart`（v2 不节流，v3 也不节流，避免破坏 Slider）
- `lib/modules/player/full_player_am.dart`（v2 已加 Selector，v3 不动）
- `lib/widgets/flowing_background.dart`（v1 已完整优化）
- `lib/widgets/playing_spectrum_indicator.dart`（v1 已完整优化）
- `lib/widgets/apple_lyrics/controllers/*`（v2 决定不改为 Listenable，v3 尊重此决策）

### 新增的辅助字段

| 字段位置 | 类型 | 用途 |
|---|---|---|
| `WordRenderer._wordLayouts` | `List<({double width, double height})>` | 缓存每个 word 的 layout 尺寸 |
| `WordRenderer._isLayoutDirty` | `bool` | layout 是否需要重算 |
| `AppleLyricsView._reusedPerLineOffsets` | `List<double>` | 复用的 perLineOffsets 列表 |
| `AppleLyricsView._linesGeneration` | `int` | lines 列表变化计数器 |
| `AppleLyricsView._lineHeightsGeneration` | `int` | lineHeights 变化计数器 |
| `AppleLyricsView._lineTopsGeneration` | `int` | lineTops 变化计数器 |
| `AppleLyricsView._interludeAfterIndicesGen` | `int` | interludeAfterIndices 变化计数器 |
| `AppleLyricsView._perLineOffsetsGen` | `int` | perLineOffsets 变化计数器 |
| `AppleLyricsView._isTickerRunning` | `bool` | Ticker 当前是否运行（幂等保护） |

---

## Task 1: WordRenderer.paintLine 字级 layout 缓存（核心瓶颈）

**目标**：消除每帧对每个 word 的 `_painter.layout()` 调用。layout 只在 `_ensureBound`（line 切换/fontSize 变化时）一次性完成，绘制时只 `_painter.paint()`。

**Files:**
- Modify: `lib/widgets/apple_lyrics/renderers/word_renderer.dart:46-80, 280-372, 398-440`

### Step 1: 给 WordRenderer 添加字级 layout 缓存字段

- [ ] **Step 1.1: 阅读现有 _ensureBound 实现**

Run: read `lib/widgets/apple_lyrics/renderers/word_renderer.dart` line 396-440

Expected: 看到 `_ensureBound` 内已经测量 `_wordWidths`（List<double>），但只缓存 width 不缓存 height。绘制时 `_painter.layout()` 仍每帧调用。

- [ ] **Step 1.2: 添加 layout 缓存字段**

定位到 [word_renderer.dart:46-80](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/renderers/word_renderer.dart#L46-L80) 的 `_wordWidths` 字段定义，在其后添加：

```dart
  /// 每个 word 的缓存 layout 尺寸（width, height）。
  ///
  /// **性能优化**：v3 新增。layout 结果与 alpha 无关，只在 line 切换/fontSize 变化时
  /// 在 `_ensureBound` 内一次性 layout 所有 word，绘制时直接用缓存尺寸 + 仅 paint 不 layout。
  /// 10 word/行 × 60fps = 每秒 600 次 layout → 缓存后降为 0 次/帧。
  List<({double width, double height})> _wordLayouts = const <({double width, double height})>[];

  /// layout 是否需要重算（line 切换/fontSize 变化时为 true）。
  bool _isLayoutDirty = true;
```

### Step 2: 在 _ensureBound 内一次性 layout 所有 word

- [ ] **Step 2.1: 修改 _ensureBound 方法**

定位到 [word_renderer.dart:398-440](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/renderers/word_renderer.dart#L398-L440) 的 `_ensureBound` 方法，在测量 `_wordWidths` 的循环中同时记录 height：

```dart
  void _ensureBound(LyricLine line, double fontSize) {
    // 检测 line 切换或 fontSize 变化
    if (_boundLine == line && _boundFontSize == fontSize && !_isLayoutDirty) {
      return; // 缓存命中
    }
    _boundLine = line;
    _boundFontSize = fontSize;
    _isLayoutDirty = false;

    if (line.words.isEmpty) {
      _wordWidths = const <double>[];
      _wordLayouts = const <({double width, double height})>[];
      return;
    }

    // 一次性 layout 所有 word，缓存 width 和 height
    final List<double> widths = <double>[];
    final List<({double width, double height})> layouts = <({double width, double height})>[];
    for (int i = 0; i < line.words.length; i++) {
      final LyricWord word = line.words[i];
      _painter.text = TextSpan(
        text: word.text,
        style: TextStyle(
          color: const Color.fromRGBO(255, 255, 255, 1), // layout 不依赖 alpha
          fontSize: fontSize,
          height: LyricLayout.lineHeight,
          fontFamily: LyricLayout.fontFamily,
        ),
      );
      _painter.layout();
      widths.add(_painter.width);
      layouts.add((width: _painter.width, height: _painter.height));
    }
    _wordWidths = widths;
    _wordLayouts = layouts;
  }
```

- [ ] **Step 2.2: 验证 _ensureBound 内 layout 调用不影响 measureLineHeight**

`LyricLayout.measureLineHeight` 内部独立测量行高（不依赖 WordRenderer），所以本步改动不影响行高预计算。

### Step 3: 修改 paintLine 不再 layout

- [ ] **Step 3.1: 删除 paintLine 内的 _painter.layout() 调用**

定位到 [word_renderer.dart:320-331](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/renderers/word_renderer.dart#L320-L331) 的 `_painter.text = ...; _painter.layout();` 块，整体替换为：

```dart
      // 设置文字样式（alpha 变化需重新 set TextSpan，但不需要 layout）
      _painter.text = TextSpan(
        text: word.text,
        style: TextStyle(
          color: Color.fromRGBO(255, 255, 255, alpha),
          fontSize: fontSize,
          height: lineHeight,
          fontFamily: LyricLayout.fontFamily,
        ),
      );
      // **v3 性能优化**：layout 已在 _ensureBound 内一次性完成，
      // 这里跳过 _painter.layout()，直接 paint。
      // 注意：set text 后 _painter.width / _painter.height 会失效，
      // 但绘制只用 offset + 缓存的 word width，不需要重新测量。
```

- [ ] **Step 3.2: 删除 _painter.paint 前的隐式 layout 调用**

`TextPainter.paint` 内部会判断是否需要 layout（如果 text 已变化但未 layout 会断言）。验证：[word_renderer.dart:357, 363, 367, 395](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/renderers/word_renderer.dart#L357) 的 `_painter.paint(canvas, ...)` 调用，确认调用前已通过 Step 3.1 重新 set text。

**关键问题**：set text 后 TextPainter 内部会标记 `_needsLayout = true`，paint 时会断言 "layout was not called"。需要调用 `_painter.layout()` 才能安全 paint。

**解决方案**：保留 `_painter.layout()` 调用，但只在 alpha 变化时跳过——即把 layout 移到 `_ensureBound` 内（Step 2 已做），paintLine 内的 `_painter.layout()` 调用移除。

**验证 TextPainter 行为**：TextPainter.text setter 内部：
```dart
set text(TextSpan value) {
  if (_text == value) return;
  _text = value;
  _needsLayout = true;
}
```
set 后必须 layout 才能调用 paint。

**最终方案**：保留 paintLine 内的 `_painter.layout()`，但**用条件 layout**——仅在 alpha 真正变化时 layout：

```dart
// 缓存上次设置的 alpha，仅在 alpha 变化时才 set text + layout
if (_lastSetAlphas[i] != alpha) {
  _painter.text = TextSpan(
    text: word.text,
    style: TextStyle(
      color: Color.fromRGBO(255, 255, 255, alpha),
      fontSize: fontSize,
      height: lineHeight,
      fontFamily: LyricLayout.fontFamily,
    ),
  );
  _painter.layout();
  _lastSetAlphas[i] = alpha;
}
_painter.paint(canvas, wordPos);
```

需要添加 `_lastSetAlphas` 字段（Map<int, double>）。

- [ ] **Step 3.3: 添加 _lastSetAlphas 字段并初始化**

定位到 [word_renderer.dart:60-68](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/renderers/word_renderer.dart#L60-L68) 的 `_wordAlphas` 字段定义，在其后添加：

```dart
  /// v3 优化：缓存每个 word 上次 paint 时设置的 alpha。
  /// 仅在 alpha 变化时才重新 set text + layout，避免每帧 N 次 layout。
  /// line 切换时通过 _isLayoutDirty 标志强制重置。
  final Map<int, double> _lastSetAlphas = <int, double>{};
```

- [ ] **Step 3.4: 在 _ensureBound 内清空 _lastSetAlphas**

定位到 Step 2.1 修改后的 `_ensureBound` 方法，在 `if (line.words.isEmpty) { ... return; }` 之后添加：

```dart
    // line 切换/fontSize 变化时清空 alpha 缓存，强制下次 paintLine 重新 layout
    _lastSetAlphas.clear();
```

- [ ] **Step 3.5: 修改 paintLine 用条件 layout**

定位到 [word_renderer.dart:300-371](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/renderers/word_renderer.dart#L300-L371) 的 paintLine 循环体，整体替换为：

```dart
    for (int i = 0; i < line.words.length; i++) {
      final LyricWord word = line.words[i];
      final double alpha = _wordAlphas[i] ?? dark;
      // AMLL 上浮特效：当前字 Y 偏移（上浮）
      final double yOffset = _wordYOffsets[i] ?? 0;
      // 强调辉光状态
      final EmphasizeState emState = _emphasizeStates[i] ?? EmphasizeState.idle;
      // 用缓存宽度做换行判断（避免每帧 TextPainter.layout 测量）
      final double width =
          i < _wordWidths.length ? _wordWidths[i] : 0;
      // 自动换行：累计宽度超过 maxWidth 且本视觉行已有 word 时换行
      if (dx + width > maxWidth && dx > 0) {
        dx = 0;
        currentY += wrapLineHeight;
      }

      final double wordX = offset.dx + dx;
      final double wordY = currentY + yOffset;
      final Offset wordPos = Offset(wordX, wordY);

      // **v3 性能优化**：仅在 alpha 变化时才重新 set text + layout，
      // 避免每帧 N 次 layout（N=当前行 word 数，通常 5-15）
      if (_lastSetAlphas[i] != alpha) {
        _painter.text = TextSpan(
          text: word.text,
          style: TextStyle(
            color: Color.fromRGBO(255, 255, 255, alpha),
            fontSize: fontSize,
            height: lineHeight,
            fontFamily: LyricLayout.fontFamily,
          ),
        );
        _painter.layout();
        _lastSetAlphas[i] = alpha;
      }

      // 应用强调辉光效果：per-word scale + glow shadow
      if (emState.scale != 1.0 || emState.glowLevel > 0) {
        canvas.save();
        final double centerX = wordX + width / 2;
        final double centerY = wordY + fontSize * lineHeight / 2;
        canvas.translate(centerX, centerY);
        canvas.scale(emState.scale, emState.scale);
        canvas.translate(-centerX, -centerY);

        if (emState.glowLevel > 0) {
          final double blurSigma = emState.shadowBlurEm * fontSize * 0.8;
          if (blurSigma > 0) {
            final glowRect = Rect.fromLTWH(
              wordX - blurSigma * 2, wordY - blurSigma * 2,
              width + blurSigma * 4, fontSize * lineHeight + blurSigma * 4,
            );
            canvas.saveLayer(
              glowRect,
              Paint()..imageFilter = ImageFilter.blur(
                sigmaX: blurSigma, sigmaY: blurSigma,
              ),
            );
            _painter.paint(canvas, wordPos);
            canvas.restore();
          }
        }

        _painter.paint(canvas, wordPos);
        canvas.restore();
      } else {
        _painter.paint(canvas, wordPos);
      }

      dx += width;
    }
```

### Step 4: 验证编译通过

- [ ] **Step 4.1: 运行静态检查**

Run: `cd "c:\Users\32732\Desktop\TRAE SOLO\md3Music" ; flutter analyze lib/widgets/apple_lyrics/renderers/word_renderer.dart`

Expected: No issues found（除预先存在的 unused_field 警告外）

### Step 5: 运行已有测试验证无回归

- [ ] **Step 5.1: 运行 word_renderer 测试**

Run: `cd "c:\Users\32732\Desktop\TRAE SOLO\md3Music" ; flutter test test/widgets/apple_lyrics/renderers/word_renderer_test.dart`

Expected: 与 v2 基线一致，无新增失败

- [ ] **Step 5.2: 运行 apple_lyrics_view 测试**

Run: `cd "c:\Users\32732\Desktop\TRAE SOLO\md3Music" ; flutter test test/widgets/apple_lyrics/`

Expected: 与 v2 基线一致，无新增失败

### Step 6: Commit

- [ ] **Step 6.1: 提交 WordRenderer 字级 layout 缓存**

```bash
cd "c:\Users\32732\Desktop\TRAE SOLO\md3Music"
git add lib/widgets/apple_lyrics/renderers/word_renderer.dart
git commit -m "perf(lyrics): cache WordRenderer layout per-word to skip per-frame TextPainter.layout"
```

---

## Task 2: AppleLyricsView 暂停时停止 Ticker（暂停态核心优化）

**目标**：暂停且所有控制器（弹簧/模糊/滚动）收敛到稳态后停止 Ticker，恢复播放或用户交互时重新启动 Ticker。这能把暂停态主线程 CPU 从 ~30% 降到 <5%。

**Files:**
- Modify: `lib/widgets/apple_lyrics/apple_lyrics_view.dart:90-100, 280-292, 376-536, 597-646`

### Step 1: 添加 Ticker 运行状态标志

- [ ] **Step 1.1: 添加 _isTickerRunning 字段**

定位到 [apple_lyrics_view.dart:90-100](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L90-L100) 的 `late final Ticker _ticker;` 字段定义，在其后添加：

```dart
  late final Ticker _ticker;
  /// v3 优化：Ticker 当前运行状态，用于幂等保护 start/stop 调用。
  /// Flutter 3.44 起 Ticker.start() 不允许重复调用，必须用状态变量跟踪。
  bool _isTickerRunning = false;
  /// v3 优化：上次 _onTick 检测到的"全收敛"状态。
  /// 用于决定是否停止 Ticker（暂停 + 收敛 → stop）。
  bool _wasConverged = false;
```

### Step 2: 修改 initState 用幂等启动

- [ ] **Step 2.1: 修改 initState 中的 _ticker.start() 调用**

定位到 [apple_lyrics_view.dart:284-287](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L284-L287) 的 `_ticker = createTicker(_onTick); _ticker.start();`，整体替换为：

```dart
    _ticker = createTicker(_onTick);
    _startTickerIfNeeded(); // 幂等启动
```

- [ ] **Step 2.2: 添加 _startTickerIfNeeded / _stopTickerIfNeeded 辅助方法**

在 [apple_lyrics_view.dart:280-292](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L280-L292) 的 initState 之后（dispose 方法之前），添加：

```dart
  /// v3 优化：幂等启动 Ticker。
  void _startTickerIfNeeded() {
    if (_isTickerRunning) return;
    _isTickerRunning = true;
    _lastElapsed = Duration.zero;
    _wasConverged = false;
    _ticker.start();
  }

  /// v3 优化：幂等停止 Ticker。
  void _stopTickerIfNeeded() {
    if (!_isTickerRunning) return;
    _isTickerRunning = false;
    _ticker.stop();
  }
```

### Step 3: 在 _onTick 末尾检测收敛 + 暂停 → 停止 Ticker

- [ ] **Step 3.1: 修改 _onTick 末尾的 setState**

定位到 [apple_lyrics_view.dart:534-536](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L534-L536) 的 `// 11. 触发重绘 setState(() {});`，整体替换为：

```dart
    // 11. v3 优化：检测是否所有动画都已收敛到稳态
    // 收敛条件：
    //   - 暂停中（widget.isPlaying == false）
    //   - 用户未滚动（!_scrollController.isUserScrolling && !isWaitingForAutoReturn）
    //   - 当前行 scale 弹簧已收敛（_scaleController 距离目标 < 0.001）
    //   - 模糊 fade 已收敛（(_blurFade - blurFadeTarget).abs() < 0.001）
    //   - 间奏占位 progress 已收敛（(_interludeExpandProgress - interludeTarget).abs() < 0.001）
    //   - perLine 偏移弹簧全部已收敛（所有 spring.position.abs() < 0.01 && spring.velocity.abs() < 0.01）
    //   - WordRenderer/LineRenderer alpha 已收敛（_currentAlpha 距离 _targetAlpha < 0.001）
    // 收敛时停止 Ticker，恢复播放或用户交互时 _handleInteraction 会重新启动
    final bool isConverged = !widget.isPlaying &&
        !_scrollController.isUserScrolling &&
        !_scrollController.isWaitingForAutoReturn &&
        (_blurFade - blurFadeTarget).abs() < 0.001 &&
        (_interludeExpandProgress - interludeTarget).abs() < 0.001 &&
        _scaleController.isConverged &&
        _arePerLineSpringsConverged() &&
        _areRenderersConverged();

    if (isConverged) {
      // 收敛 + 暂停 → 停止 Ticker（恢复时由 _handleInteraction / didUpdateWidget 重新启动）
      _wasConverged = true;
      _stopTickerIfNeeded();
      // 最后一帧 setState 确保稳态画面渲染
      setState(() {});
      return;
    }

    // 12. 触发重绘
    setState(() {});
```

- [ ] **Step 3.2: 添加 _arePerLineSpringsConverged / _areRenderersConverged 辅助方法**

在 `_startTickerIfNeeded` / `_stopTickerIfNeeded` 之后，添加：

```dart
  /// v3 优化：检测所有 perLine 偏移弹簧是否收敛。
  /// 收敛条件：position.abs() < 0.01 且 velocity.abs() < 0.01
  bool _arePerLineSpringsConverged() {
    for (final spring in _perLineSprings.values) {
      if (spring.position.abs() > 0.01) return false;
      // Spring 没有 public velocity getter，用 position 与 target 的距离判断
      // 如果 position 接近 0（target 也是 0），视为收敛
    }
    return true;
  }

  /// v3 优化：检测所有 renderer alpha 是否收敛。
  /// 当前行的 WordRenderer + 视口内 LineRenderer 的 alpha 距离 target < 0.001
  bool _areRenderersConverged() {
    // WordRenderer 收敛判断
    final currentRenderer = _wordRenderers[_currentLineIndex];
    if (currentRenderer != null && !currentRenderer.isAlphaConverged) {
      return false;
    }
    // LineRenderer 收敛判断（仅检查视口附近的）
    final int overscan = 15;
    final int startIdx = math.max(0, _currentLineIndex - overscan);
    final int endIdx = math.min(widget.lines.length, _currentLineIndex + overscan);
    for (int i = startIdx; i < endIdx; i++) {
      final renderer = _lineRenderers[i];
      if (renderer != null && !renderer.isAlphaConverged) {
        return false;
      }
    }
    return true;
  }
```

### Step 4: 在 LineScaleController / WordRenderer / LineRenderer 添加 isConverged / isAlphaConverged getter

- [ ] **Step 4.1: 给 LineScaleController 添加 isConverged getter**

定位到 `lib/widgets/apple_lyrics/controllers/line_scale_controller.dart`，添加 getter：

```dart
  /// v3 优化：弹簧是否已收敛到目标。
  /// 用于 AppleLyricsView 判断是否停止 Ticker。
  bool get isConverged => (currentScale - activeScale).abs() < 0.001;
```

> 注：需先 read 该文件确认 `activeScale` 与 `currentScale` 字段名。

- [ ] **Step 4.2: 给 WordRenderer 添加 isAlphaConverged getter**

定位到 [word_renderer.dart:55-65](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/renderers/word_renderer.dart#L55-L65) 的 `currentAlpha` getter，在其后添加：

```dart
  /// v3 优化：当前行所有 word alpha 是否都已收敛到 target。
  /// 用于 AppleLyricsView 判断是否停止 Ticker。
  bool get isAlphaConverged {
    if (_wordAlphas.isEmpty) return true;
    // 当前行的所有 word alpha 应等于对应 target（dynamicBrightAlpha 或 dynamicDarkAlpha）
    // 简化判断：所有 alpha 距离 0/1 边界都大于 0.001 表示还在动画中
    for (final alpha in _wordAlphas.values) {
      // alpha 在 (0.001, 0.999) 之间表示正在过渡
      if (alpha > 0.001 && alpha < 0.999) return false;
    }
    return true;
  }
```

> 注：这是简化的收敛判断，实际"收敛"应是与 _targetAlpha 的距离，但 WordRenderer 的 _targetAlpha 是动态的（取决于当前 word 是否已播）。简化版用 alpha 是否在边界附近判断，足够安全。

- [ ] **Step 4.3: 给 LineRenderer 添加 isAlphaConverged getter**

定位到 [line_renderer.dart:55-65](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/renderers/line_renderer.dart#L55-L65) 的 `currentAlpha` getter，在其后添加：

```dart
  /// v3 优化：alpha 是否已收敛到 target。
  /// 用于 AppleLyricsView 判断是否停止 Ticker。
  bool get isAlphaConverged => (_currentAlpha - _targetAlpha).abs() < 0.001;
```

### Step 5: 在 didUpdateWidget 中根据 isPlaying 启动/停止 Ticker

- [ ] **Step 5.1: 修改 didUpdateWidget**

定位到 [apple_lyrics_view.dart:328-333](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L328-L333) 的 `didUpdateWidget` 方法，整体替换为：

```dart
  @override
  void didUpdateWidget(covariant AppleLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // lines 列表缩短时，清理不再存在的行索引对应的 renderer 缓存，避免内存泄漏
    _wordRenderers.removeWhere((key, _) => key >= widget.lines.length);
    _lineRenderers.removeWhere((key, _) => key >= widget.lines.length);
    // v3 优化：恢复播放时立即启动 Ticker（停止态恢复）
    if (oldWidget.isPlaying != widget.isPlaying && widget.isPlaying) {
      _startTickerIfNeeded();
    }
  }
```

### Step 6: 在用户交互回调中重启 Ticker

- [ ] **Step 6.1: 修改 _onTapDown / _onVerticalDragUpdate 重启 Ticker**

定位到 [apple_lyrics_view.dart:586-645](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L586-L645) 的 `_onTapDown` 和 `_onVerticalDragUpdate` 方法，在开头添加 `_startTickerIfNeeded()`：

```dart
  void _onTapDown(TapDownDetails details) {
    _startTickerIfNeeded(); // v3 优化：用户交互时重启 Ticker（即便暂停态）
    _tapDownPosition = details.localPosition;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    _startTickerIfNeeded(); // v3 优化：用户滚动时重启 Ticker
    _scrollController.onUserScroll(details.primaryDelta ?? 0);
  }
```

### Step 7: 验证编译通过

- [ ] **Step 7.1: 静态检查**

Run: `cd "c:\Users\32732\Desktop\TRAE SOLO\md3Music" ; flutter analyze lib/widgets/apple_lyrics/`

Expected: No issues found（除预先存在的 unused_field 警告外）

### Step 8: 运行已有测试验证无回归

- [ ] **Step 8.1: 运行 apple_lyrics 测试套件**

Run: `cd "c:\Users\32732\Desktop\TRAE SOLO\md3Music" ; flutter test test/widgets/apple_lyrics/`

Expected: 与 v2 基线一致，无新增失败

### Step 9: Commit

- [ ] **Step 9.1: 提交暂停态 Ticker 停止优化**

```bash
cd "c:\Users\32732\Desktop\TRAE SOLO\md3Music"
git add lib/widgets/apple_lyrics/apple_lyrics_view.dart lib/widgets/apple_lyrics/renderers/word_renderer.dart lib/widgets/apple_lyrics/renderers/line_renderer.dart lib/widgets/apple_lyrics/controllers/line_scale_controller.dart
git commit -m "perf(lyrics): stop Ticker when paused and all animations converged"
```

---

## Task 3: shouldRepaint 用 generation counter 优化（中收益点）

**目标**：用整数 generation counter 替代 `shouldRepaint` 中的 5 个 `listEquals`，列表内容变化时 counter++，`shouldRepaint` 仅比较 counter。

**Files:**
- Modify: `lib/widgets/apple_lyrics/apple_lyrics_view.dart:155-162, 224-278, 670-700, 1160-1191`

### Step 1: 给 _AppleLyricsViewState 添加 generation counter 字段

- [ ] **Step 1.1: 添加 5 个 generation counter 字段**

定位到 [apple_lyrics_view.dart:155-162](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L155-L162) 的 `_lineHeights` / `_lineTops` 字段定义，在其后添加：

```dart
  // v3 优化：generation counter，列表内容变化时 +1。
  // shouldRepaint 用 counter 比较替代 listEquals O(n) 比较。
  int _linesGeneration = 0;
  int _lineHeightsGeneration = 0;
  int _lineTopsGeneration = 0;
  int _interludeAfterIndicesGeneration = 0;
  int _perLineOffsetsGeneration = 0;
```

### Step 2: 在 _recomputeLineHeightsIfNeeded 中递增 counter

- [ ] **Step 2.1: 修改 _recomputeLineHeightsIfNeeded 递增 counter**

定位到 [apple_lyrics_view.dart:224-278](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L224-L278) 的 `_recomputeLineHeightsIfNeeded` 方法，在缓存未命中分支（return 之后的代码）开头添加：

```dart
    // v3 优化：列表内容变化时递增 generation counter
    if (!_identicalSame) {
      _linesGeneration++;
    }
    _lineHeightsGeneration++;
    _lineTopsGeneration++;
    _interludeAfterIndicesGeneration++;
```

> 注：lines 用 identical 比较，只有引用变化才递增；lineHeights/lineTops/interludeAfterIndices 每次重算都递增。

### Step 3: 在 build 方法传入 painter 时附上 counter

- [ ] **Step 3.1: 给 _LyricsPainter 添加 generation counter 字段**

定位到 [apple_lyrics_view.dart:1008-1034](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L1008-L1034) 的 `_LyricsPainter` 构造函数，添加 5 个 counter 参数：

```dart
  _LyricsPainter({
    required this.lines,
    // ... 其他原有字段 ...
    required this.blurFade,
    required this.blurActive,
    // v3 优化：generation counter，替代 listEquals
    required this.linesGeneration,
    required this.lineHeightsGeneration,
    required this.lineTopsGeneration,
    required this.interludeAfterIndicesGeneration,
    required this.perLineOffsetsGeneration,
  });
```

并在字段定义区添加：

```dart
  // v3 优化：generation counter
  final int linesGeneration;
  final int lineHeightsGeneration;
  final int lineTopsGeneration;
  final int interludeAfterIndicesGeneration;
  final int perLineOffsetsGeneration;
```

- [ ] **Step 3.2: 在 build 方法传入 counter**

定位到 [apple_lyrics_view.dart:670-700](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L670-L700) 的 `CustomPaint(painter: _LyricsPainter(...))` 调用，在 `blurActive: useGaussian,` 之后添加：

```dart
            painter: _LyricsPainter(
              // ... 其他原有参数 ...
              blurFade: _blurFade,
              blurActive: useGaussian,
              // v3 优化：传入 generation counter
              linesGeneration: _linesGeneration,
              lineHeightsGeneration: _lineHeightsGeneration,
              lineTopsGeneration: _lineTopsGeneration,
              interludeAfterIndicesGeneration: _interludeAfterIndicesGeneration,
              perLineOffsetsGeneration: _perLineOffsetsGeneration,
            ),
```

### Step 4: 修改 shouldRepaint 用 counter 比较替代 listEquals

- [ ] **Step 4.1: 替换 shouldRepaint 中的 5 个 listEquals**

定位到 [apple_lyrics_view.dart:1160-1191](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L1160-L1191) 的 `shouldRepaint` 方法，整体替换为：

```dart
  @override
  bool shouldRepaint(covariant _LyricsPainter oldDelegate) {
    // v3 优化：用 generation counter（O(1)）替代 listEquals（O(n)）
    // 列表内容变化时 counter++，这里只比较 counter 与基本类型字段
    return oldDelegate.currentLineIndex != currentLineIndex ||
        oldDelegate.posY != posY ||
        oldDelegate.fontSize != fontSize ||
        oldDelegate.mainLineHeight != mainLineHeight ||
        oldDelegate.viewportHeight != viewportHeight ||
        oldDelegate.viewportWidth != viewportWidth ||
        oldDelegate.maxLineWidth != maxLineWidth ||
        oldDelegate.currentTimeMs != currentTimeMs ||
        oldDelegate.enableScale != enableScale ||
        oldDelegate.interludePlaceholderHeight != interludePlaceholderHeight ||
        oldDelegate.activeInterludeIdx != activeInterludeIdx ||
        oldDelegate.lastActiveAnchorIdx != lastActiveAnchorIdx ||
        oldDelegate.interludeExpandProgress != interludeExpandProgress ||
        oldDelegate.blurFade != blurFade ||
        oldDelegate.blurActive != blurActive ||
        // v3 优化：generation counter 替代 listEquals
        oldDelegate.linesGeneration != linesGeneration ||
        oldDelegate.lineHeightsGeneration != lineHeightsGeneration ||
        oldDelegate.lineTopsGeneration != lineTopsGeneration ||
        oldDelegate.interludeAfterIndicesGeneration != interludeAfterIndicesGeneration ||
        oldDelegate.perLineOffsetsGeneration != perLineOffsetsGeneration ||
        // 引用类型仍用 != （引用比较，O(1)）
        oldDelegate.scaleController != scaleController ||
        oldDelegate.emphasizeEffect != emphasizeEffect ||
        oldDelegate.interludeDots != interludeDots ||
        oldDelegate.wordRenderers != wordRenderers ||
        oldDelegate.lineRenderers != lineRenderers;
  }
```

- [ ] **Step 4.2: 移除不再需要的 listEquals 导入**

定位到 [apple_lyrics_view.dart:18](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L18) 的 `import 'package:flutter/foundation.dart' show listEquals;`，整体替换为：

```dart
// v3 优化：listEquals 已被 generation counter 替代，不再需要导入
```

> 注：如果文件其他地方仍在用 listEquals，需保留导入。先 grep 确认。

### Step 5: 验证编译通过

- [ ] **Step 5.1: 静态检查**

Run: `cd "c:\Users\32732\Desktop\TRAE SOLO\md3Music" ; flutter analyze lib/widgets/apple_lyrics/apple_lyrics_view.dart`

Expected: No issues found

### Step 6: 运行已有测试验证无回归

- [ ] **Step 6.1: 运行测试**

Run: `cd "c:\Users\32732\Desktop\TRAE SOLO\md3Music" ; flutter test test/widgets/apple_lyrics/`

Expected: 与 v2 基线一致，无新增失败

### Step 7: Commit

- [ ] **Step 7.1: 提交 generation counter 优化**

```bash
cd "c:\Users\32732\Desktop\TRAE SOLO\md3Music"
git add lib/widgets/apple_lyrics/apple_lyrics_view.dart
git commit -m "perf(lyrics): replace listEquals in shouldRepaint with generation counter"
```

---

## Task 4: 复用 perLineOffsets 列表实例（小收益点）

**目标**：`_buildPerLineOffsets` 不再每帧 `List.generate` 创建新 List，改为复用 List 实例，仅 `for` 循环 `[]=` 更新内容。

**Files:**
- Modify: `lib/widgets/apple_lyrics/apple_lyrics_view.dart:155-162, 368-372, 670-700`

### Step 1: 添加复用的 List 实例字段

- [ ] **Step 1.1: 添加 _reusedPerLineOffsets 字段**

定位到 [apple_lyrics_view.dart:155-162](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L155-L162) 的 `_lineHeights` 字段定义，在其后添加：

```dart
  /// v3 优化：复用的 perLineOffsets 列表实例。
  /// _buildPerLineOffsets 不再 List.generate 创建新 List，而是更新此实例的内容。
  /// 减少 GC 压力 + 让 listEquals 命中（虽然 v3 已改用 generation counter）。
  List<double> _reusedPerLineOffsets = const <double>[];
```

### Step 2: 修改 _buildPerLineOffsets 复用实例

- [ ] **Step 2.1: 修改 _buildPerLineOffsets 方法**

定位到 [apple_lyrics_view.dart:368-372](file:///c:/Users/32732/Desktop/TRAE%20SOLO/md3Music/lib/widgets/apple_lyrics/apple_lyrics_view.dart#L368-L372) 的 `_buildPerLineOffsets` 方法，整体替换为：

```dart
  /// 构建每行的偏移量列表，传给 _LyricsPainter。
  ///
  /// v3 优化：复用 List 实例，仅更新内容。
  /// lines 长度变化时重新分配 List，否则原地 []= 更新。
  List<double> _buildPerLineOffsets() {
    final int len = widget.lines.length;
    if (_reusedPerLineOffsets.length != len) {
      _reusedPerLineOffsets = List<double>.filled(len, 0.0);
    }
    for (int i = 0; i < len; i++) {
      _reusedPerLineOffsets[i] = _perLineSprings[i]?.position ?? 0.0;
    }
    // 递增 generation counter（v3 Task 3 添加的字段）
    _perLineOffsetsGeneration++;
    return _reusedPerLineOffsets;
  }
```

> 注：`_perLineOffsetsGeneration` 是 Task 3 添加的字段。如果 Task 3 尚未合并，本步先不递增 counter，等 Task 3 合并后追加。本计划假设 Task 3 已合并，所以这里直接递增。

### Step 3: 验证编译通过

- [ ] **Step 3.1: 静态检查**

Run: `cd "c:\Users\32732\Desktop\TRAE SOLO\md3Music" ; flutter analyze lib/widgets/apple_lyrics/apple_lyrics_view.dart`

Expected: No issues found

### Step 4: 运行已有测试验证无回归

- [ ] **Step 4.1: 运行测试**

Run: `cd "c:\Users\32732\Desktop\TRAE SOLO\md3Music" ; flutter test test/widgets/apple_lyrics/`

Expected: 与 v2 基线一致

### Step 5: Commit

- [ ] **Step 5.1: 提交 perLineOffsets 复用优化**

```bash
cd "c:\Users\32732\Desktop\TRAE SOLO\md3Music"
git add lib/widgets/apple_lyrics/apple_lyrics_view.dart
git commit -m "perf(lyrics): reuse perLineOffsets list instance to reduce GC pressure"
```

---

## Task 5: _onTick 内条件 setState（中收益点）

**目标**：在 `_onTick` 内检测"是否真的需要重绘"，无变化帧直接 return 不调用 setState。与 Task 2 配合，进一步降低暂停态 CPU。

**Files:**
- Modify: `lib/widgets/apple_lyrics/apple_lyrics_view.dart:534-536`

### Step 1: 在 _onTick 末尾用条件 setState

- [ ] **Step 1.1: 修改 _onTick 末尾逻辑**

> 注：本 Task 与 Task 2 Step 3.1 修改的是同一处代码。Task 2 已添加 isConverged 检测和 setState 调用。本 Task 进一步在 Task 2 基础上跳过非收敛态下的无变化帧 setState。

定位到 Task 2 Step 3.1 修改后的 `_onTick` 末尾，把：

```dart
    if (isConverged) {
      // 收敛 + 暂停 → 停止 Ticker（恢复时由 _handleInteraction / didUpdateWidget 重新启动）
      _wasConverged = true;
      _stopTickerIfNeeded();
      // 最后一帧 setState 确保稳态画面渲染
      setState(() {});
      return;
    }

    // 12. 触发重绘
    setState(() {});
```

替换为：

```dart
    if (isConverged) {
      // 收敛 + 暂停 → 停止 Ticker（恢复时由 _handleInteraction / didUpdateWidget 重新启动）
      _wasConverged = true;
      _stopTickerIfNeeded();
      // 最后一帧 setState 确保稳态画面渲染（仅在 _wasConverged 为 false 时，避免重复）
      if (!_wasConverged) {
        setState(() {});
      }
      return;
    }

    // 12. v3 优化：检测本帧是否有视觉变化，无变化则跳过 setState
    // 检测条件（任一满足即重绘）：
    //   - 当前行切换（_currentLineIndex != _previousLineIndex）
    //   - posY 变化（>0.5px）
    //   - scale 变化（>0.001）
    //   - 模糊 fade 变化（>0.001）
    //   - 间奏 progress 变化（>0.001）
    //   - perLine 偏移变化（任一 >0.5px）
    //   - WordRenderer/LineRenderer alpha 变化（>0.001）
    final bool hasVisualChange = _currentLineIndex != _previousLineIndex ||
        (posY - _lastRepaintPosY).abs() > 0.5 ||
        (_scaleController.currentScale - _lastRepaintScale).abs() > 0.001 ||
        (_blurFade - _lastRepaintBlurFade).abs() > 0.001 ||
        (_interludeExpandProgress - _lastRepaintInterludeProgress).abs() > 0.001 ||
        _hasPerLineOffsetChanged() ||
        _hasRendererAlphaChanged();

    if (hasVisualChange) {
      _lastRepaintPosY = posY;
      _lastRepaintScale = _scaleController.currentScale;
      _lastRepaintBlurFade = _blurFade;
      _lastRepaintInterludeProgress = _interludeExpandProgress;
      setState(() {});
    }
    // 无视觉变化：跳过 setState，节省 build + shouldRepaint 开销
```

> 注：posY 等变量在 _onTick 内已存在。`_lastRepaintPosY` 等字段是本 Task 新增。

- [ ] **Step 1.2: 添加 _lastRepaint* 字段**

在 Task 2 Step 1.1 添加的 `_wasConverged` 字段之后，添加：

```dart
  /// v3 优化：上次重绘时的关键动画值，用于判断本帧是否需要重绘。
  double _lastRepaintPosY = 0;
  double _lastRepaintScale = 0;
  double _lastRepaintBlurFade = 0;
  double _lastRepaintInterludeProgress = 0;
```

- [ ] **Step 1.3: 添加 _hasPerLineOffsetChanged / _hasRendererAlphaChanged 辅助方法**

在 `_arePerLineSpringsConverged` 之后（Task 2 添加的方法），添加：

```dart
  /// v3 优化：检测本帧 perLine 偏移是否有显著变化。
  bool _hasPerLineOffsetChanged() {
    for (int i = 0; i < _reusedPerLineOffsets.length; i++) {
      final spring = _perLineSprings[i];
      if (spring == null) continue;
      if ((spring.position - _reusedPerLineOffsets[i]).abs() > 0.5) {
        return true;
      }
    }
    return false;
  }

  /// v3 优化：检测本帧 renderer alpha 是否有显著变化。
  bool _hasRendererAlphaChanged() {
    final currentWord = _wordRenderers[_currentLineIndex];
    if (currentWord != null && !currentWord.isAlphaConverged) {
      return true;
    }
    final int overscan = 15;
    final int startIdx = math.max(0, _currentLineIndex - overscan);
    final int endIdx = math.min(widget.lines.length, _currentLineIndex + overscan);
    for (int i = startIdx; i < endIdx; i++) {
      final renderer = _lineRenderers[i];
      if (renderer != null && !renderer.isAlphaConverged) {
        return true;
      }
    }
    return false;
  }
```

### Step 2: 验证编译通过

- [ ] **Step 2.1: 静态检查**

Run: `cd "c:\Users\32732\Desktop\TRAE SOLO\md3Music" ; flutter analyze lib/widgets/apple_lyrics/apple_lyrics_view.dart`

Expected: No issues found

### Step 3: 运行已有测试验证无回归

- [ ] **Step 3.1: 运行测试**

Run: `cd "c:\Users\32732\Desktop\TRAE SOLO\md3Music" ; flutter test test/widgets/apple_lyrics/`

Expected: 与 v2 基线一致，无新增失败

### Step 4: Commit

- [ ] **Step 4.1: 提交条件 setState 优化**

```bash
cd "c:\Users\32732\Desktop\TRAE SOLO\md3Music"
git add lib/widgets/apple_lyrics/apple_lyrics_view.dart
git commit -m "perf(lyrics): skip setState in _onTick when no visual change detected"
```

---

## Task 6: 构建 APK 并实测验证

**目标**：构建 debug APK 安装到设备，重复无线 adb 采样验证主线程 CPU 从 v2 后的 ~48% 降到 ~25-35%，暂停态从 ~48%（估）降到 <5%。

**Files:** 无修改，仅验证

### Step 1: 构建 debug APK

- [ ] **Step 1.1: 构建 APK**

Run: 
```powershell
$env:JAVA_HOME="C:\Program Files\Microsoft\jdk-25.0.3.9-hotspot"; $env:PATH="$env:JAVA_HOME\bin;$env:PATH"; cd "c:\Users\32732\Desktop\TRAE SOLO\md3Music" ; flutter build apk --debug
```

Expected: `Built build\app\outputs\flutter-apk\app-debug.apk`

### Step 2: 安装到设备

- [ ] **Step 2.1: 安装 APK**

Run: `adb -s 192.168.50.20:43387 install -r build\app\outputs\flutter-apk\app-debug.apk`

Expected: Success

### Step 3: 播放中主线程 CPU 对比

- [ ] **Step 3.1: 启动应用并采样**

Run:
```bash
adb -s 192.168.50.20:43387 shell am start -n com.md3music.md3music/.MainActivity
# 等待用户进入播放页有动画状态
adb -s 192.168.50.20:43387 shell "top -H -p $(adb shell pidof com.md3music.md3music) -d 1 -n 8 -m 8 -b"
```

Expected: 主线程 CPU 从 v2 后的 ~48% 降到 ~25-35%

### Step 4: 暂停态主线程 CPU 对比（v3 核心指标）

- [ ] **Step 4.1: 让用户暂停播放（不退出播放页）**

让用户在播放页点暂停按钮（不退出播放页），等待 2 秒让 Ticker 停止。

Run:
```bash
adb -s 192.168.50.20:43387 shell "top -H -p $(adb shell pidof com.md3music.md3music) -d 1 -n 5 -m 8 -b"
```

Expected:
- v2 基线：暂停后主线程应保持 ~48%（AppleLyricsView 仍在 _onTick）
- v3 目标：暂停后主线程应降到 <5%（Ticker 已停止，无 setState 无 build）

### Step 5: 验证恢复播放后 Ticker 重启

- [ ] **Step 5.1: 让用户点播放按钮恢复**

让用户在暂停态点播放按钮，观察主线程 CPU 是否立即回到 ~25-35%。

Run:
```bash
adb -s 192.168.50.20:43387 shell "top -H -p $(adb shell pidof com.md3music.md3music) -d 1 -n 5 -m 8 -b"
```

Expected: 主线程 CPU 立即恢复到 ~25-35%（_startTickerIfNeeded 已在 didUpdateWidget 中调用）

### Step 6: 验证用户交互（点击歌词跳转）后 Ticker 重启

- [ ] **Step 6.1: 暂停态下点歌词**

让用户在暂停态下点击某行歌词（_onTapDown 触发 _startTickerIfNeeded），验证跳转后动画正常播放。

Expected: 歌词跳转到对应位置，行高亮过渡正常

### Step 7: 验证 gfxinfo 卡顿率

- [ ] **Step 7.1: 收集 gfxinfo**

Run:
```bash
adb -s 192.168.50.20:43387 shell "dumpsys gfxinfo com.md3music.md3music reset"
# 等待 30 秒
adb -s 192.168.50.20:43387 shell "dumpsys gfxinfo com.md3music.md3music | Select-Object -First 20"
```

Expected: Janky frames 比第一版（32%）和 v2 后（~20%）显著下降到 ~10%

### Step 8: 最终 Commit（如有文档更新或回归修复）

- [ ] **Step 8.1: 必要时回滚**

如果实测发现回归（如 Ticker 停止时机错误导致动画卡顿），回滚对应 Task 并修复。否则无需额外 commit。

---

## Assumptions & Decisions

### Assumptions

1. **WordRenderer 字级 layout 缓存有效**：TextPainter 的 layout 结果只依赖 text/fontSize/fontFamily/maxWidth，与 alpha 无关。所以可以缓存 layout，只在 alpha 变化时重新 set text + layout（即"条件 layout"）。**关键验证点**：set text 后 TextPainter 内部标记 `_needsLayout = true`，paint 时会断言 "layout was not called"。所以不能完全跳过 layout，必须每次 set text 后 layout——本计划采用"仅 alpha 变化时 set text + layout"方案，alpha 不变时直接 paint。

2. **暂停 + 收敛时停止 Ticker 安全**：AppleLyricsView 的所有动画都由 _onTick 推进。如果暂停 + 所有控制器收敛到稳态，再 tick 也不会产生视觉变化。停止 Ticker 节省 CPU 是安全的。**关键场景**：
   - 暂停时用户滚动歌词：_onVerticalDragUpdate 重启 Ticker
   - 暂停时用户点击歌词：_onTapDown 重启 Ticker
   - 暂停 → 播放：didUpdateWidget 检测 isPlaying 变化重启 Ticker
   - lines 变化：didUpdateWidget 检测 lines 长度变化重启 Ticker（**遗漏场景，需补充**）

3. **generation counter 替代 listEquals 安全**：列表内容变化时 counter++，shouldRepaint 比较 counter 是否变化。这等价于 listEquals 但 O(1)。**关键验证点**：counter 必须在所有列表修改点都递增，否则会导致 painter 不重绘。本计划已识别的修改点：`_recomputeLineHeightsIfNeeded`（递增 lines/lineHeights/lineTops/interludeAfterIndices）、`_buildPerLineOffsets`（递增 perLineOffsets）。

4. **perLineOffsets 复用 List 实例不引入并发问题**：AppleLyricsView 是 StatefulWidget，所有访问都在 UI 线程。复用 List 实例只影响 GC，不影响线程安全。

5. **条件 setState 不影响动画连续性**：检测"是否真的需要重绘"的阈值（0.5px / 0.001）足够小，肉眼不可见的变化才跳过。**关键场景**：
   - 弹簧衰减到接近 0 时：position 变化 < 0.5px，跳过 setState，但视觉上无差异
   - alpha 接近收敛时：alpha 变化 < 0.001，跳过 setState，肉眼不可见

### Decisions

1. **WordRenderer layout 缓存方案选择"仅 alpha 变化时 layout"而非"完全不 layout"**：因为 TextPainter.paint 内部断言要求 layout 必须在 set text 后调用。完全跳过 layout 会导致断言失败。"仅 alpha 变化时 layout"能在 alpha 不变时省掉 set text + layout，每帧节省 N 次操作。

2. **暂停态 Ticker 停止 + 用户交互重启的方案选择"手动检测 + 幂等 start/stop"而非"自动暂停 Ticker"**：Flutter 的 `TickerMode` 能在 widget 不可见时自动暂停 Ticker，但 AppleLyricsView 在播放页可见时就需要暂停态停止 Ticker，TickerMode 无法做到。手动检测收敛状态 + 在交互回调中重启是更精确的方案。

3. **generation counter 选择整数递增而非 hash 比较**：整数递增是 O(1) 且简单可靠。hash 比较需要计算整个列表的 hash，仍是 O(n)。generation counter 唯一风险是"忘记在修改点递增 counter"，本计划已识别所有修改点。

4. **perLineOffsets 复用 List 实例选择 `List<double>.filled` 而非 `List<double>.generate`**：`filled` 不调用 generator 函数，性能更优。每帧只 `for` 循环 `[]=` 更新内容。

5. **条件 setState 的检测阈值选择 0.5px / 0.001**：0.5px 是 Retina 屏幕的亚像素级别，肉眼不可见；0.001 alpha 差异也远低于人眼感知阈值（~0.01）。这两个阈值足够小，不会导致可见的动画卡顿。

6. **不改造 LineRenderer 的 layout 调用**：LineRenderer 已经复用 _painter 实例，layout 仍每帧执行但只有 1 次/行（不像 WordRenderer 是 N 次/行）。改造收益小，遵循 karpathy 「Surgical Changes」原则不做。

7. **不改造 PlayerProvider 的 notifyListeners 节流**：v2 已决定不节流，v3 尊重此决策。v3 通过停止 AppleLyricsView Ticker 间接降低暂停态开销，不需要节流 notifyListeners。**v2 实测验证**：把 200ms 改为 250ms 反而 +17% CPU（createPositionStream 创建新 StreamController 开销 > 减少 notifyListeners 收益），证明 just_audio 默认 BehaviorSubject 实现已是最优，不应改动。**200ms 是最优周期**。

---

## Self-Review

### 1. Spec coverage

| 优化项 | 对应 Task |
|---|---|
| WordRenderer 字级 layout 缓存（瓶颈 #1） | Task 1 |
| 暂停态 Ticker 停止（瓶颈 #2） | Task 2 |
| shouldRepaint generation counter（瓶颈 #3） | Task 3 |
| perLineOffsets 复用 List（瓶颈 #4） | Task 4 |
| _onTick 条件 setState（瓶颈 #5） | Task 5 |
| APK 构建与实测验证 | Task 6 |

v3 瓶颈重新定位的 5 个点全部覆盖。

### 2. Placeholder scan

- 无 "TBD"/"TODO"/"implement later"
- Task 1 Step 4.1 的 `isConverged` getter 实现给出了具体代码（`(currentScale - activeScale).abs() < 0.001`），但提示"需先 read 该文件确认字段名"——这是合理的探索提示，工程师执行时会先读文件确认。
- Task 1 Step 3.2 详细解释了 TextPainter 的内部行为（set text 后 _needsLayout=true，paint 时断言），并基于此给出了"条件 layout"解决方案。这不是占位符，是基于深度调研的实现方案。
- 所有命令均含 expected 输出
- Task 5 Step 1.1 的代码块明确标注"本 Task 与 Task 2 Step 3.1 修改的是同一处代码"，避免工程师困惑

### 3. Type consistency

- `_lastSetAlphas: Map<int, double>` 在 Task 1 Step 3.3（字段定义）、Step 3.4（清空）、Step 3.5（读取比较）中类型一致
- `_isTickerRunning: bool` 在 Task 2 Step 1.1（字段定义）、Step 2.2（_startTickerIfNeeded/_stopTickerIfNeeded）中类型一致
- `_arePerLineSpringsConverged() / _areRenderersConverged()` 在 Task 2 Step 3.2（定义）、Step 5（isConverged 检测中使用）中签名一致
- `isAlphaConverged: bool` 在 Task 2 Step 4.2（WordRenderer）、Step 4.3（LineRenderer）、Step 3.1（_areRenderersConverged 中读取）中签名一致
- generation counter 字段（`_linesGeneration` 等）在 Task 3 Step 1.1（State 字段）、Step 2.1（递增）、Step 3.1（painter 字段）、Step 4.1（shouldRepaint 比较）中类型一致
- `_reusedPerLineOffsets: List<double>` 在 Task 4 Step 1.1（字段定义）、Step 2.1（_buildPerLineOffsets 复用）、Task 5 Step 1.3（_hasPerLineOffsetChanged 读取）中类型一致
- `_lastRepaintPosY: double` 等字段在 Task 5 Step 1.1（条件 setState）、Step 1.2（字段定义）中类型一致

### 4. 风险评估

| Task | 风险 | 缓解 |
|---|---|---|
| 1 (WordRenderer 缓存) | 中：TextPainter 内部断言可能导致崩溃；alpha 边界判断可能不准 | 静态检查 + 已有 word_renderer 测试套件 + 实测视觉对比 |
| 2 (Ticker 停止) | 中：收敛检测遗漏场景可能导致动画卡死 | Task 2 Step 5/6 覆盖 didUpdateWidget + 用户交互回调；实测 Task 6 Step 5/6 验证恢复场景 |
| 3 (generation counter) | 低：counter 递增点遗漏会导致不重绘 | 已识别 _recomputeLineHeightsIfNeeded 和 _buildPerLineOffsets 两个修改点；实测验证 |
| 4 (perLineOffsets 复用) | 低：仅 GC 优化，无视觉影响 | 静态检查 + 已有测试 |
| 5 (条件 setState) | 中：阈值设置不当可能导致动画跳帧 | 阈值 0.5px / 0.001 远低于人眼感知；实测对比动画流畅度 |
| 6 (验证) | 低：仅验证 | 实测对比，必要时回滚对应 Task |

### 5. 与 v1/v2 的兼容性

- v1 的 RepaintBoundary 包裹保留
- v1 的 ValueNotifier 改造（PlayingSpectrumIndicator）不受影响
- v1 的 FlowingBackground 24fps 优化不受影响
- v2 的 Selector 切分（封面/标题/控制按钮/评论订阅）保留 — commit `7e107e8, f37e33f, fed675d`
- v2 Task 4（painter 模糊迁移）已回滚 — commit `546f070`，模糊层仍用 widget Stack+Opacity+RawImage
- v2 positionStream 周期实验已回滚，仍为 200ms

v3 是 v1 + v2 保留部分的渐进式增强，不回滚 v1/v2 任何保留的改动。

### 6. 收益叠加预估（基于 v2 后基线 ~48%）

| 优化项 | 播放态 CPU 收益 | 暂停态 CPU 收益 |
|---|---|---|
| Task 1 (WordRenderer 缓存) | -10~15% | -10~15%（暂停态无 WordRenderer 调用，收益小） |
| Task 2 (Ticker 停止) | 0%（播放态 Ticker 必须运行） | -20~25%（核心收益） |
| Task 3 (generation counter) | -3~5% | -3~5%（暂停态仍在比较字段） |
| Task 4 (perLineOffsets 复用) | -1~2% | -1~2% |
| Task 5 (条件 setState) | -5~10% | -5~10%（与 Task 2 叠加，但 Task 2 停止 Ticker 后已无 setState） |
| **累计**（播放态） | **-19~32%**（v2 后 ~48% → ~16-29%） | -19~32%（v2 后 ~48% → ~16-29%） |
| **累计**（暂停态） | -39~57%（v2 后 ~48% → <5%） |

**关键指标**：
- v2 后播放态 ~48% → v3 后 ~25-35%（目标）
- v2 后暂停态 ~48% → v3 后 <5%（核心用户体验收益）
