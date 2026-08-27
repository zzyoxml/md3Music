import 'dart:async';

import 'package:flutter/material.dart';

import '../../widgets/md3_lyric_preferences.dart';

class LyricsView extends StatefulWidget {
  final String lyrics;
  final Duration position;
  final ValueChanged<Duration> onSeek;
  /// 是否启用双击跳转（开启后单击不跳转，双击才跳转）
  final bool doubleTapToJump;

  const LyricsView({
    super.key,
    required this.lyrics,
    required this.position,
    required this.onSeek,
    this.doubleTapToJump = false,
  });

  @override
  State<LyricsView> createState() => LyricsViewState();
}

class LyricsViewState extends State<LyricsView> {
  final ScrollController _scrollController = ScrollController();
  List<_LyricLine> _parsedLyrics = [];
  int _currentLineIndex = -1;
  bool _forceScroll = false;

  // 首次进入 / 切歌后第一次滚动用 jumpTo 直接定位当前行，
  // 避免每次切到歌词页都从顶部滚 300ms 到当前行
  bool _initialJumpDone = false;

  // 用户是否正在触摸歌词列表（手指按下状态）
  bool _userTouching = false;
  // 用户松手后，延迟恢复自动滚动的定时器
  Timer? _resumeAutoScrollTimer;

  // 长歌词行（如英文整句）换行后行高自适应缓存：
  // 每行高度按实际换行数测量，滚动用累计偏移；避免每帧 TextPainter 重测。
  bool _layoutDirty = true;
  double _lastLayoutWidth = -1;
  List<double> _lineHeights = [];
  List<double> _lineTopOffsets = [];

  // ListView 顶部 padding
  static const double _topPadding = 100.0;

  // 当前 MD3 歌词偏好快照（行高 = fontSize * lineSpacing）
  Md3LyricPreferences get _prefs => Md3LyricPreferences.instance;

  void forceScrollToPosition([Duration? target]) {
    _cancelResumeTimer();
    _userTouching = false;
    _forceScroll = true;
    if (target != null) {
      _scrollToTargetPosition(target);
      return;
    }
    _updateCurrentLine();
  }

