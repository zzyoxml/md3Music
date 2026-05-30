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
  final Map<int, GlobalKey> _lineKeys = {};
  List<_LyricLine> _parsedLyrics = [];
  int _currentLineIndex = -1;
  bool _isUserScrolling = false;
  DateTime? _userScrollEndTime;
  bool _forceScroll = false;

  void forceScrollToPosition() {
    _isUserScrolling = false;
    _forceScroll = true;
    _updateCurrentLine();
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
    _scrollController.dispose();
    super.dispose();
  }

  void _parseLyrics() {
    _parsedLyrics = [];
    _lineKeys.clear();
    if (widget.lyrics.isEmpty) return;

    final lines = widget.lyrics.split('\n');
    final regex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

    for (final line in lines) {
      final match = regex.firstMatch(line.trim());
      if (match != null) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final millisStr = match.group(3)!;
        final millis = millisStr.length == 2
            ? int.parse(millisStr) * 10
            : int.parse(millisStr);
        final text = match.group(4)?.trim() ?? '';
        final timestamp = Duration(
          minutes: minutes,
          seconds: seconds,
          milliseconds: millis,
        );
        _parsedLyrics.add(_LyricLine(timestamp: timestamp, text: text));
      }
    }

    _parsedLyrics.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    for (int i = 0; i < _parsedLyrics.length; i++) {
      _lineKeys[i] = GlobalKey();
    }
  }

  void _updateCurrentLine() {
    if (_parsedLyrics.isEmpty) return;

    int newIndex = -1;
    for (int i = 0; i < _parsedLyrics.length; i++) {
      if (widget.position >= _parsedLyrics[i].timestamp) {
        newIndex = i;
      } else {
        break;
      }
    }

    final shouldScroll = _forceScroll || (newIndex != _currentLineIndex);
    _currentLineIndex = newIndex;

    if (mounted) {
      setState(() {});
      if (shouldScroll && !_isUserScrolling && newIndex >= 0) {
        _forceScroll = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollToLine(newIndex);
        });
      } else {
        _forceScroll = false;
      }
    }
  }

  void _scrollToLine(int index) {
    if (!_scrollController.hasClients) return;

    final key = _lineKeys[index];
    if (key?.currentContext != null) {
      final RenderBox renderBox =
          key!.currentContext!.findRenderObject() as RenderBox;
      final scrollOffset = renderBox.localToGlobal(Offset.zero).dy;
      final viewportHeight = _scrollController.position.viewportDimension;
      final targetOffset =
          _scrollController.offset + scrollOffset - (viewportHeight / 2.5);
      _scrollController.animateTo(
        targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _onLineTap(int index) {
    if (index < _parsedLyrics.length) {
      widget.onSeek(_parsedLyrics[index].timestamp);
      _isUserScrolling = false;
    }
  }

  bool get _isUserScrollActive {
    if (_userScrollEndTime == null) return false;
    return DateTime.now().difference(_userScrollEndTime!) <
        const Duration(seconds: 4);
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

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is UserScrollNotification) {
          if (notification.direction.index != 0) {
            _isUserScrolling = true;
            _userScrollEndTime = null;
          } else {
            _userScrollEndTime = DateTime.now();
            Future.delayed(const Duration(seconds: 4), () {
              if (mounted && !_isUserScrollActive) {
                _isUserScrolling = false;
              }
            });
          }
        }
        return false;
      },
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(vertical: 100, horizontal: 24),
        itemCount: _parsedLyrics.length,
        itemBuilder: (context, index) {
          final isCurrent = index == _currentLineIndex;
          final line = _parsedLyrics[index];

          return GestureDetector(
            key: _lineKeys[index],
            onTap: () => _onLineTap(index),
            child: Container(
              height: 48,
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
