import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/models/song.dart';
import '../../providers/favorites_provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import 'media_notification_service.dart';

/// vivo 原子随身听（vivomusicmix）列表快照推送与点播回调。
///
/// 岛（com.vivo.musicwidgetmix）在能力位放行后，会经 MediaBrowserServiceCompat
/// 绑定取三棵列表树（岛面板标签为「播放列表 / 收藏列表 / 下载列表」；
/// 本 App 对应「当前队列 / 云端收藏 / 本地音乐」）。原生侧只读内存快照，
/// 由本类把 Dart 侧三份列表（去抖 + 内容指纹去重 + 条数上限）推送过去；
/// 同时承接岛端点播回调，按 `<来源>:<songId>` 稳定寻址回播。
///
/// v40 修复（第六轮独立审查）：
/// - attach 改为"换绑"语义：重复 attach 会先摘旧监听再绑新 provider，引擎重建
///   （AppViewState 重建窗口）后不再推送陈旧数据，也不阻止旧 provider 回收；
/// - 补 dispose 路径（去抖 Timer 取消、监听摘除、点播回调置空）；
/// - 内容指纹去重：三棵树的 id 串没变就不推（对齐 FmWidgetSync 的闸门）；
/// - 本地列表截断（[_localCap]）：设备级媒体库可达数千首，全量推送会把 UI
///   isolate 与原生主线程都拖住；岛分页每页 50，截断不影响浏览体验；
/// - 标题统一 [Song.displayName]（与 App 其它展示点一致，剥离 .mp3 等后缀）；
/// - payload 带 [Song.id]：原生 media id 用稳定键寻址，不受队列插删漂移影响；
/// - attach 时主动 [LibraryProvider.loadSavedSongs]（读缓存幂等）——否则用户
///   不进"本地音乐"页时该树恒空。
class VivoMixSync {
  VivoMixSync._();

  static final VivoMixSync instance = VivoMixSync._();

  /// 本地列表推送上限（对齐岛端分页深度；避免全库过通道）。
  static const int _localCap = 500;

  PlayerProvider? _player;
  FavoritesProvider? _favorites;
  LibraryProvider? _library;
  Timer? _debounce;
  String? _lastPayloadFingerprint;

  /// v50：状态回显去重（循环模式 / 当前曲红心）。
  int? _lastLoopMode;
  bool? _lastIsFav;
  // MD3Music fork v64: 当前曲 id 也进去重闸门（换曲要重推红心态）。
  String? _lastSongId;

  /// App 首帧后调用（provider 均已创建）；重复调用为换绑（引擎重建场景）。
  void attach({
    required PlayerProvider player,
    required FavoritesProvider favorites,
    required LibraryProvider library,
  }) {
    _detachListeners();
    _player = player;
    _favorites = favorites;
    _library = library;
    player.addListener(_schedule);
    favorites.addListener(_schedule);
    library.addListener(_schedule);
    MediaNotificationService.onVivoMixPlay = _handleVivoMixPlay;
    MediaNotificationService.onVivoMixPlayMode = _handleVivoMixPlayMode;
    // MD3Music fork v64：岛 ❤️ 收藏（目标态）回调。
    MediaNotificationService.onVivoMixRating = _handleVivoMixRating;
    debugPrint('[VivoMixSync] attach: player=${player.hashCode} '
        'fav=${favorites.hashCode} lib=${library.hashCode}');
    // 本地库默认懒加载（只有进"本地音乐"页才读）——主动补一次缓存读取，
    // 让岛上的本地列表树（面板标签「下载列表」）在冷启动后也有内容。
    unawaited(library.loadSavedSongs());
    // MD3Music fork v65：收藏树同样主动拉云端「我喜欢」整表——FavoritesProvider
    // 的 _favorites 只装 App 内点过红心的歌（云端收藏仅同步 id 集合），不主动拉
    // 就会表现为岛上"收藏列表"只有测试收藏的那几首（真机 21 首只显示 1 首）。
    unawaited(favorites.loadCloudFavoriteSongs());
    _schedule();
  }

  /// App 退出/引擎重建时解绑（app.dart 的 dispose 会调用）。
  void dispose() {
    _detachListeners();
    _debounce?.cancel();
    _debounce = null;
    _player = null;
    _favorites = null;
    _library = null;
    if (MediaNotificationService.onVivoMixPlay == _handleVivoMixPlay) {
      MediaNotificationService.onVivoMixPlay = null;
    }
    if (MediaNotificationService.onVivoMixPlayMode == _handleVivoMixPlayMode) {
      MediaNotificationService.onVivoMixPlayMode = null;
    }
    // MD3Music fork v64: 收藏回调同样要摘干净（换绑/引擎重建不留旧闭包）。
    if (MediaNotificationService.onVivoMixRating == _handleVivoMixRating) {
      MediaNotificationService.onVivoMixRating = null;
    }
  }

