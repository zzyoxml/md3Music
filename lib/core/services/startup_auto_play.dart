import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/repositories/settings_repository.dart';
import '../../modules/discover/home_discover_refill.dart';
import '../../modules/personal_fm/personal_fm_core.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/player_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';

/// 启动自动播放的结果，供调用方决定后续动作（是否推起完整播放页）。
///
/// 用 record 而非自定义类：仓库已有同款多值返回（见 `runBootstrap()` 的
/// `(needsOnboarding, needsUserAgreement)`），风格一致且不额外占一个类型名。
///
/// - [started]：本次是否真的建立了播放。
/// - [openPlayerPage]：用户是否希望「起播后连带进入播放页」。
///
/// 调用方必须先看 [started] 再看 [openPlayerPage]：开关开着但没起播成功
/// （未登录 / 音源为空 / 地址解析失败）时，不该把用户推进一个播不起来的页面。
typedef StartupAutoPlayResult = ({bool started, bool openPlayerPage});

/// 启动时自动播放的音源。
///
/// 五个值的 `value` 是写进 SharedPreferences 的稳定字符串，**不要改**
/// （改了等于把老用户的设置丢弃）；[label] 只用于设置页下拉显示。
enum StartupAutoPlaySource {
  /// 继续上次播放：唯一不依赖登录、也不依赖网络的音源，故作为默认值。
  resume('resume', '继续上次播放'),

  /// 每日推荐（`/everyday/recommend`）。
  daily('daily', '每日推荐'),

  /// 私人 FM · 红心（`mode=normal` + `song_pool_id=0`）。
  fmHeart('fmHeart', '私人FM · 红心'),

  /// 私人 FM · 探索（`mode=normal` + `song_pool_id=2`）。
  fmExplore('fmExplore', '私人FM · 探索'),

  /// 私人 FM · 小众（`mode=small` + `song_pool_id=1`）。
  fmNiche('fmNiche', '私人FM · 小众'),

  /// 私人 FM · 电台（`mode=radio` + `song_pool_id=0`）。
  fmRadio('fmRadio', '私人FM · 电台'),

  /// 刷歌推荐（首页发现流的刷歌池，`today_play_num` 客户端游标）。
  homeDiscover('homeDiscover', '刷歌推荐');

  const StartupAutoPlaySource(this.value, this.label);

  /// 持久化用的稳定字符串。
  final String value;

  /// 设置页下拉里显示的文案。
  final String label;

  /// 反解持久化值；未知/空值一律回落到 [resume]。
  ///
  /// 必须容忍非法值：设置项是按字符串存的，用户清数据后重装、跨版本升级、
  /// 或手工改过 preferences 都会塞进这里没有的值。让它抛异常等于让启动流程
  /// 崩在开机第一步。
  static StartupAutoPlaySource fromValue(String? value) {
    for (final source in StartupAutoPlaySource.values) {
      if (source.value == value) return source;
    }
    return StartupAutoPlaySource.resume;
  }

  /// 除 [resume] 外都走网络接口，需要登录态才能解析到播放地址。
  ///
  /// 判的是 `KugouApiClient().isLoggedIn` 而非 `KugouProvider.isLoggedIn`——
  /// 播放器自身（`playOnlineSong` / `playOnlinePlaylist` / `playCloudPlaylist`）
  /// 读的就是前者，两边判定不一致会让本服务以为登录好了、却被播放器静默拦下
  /// 转成一次 `onLoginRequired` 弹窗。
  bool get needsLogin => this != StartupAutoPlaySource.resume;

  /// 对应 [kFmStations] 的下标；非 FM 音源返回 null。
  int? get fmStationIndex {
    switch (this) {
      case StartupAutoPlaySource.fmHeart:
        return 0;
      case StartupAutoPlaySource.fmExplore:
        return 1;
      case StartupAutoPlaySource.fmNiche:
        return 2;
      case StartupAutoPlaySource.fmRadio:
        return 3;
      case StartupAutoPlaySource.resume:
      case StartupAutoPlaySource.daily:
      case StartupAutoPlaySource.homeDiscover:
        return null;
    }
  }
}

