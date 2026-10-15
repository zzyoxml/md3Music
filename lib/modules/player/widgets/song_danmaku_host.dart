import 'dart:io';

import 'package:flutter/material.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../../core/build_flags.dart';
import '../../../core/danmaku/danmaku_buckets.dart';
import '../../../core/danmaku/danmaku_clock.dart';
import '../../../core/danmaku/danmaku_entry.dart';
import '../../../core/danmaku/danmaku_source.dart';
import '../../../core/danmaku/local_danmaku_store.dart';
import '../../../core/danmaku/song_barrage_mapper.dart';
import '../../../core/services/player_frame_driver.dart';
import '../../../data/models/song.dart';
import '../../../data/repositories/settings_repository.dart';
import '../../../providers/player_provider.dart';
import '../../../services/kugou_api/kugou_api_client.dart';
import '../../../widgets/danmaku/scroll_danmaku_layer.dart';
import '../comment_compose_sheet.dart';

/// 这首歌能不能发/收弹幕 —— 唯一判定处，播放页两处 `_openComposeSheet` 与宿主共用。
///
/// 在线歌曲的 `Song.id` 就是酷狗 hash；本地歌曲（含未匹配的 `local_...` 占位 id，
/// 见 `comments_view.dart` 的 `_isUnmatchedLocal` 同一判据）在酷狗没有弹幕池，
/// 既取不到也发不出，因此整层不渲染、弹幕档不出现。
bool songDanmakuUsable(Song? song) {
  if (song == null || !song.isOnline) return false;
  final id = song.id;
  return id.isNotEmpty && !id.startsWith('local_');
}

/// 播放页「歌曲弹幕」宿主：把弹幕**精确盖在封面（artwork）区域**上。
///
/// 用法是把封面子树交给 [cover]，本组件用 Stack 叠在其上；关闭态直接原样返回
/// [cover]，不增加任何 widget 层级 —— 这是「默认关闭 = 播放页零变化」的实现前提。
///
/// 与 MV 弹幕层（`../../widgets/danmaku/mv_danmaku_layer.dart`）的关键差异：
/// 音频侧的位置来自 `PlayerProvider.positionNotifier`（约 200ms 一次），弹幕滚动
/// 属于「不需要即时响应操作」的装饰性动效，按 AGENTS §10 必须挂共享节拍
/// [PlayerFrameDriver] 而非 `Ticker` —— 用 Ticker 会把整页帧提交顶到 vsync 满帧。
class SongDanmakuHost extends StatefulWidget {
  const SongDanmakuHost({super.key, required this.cover});

  /// 被盖住的封面子树。本组件不改变它的尺寸约束（Stack 的 tight 约束原样下传）。
  final Widget cover;

  /// 刚发送的弹幕的投递通道。
  ///
  /// 播放页与评论弹层之间没有共享 Provider（本功能只在播放页出现），沿用仓内
  /// `PlayerCoverMorphBus` 那套「静态可观察值」的做法，避免为一个跨层投递新建 Provider。
  static final ValueNotifier<DanmakuEntry?> delivery = ValueNotifier<DanmakuEntry?>(null);

  /// 投递一条刚发送的弹幕：立即上屏（若有存活宿主）**并**落盘。
  ///
  /// 落盘刻意在本方法内完成而不是交给宿主 —— 用户可能停在歌词/评论 tab，
  /// 那时封面子树已被 PageView 销毁、宿主不存活，但这条弹幕必须留下记录。
  static Future<void> deliver(DanmakuEntry entry, String hash) async {
    delivery.value = entry;
    try {
      final supportDir = await getApplicationSupportDirectory();
      await LocalDanmakuStore(
        root: Directory('${supportDir.path}/danmaku'),
      ).append(songDanmakuKey(hash), entry);
    } catch (_) {
      // 落盘失败不影响已经上屏的弹幕（与 MV 侧同一取舍）
    }
  }

