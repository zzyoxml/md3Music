import 'dart:async';

import 'package:dpad/dpad.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import '../../widgets/md3_lyric_preferences.dart';
import '../../providers/theme_provider.dart';
import '../../core/build_flags.dart';
import '../../core/remote/tv_hint_bar.dart';
import '../../core/remote/tv_lyrics_focus.dart';
import '../../core/utils/lyric_wrap_plan.dart';

class LyricsView extends StatefulWidget {
  final String lyrics;
  /// 已解析的结构化歌词，仅用于补充翻译/罗马音副行。
  final List<LyricLine>? parsedLyrics;
  /// 静态初始位置（未提供 [positionListenable] 时使用）
  final Duration position;
  /// 播放位置 listenable：提供后内部订阅，仅当前行变化时重建歌词，
  /// 不再由外层每 ~200ms 因 position 通知强制重建整棵歌词（性能优化）。
  final ValueListenable<Duration>? positionListenable;
  /// 对 [positionListenable] 的位置做二次校正（如在线歌词时间偏移），可为 null。
  final Duration Function(Duration)? adaptPosition;
  final ValueChanged<Duration> onSeek;
  /// 是否启用双击跳转（开启后单击不跳转，双击才跳转）
  final bool doubleTapToJump;

  const LyricsView({
    super.key,
    required this.lyrics,
    this.parsedLyrics,
    required this.position,
    required this.onSeek,
    this.positionListenable,
    this.adaptPosition,
    this.doubleTapToJump = false,
  });

  @override
  State<LyricsView> createState() => LyricsViewState();
}

class LyricsViewState extends State<LyricsView> {
  final ScrollController _scrollController = ScrollController();
  List<_LyricLine> _parsedLyrics = [];
  bool _hasTranslation = false;
  bool _hasRoma = false;
  int _currentLineIndex = -1;
  bool _forceScroll = false;
  /// 内部生效的当前位置：由 [LyricsView.position] 或 [positionListenable] 提供
  Duration _effPosition = Duration.zero;

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

  /// 换行计划落成的展示文本（含硬断点 \n），索引与 [_parsedLyrics] 对齐。
  ///
  /// 渲染与测高共用同一字符串，于是「测到的行数 == 显示的行数」由构造保证。
  /// 关闭平衡开关时这里就是原文，行为与改造前完全一致。
  List<String> _displayTexts = const <String>[];
  List<String?> _auxDisplayTexts = const <String?>[];

  // ListView 顶部 padding
  static const double _topPadding = 100.0;

  // tv: 歌词页遥控焦点状态机与逐行 FocusNode 登记表。
  //
  // 只在 `kTvBuild` 分支创建/登记：触屏构建既不创建状态机，也不把行包成
  // 遥控停点，路径逐像素不变（AGENTS §12 惯例：可测状态机不带编译期旗标，
  // 由调用方门控）。状态机本身在 `tv_lyrics_focus.dart`，`flutter test` 可钉。
  TvLyricsFocus? _tvFocus;
  final Map<int, FocusNode> _tvLineNodes = <int, FocusNode>{};

