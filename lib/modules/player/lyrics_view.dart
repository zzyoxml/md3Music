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
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final ScrollController _scrollController = ScrollController();
  List<_LyricLine> _parsedLyrics = [];
  int _currentLineIndex = -1;
  bool _isUserScrolling = false;

  @override
  void initState() {
    super.initState();
    _parseLyrics();
    _scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyrics != widget.lyrics) {
      _parseLyrics();
    }
    _updateCurrentLine();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _parseLyrics() {
    _parsedLyrics = [];
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

    if (newIndex != _currentLineIndex) {
      setState(() {
        _currentLineIndex = newIndex;
      });
      if (!_isUserScrolling && newIndex >= 0) {
        _scrollToLine(newIndex);
      }
    }
  }

  void _scrollToLine(int index) {
    if (!_scrollController.hasClients) return;

    const itemHeight = 48.0;
    final offset = (index * itemHeight) - (MediaQuery.sizeOf(context).height / 3);
    _scrollController.animateTo(
      offset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _onScroll() {
    if (_scrollController.position.isScrollingNotifier.value) {
      _isUserScrolling = true;
    }
  }

  void _onLineTap(int index) {
    if (index < _parsedLyrics.length) {
      widget.onSeek(_parsedLyrics[index].timestamp);
      _isUserScrolling = false;
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

    return GestureDetector(
      onVerticalDragDown: (_) => _isUserScrolling = true,
      onVerticalDragEnd: (_) {
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) _isUserScrolling = false;
        });
      },
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(vertical: 100, horizontal: 24),
        itemCount: _parsedLyrics.length,
        itemExtent: 48,
        itemBuilder: (context, index) {
          final isCurrent = index == _currentLineIndex;
          final line = _parsedLyrics[index];

          return GestureDetector(
            onTap: () => _onLineTap(index),
            child: Center(
              child: Text(
                line.text.isEmpty ? '...' : line.text,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: isCurrent ? 18 : 15,
                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                  color: isCurrent
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                  height: 1.4,
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