  /// 播放页评论入口的投递便捷方法：弹幕的时间轴坐标 = 发送那一刻的播放位置。
  ///
  /// 之所以由这里而不是调用方拼 [DanmakuEntry]：`Song` 与 `DanmakuEntry` 的组装
  /// 口径（id 前缀、selfSend）收在一处，两处各写一份必然会漂移。
  static void deliverText(String text, String hash, Duration time) {
    deliver(
      DanmakuEntry(
        time: time,
        text: text,
        id: 'local-${DateTime.now().microsecondsSinceEpoch}',
        selfSend: true,
      ),
      hash,
    );
  }

  @override
  State<SongDanmakuHost> createState() => _SongDanmakuHostState();
}

class _SongDanmakuHostState extends State<SongDanmakuHost> {
  /// 滚动弹幕绘制层的命令句柄。飞行推进挂共享节拍（见 `ScrollDanmakuLayer`，
  /// 显示区域也在那里钳到容器顶部约 45%），本宿主只负责「何时投哪条」。
  final ScrollDanmakuController _danmaku = ScrollDanmakuController();

  PlayerProvider? _player;
  DanmakuBuckets? _timeline;

  /// 弹幕总量。**只在加载完成时整体替换一次**；用户自己发送的弹幕直接投渲染器，
  /// 不回写本列表 —— 否则时间轴重建会让已出现的弹幕整批重放（炸屏）。
  List<DanmakuEntry> _entries = const [];

  /// 单调时钟：`DateTime.now()` 会被 NTP 同步/手动改时间打断，外推会跳变并被
  /// 误判为 seek。全程只 start 一次，不 reset —— 它不是帧源，不产生功耗。
  final Stopwatch _clock = Stopwatch()..start();

  /// 最近一次从播放器采样到的位置及采样时刻，用于两次采样之间线性外推。
  Duration _samplePosition = Duration.zero;
  Duration _sampleElapsed = Duration.zero;

  /// 是否已采样过一次。**未采样前严禁 feed**：否则 `elapsed - 0` 是进程启动以来
  /// 的巨大时长，会被当成播放位置。
  bool _sampled = false;

  bool _enabled = false;
  bool _bound = false;

  /// `TickerMode` 为 false（例如被离屏 TabView 冻结）时不得产帧。
  bool _tickerVisible = true;

  String? _hash;
  int _loadSeq = 0;

  /// 上次尝试加载时时长还未知 —— 挂起等下一次通知补拉，避免空手。
  bool _awaitingDuration = false;