  void _scrollToTargetPosition(Duration target) {
    if (_parsedLyrics.isEmpty) return;
    final newIndex = _findLineIndex(target);
    _currentLineIndex = newIndex;
    if (mounted) {
      setState(() {});
      _forceScroll = false;
      if (newIndex >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollToLine(newIndex, jump: true);
        });
      }
    }
  }

  int _findLineIndex(Duration position) {
    int index = -1;
    for (int i = 0; i < _parsedLyrics.length; i++) {
      if (position >= _parsedLyrics[i].timestamp) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  void _cancelResumeTimer() {
    _resumeAutoScrollTimer?.cancel();
    _resumeAutoScrollTimer = null;
  }

  void _onPointerDown(PointerDownEvent _) {
    _cancelResumeTimer();
    _userTouching = true;
  }

  void _onPointerUp(PointerUpEvent _) {
    _cancelResumeTimer();
    _resumeAutoScrollTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        _userTouching = false;
        _forceScroll = true;
        _updateCurrentLine();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _parseLyrics();
    // 监听 MD3 歌词偏好变化（字号/行间距/字体），实时刷新视图
    _prefs.addListener(_onPrefsChanged);
  }

  @override
  void didUpdateWidget(covariant LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyrics != widget.lyrics) {
      _parseLyrics();
      _currentLineIndex = -1;
      _forceScroll = true;
      _initialJumpDone = false; // 切歌后重新定位时直接跳转
    }

    _updateCurrentLine();
  }

  @override
  void dispose() {
    _prefs.removeListener(_onPrefsChanged);
    _cancelResumeTimer();
    _scrollController.dispose();
    super.dispose();
  }

  void _onPrefsChanged() {
    _layoutDirty = true;
    if (mounted) setState(() {});
  }

  void _parseLyrics() {
    _layoutDirty = true;
    _parsedLyrics = [];
    if (widget.lyrics.isEmpty) return;

    final lines = widget.lyrics.split('\n');
    // LRC 格式: [mm:ss.fff]text
    final lrcRegex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
    // 逐字 LRC 时间戳（用于检测一行内多个时间戳）
    final lrcTimestampRegex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\]');
    // KRC 行首: [start_ms,duration_ms]  后跟 <offset,duration[,property]>word
    final krcLineRegex = RegExp(r'^\[(\d+),(\d+)\](.*)$');
    // KRC 词时间标签：<offset,duration> 或 <offset,duration,property>
    final krcWordTag = RegExp(r'<(-?\d+),(-?\d+)(?:,-?\d+)?>');
    // LRC offset 标签: [offset:+/-xxx]
    final offsetRegex = RegExp(r'^\[offset:([+-]?\d+)\]');

    // 先提取 offset（毫秒偏移量）
    int offsetMs = 0;
    for (final raw in lines) {
      final offsetMatch = offsetRegex.firstMatch(raw.trim());
      if (offsetMatch != null) {
        offsetMs = int.tryParse(offsetMatch.group(1)!) ?? 0;
        break;
      }
    }

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      // 检测逐字 LRC：一行内有多个时间戳且时间戳之间有文本
      final allTimestamps = lrcTimestampRegex.allMatches(line).toList();
      if (allTimestamps.length > 1) {
        // 检查是否为逐字 LRC（时间戳之间有非空白文本）
        bool isWordLevel = false;
        for (int i = 0; i < allTimestamps.length - 1; i++) {
          final between = line.substring(
            allTimestamps[i].end,
            allTimestamps[i + 1].start,
          );
          if (between.trim().isNotEmpty) {
            isWordLevel = true;
            break;
          }
        }

        if (isWordLevel) {
          // 逐字 LRC：提取第一个时间戳，剥离所有时间戳后拼接文本
          final firstMatch = allTimestamps.first;
          final minutes = int.parse(firstMatch.group(1)!);
          final seconds = int.parse(firstMatch.group(2)!);
          final millisStr = firstMatch.group(3)!;
          final millis = millisStr.length == 2
              ? int.parse(millisStr) * 10
              : int.parse(millisStr);
          // 剥离所有时间戳，只保留文本
          final text = line.replaceAll(lrcTimestampRegex, '').trim();
          if (text.isNotEmpty) {
            _parsedLyrics.add(
              _LyricLine(
                timestamp: Duration(
                  milliseconds: minutes * 60000 + seconds * 1000 + millis - offsetMs,
                ),
                text: text,
              ),
            );
          }
          continue;
        }
      }

      final lrcMatch = lrcRegex.firstMatch(line);
      if (lrcMatch != null) {
        final minutes = int.parse(lrcMatch.group(1)!);
        final seconds = int.parse(lrcMatch.group(2)!);
        final millisStr = lrcMatch.group(3)!;
        final millis = millisStr.length == 2
            ? int.parse(millisStr) * 10
            : int.parse(millisStr);
        final text = lrcMatch.group(4)?.trim() ?? '';
        _parsedLyrics.add(
          _LyricLine(
            timestamp: Duration(
              milliseconds: minutes * 60000 + seconds * 1000 + millis - offsetMs,
            ),
            text: text,
          ),
        );
        continue;
      }

      final krcMatch = krcLineRegex.firstMatch(line);
      if (krcMatch != null) {
        final startMs = int.parse(krcMatch.group(1)!);
        final body = krcMatch.group(3) ?? '';
        final text = body.replaceAll(krcWordTag, '').trim();
        if (text.isEmpty) continue;
        _parsedLyrics.add(
          _LyricLine(
            timestamp: Duration(milliseconds: startMs - offsetMs),
            text: text,
          ),
        );
        continue;
      }

      // KRC 孤立 word tag 行（无行级时间戳）：剥离标签后追加到上一行
      if (krcWordTag.hasMatch(line)) {
        final stripped = line.replaceAll(krcWordTag, '').trim();
        if (stripped.isNotEmpty && _parsedLyrics.isNotEmpty) {
          _parsedLyrics.last = _LyricLine(
            timestamp: _parsedLyrics.last.timestamp,
            text: '${_parsedLyrics.last.text}$stripped',
          );
        }
      }
    }

    _parsedLyrics.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  void _updateCurrentLine() {
    if (_parsedLyrics.isEmpty) return;

    final newIndex = _findLineIndex(widget.position);
    final shouldScroll = _forceScroll || (newIndex != _currentLineIndex);
    _currentLineIndex = newIndex;

    if (mounted) {
      setState(() {});
      if (shouldScroll && !_userTouching && newIndex >= 0) {
        _forceScroll = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollToLine(newIndex, jump: !_initialJumpDone);
        });
      } else {
        _forceScroll = false;
      }
    }
  }

  /// 用直接偏移量计算滚动，不依赖 Scrollable.ensureVisible
  /// （ensureVisible 会冒泡到 TabBarView 的 PageView，破坏滚动状态）
  void _scrollToLine(int index, {bool jump = false}) {
    if (!_scrollController.hasClients) return;
    if (index < 0 || index >= _lineTopOffsets.length) return;
    final viewportHeight = _scrollController.position.viewportDimension;
    if (viewportHeight <= 0) return;

    // 行高自适应后各行高度不同，用累计偏移定位当前行顶部
    final targetOffset =
        _topPadding + _lineTopOffsets[index] - viewportHeight * 0.4;
    final clampedOffset =
        targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent);

    if (jump) {
      _scrollController.jumpTo(clampedOffset);
    } else {
      _scrollController.animateTo(
        clampedOffset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
    // 首次定位已完成，后续行进中的行切换保持 300ms 平滑滚动
    _initialJumpDone = true;
  }

  /// 计算每行容器高度与累计偏移（缓存，仅在歌词/偏好/宽度变化时重测）。
  ///
  /// 行高 = 实际文本块高（按当前字号 TextPainter 完整测量，英文原词+翻译
  /// 超长行可换 2 行及以上，不截断）
  ///        + 行间距留白 `fontSize * (lineSpacing - 1.4)`（下限 0）。
  /// 行距基准取 1.4 而非 1.2：英文 ascenders/descenders（g/y/p/j/l/h）需要
  /// 更宽松的行距，否则长英文行换行后字形会被上下行重叠/截断；lineSpacing
  /// 低于 1.4 时以 1.4 为下限，保证容器高度不低于文本块（lineSpacing 最小
  /// 可调到 0.8，原实现会出现负留白导致行高小于文本被裁切）。
  void _ensureLayout(double width, double fontSize, String? fontFamily) {
    if (!_layoutDirty && _lastLayoutWidth == width) return;
    _layoutDirty = false;
    _lastLayoutWidth = width;

    final n = _parsedLyrics.length;
    final spacingExtra = fontSize * (_prefs.lineSpacing - 1.4);
    final safeSpacing = spacingExtra > 0 ? spacingExtra : 0.0;
    final minRowHeight =
        fontSize * (_prefs.lineSpacing < 1.4 ? 1.4 : _prefs.lineSpacing);
    _lineHeights = List<double>.generate(n, (i) {
      final text = _parsedLyrics[i].text;
      // 空行显示 '...' 占位，按单行处理
      if (text.isEmpty) return minRowHeight;
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: fontSize,
            height: 1.4,
            // 用当前行字重测量（当前行字重 >= 非当前行，可保证所有行不截断）
            fontWeight: _prefs.fontWeight,
            fontFamily: fontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      final blockHeight = painter.computeLineMetrics().fold<double>(
        0,
        (sum, m) => sum + m.height,
      );
      return blockHeight + safeSpacing;
    });

    _lineTopOffsets = List<double>.filled(n, 0);
    for (var i = 1; i < n; i++) {
      _lineTopOffsets[i] = _lineTopOffsets[i - 1] + _lineHeights[i - 1];
    }
  }

  void _onLineTap(int index) {
    if (index < _parsedLyrics.length) {
      widget.onSeek(_parsedLyrics[index].timestamp);
      _cancelResumeTimer();
      _userTouching = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final prefs = _prefs;
    final fontSize = prefs.fontSize;
    final otherFontSize = (fontSize - 3).clamp(10.0, fontSize);
    final fontFamily = prefs.effectiveFontFamily;

    // 排除全局 UI 缩放，歌词保持原始大小
    Widget content;
    if (_parsedLyrics.isEmpty) {
      content = Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.lyrics_outlined,
              size: 48,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              '暂无歌词',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    } else {
      // LayoutBuilder 提供实际宽度，用于测量每行是否换行（长英文歌词自适应行高）
      content = LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth - 48; // 水平 padding 24*2
          _ensureLayout(availableWidth, fontSize, fontFamily);
          return Listener(
            onPointerDown: _onPointerDown,
            onPointerUp: _onPointerUp,
            onPointerCancel: (_) => _onPointerUp(PointerUpEvent()),
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(
                vertical: _topPadding,
                horizontal: 24,
              ),
              itemCount: _parsedLyrics.length,
              itemBuilder: (context, index) {
                final isCurrent = index == _currentLineIndex;
                final line = _parsedLyrics[index];

                return GestureDetector(
                  onTap: widget.doubleTapToJump
                      ? null
                      : () => _onLineTap(index),
                  onDoubleTap: widget.doubleTapToJump
                      ? () => _onLineTap(index)
                      : null,
                  child: Container(
                    // 行高随换行自适应（1 行或 2 行），不再裁切长歌词
                    height: _lineHeights[index],
                    alignment: Alignment.center,
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                      style: DefaultTextStyle.of(context).style.copyWith(
                        fontSize: isCurrent ? fontSize : otherFontSize,
                        fontWeight: isCurrent
                            ? prefs.fontWeight
                            : prefs.otherFontWeight,
                        fontFamily: fontFamily,
                        color: isCurrent
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                      child: Text(
                        line.text.isEmpty ? '...' : line.text,
                        textAlign: TextAlign.center,
                        // 不截断：英文原词+翻译超长时完整换行显示
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      );
    }

    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
      child: content,
    );
  }
}

class _LyricLine {
  final Duration timestamp;
  final String text;

  _LyricLine({required this.timestamp, required this.text});
}
