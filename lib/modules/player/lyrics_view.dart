import 'dart:async';

import 'package:flutter/material.dart';

class LyricsView extends StatefulWidget {
  final String lyrics;
  final Duration position;
  final ValueChanged<Duration> onSeek;

  const LyricsView({
    super.key,
    required this.lyrics,
    required this.position,
    required this.onSeek,
  });

  @override
  State<LyricsView> createState() => LyricsViewState();
}

class LyricsViewState extends State<LyricsView> {
  final ScrollController _scrollController = ScrollController();
  List<_LyricLine> _parsedLyrics = [];
  int _currentLineIndex = -1;
  bool _forceScroll = false;

  // 用户是否正在触摸歌词列表（手指按下状态）
  bool _userTouching = false;
  // 用户松手后，延迟恢复自动滚动的定时器
  Timer? _resumeAutoScrollTimer;

  // 每行歌词固定高度
  static const double _lineHeight = 48.0;
  // ListView 顶部 padding
  static const double _topPadding = 100.0;

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
  }

  @override
  void didUpdateWidget(covariant LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyrics != widget.lyrics) {
      _parseLyrics();
      _currentLineIndex = -1;
      _forceScroll = true;
    }

    _updateCurrentLine();
  }

  @override
  void dispose() {
    _cancelResumeTimer();
    _scrollController.dispose();
    super.dispose();
  }

  void _parseLyrics() {
    _parsedLyrics = [];
    if (widget.lyrics.isEmpty) return;

    final lines = widget.lyrics.split('\n');
    // LRC 格式: [mm:ss.fff]text
    final lrcRegex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
    // KRC 行首: [start_ms,duration_ms]  后跟 <offset,duration[,property]>word
    final krcLineRegex = RegExp(r'^\[(\d+),(\d+)\](.*)$');
    // KRC 词时间标签：<offset,duration> 或 <offset,duration,property>
    final krcWordTag = RegExp(r'<(-?\d+),(-?\d+)(?:,-?\d+)?>');

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;

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
              milliseconds: minutes * 60000 + seconds * 1000 + millis,
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
            timestamp: Duration(milliseconds: startMs),
            text: text,
          ),
        );
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
          if (mounted) _scrollToLine(newIndex);
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
    final viewportHeight = _scrollController.position.viewportDimension;
    if (viewportHeight <= 0) return;

    final targetOffset =
        _topPadding + index * _lineHeight - viewportHeight * 0.4;
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

    if (_parsedLyrics.isEmpty) {
      return Center(
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
    }

    return Listener(
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: (_) => _onPointerUp(PointerUpEvent()),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(vertical: _topPadding, horizontal: 24),
        itemCount: _parsedLyrics.length,
        itemBuilder: (context, index) {
          final isCurrent = index == _currentLineIndex;
          final line = _parsedLyrics[index];

          return GestureDetector(
            onTap: () => _onLineTap(index),
            child: Container(
              height: _lineHeight,
              alignment: Alignment.center,
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                style: TextStyle(
                  fontSize: isCurrent ? 18 : 15,
                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                  color: isCurrent
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
                child: Text(
                  line.text.isEmpty ? '...' : line.text,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LyricLine {
  final Duration timestamp;
  final String text;

  _LyricLine({required this.timestamp, required this.text});
}
