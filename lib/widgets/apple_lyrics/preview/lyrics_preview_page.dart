/// AppleLyricsView 渲染预览页（开发调试用）。
///
/// 参照 spec.md "Requirement: 单元测试与渲染预览页" 与 tasks.md Task 22。
/// 不依赖 just_audio 与 KugouProvider，可独立运行：
/// - 文本框输入 KRC/LRC 原文，点击"渲染"按钮解析并显示 [AppleLyricsView]
/// - 时间滑块（0~60000ms）模拟播放进度，验证动画时序
/// - "播放/暂停"按钮通过 [AnimationController] 每帧 +16ms 自动推进时间
/// - 顶部 PopupMenuButton 提供示例数据一键加载
library;

import 'package:flutter/material.dart';
import 'package:md3music/widgets/apple_lyrics/apple_lyrics_view.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_preferences_panel.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import 'package:md3music/widgets/apple_lyrics/parsers/lyric_parser_chain.dart';

class LyricsPreviewPage extends StatefulWidget {
  const LyricsPreviewPage({super.key});

  @override
  State<LyricsPreviewPage> createState() => _LyricsPreviewPageState();
}

class _LyricsPreviewPageState extends State<LyricsPreviewPage>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _textController;
  // 用 AnimationController.repeat() 的 addListener 作为每帧回调（≈16ms/帧），
  // 在 _isPlaying=true 时推进 _currentTimeMs，模拟播放器时钟。
  // 选用 AnimationController 而非 Timer，是因为它受 Ticker 驱动，
  // 在页面不可见时自动暂停，节省 CPU。
  late final AnimationController _playController;

  List<LyricLine> _parsedLines = const [];
  int _currentTimeMs = 0;
  bool _isPlaying = false;

  /// 时间滑块与自动播放的循环周期上限（毫秒），覆盖示例数据最大 startTime。
  static const int _maxTimeMs = 60000;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: _krcSample);
    _parseAndRender();
    _playController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(() {
        if (!_isPlaying) return;
        setState(() {
          // 每帧 +16ms 模拟 60fps 播放推进，到达上限后循环回到 0
          _currentTimeMs = (_currentTimeMs + 16) % _maxTimeMs;
        });
      });
    _playController.repeat();
  }

  /// 解析文本框内容并刷新预览，重置时间到 0。
  void _parseAndRender() {
    final text = _textController.text;
    setState(() {
      _parsedLines = LyricParserChain.parse(text);
      _currentTimeMs = 0;
    });
  }

  void _togglePlay() {
    setState(() {
      _isPlaying = !_isPlaying;
    });
  }

  @override
  void dispose() {
    _playController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('歌词预览'),
        actions: [
          // 歌词显示设置（字号/行间距）
          IconButton(
            icon: const Icon(Icons.lyrics),
            tooltip: '歌词显示设置',
            onPressed: () {
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (context) => SafeArea(
                  child: const LyricPreferencesPanel(),
                ),
              );
            },
          ),
          // 示例数据按钮：一键加载 KRC / LRC 示例并立即渲染
          PopupMenuButton<String>(
            onSelected: (value) {
              _textController.text = value == 'krc' ? _krcSample : _lrcSample;
              _parseAndRender();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'krc', child: Text('加载 KRC 示例')),
              PopupMenuItem(value: 'lrc', child: Text('加载 LRC 示例')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 1. 歌词渲染区（占大部分空间）
          Expanded(
            flex: 3,
            child: AppleLyricsView(
              lines: _parsedLines,
              currentTimeMs: _currentTimeMs,
              isPlaying: _isPlaying,
              onSeek: (ms) => setState(() => _currentTimeMs = ms),
            ),
          ),
          // 2. 控制区：时间滑块 + 播放/暂停 + 可折叠文本输入
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Text('${(_currentTimeMs / 1000).toStringAsFixed(1)}s'),
                    Expanded(
                      child: Slider(
                        value: _currentTimeMs.toDouble(),
                        min: 0,
                        max: _maxTimeMs.toDouble(),
                        onChanged: (v) =>
                            setState(() => _currentTimeMs = v.toInt()),
                      ),
                    ),
                    IconButton(
                      icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                      onPressed: _togglePlay,
                    ),
                  ],
                ),
                // 3. 文本输入框（可折叠），方便快速替换歌词数据
                ExpansionTile(
                  title: const Text('歌词文本'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: TextField(
                        controller: _textController,
                        maxLines: 10,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          hintText: '输入 KRC 或 LRC 歌词文本',
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: ElevatedButton(
                        onPressed: _parseAndRender,
                        child: const Text('渲染'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// KRC 示例：包含元数据、逐字时间戳、间奏行，用于验证 Apple Music 逐字动画。
const String _krcSample = '''[id:\$00000000]
[ar:トゲナシトゲアリ]
[ti:運命の華]
[total:195735]
[offset:0]
[0,3000]<0,300,0>運<300,400,0>命<700,500,0>の<1200,600,0>華<1800,1200,0>
[3000,4000]<0,350,0>泣<350,450,0>き<800,500,0>出<1300,700,0>し<2000,1000,0>た<3000,1000,0>
[7000,3000]<0,500,0>運<500,500,0>命<1000,500,0>の<1500,500,0>華<2000,1000,0>
[10000,5000]<0,400,0>咲<400,600,0>き<1000,800,0>誇<1800,1000,0>れ<2800,1200,0>ば<4000,1000,0>
[15000,0]間奏
[20000,3000]<0,500,0>終<500,500,0>わ<1000,500,0>り<1500,500,0>な<2000,500,0>き<2500,500,0>旅<3000,0,0>
''';

/// LRC 示例：仅整行时间戳，用于验证降级渲染模式（整行渐入渐出）。
const String _lrcSample = '''[ar:Sample Artist]
[ti:Sample Song]
[00:00.00]First line of lyrics
[00:03.00]Second line here
[00:07.00]Third line continues
[00:10.00]Fourth line of the song
[00:15.00]Fifth line ending
[00:20.00]Outro
''';