/// 冷启动自动播放的编排器。
///
/// 调用点在 `_MainLayoutState.initState` 的首帧回调里（见 `app.dart`），
/// 串在一同房里**一起听会话恢复之后**——那条恢复路径末尾可能自己
/// `resume()` / `playSong()`，并发会互相顶掉播放目标。
///
/// **本类不认识导航、也不需要 BuildContext**：只负责「读偏好 → 起播 → 报告
/// 结果」，推不推播放页由调用方看着 [StartupAutoPlayResult] 决定。这样
/// 后台唤醒 / 桌面小部件等无 UI 上下文的地方也能复用同一份起播逻辑。
///
/// 全部失败路径都静默：开机不该被 toast 或弹窗打扰。
class StartupAutoPlay {
  StartupAutoPlay._();

  /// 一次性保护。hot reload 与重复的首帧回调都可能再进来一次，
  /// 而重复起播会打断正在进行的恢复流程。
  static bool _started = false;

  /// 冷启动时最多等登录态多久。
  ///
  /// [KugouApiClient] 的 token 是从 secure storage 异步读出来的，冷启动早期
  /// 可能还没落定；不等就等于把「token 还在路上」误判成「没登录」。但也不能
  /// 无限等——所以给一个上限，到点没来就当没登录，静默跳过。
  static const Duration _loginGrace = Duration(seconds: 3);
  static const Duration _loginPollInterval = Duration(milliseconds: 300);

  /// 依设置尝试起播；未起播或没这个功能时返回 `started: false`。
  static Future<StartupAutoPlayResult> maybeAutoPlay({
    required KugouProvider kugou,
    required PlayerProvider player,
  }) async {
    if (_started) return const (started: false, openPlayerPage: false);
    _started = true;

    // 先读偏好、遇到「关」立刻返回：默认关闭时启动流程对播放零参与，
    // 连 audioReady 都不等。
    final settings = SettingsRepository();
    if (!await settings.getStartupAutoPlayEnabled()) {
      return const (started: false, openPlayerPage: false);
    }
    final openPlayerPage = await settings.getStartupAutoPlayOpenPage();
    const skipped = (started: false, openPlayerPage: false);

    try {
      // 音频引擎就绪。PlayerProvider 的时序不变量保证本 Future 完成时
      // _restoreState() 已经跑完 —— 这正是「继续上次播放」能拿到
      // 恢复态与播放进度的前提。不等它，play* 系列会因 _audioService 为
      // null 而静默跳过实际播放。
      await player.audioReady;

      // 已经有东西在响了（一起听恢复、外部音频唤起）：让位，也不要把
      // 已经在听歌的用户拽进播放页。
      if (player.isPlaying) return skipped;

      final source =
          StartupAutoPlaySource.fromValue(await settings.getStartupAutoPlaySource());

      // 「继续上次播放」在没有记录时无事可做，直接跳过而不是去走联网源：
      // 用户明确选的是「续播」，替他换成每日推荐属于擅自改主意。
      if (source == StartupAutoPlaySource.resume &&
          player.currentSong == null) {
        return skipped;
      }

      if (source.needsLogin && !await _waitForLogin()) return skipped;

      if (!await _play(source, kugou: kugou, player: player)) return skipped;

      return (started: true, openPlayerPage: openPlayerPage);
    } catch (e) {
      // 抛出去只会变成没人接的异步异常。开机自动播放失败不该有任何表现。
      debugPrint('[StartupAutoPlay] 起播失败: $e');
      return skipped;
    }
  }