  /// tv: 歌词页的遥控键位提示文案（也用于「只有文案仍属于本页时才清除」——
  /// 焦点移到进度条/传输行等自带提示的控件时不覆盖它们的文案）。
  static const String _tvLyricsHint = '上下键选歌词行 · OK 跳到该行';

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
    // 若外层提供 positionListenable（性能优化：内部仅当前行变化才重建），订阅它
    _effPosition = widget.position;
    if (widget.positionListenable != null) {
      _onExternalPos();
      widget.positionListenable!.addListener(_onExternalPos);
    }
    // 监听 MD3 歌词偏好变化（字号/行间距/字体），实时刷新视图
    _prefs.addListener(_onPrefsChanged);
  }

  @override
  void didUpdateWidget(covariant LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 无 listenable（静态模式）时，用外层传的 position 覆盖
    if (widget.positionListenable == null) {
      _effPosition = widget.position;
    }
    final metadataChanged = !identical(
          oldWidget.parsedLyrics,
          widget.parsedLyrics,
        ) &&
        !listEquals(oldWidget.parsedLyrics, widget.parsedLyrics);
    if (oldWidget.lyrics != widget.lyrics || metadataChanged) {
      _parseLyrics();
      _currentLineIndex = -1;
      _forceScroll = true;
      _initialJumpDone = false; // 切歌后重新定位时直接跳转
    }

    _updateCurrentLine();
  }

  @override
  void dispose() {
    widget.positionListenable?.removeListener(_onExternalPos);
    _prefs.removeListener(_onPrefsChanged);
    _cancelResumeTimer();
    // tv: 状态机只持有 4s 恢复跟随的 Timer，页面销毁时必须取消
    // （AGENTS §10.4 第 7 条）；逐行 FocusNode 由各行 State 自行释放。
    _tvFocus?.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 接收外部 position 变化：仅更新内部当前位置并在行变化时重建，
  /// 行不变时 _updateCurrentLine 的门控会直接跳过，避免每 200ms 全量 build。
  void _onExternalPos() {
    final v = widget.positionListenable?.value;
    if (v != null) {
      _effPosition = widget.adaptPosition?.call(v) ?? v;
    }
    if (mounted) _updateCurrentLine();
  }

  void _onPrefsChanged() {
    _layoutDirty = true;
    if (mounted) setState(() {});
  }

  void _parseLyrics() {
    _layoutDirty = true;
    _parsedLyrics = [];
    _hasTranslation = false;
    _hasRoma = false;
    if (widget.lyrics.isEmpty) return;

    final lines = widget.lyrics.split('\n');
    // LRC 格式: [mm:ss.fff]text
    final lrcRegex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');
    // 逐字 LRC 时间戳（用于检测一行内多个时间戳）
    final lrcTimestampRegex = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\]');
    // KRC 行首: [start_ms,duration_ms]  后跟 <offset,duration[,property]>word
    final krcLineRegex = RegExp(r'^\[(\d+),(\d+)\](.*)$');
    // KRC 词时间标签：<offset,duration[,property...]>。
    // 兼容本地文件中出现的多字段扩展标签，避免标签原样显示。
    final krcWordTag = RegExp(r'<-?\d+(?:,-?\d+)+>');
    // 增强型 LRC 逐字标签：<mm:ss.xx>。MD3 只显示普通行文本，
    // 因此在保留行首时间戳的同时剥离内层逐字标签。
    final inlineLyricTag = RegExp(
      r'<(?:\d{1,3}:\d{2}\.\d{2,3}|-?\d+(?:,-?\d+)+)>',
    );
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
        final text =
            lrcMatch.group(4)?.replaceAll(inlineLyricTag, '').trim() ?? '';
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
            translation: _parsedLyrics.last.translation,
            roma: _parsedLyrics.last.roma,
          );
        }
      }
    }

    _collapseDuplicateTimestampLines();
    _parsedLyrics.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    _mergeParsedMetadata();
    _hasTranslation = _parsedLyrics.any(
      (line) => line.translation != null && line.translation!.isNotEmpty,
    );
    _hasRoma = _parsedLyrics.any(
      (line) => line.roma != null && line.roma!.isNotEmpty,
    );
  }

  /// 合并相邻且时间戳完全相同的行：第一行为主歌词，第二行为翻译，第三行为
  /// 罗马音，其余丢弃。
  ///
  /// 与 [LrcParser] 的同名规则保持一致（详见 `lrc_parser.dart`）。LyricsView
  /// 自带一套 LRC/KRC 正则解析，若不在这里合并，双行 LRC 的副行会被当成独立
  /// 主歌词行渲染，与 AppleLyricsView 的表现不一致。
  ///
  /// 必须在排序前执行：合并依赖源码相邻顺序（`List.sort` 不稳定）。
  void _collapseDuplicateTimestampLines() {
    if (_parsedLyrics.length < 2) return;
    final out = <_LyricLine>[];
    for (final line in _parsedLyrics) {
      final prev = out.isEmpty ? null : out.last;
      if (prev != null &&
          prev.timestamp == line.timestamp &&
          line.text.isNotEmpty &&
          line.text != '\u00A0') {
        if (prev.translation == null || prev.translation!.isEmpty) {
          out[out.length - 1] = _LyricLine(
            timestamp: prev.timestamp,
            text: prev.text,
            translation: line.text,
            roma: prev.roma,
          );
        } else if (prev.roma == null || prev.roma!.isEmpty) {
          out[out.length - 1] = _LyricLine(
            timestamp: prev.timestamp,
            text: prev.text,
            translation: prev.translation,
            roma: line.text,
          );
        }
        // 第 4 行及以后无槽位，直接丢弃
        continue;
      }
      out.add(line);
    }
    _parsedLyrics = out;
  }

  /// 将统一歌词模型中的翻译/罗马音合并到原有 MD3 主行。
  ///
  /// 主行仍由本文件原有的 LRC/KRC 解析器生成；结构化模型只按时间戳补充
  /// 副行。相同时间戳按出现顺序匹配，轻微精度差异允许 500ms 容差。
  void _mergeParsedMetadata() {
    final metadata = widget.parsedLyrics;
    if (metadata == null || metadata.isEmpty || _parsedLyrics.isEmpty) return;

    final used = <int>{};
    for (final line in _parsedLyrics) {
      var bestIndex = -1;
      var bestDelta = 501;
      for (var i = 0; i < metadata.length; i++) {
        if (used.contains(i)) continue;
        final delta =
            (metadata[i].startTime - line.timestamp.inMilliseconds).abs();
        if (delta <= 500 && delta < bestDelta) {
          bestIndex = i;
          bestDelta = delta;
        }
      }
      if (bestIndex < 0) continue;
      used.add(bestIndex);
      final source = metadata[bestIndex];
      // 保留本文件解析出的副行：metadata 对应字段为 null 时不要覆盖。
      // （_parsedLyrics 每次重建，原本即为 null，该判断不改变既有行为）
      if (source.translation != null) line.translation = source.translation;
      if (source.roma != null) line.roma = source.roma;
    }
  }

  void _updateCurrentLine() {
    if (_parsedLyrics.isEmpty) return;

    final newIndex = _findLineIndex(_effPosition);
    final lineChanged = newIndex != _currentLineIndex;
    final scrollNeeded = _forceScroll || lineChanged;
    // P0 优化：父组件经 positionNotifier 每 ~200ms 以新 position 重建本 Widget，
    // 行未变化时跳过 setState，避免播放中每 200ms 重建 ListView 可见行；
    // 仅在行切换或显式强制滚动（切歌定位/松手回弹）时才刷新。
    if (!lineChanged && !_forceScroll) return;
    _currentLineIndex = newIndex;

    if (mounted) {
      setState(() {});
      // tv: 遥控期间互斥——用户刚移行就被「按播放进度回滚」拉回去会看不清自己
      // 在哪一行，故判据取「未进入遥控（_tvFocus == null）或状态机仍在跟随」。
      // following == false 期间只更新高亮，不回滚视图。
      final bool followPlayback = _tvFocus == null || _tvFocus!.following;
      if (scrollNeeded && !_userTouching && followPlayback && newIndex >= 0) {
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
  /// 超长行可换 2 行及以上，不截断）+ 行间留白。
  ///
  /// 换行自适应间距：一行歌词换行后的**内部**视觉行距不再固定 1.4，而是跟随
  /// 用户的行间距设置按 0.8× 缩放（[_wrapLineHeight]，与 Apple Music 风格歌词
  /// 的 `wrapLineHeightFactor` 一致）——换行块因此和整体行距成比例，不会在大
  /// 行间距下显得挤成一团。行与行之间的留白补足到 `fontSize * lineSpacing`，
  /// 单行歌词的行距与改动前完全一致。
  ///
  /// 行距下限取 1.4：英文 ascenders/descenders（g/y/p/j/l/h）需要更宽松的行距，
  /// 否则长英文行换行后字形会被上下行重叠/截断；lineSpacing 可低至 0.8，
  /// 以 1.4 为下限保证容器高度不低于文本块。
  void _ensureLayout(double width, double fontSize, String? fontFamily) {
    if (!_layoutDirty && _lastLayoutWidth == width) return;
    _layoutDirty = false;
    _lastLayoutWidth = width;

    final n = _parsedLyrics.length;
    final wrapHeight = _wrapLineHeight;
    // 行间留白：把单行行距补足到 fontSize * lineSpacing（不足则为 0）
    final spacingExtra = fontSize * (_prefs.lineSpacing - wrapHeight);
    final safeSpacing = spacingExtra > 0 ? spacingExtra : 0.0;
    final bool balanced = _prefs.lineBalance;
    final TextStyle mainStyle = TextStyle(
      fontSize: fontSize,
      height: wrapHeight,
      // 用当前行字重测量（当前行字重 >= 非当前行，可保证所有行不截断）
      fontWeight: _prefs.fontWeight,
      fontFamily: fontFamily,
    );
    final TextStyle auxStyle = TextStyle(
      fontSize: _auxiliaryFontSize(fontSize),
      height: _auxiliaryLineHeight,
      fontWeight: _prefs.otherFontWeight,
      fontFamily: fontFamily,
    );
    // 平衡开关开启时，把 DP 断点落成硬换行；关闭时保持原文交给 Text 自动换行
    _displayTexts = List<String>.generate(n, (i) {
      final String raw = _parsedLyrics[i].text.isEmpty
          ? '...'
          : _parsedLyrics[i].text;
      if (!balanced) return raw;
      return LyricWrapPlanner.forText(
        raw,
        mainStyle,
        width,
        balanced: true,
      ).rowTexts.join('\n');
    });
    _auxDisplayTexts = List<String?>.generate(n, (i) {
      final String? aux = _selectedAuxiliaryText(_parsedLyrics[i]);
      if (aux == null) return null;
      if (!balanced) return aux;
      return LyricWrapPlanner.forText(
        aux,
        auxStyle,
        width,
        balanced: true,
      ).rowTexts.join('\n');
    });
    _lineHeights = List<double>.generate(n, (i) {
      final text = _displayTexts[i];
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: mainStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      final blockHeight = painter.computeLineMetrics().fold<double>(
        0,
        (sum, m) => sum + m.height,
      );
      final auxiliaryText = _auxDisplayTexts[i];
      var auxiliaryHeight = 0.0;
      if (auxiliaryText != null) {
        final auxiliaryPainter = TextPainter(
          text: TextSpan(
            text: auxiliaryText,
            style: auxStyle,
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: width);
        auxiliaryHeight =
            auxiliaryPainter.computeLineMetrics().fold<double>(
              0,
              (sum, m) => sum + m.height,
            ) +
            _auxiliaryFontSize(fontSize) * 0.25;
      }
      return blockHeight + auxiliaryHeight + safeSpacing;
    });

    _lineTopOffsets = List<double>.filled(n, 0);
    for (var i = 1; i < n; i++) {
      _lineTopOffsets[i] = _lineTopOffsets[i - 1] + _lineHeights[i - 1];
    }
  }

  /// 换行后的内部视觉行距系数：行间距设置的 0.8×，下限 1.4。
  ///
  /// 必须与渲染用的 `TextStyle.height` 保持一致，否则测量出的容器高度与实际
  /// 文本块高不符，长歌词会被裁切或多出空白。
  double get _wrapLineHeight {
    final scaled = _prefs.lineSpacing * _wrapLineHeightFactor;
    return scaled > _minWrapLineHeight ? scaled : _minWrapLineHeight;
  }

  /// 换行内部行距相对整体行间距的比例
  static const double _wrapLineHeightFactor = 0.8;

  /// 换行内部行距下限（避免英文 descenders 被裁切）
  static const double _minWrapLineHeight = 1.4;

  double _auxiliaryFontSize(double fontSize) {
    final scaled = fontSize * 0.7;
    return scaled > 12 ? scaled : 12;
  }

  static const double _auxiliaryLineHeight = 1.4;

  String? _selectedAuxiliaryText(_LyricLine line) {
    if (!_prefs.showAuxiliary) return null;
    final preferred = _prefs.displayMode;
    final mode = preferred == Md3LyricDisplayMode.translation
        ? (_hasTranslation
              ? Md3LyricDisplayMode.translation
              : Md3LyricDisplayMode.roma)
        : (_hasRoma
              ? Md3LyricDisplayMode.roma
              : Md3LyricDisplayMode.translation);
    final text = mode == Md3LyricDisplayMode.translation
        ? line.translation
        : line.roma;
    return text == null || text.isEmpty ? null : text;
  }

  void _onLineTap(int index) {
    if (index < _parsedLyrics.length) {
      widget.onSeek(_parsedLyrics[index].timestamp);
      _cancelResumeTimer();
      _userTouching = false;
    }
  }

  /// tv: 惰性创建遥控焦点状态机。
  ///
  /// OK 提交出口是 [widget.onSeek]——与触屏 [_onLineTap] **同一条** seek 出口
  /// （行时间戳在该页就是 `_parsedLyrics[i].timestamp`，字段名照旧），
  /// 不新增第二套 seek 路径。
  TvLyricsFocus _ensureTvFocus() {
    return _tvFocus ??= TvLyricsFocus(
      lineCount: () => _parsedLyrics.length,
      onSeek: (ms) => widget.onSeek(Duration(milliseconds: ms)),
    );
  }

  /// tv: 行上/下键 → 状态机移行，再对目标行 `requestFocus`；左右放行（返回
  /// false）让焦点出得去（AGENTS §12.4 规则：只吃本控件真正消费的方向键）。
  bool _tvHandleDirection(TraversalDirection direction) {
    final TvLyricsFocus? focus = _tvFocus;
    if (focus == null || !focus.move(direction)) return false;
    final int? target = focus.focusedIndex;
    if (target == null) return true;
    final FocusNode? node = _tvLineNodes[target];
    if (node != null && node.canRequestFocus) {
      node.requestFocus();
    } else {
      // 目标行还没进 ListView 的构建窗口（视口外）：先把列表滚到那一行，等它
      // 建出来后再落焦。少了这一步，长按上下键越过已构建范围就再也移不动
      // （节点不在 `_tvLineNodes` 里，requestFocus 无处可发）。
      _scrollToLine(target, jump: true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _tvLineNodes[target]?.requestFocus();
      });
    }
    if (mounted) setState(() {});
    return true;
  }

  /// tv: OK → 焦点行跳到它的时间戳（状态机的 [TvLyricsFocus.commit]）。
  void _tvCommitFocusedLine() {
    _ensureTvFocus().commit(
      timeMsOfLine: (i) => _parsedLyrics[i].timestamp.inMilliseconds,
    );
  }

  /// tv: 行获得焦点 → 焦点行落到该行（即屏幕上看得见的那一行，红框与高亮
  /// 始终一致），并暂停按播放进度回滚；失焦 → 下一帧再判定是「行间移动」还是
  /// 「真的离开了歌词区」，后者清空状态机与提示。
  void _tvLineFocusChanged(int index, bool focused) {
    final TvLyricsFocus focus = _ensureTvFocus();
    if (focused) {
      focus.enter(currentIndex: index);
      TvHintBarScope.show(_tvLyricsHint);
      if (mounted) setState(() {});
      return;
    }
    // 失焦回调可能先于目标行的获焦回调触发，此刻判「是否已离开歌词区」会误判；
    // 延到下一帧按 primaryFocus 判定。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final FocusNode? primary = FocusManager.instance.primaryFocus;
      if (primary != null && _tvLineNodes.containsValue(primary)) return;
      _tvFocus?.exit();
      // 只在本页文案还在时清除：焦点落到了自带提示的控件（进度条等）时不覆盖。
      if (TvHintBarScope.current.value == _tvLyricsHint) {
        TvHintBarScope.clear();
      }
      setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final prefs = _prefs;
    final lyricTextColor = prefs.customTextColor;
    final themeProvider = context.read<ThemeProvider?>();
    // 全局界面文字颜色不得改变未单独设色的歌词；还原主题原本的副文字色。
    final defaultInactiveColor = themeProvider?.customTextColor == null
        ? colorScheme.onSurfaceVariant
        : ColorScheme.fromSeed(
            seedColor: themeProvider!.effectiveSeedColor,
            brightness: Theme.of(context).brightness,
          ).onSurfaceVariant;
    final fontSize = prefs.fontSize;
    // 非当前行仍是歌词内容，下限取 12（与 LyricLayout 的可读下限一致）
    final otherFontSize = (fontSize - 3).clamp(12.0, fontSize);
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
                // tv: 焦点行沿用本页既有的「当前行 / 非当前行」配色体系
                // （见下方 AnimatedDefaultTextStyle 的 isCurrent 分支），
                // 不新增第二套视觉。
                final int? tvFocusedIndex =
                    kTvBuild ? _tvFocus?.focusedIndex : null;
                final isCurrent =
                    index == _currentLineIndex || index == tvFocusedIndex;
                final line = _parsedLyrics[index];
                final auxiliaryText = _selectedAuxiliaryText(line);
                final auxiliaryFontSize = _auxiliaryFontSize(fontSize);

                final Widget row = GestureDetector(
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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeInOut,
                          style: DefaultTextStyle.of(context).style.copyWith(
                            fontSize: isCurrent ? fontSize : otherFontSize,
                            fontWeight: isCurrent
                                ? prefs.fontWeight
                                : prefs.otherFontWeight,
                            fontFamily: fontFamily,
                            color: lyricTextColor == null
                                ? (isCurrent
                                    ? colorScheme.primary
                                    : defaultInactiveColor)
                                : (isCurrent
                                    ? lyricTextColor
                                    : lyricTextColor.withValues(alpha: 0.7)),
                            // 与 _ensureLayout 的测量保持一致（换行内部行距）
                            height: _wrapLineHeight,
                          ),
                          child: Text(
                            index < _displayTexts.length
                                ? _displayTexts[index]
                                : (line.text.isEmpty ? '...' : line.text),
                            textAlign: TextAlign.center,
                            // 不截断：英文原词+翻译超长时完整换行显示
                          ),
                        ),
                        if (auxiliaryText != null)
                          Padding(
                            padding: EdgeInsets.only(
                              top: auxiliaryFontSize * 0.25,
                            ),
                            child: Text(
                              index < _auxDisplayTexts.length &&
                                      _auxDisplayTexts[index] != null
                                  ? _auxDisplayTexts[index]!
                                  : auxiliaryText,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: auxiliaryFontSize,
                                height: _auxiliaryLineHeight,
                                fontWeight: prefs.otherFontWeight,
                                fontFamily: fontFamily,
                                color: lyricTextColor == null
                                    ? (isCurrent
                                        ? colorScheme.primary.withValues(alpha: 0.7)
                                        : defaultInactiveColor.withValues(alpha: 0.7))
                                    : lyricTextColor.withValues(
                                        alpha: isCurrent ? 0.7 : 0.5,
                                      ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );

                // tv: 每行一个遥控停点（上/下移行、OK 跳到该行时间戳）。
                // 非 TV 构建原样返回上面那棵树，触屏路径逐像素不变。
                if (!kTvBuild) return row;
                return _TvLyricLineRow(
                  key: ValueKey<int>(index),
                  index: index,
                  host: this,
                  child: row,
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
  String? translation;
  String? roma;

  _LyricLine({
    required this.timestamp,
    required this.text,
    this.translation,
    this.roma,
  });
}

/// tv: 歌词行的遥控包装——每行一个停点，FocusNode 与行的挂载生命周期同生共死。
///
/// ## 为什么节点必须随行销毁并从登记表移除
///
/// `ListView.builder` 会把滚出构建窗口的行整棵销毁。若把节点留在
/// [_LyricsViewState._tvLineNodes] 里，之后 `requestFocus` 会点到已 `dispose`
/// 的节点（debug 下直接断言崩），也会让 `_tvLineFocusChanged` 的
/// 「焦点是否仍在歌词区」判定（`_tvLineNodes.containsValue`）被幽灵节点骗过。
/// 因此 [dispose] 必须**同时**移除登记项并释放节点。
///
/// ## 与触屏路径的关系
///
/// 只有调用方在 `kTvBuild` 分支才会构造本组件（见 itemBuilder 里的门控），
/// 非 TV 构建 `ListView` 的行仍是原 `GestureDetector`，逐像素不变。
/// `DpadFocusable` 的 `excludeChildFocus` 保持默认 true：内层
/// `GestureDetector` 不产生第二个停点（AGENTS §12.4 规则 3）。
class _TvLyricLineRow extends StatefulWidget {
  const _TvLyricLineRow({
    super.key,
    required this.index,
    required this.host,
    required this.child,
  });

  final int index;
  final LyricsViewState host;
  final Widget child;

  @override
  State<_TvLyricLineRow> createState() => _TvLyricLineRowState();
}

class _TvLyricLineRowState extends State<_TvLyricLineRow> {
  late final FocusNode _node;

  @override
  void initState() {
    super.initState();
    _node = FocusNode(debugLabel: 'tv/lyric-line-${widget.index}');
    widget.host._tvLineNodes[widget.index] = _node;
  }

  @override
  void dispose() {
    // 顺序要紧：先摘登记表，再释放节点（释放后访问会断言）。
    widget.host._tvLineNodes.remove(widget.index);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DpadFocusable(
      focusNode: _node,
      onFocusChange: (focused) =>
          widget.host._tvLineFocusChanged(widget.index, focused),
      onSelect: widget.host._tvCommitFocusedLine,
      onDirection: widget.host._tvHandleDirection,
      child: widget.child,
    );
  }
}