  void _detachListeners() {
    _player?.removeListener(_schedule);
    _favorites?.removeListener(_schedule);
    _library?.removeListener(_schedule);
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _push);
  }

  void _push() {
    final player = _player;
    final favorites = _favorites;
    final library = _library;
    if (player == null || favorites == null || library == null) return;

    final currentSongs = player.playlist;
    // MD3Music fork v65：收藏树 = 云端「我喜欢」整表 + App 内红心（按 id 去重），
    // 不能直接用 favorites.favorites（那只有 App 内点过红心的歌）。
    final favoriteSongs = favorites.favoritesForBridge;
    final localSongs = library.allSongs.take(_localCap).toList(growable: false);

    // 内容指纹：三棵树的 id 串未变就不推（高频 notify 下免重复编码/IPC）。
    final fingerprint = _fingerprint(currentSongs) + '|'
        + _fingerprint(favoriteSongs) + '|'
        + _fingerprint(localSongs);
    // v50：状态回显必须在指纹闸门**之前**——切循环模式/红心时列表指纹不变，
    // 放在闸门后会被提前 return 吞掉（岛上按钮状态就永远不更新）。
    _pushState(player, favorites);
    // v51：冷启动队列/收藏未恢复时的全空快照不推——岛会先拉到空树显示
    // "暂无歌曲"，队列就绪的下一份推送又刷回（真机实测偶现抖动）。
    if (currentSongs.isEmpty && favoriteSongs.isEmpty && localSongs.isEmpty) {
      return;
    }
    if (fingerprint == _lastPayloadFingerprint) {
      debugPrint('[VivoMixSync] push skipped: current=${currentSongs.length} '
          'fav=${favoriteSongs.length} local=${localSongs.length}');
      return;
    }
    _lastPayloadFingerprint = fingerprint;
    debugPrint('[VivoMixSync] push: current=${currentSongs.length} '
        'fav=${favoriteSongs.length} local=${localSongs.length}');

    // ignore: discarded_futures
    MediaNotificationService.updateVivoMixLists(
      current: currentSongs.map(_toMap).toList(growable: false),
      favorites: favoriteSongs.map(_toMap).toList(growable: false),
      local: localSongs.map(_toMap).toList(growable: false),
    );
  }

  /// v50：状态回显（循环模式 + 当前曲红心）——岛只认 metadata，变化即推。
  /// 与列表共用去抖（provider 任一变化都会触发 _push）；值没变就不推。
  void _pushState(PlayerProvider player, FavoritesProvider favorites) {
    final loopMode = player.roomPlayModeValue;
    final song = player.currentSong;
    final isFav = song == null ? null : favorites.favoriteIds.contains(song.id);
    // MD3Music fork v64: 曲目 id 进闸门——A->B 两首都已收藏时 isFav 不变，但 B 的
    // metadata 不带 RATING（红心写在上一首的 item 上），岛上红心会停在旧曲。
    final songId = song?.id;
    if (loopMode == _lastLoopMode &&
        isFav == _lastIsFav &&
        songId == _lastSongId) {
      return;
    }
    _lastLoopMode = loopMode;
    _lastIsFav = isFav;
    _lastSongId = songId;
    debugPrint('[VivoMixSync] pushState: loop=$loopMode isFav=$isFav song=$songId');
    // ignore: discarded_futures
    MediaNotificationService.updateVivoMixState(
        loopMode: loopMode, isFav: isFav);
  }

  String _fingerprint(List<Song> songs) =>
      songs.length.toString() + ':' + songs.map((s) => s.id).join(',');

  Map<String, dynamic> _toMap(Song song) => {
        'id': song.id,
        'title': song.displayName,
        'artist': song.artist,
        'album': song.album,
        'artworkUri': song.artworkUri,
        'durationMs': song.duration.inMilliseconds,
      };

  /// 岛端点播：media id 两种口径——`<来源>:<songId>`（收藏/本地树）或
  /// `title|artist`（当前播放树，v41 起与岛高亮匹配口径一致）。按来源找 Song
  /// 后交 PlayerProvider 播放；找不到则放弃（快照未覆盖的条目宁可无响应也不
  /// 模糊匹配错歌）。
  /// v61：**game 改队列定位**——`title|artist` 树本来就是当前队列的镜像，点哪
  /// 首就 `playSongAt` 定位到队列下标；此前用 `playSong` 的"单击列表单播"语义
  /// 会把整个队列替换成 [song]，播放列表瞬间只剩一首（v60 真机实测）。收藏/
  /// 本地树仍是"把这首歌播起来"的语义，队列不在当前队列里则照旧 playSong。
  Future<void> _handleVivoMixPlay(String mediaId) async {
    final player = _player;
    final favorites = _favorites;
    final library = _library;
    debugPrint('[CardLyricLink] vivoMixPlay: $mediaId');
    if (player == null || favorites == null || library == null) return;

    Song? song;
    final sep = mediaId.indexOf(':');
    final hasKnownPrefix = sep > 0 &&
        (mediaId.startsWith('queue:') ||
            mediaId.startsWith('fav:') ||
            mediaId.startsWith('local:'));
    var fromCurrentTree = false;
    if (hasKnownPrefix) {
      final source = mediaId.substring(0, sep);
      final songId = mediaId.substring(sep + 1);
      switch (source) {
        case 'queue':
          song = player.playlist.where((s) => s.id == songId).firstOrNull;
          fromCurrentTree = true;
        case 'fav':
          // v65：收藏树含云端整表，必须在同一份合并视图里反查，否则云端收藏的歌
          // 点播必然"找不到"（favorites.favorites 里没有它们）。
          song = favorites.favoritesForBridge
              .where((s) => s.id == songId)
              .firstOrNull;
        case 'local':
          song = library.allSongs.where((s) => s.id == songId).firstOrNull;
      }
    } else {
      // `title|artist` 口径：与岛识别"正在播放"的身份一致。
      final pipe = mediaId.indexOf('|');
      if (pipe <= 0 || pipe + 1 >= mediaId.length) return;
      final title = mediaId.substring(0, pipe);
      final artist = mediaId.substring(pipe + 1);
      song = player.playlist
          .where((s) => s.displayName == title && s.artist == artist)
          .firstOrNull;
      fromCurrentTree = true;
    }
    if (song == null) {
      debugPrint('[CardLyricLink] vivoMixPlay: no match for $mediaId');
      return;
    }
    debugPrint('[CardLyricLink] vivoMixPlay: play ${song.displayName}');
    if (fromCurrentTree) {
      // 当前队列镜像：定位下标播放，不替换队列。
      final index = player.playlist.indexWhere((s) => s.id == song!.id);
      if (index >= 0) {
        await player.playSongAt(index);
        // v63：起播后主动刷新岛列表——列表内容没变时岛不会自己重渲染，
        // 高亮停在旧项要等 3~5 秒（真机实测）。刷新一次让高亮立即跟随。
        unawaited(MediaNotificationService.refreshVivoMixChildren());
        return;
      }
      // 队列定位失败（快照与队列漂移）：退回单播保证"至少能播"。
    }
    await player.playSong(song);
    // v63：同上（收藏/本地树点播也把岛列表刷新到最新高亮状态）。
    unawaited(MediaNotificationService.refreshVivoMixChildren());
  }

  /// MD3Music fork v64: 岛 heart 收藏（目标态）。
  ///
  /// 直接用 provider，不经 navigator 上下文：App 未起界面时（只有后台引擎）
  /// 走 UI 上下文那条链取不到 provider，表现为岛上点红心毫无反应。
  /// 用 toggleFavorite（而不是 removeFavorite）：toggle 会同步酷狗云端
  /// 「我喜欢」歌单，取消收藏也要删云端记录，removeFavorite 只动本地库。
  Future<void> _handleVivoMixRating(bool favorite) async {
    final player = _player;
    final favorites = _favorites;
    if (player == null || favorites == null) return;
    final song = player.currentSong;
    if (song == null) return;
    final isFav = favorites.favoriteIds.contains(song.id);
    if (isFav == favorite) return; // 已是目标态，无需变更
    debugPrint('[VivoMixSync] vivoMixRating: favorite=$favorite song=${song.id}');
    await favorites.toggleFavorite(song);
  }

  /// v45：岛循环模式切换（1=列表 / 2=单曲 / 3=随机）→ setLoopMode/setShuffle。
  Future<void> _handleVivoMixPlayMode(int mode) async {
    final player = _player;
    if (player == null) return;
    debugPrint('[CardLyricLink] vivoMixPlayMode: $mode');
    switch (mode) {
      case 3:
        await player.setLoopMode(AppLoopMode.all);
        await player.setShuffle(true);
      case 2:
        await player.setShuffle(false);
        await player.setLoopMode(AppLoopMode.one);
      default:
        await player.setShuffle(false);
        await player.setLoopMode(AppLoopMode.all);
    }
  }
}