  /// 等登录态就绪，返回是否等到。全程无 UI。
  static Future<bool> _waitForLogin() async {
    if (KugouApiClient().isLoggedIn) return true;
    final deadline = DateTime.now().add(_loginGrace);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(_loginPollInterval);
      if (KugouApiClient().isLoggedIn) return true;
    }
    return false;
  }

  /// 按音源起播，返回是否真的建立了播放。
  static Future<bool> _play(
    StartupAutoPlaySource source, {
    required KugouProvider kugou,
    required PlayerProvider player,
  }) async {
    switch (source) {
      case StartupAutoPlaySource.resume:
        // 不重复设 seekTo：位置已由 _restoreState 写进播放源，
        // 这里再 seek 会与恢复流程抢 seek 会话。
        await player.resume();
      case StartupAutoPlaySource.daily:
        // KugouProvider 内部吞异常并把错误写进 _error，所以判据是
        // 拉完之后列表有没有内容，而不是 await 有没有抛。
        await kugou.getRecommendDaily();
        final songs = kugou.recommendSongsAsSongs;
        if (songs.isEmpty) return false;
        await player.playOnlinePlaylist(songs, 0);
      case StartupAutoPlaySource.fmHeart:
      case StartupAutoPlaySource.fmExplore:
      case StartupAutoPlaySource.fmNiche:
      case StartupAutoPlaySource.fmRadio:
        await _playPersonalFm(source.fmStationIndex!, kugou, player);
      case StartupAutoPlaySource.homeDiscover:
        await _playHomeDiscover(kugou, player);
    }
    // play* 系列对解析失败的处理是「停在原地 + 报 resolveError」而非抛异常，
    // 所以成功与否只能回到播放器身上看：起播后一定有 currentSong。
    return player.currentSong != null;
  }

  /// 私人 FM 四个档位。
  ///
  /// 走 [PersonalFmWidgetActions] 而不是自己拼：它是发现页 FM 区块与桌面小
  /// 部件共同使用的同一份起播逻辑，内含两件缺了就一定会出事的事——
  /// `armRefill` 挂上 `onPlaylistEnd` 续播器（否则约 3 首后停住）、以及
  /// 持久化 FM 会话标记（否则杀后台重进后队列永不补货）。
  static Future<void> _playPersonalFm(
    int stationIndex,
    KugouProvider kugou,
    PlayerProvider player,
  ) async {
    await PersonalFmWidgetActions.loadFm(kugou, kFmStations[stationIndex]);
    final songs = kugou.personalFmSongs;
    if (songs.isEmpty) return;
    await PersonalFmWidgetActions.playSong(kugou, player, stationIndex, songs.first);
  }

  /// 刷歌推荐。
  ///
  /// 顺序与发现页 `_play(index)`（discover_page.dart）完全一致，两条都是踩出来的：
  /// 1. **先起播再 arm**。补货器靠识别「当前队列是不是刷歌来的」决定留场，
  ///    队列在 [PlayerProvider.playOnlinePlaylist] 里落地，顺序反了它会把
  ///    currentSong 还停在上一首的队列当成别人的直接退场。
  /// 2. **必须立刻补一批**。PlayerProvider 一次只把当前这一首灌进
  ///    audio_service，不补的话播到队尾就停，「刷歌」退化成「听四首就完事」。
  /// 3. **播放源取 provider 的权威列表快照**（homeDiscoverSongsAsSongs），
  ///    不存本地副本，补货器追加的新歌才能进队列。
  /// 之后队列的提前补货 / 播完补货 / 停摆自愈全部由 [HomeDiscoverRefill]
  /// 接管（它不依赖 UI，生命周期跟 App 走，冷启动场景正好合适）。
  static Future<void> _playHomeDiscover(
    KugouProvider kugou,
    PlayerProvider player,
  ) async {
    await kugou.getHomeDiscover();
    final songs = kugou.homeDiscoverSongsAsSongs;
    if (songs.isEmpty) return;
    await player.playOnlinePlaylist(songs, 0);
    final refill = HomeDiscoverRefill.arm(kugou, player);
    if (refill == null) return;
    await refill.append();
  }

  /// 仅供测试：重置一次性保护。
  @visibleForTesting
  static void debugReset() => _started = false;
}