  /// 自发送弹幕 id 的自增序号：同一微秒内连发两条时保证 id 唯一。
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _enabled = SettingsRepository.songDanmakuEnabled.value;
    SettingsRepository.songDanmakuEnabled.addListener(_onSettingsChanged);
    SongDanmakuHost.delivery.addListener(_onDelivery);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final player = context.read<PlayerProvider>();
    if (!identical(_player, player)) {
      _player?.positionNotifier.removeListener(_onPositionSample);
      _player?.removeListener(_onPlayerChanged);
      _player = player;
      player.positionNotifier.addListener(_onPositionSample);
      player.addListener(_onPlayerChanged);
    }
    _tickerVisible = TickerMode.valuesOf(context).enabled;
    _syncSong();
    _syncDriver();
  }

  @override
  void didUpdateWidget(covariant SongDanmakuHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 挂载点从 4 处封面分支进来，转屏/切换布局会让本 widget 换位置但不换 State；
    // 歌曲与时长在这里可能对不齐，统一交给 _syncSong 判定。
    _syncSong();
    _syncDriver();
  }

  @override
  void deactivate() {
    // 不可见期间必须解绑：否则离屏组件仍在持续产帧（§10.4.3 的常见漏电点）。
    _unbindDriver();
    super.deactivate();
  }

  @override
  void dispose() {
    SettingsRepository.songDanmakuEnabled.removeListener(_onSettingsChanged);
    SongDanmakuHost.delivery.removeListener(_onDelivery);
    _player?.positionNotifier.removeListener(_onPositionSample);
    _player?.removeListener(_onPlayerChanged);
    _unbindDriver();
    super.dispose();
  }

  /// 可用 hash：在线歌曲的 `Song.id` 就是酷狗 hash；本地歌曲（含未匹配的
  /// `local_...`）没有弹幕池，整层与入口都不出现。
  String? _usableHash(Song? song) => songDanmakuUsable(song) ? song!.id : null;

  void _onSettingsChanged() {
    final enabled = SettingsRepository.songDanmakuEnabled.value;
    if (enabled == _enabled) return;
    setState(() => _enabled = enabled);
    if (enabled) {
      _syncSong();
    } else {
      _unbindDriver();
    }
  }

  void _onPlayerChanged() {
    _syncSong();
    _syncDriver();
  }

  /// 低频位置采样（约 200ms）：刷新外推基准，并按播放态起停帧驱动。
  void _onPositionSample() {
    final player = _player;
    if (player == null) return;
    final position = player.position;
    if (position != _samplePosition) {
      _samplePosition = position;
      _sampleElapsed = _clock.elapsed;
      _sampled = true;
    }
    _syncDriver();
  }

  /// 歌曲/时长变化 → 重新拉取。
  ///
  /// 时长是铺开时间轴的除数，未知（0）时**不拉**：等 `duration` 到位后的那一次
  /// 通知再来，否则整池弹幕会被挤在 0 附近。
  void _syncSong() {
    final player = _player;
    if (player == null) return;
    final song = player.currentSong;
    final hash = _usableHash(song);
    final duration = player.duration ?? song?.duration ?? Duration.zero;

    if (hash == _hash) {
      // 同一首歌：仅在「上次因时长未知而没拉到、这次时长到位」时补拉一次。
      if (_awaitingDuration && hash != null && duration > Duration.zero) {
        _load(hash, duration);
      }
      return;
    }
    _hash = hash;
    _awaitingDuration = false;
    _danmaku.clear();
    _timeline = null;
    _entries = const [];
    if (hash != null && _enabled) _load(hash, duration);
  }

  Future<void> _load(String hash, Duration duration) async {
    if (duration <= Duration.zero) {
      // 时长是铺开时间轴的除数，未知时不拉：挂起等 `duration` 到位后的那一次通知，
      // 否则整池弹幕会被挤在 0 附近（而且白耗一次 3 页请求）。
      if (mounted) setState(() => _awaitingDuration = true);
      return;
    }
    final seq = ++_loadSeq;
    final api = KugouApiClient();
    final remote = await fetchSongBarragePages(
      hash: hash,
      songDuration: duration,
      fetchPage: (page, pagesize) => api.getSongBarrage(
        hash: hash,
        page: page,
        pagesize: pagesize,
      ),
    );
    final local = await _loadLocal(hash);
    if (!mounted || seq != _loadSeq) return;

    final merged = _mergeEntries(remote, local);
    setState(() {
      _entries = merged;
      _timeline = DanmakuBuckets(merged);
    });
    _syncDriver();
  }

  Future<List<DanmakuEntry>> _loadLocal(String hash) async {
    try {
      final supportDir = await getApplicationSupportDirectory();
      final store = LocalDanmakuStore(
        root: Directory('${supportDir.path}/danmaku'),
      );
      return await LocalDanmakuSource(
        store: store,
        key: songDanmakuKey(hash),
      ).load();
    } catch (_) {
      return const [];
    }
  }

  /// 本地弹幕优先于远端（同 id 只留本地那条，避免自己发的重复出现两次）。
  List<DanmakuEntry> _mergeEntries(List<DanmakuEntry> remote, List<DanmakuEntry> local) {
    if (local.isEmpty) return remote;
    final seen = <String>{};
    final merged = <DanmakuEntry>[];
    for (final entry in [...local, ...remote]) {
      if (entry.text.trim().isEmpty) continue;
      final id = entry.id;
      if (id.isNotEmpty && !seen.add(id)) continue;
      merged.add(entry);
    }
    merged.sort((a, b) => a.time.compareTo(b.time));
    return merged;
  }

  /// 帧驱动的唯一收口：绑/解只在这里发生（§10.4.5 —— 已有驱动时不得再起 Ticker）。
  ///
  /// 条件不满足必须**解绑**而不是在回调里早退：早退省不掉帧提交，只省掉了计算。
  void _syncDriver() {
    if (kTvBuild) return;
    final player = _player;
    final shouldRun = _enabled &&
        _tickerVisible &&
        _sampled &&
        _hash != null &&
        _entries.isNotEmpty &&
        player != null &&
        player.isPlaying &&
        !player.isPlaybackNotReady;

    if (shouldRun && !_bound) {
      PlayerFrameDriver.instance.addListener(_onTick);
      _bound = true;
    } else if (!shouldRun && _bound) {
      _unbindDriver();
    }
  }

  void _unbindDriver() {
    if (!_bound) return;
    PlayerFrameDriver.instance.removeListener(_onTick);
    _bound = false;
    // 停驱动时一并停飞行：暂停期间弹幕继续飘是错的。
    _danmaku.setFlying(false);
  }

  void _onTick() {
    final player = _player;
    final timeline = _timeline;
    if (player == null || timeline == null || !_sampled) return;

    final position = estimatePosition(
      base: _samplePosition,
      wallClock: _clock.elapsed,
      sampleClock: _sampleElapsed,
      isPlaying: player.isPlaying && !player.isPlaybackNotReady,
    );

    final result = timeline.feed(position);
    if (result.reset) {
      // 真 seek（回退超过 DanmakuBuckets.backwardTolerance）：清屏重放。
      _danmaku.clear();
    }
    if (!player.isPlaying || player.isPlaybackNotReady) return;
    _danmaku.setFlying(true);
    for (final entry in result.due) {
      _danmaku.spawn(entry);
    }
  }

  /// 评论弹层发送成功后投递过来的弹幕：直投绘制层，**不回写 [_entries]**。
  void _onDelivery() {
    final entry = SongDanmakuHost.delivery.value;
    if (entry == null) return;
    _danmaku.spawn(entry);
  }

  void _openComposer() {
    final hash = _hash;
    final song = _player?.currentSong;
    if (hash == null || song == null) return;
    showCommentComposeSheet(
      context,
      song: song,
      startInDanmakuMode: true,
      // 弹层只管取文本与发远端；上屏与落盘回到宿主，因为只有宿主知道当前
      // 播放位置（弹幕的时间轴坐标）和自增序号。
      onDanmakuSent: (text) {
        _seq++;
        SongDanmakuHost.deliver(
          DanmakuEntry(
            time: _player?.position ?? Duration.zero,
            text: text,
            // 微秒时间戳在同微秒内仍可能重复，叠加自增序号保证唯一
            id: 'local-${DateTime.now().microsecondsSinceEpoch}-$_seq',
            selfSend: true,
          ),
          hash,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 关闭态原样返回封面：零额外层级、零额外功耗。
    // tv: 弹幕正文输入依赖软键盘，遥控不可用 —— 整层（渲染 + 入口）不挂载。
    if (kTvBuild || !_enabled || _hash == null) return widget.cover;

    final colorScheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.cover,
        Positioned.fill(
          child: IgnorePointer(
            child: ScrollDanmakuLayer(
              controller: _danmaku,
              highlightColor: colorScheme.primary,
            ),
          ),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: M3EFilledButton.tonal(
            onPressed: _openComposer,
            tooltip: '发弹幕',
            shape: M3EButtonShape.round,
            decoration: M3EButtonDecoration(
              fixedSize: const Size(40, 40),
              padding: EdgeInsets.zero,
              backgroundColor:
                  WidgetStatePropertyAll(colorScheme.secondaryContainer),
              foregroundColor:
                  WidgetStatePropertyAll(colorScheme.onSecondaryContainer),
            ),
            child: const Icon(Icons.subtitles_outlined, size: 20),
          ),
        ),
      ],
    );
  }
}
