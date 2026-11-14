import '../../core/utils/lyric_timeline.dart';
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui';

import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/platform_capabilities.dart';
import '../../core/remote/tv_hint_bar.dart';
import '../../core/remote/tv_menu_key_shortcuts.dart';
import '../../core/remote/tv_player_back_focus.dart';
import '../../core/layout/responsive_layout.dart';
import '../../core/layout/display_space.dart';
import '../../core/remote/remote_slider.dart';
import '../../core/services/audio_service.dart';
import '../../core/services/desktop_lyric_service.dart';
import '../../core/services/depth_cover_feature.dart';
import '../../core/services/dynamic_cover_service.dart';
import '../../core/services/equalizer_service.dart';
import '../../core/services/media_notification_service.dart';
import '../../core/services/music_haptics_service.dart';
import '../../core/services/spectrum_service.dart';
import '../../core/services/stem_separation_service.dart';
import '../../core/services/windows_fullscreen.dart';
import '../../core/services/windows_window_controls.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/widgets/windows_caption_buttons.dart';
import '../../core/utils/local_lyric_loader.dart';
import '../../core/utils/app_haptics.dart';
import '../../main.dart';
import '../../core/utils/app_toast.dart';
import '../../widgets/add_to_playlist_dialog.dart';
import '../../widgets/player_top_bar_actions.dart';
import '../../widgets/player_top_bar_tab_dots.dart';
import '../../widgets/depth_cover_host.dart';
import '../../widgets/marquee_text.dart';
import '../../widgets/player_dock/tv_player_edge_action.dart';
import '../../core/utils/artwork_color_extractor.dart';
import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/depth_cover_service.dart';
import '../album/album_detail_page.dart';
import '../artist/artist_detail_page.dart';
import '../coverflow/coverflow_page.dart';
import '../library/song_match_sheet.dart';
import '../listen_together/widgets/listen_together_trailing.dart';
import '../settings/equalizer_settings_page.dart';
import '../sheet/song_sheet_sheet.dart';
import '../sound/sounds_page.dart';
import 'mv_player_page.dart';
import 'accompany_toggle.dart';
import 'widgets/low_res_blur.dart';
import 'audio_quality_dialog.dart';
import 'sleep_timer_sheet.dart';
import 'speed_picker_sheet.dart';
import 'song_info_page.dart';
import 'am_artist_photo_cover.dart';
import 'am_transport_controls.dart';
import '../../providers/favorites_provider.dart';
import '../../data/repositories/song_match_repository.dart';
import '../../providers/song_match_provider.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/local_favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../providers/comment_display_provider.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../widgets/apple_lyrics/apple_lyrics_view.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences_panel.dart';
import '../../widgets/flowing_background.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import '../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import '../../widgets/apple_lyrics/utils/lyric_credit_filter.dart';
import '../../widgets/ai_recommend_sheet.dart';
import '../../widgets/menu_action_cell.dart';
import '../../widgets/dynamic_cover_view.dart';
import '../../widgets/player_artwork_image.dart';
import '../../widgets/player_seek_bar.dart';
import '../../widgets/player_tab_strip.dart';
import '../../widgets/tv_player_tab_bar.dart';
import '../../widgets/player_dock/dock_skin.dart';
import '../../widgets/player_dock/player_control_dock.dart';
import '../../widgets/player_dock/zen_fade.dart';
import '../../widgets/player_volume_bar.dart';
import '../../widgets/spectrum_artwork.dart';
import '../../widgets/spectrum_background.dart';
import '../../utils/landscape_immersive.dart';
import '../../widgets/player_playlist_view.dart';
import '../../widgets/playback_hint_pills.dart';
import '../../widgets/playback_status_feedback.dart';
import 'car_mode_exit.dart';
import '../../services/kugou_api/comment_reply_target.dart';
import 'comment_compose_sheet.dart';
import 'comments_view.dart';
import 'dlna_cast_sheet.dart';
import 'full_player_route.dart';
import 'lyric_flight_batcher.dart';
import 'playback_center_sheet.dart';
// 只引入形变槽位：PlayerCoverSlot 内部转发到 player_cover_morph.dart 的登记簿，
// 本文件不直接用登记簿或纯函数，少引一个包就少一条 unused_import。
import 'player_cover_morph.dart';
import 'player_cover_shadow.dart';
import 'player_cover_morph_layer.dart';
import 'cover_switch_physics.dart';
import 'player_page_role.dart';
import 'player_zen_bridge.dart';
import 'widgets/cover_flip_crossfade.dart';
import 'widgets/edge_fade_mask.dart';
import 'widgets/song_danmaku_host.dart';
import 'player_tab_layout.dart';
import 'player_tab_pager.dart';
import 'player_volume_state.dart';
import 'player_wide_pane.dart';
import 'playlist_swipe_driver.dart';

/// 预加载封面图片到磁盘缓存，防止切换时白屏
void _preloadArtwork(String? url) {
  preloadPlayerArtwork(url);
}

/// 翻译/罗马音按钮图标四周的透明安全区（每边像素）。
///
/// 歌词区用 TapUp 计算命中行，无 hit slop：点在按钮边缘但落在按钮外时
/// 会穿透到歌词并跳转行。这里给按钮外扩一圈自身的透明热区吸收点击，
/// 使「想点按钮却点偏」不再误触发寻址。
const double _kTranslateTogglePadding = 8;

class AmStyleFullPlayer extends StatefulWidget {
  static void Function(BuildContext context, dynamic song)?
  coverLongPressCallback;

  /// 车机模式：开启后播放器以常驻面板（由 CarModePanel 承载）形式嵌入任意界面，
  /// 不可收起、不显示 MiniPlayer。
  /// 语义与 FullPlayer.dockMode 完全一致（不可收起 / 不接管系统栏 /
  /// 禁用 Zen 与横屏沉浸 / 整页跳转走根 Navigator / tab 结构恒按窄屏）。
  /// 默认 false，既有 `const AmStyleFullPlayer()` 调用点不受影响。
  final bool dockMode;

  const AmStyleFullPlayer({super.key, this.dockMode = false});

  @override
  State<AmStyleFullPlayer> createState() => _AmStyleFullPlayerState();
}

class _AmStyleFullPlayerState extends State<AmStyleFullPlayer>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  /// Windows 顶栏右上角窗口三键的最小可用宽度（口径与 MD3 版一致）：
  /// 再窄就退回「更多」菜单里的同名三项，避免 Row 溢出。
  static const double _kTopBarCaptionMinWidth = 400;

  late TabController _tabController;

  /// 播放列表 tab 左滑跟手的驱动（见 playlist_swipe_driver.dart）。
  /// 真正执行的是 [_pagerKey] 指向的 pager，本类只负责把面板上报的进度
  /// 换算成页位置。driver 不持有任何时钟，故可安全用 late final 惰性构造。
  late final PlaylistSwipeDriver _playlistSwipe = PlaylistSwipeDriver(
    readPage: () => _pagerKey.currentState?.page ?? 0,
    jumpToPage: (page) => _pagerKey.currentState?.jumpToPage(page),
    animateToPage: (page, duration, curve) => _pagerKey.currentState
        ?.animateToPage(page, duration: duration, curve: curve),
  );

  /// 内容区 pager 的句柄。三个布局分支（竖屏 / 横屏 / Pad）里各有一处
  /// PlayerTabPager，但同一时刻只会构建其中之一，因此单 key 足够。
  final GlobalKey<PlayerTabPagerState> _pagerKey =
      GlobalKey<PlayerTabPagerState>();

  /// 播放列表的滚动归属（控制器 + 「为哪首歌定位过」）：面板会被 PageView
  /// 连子树一起销毁（cacheExtent=0），所以这份状态必须活在面板之外。
  /// 三个布局分支同一时刻只构建其中之一，共用一份是安全的。
  final PlaylistScrollAnchor _playlistScroll = PlaylistScrollAnchor();

  /// 播放列表面板的句柄：返回键要问它「是否在编辑模式」。
  /// 与 [_pagerKey] 同一口径 —— 三个布局分支各有一处 PlayerPlaylistView，
  /// 同一时刻只构建其中之一，故单 key 足够。
  final GlobalKey<PlayerPlaylistViewState> _playlistKey =
      GlobalKey<PlayerPlaylistViewState>();

  /// 导航条一段的宽度：导航条拖动「一段 = 一页」，用它作位移换算的除数。
  double _tabDragBtnW = 0;

  /// 宽屏「控制」页手势锁：进度条/音量条是水平拖动，按下期间锁掉
  /// PageView 横滑，防止滑条与切页抢手势。由滑条那一行的 Listener
  /// （[_lockSliderRowSwipe]）置位复位；**只罩滑条行**，控制页其他地方仍要能滑。
  final ValueNotifier<bool> _controlsPageGestureLock = ValueNotifier<bool>(
    false,
  );
  // Apple Music 风格歌词：已解析的 LyricLine 列表，由 LyricParserChain.parse 产出
  // （经「屏蔽歌词作者信息」过滤后的显示列表）
  List<LyricLine> _parsedLyrics = const [];
  /// 未经过滤的完整解析结果：过滤开关/正则在设置页变化时由此即时重派生，
  /// 无需重新取词或切歌。副行可用性（hasTranslation/hasRoma）也以本列表判定，
  /// 避免名单行被滤掉后误判「无翻译」。
  List<LyricLine> _parsedLyricsRaw = const [];
  /// 上次派生 [_parsedLyrics] 时的过滤开关/正则快照：仅在这两项变化时才重派生，
  /// 避免字号等无关偏好通知反复打穿 AppleLyricsView 的行缓存。
  bool _derivedFilterEnabled = false;
  String _derivedFilterPattern = '';
  bool _isLoadingLyrics = false;

  /// 歌词类提交的转场排队器：转场窗口内排队、落位后一次性应用（见 [LyricFlightBatcher]）。
  late final LyricFlightBatcher _lyricBatcher =
      LyricFlightBatcher(isHostMounted: () => mounted);
  String? _lastSongId;

  /// 歌词已获取时歌曲的元数据键（id:秒时长:albumAudioId）。
  /// 一起听跟随端起播时只有 hash 身份（时长 0、无 albumAudioId），
  /// 富化回写保持 id 不变——仅按 id 判重会让歌词永远停在「未知歌曲」占位；
  /// 元数据键变化（补齐时长/专辑 id）后强制重取一次（对齐 EchoMusic
  /// lastForcedLyricMetadataKey）。
  String _lastLyricMetadataKey = '';
  // 当前歌词格式（KRC / LRC / plaintext），用于底部标注；null 表示尚未检测
  LyricFormat? _lyricFormat;
  // 当前歌曲是否有翻译/罗马音数据，用于 ActionBar 长按切换模式判断
  bool _hasTranslation = false;
  bool _hasRoma = false;

  // 背景（模糊大图）淡入淡出动画。封面自身的切歌过渡已改为
  // 「模糊 + 纵轴翻转」（见 widgets/cover_flip_crossfade.dart 的
  // CoverFlipCrossfade），以下字段只为背景交叉淡服务。
  late final AnimationController _artworkFadeController;
  Animation<double>? _pendingEntryAnimation;
  late final Animation<double> _artworkFadeAnimation;
  String? _previousArtworkUrl;

  /// 上一次切歌时的播放列表下标：用于判定封面翻转方向（下一曲/上一曲镜像）。
  int? _lastCoverFlipIndex;

  /// 当前翻转方向系数（+1 下一曲方向 / -1 上一曲方向）；方向不明时沿用上次。
  int _coverFlipDirection = 1;

  /// 相邻曲目封面预载的错峰 Timer（翻转窗口结束后才跑，见 _onPlayerSongChanged）。
  Timer? _preloadNeighborTimer;

  /// 歌手写真拉取与轮播调度（见 [ArtistPhotoController]）。
  /// 写真不再作为页面背景，只渲染在封面位置（竖屏专辑 tab / 横屏与平板左栏）。
  final ArtistPhotoController _photoController = ArtistPhotoController();

  /// 已排期到下一帧的写真 hash：build 内只比对与排期，
  /// setHash 真正在 post-frame 执行——它内部的 notifyListeners 若发生在
  /// build 期间会触发 setState-during-build（与 _previousArtworkUrl 的
  /// 「build 改字段不 setState」是同一约束）。
  String _photoScheduledHash = '';

  /// 已应用到轮播定时器的间隔（秒）。设置页改「轮播间隔」后，播放中也要即时
  /// 生效——比对它决定是否重起定时器（见 [_buildFullLayout]）。
  int _photoIntervalApplied = 0;

  // 桌面歌词状态监听：长按歌词按钮 toggle 后同步 icon
  late final VoidCallback _onDesktopLyricChanged;

  // 动态字体颜色：从专辑封面提取的主色（歌词当前行按「混色比例」与白色混色用）
  Color? _lyricAccentColor;
  String? _lastAccentUrl;

  /// 当前生效的 tab 结构（含封面 tab / 含评论 tab）。
  /// TabController.length、TabBarView.children、底部导航条 items 全部由它派生；
  /// 任一输入变化（屏幕宽度、切歌、设置开关）都必须先调用 [_syncTabLayout]
  /// 重算，保证三者始终一致。
  PlayerTabLayout _tabLayout =
      (hasCover: true, hasComments: true, hasControls: false);

  // === 顶栏向下拖拽收起：与 MiniPlayer 上滑展开镜像的手势，仍然存在
  //     （状态字段见下方 _topBarDrag*，处理见 _onTopBarDrag*）。
  //     仍然成立的布局约束：顶栏为无把手单行布局，故除拖拽外另有
  //     返回按钮 / 系统返回键作为收起入口。 ===
  /// 防止 PopScope 回调与 dismiss() 重复触发。
  bool _isDismissing = false;

  /// 拖拽展开模式下的源路由：展开完成前延迟应用沉浸模式，
  /// 避免拖动过程系统栏提前切换造成闪烁。
  DraggablePlayerRoute? _dragRoute;

  /// 系统栏/沉浸模式初始化是否已完成。
  /// 需在 [didChangeDependencies] 中执行一次（[ModalRoute.of] 依赖
  /// `_ModalScopeStatus` inherited widget，initState 阶段不可用）。
  bool _systemUiInitialized = false;

  /// 本页当前的身份，见 [PlayerPageRole]。显式 [PlayerPageRoleScope] 优先，
  /// 没标注时由 `PlayerPageRole.of` 退回旧推导（`ModalRoute` 缺失 + 拖拽激活），
  /// 所以本步改动与之前逐位等价；`dormant` 留给常驻预建那一步使用。
  PlayerPageRole get _pageRole => PlayerPageRole.of(context);

  /// 是否为拖拽覆盖层（非路由）场景：拖拽期间由 Navigator 之上的
  /// PlayerDragOverlay 渲染，无 ModalRoute；系统栏与收起行为需走覆盖层逻辑。
  bool get _isDragOverlay => _pageRole == PlayerPageRole.dragOverlay;

  /// 封面是否为圆形（旋转圆盘）：仅在开启频谱且样式为柱状(0)/曲线(1)时成立，
  /// 其余情况为圆角方形。圆盘时横屏/平板标题居中，方形时左对齐（见改版计划）。
  ///
  /// 读**同步镜像** [kSpectrumDiscCoverActive] 而非本页的 `_spectrumEnabled`：
  /// 跟手覆盖层里的播放页是当场新建的，首帧（0<p<1，资格正在锁存）自己的偏好
  /// 必然还没读到。镜像由 bootstrap 预热、频谱偏好读写时维护。
  bool get _isDiscCover => kSpectrumDiscCoverActive;

  /// 是否已修改过系统栏（沉浸模式）。
  /// 覆盖层（非路由）场景从未修改，dispose 时无需恢复系统栏。
  bool _systemUiModified = false;

  // ── 顶栏向下拖拽收起状态（与上滑展开镜像） ──
  DraggablePlayerRoute? _topBarDragRoute; // 正在拖拽的路由
  double _topBarDragDistance = 0.0; // 向下累计距离（px，≥0）
  double _topBarDragTotal = 0.0; // 完整收起距离（px）
  double? _topBarDragLastY; // 上次 Y（速度估计用）
  Duration? _topBarDragLastTime;
  double _topBarDragVelocity = 0.0; // 向下速度 px/s

  /// 上次的物理尺寸，用于 didChangeMetrics 方向变化防抖。
  /// 避免 immersiveSticky 下用户触摸边缘唤醒系统栏等 insets 抖动
  /// 引发无效的 applyImmersiveForOrientation 调用导致系统栏闪烁。
  Size? _lastPhysicalSize;

  // ── Zen Mode：长按专辑封面进入/退出沉浸模式 ──
  bool _zenMode = false;

  /// Zen 下单击封面唤出 chrome 的停留时长：这段时间内不透明度一路线性降到
  /// [_zenPeekEndDim]，抵达的那一刻即收回（计划 §2.2 ③）。
  static const Duration _zenPeekDuration = Duration(seconds: 4);

  /// 上述停留的倒计时 + 渐隐斜坡的节拍：每 tick 既推进一档不透明度，也在末档
  /// 收回 Zen；dispose 与退出 Zen 两处都要 cancel。
  Timer? _zenPeekTimer;

  /// peek 期间 chrome 的额外压暗因子：1.0 = 不压暗， [_zenPeekDuration] 内线性降到 [_zenPeekEndDim]。
  final ValueNotifier<double> _zenChromeDim = ValueNotifier<double>(1.0);

  /// 渐隐终点：不透明度降到 20% 的同一刻恢复 Zen（余下由 ZenFade 的 400ms 补到 0）。
  static const double _zenPeekEndDim = 0.2;

  /// 斜坡节拍：100ms 一档，四秒 40 档，每档 Δ0.02 看不出阶梯（AGENTS §10.2 选档判据）。
  static const Duration _zenPeekInterval = Duration(milliseconds: 100);

  // Duration 没有 Duration ~/ Duration 运算符（只有 Duration ~/ int），故按毫秒整除。
  int get _zenPeekSteps =>
      _zenPeekDuration.inMilliseconds ~/ _zenPeekInterval.inMilliseconds;
  int _zenPeekStep = 0;

  /// 长按封面进入 Zen 模式开关（设置→播放，默认开启；关闭后禁用长按）
  bool _zenLongPressEnabled = true;

  /// 本趟 Zen 是否由本页把窗口切成全屏（Windows）。
  ///
  /// 右键封面进入的是「只淡出 Flutter 侧 chrome、窗口尺寸/位置/最大化态一律不动」
  /// 的沉浸，不调 `WindowsFullscreen.enterZen()`，因此没有快照可恢复。
  /// 但 peek（单击封面唤出 chrome）4 秒后会自动重新进 Zen —— 那次必须沿用**本趟**
  /// 取值，否则右键进的沉浸会在 4 秒后突然把窗口撑成全屏。
  /// 用「本趟」而非「上一次的残值」：长按 / F11 每次进入都显式传 true，
  /// 不会把右键那次的 false 泄漏给下一次手势。
  bool _zenWindowFullscreen = true;

  /// Windows F11 → Zen 的桥回调（注册/注销要同一个引用，故存字段）。
  late final bool Function() _zenToggleHandler = _f11ToggleZen;

  // 专辑动态封面开关（设置页「播放页样式」与播放页「界面设置」共用；默认开启）
  bool _dynamicCoverEnabled = true;

  /// 播放页「界面设置」里「当前歌曲动态封面」的展示值（null = 检测中）
  ///
  /// 刻意**不在 dispose() 里销毁**：二级菜单挂在根 Navigator 上，可能比本 State
  /// 活得更久（如车机模式切换导致播放器被销毁时菜单仍开着），销毁后菜单关闭时
  /// `removeListener` 会命中「used after being disposed」断言。不销毁则菜单关闭后
  /// notifier 与监听者一起变成垃圾被回收。
  final ValueNotifier<String?> _dyCoverStatus = ValueNotifier<String?>(null);
  late final AnimationController _zenController;
  late final Animation<double> _zenAnimation;

  // ── Zen 长按专辑封面（进入 / 退出）──
  /// 长按封面切换 Zen 模式所需时长（进入与退出一致）。
  static const Duration _zenPressDuration = Duration(milliseconds: 2000);

  /// 提示层开始淡入的进度点（≈500ms，与系统长按识别时机对齐）。
  static const double _zenHintStart = 0.25;

  /// 判定为滑动手势（切 tab / 拖拽）而取消长按的指针位移阈值（px）。
  static const double _zenPressSlop = 18.0;

  /// 按压进度 0→1：驱动封面内缩、提示层淡入与进度环；跑满即切换 Zen 模式。
  late final AnimationController _zenPressController;

  /// 提示层淡入时的轻震是否已触发（每次长按只震一次）。
  bool _zenHintHapticFired = false;

  /// 本次按压是否已进入长按引导阶段：松手不再当作点击（否则封面 tab 的
  /// onTap 会把长按当点击、跳到歌词页）。Listener 不参与手势竞技场，
  /// 只能由封面 tab 的 onTap 主动放弃这一次点击。
  bool _zenPressConsumedTap = false;

  /// 按下时的指针全局位置；null 表示当前没有长按在进行。
  Offset? _zenPressOrigin;

  // ── 封面连贯形变（与 MiniPlayer 交接） ──
  /// **文字**连贯是否接管本次转场（歌名 / 艺人从迷你条飞进播放页）。
  ///
  /// 只放**结构性**、转场期间不会变、且**同步可读**的条件：
  /// - 车机常驻面板：不是全屏页，没有 MiniPlayer 可对位；
  /// - 封面此刻不可见（竖屏停在歌单 / 歌词 / 评论 tab，见下）。
  ///
  /// **刻意不含封面形状**：文字块与封面形状无关。频谱圆盘已经不再压制封面
  /// （见 [_coverMorphEligible]），但两者仍然**故意不同源**：写真只压封面一侧。
  ///
  /// 刻意不含「3D 深度封面 / 动态封面视频是否已就绪」：它们是挂载后才异步就绪的
  /// 位图 / 视频图层，实时求值会让形变半空中中断，加锁存又会在进入方向失效
  /// （详见 MD 侧 full_player.dart 同名 getter 的说明）。
  bool get _morphStructuralEligible =>
      !widget.dockMode &&
      // 封面此刻是否真的可见：
      // - 窄屏（手机竖屏）封面只在封面 tab 里。切到歌单 / 歌词 / 评论后封面并不
      //   显示，此时若还做形变，下拉收起就会「凭空飞出一个封面和歌名」。
      // - 宽屏（横屏 / 平板）没有封面 tab（`coverIndex == -1`），封面常驻左栏、
      //   与 tab 无关，永远可见，故不受此限。
      (_tabLayout.coverIndex < 0 ||
          _tabController.index == _tabLayout.coverIndex);

  /// **封面**连贯是否接管本次转场 = 结构条件 且 非写真。
  ///
  /// 写真画不出那张平面方图（整页换成出血的写真背景），只有封面一侧退出，文字
  /// 形变走 [_morphStructuralEligible]，不受影响（真机验收明确要求）。
  ///
  /// **频谱圆盘（style 0/1）不再压制封面**：圆盘形状由槽位上报的
  /// `settledInsetRatio` 与飞行层现算的终点唱片角（共享相位，见
  /// `SpectrumDiscSpin`）完整描述。改动前因为它"形变层只会画方图"而整体退出，
  /// 观感是圆盘模式下上滑完全没有封面动画（用户要求补上）。
  ///
  /// 圆盘判定读 [kSpectrumDiscCoverActive] 同步镜像决定**终点形状**（见
  /// [_coverMorphSettledInset]）：跟手覆盖层第一帧就在 0<p<1，本页的异步偏好还
  /// 没读到，形状判据必须同步可读。早前直接读本页的 `_spectrumEnabled`，覆盖层
  /// 首帧恒为 false，锁存把「频谱开着」误判成「落方图」，于是每次上滑都飞出方封面。
  bool get _coverMorphEligible => _morphStructuralEligible && !_photoWanted;

  /// 封面形变的**终点形状**：频谱圆盘时可见圆在槽位盒内单侧内缩
  /// [SpectrumArtwork.barReserveRatio]，其余（含 style 2 背景层）恒 0（方图）。
  ///
  /// 与 [_buildLandscapeArtworkContent] / [_buildArtworkView] 里 `_isDiscCover`
  /// 的分流同源：那两处决定真身画圆盘还是方图，这里必须给出同一答案。
  double get _coverMorphSettledInset =>
      _isDiscCover ? SpectrumArtwork.barReserveRatio : 0.0;

  /// 写真封面是否生效：开关开 + 在线歌曲写真已实际取到图（hash 由
  /// [_buildFullLayout] 排期同步，关开关/本地歌会被置空）。
  /// 缺一即回落方形封面，避免出现「写真没出来、封面也没了」的空屏。
  bool get _photoCoverActive =>
      _photoController.hasImages &&
      context.read<ThemeProvider>().useArtistPhotoBackground;

  /// 写真**功能意图**：开关开 + 在线歌曲（不要求已取到图）。
  ///
  /// 封面形变抑制用它而非 [_photoCoverActive]：拖拽转场由覆盖层的第二个
  /// State 实例渲染，其 setHash 在 post-frame 才跑——未缓存歌曲在转场起点
  /// hasImages=false，若按「已落地」抑制，专辑封面会先起飞、写真到达后
  /// 中途掐断（真机「上拉封面跟随一段时间」）。功能开着就一律不飞封面，
  /// 写真失败时方封面只走淡入淡出，行为一致。
  bool get _photoWanted => _photoScheduledHash.isNotEmpty;

  // 进度条拖动状态：记录拖动前是否正在播放，拖动结束后恢复
  bool _wasPlayingBeforeDrag = false;

  // ── 音乐频谱环绕显示 ──
  bool _spectrumEnabled = false;
  // 是否允许原生端挂 Visualizer 兜底（默认关闭）。关闭时走 PCM 截取，不需要录音权限
  bool _spectrumVisualizerFallback = false;
  bool _spectrumStarted = false;
  final Object _spectrumOwner = Object();
  // 频谱样式：0=柱状图(环绕)，1=曲线(环绕)，2=背景层(条形)
  int _spectrumStyle = 0;
  // 频谱背景层参数（仅 style=2 时使用）
  double _spectrumBgOpacity = 0.4;
  double _spectrumBgHeight = 0.4;
  // 环绕频谱透明度（style 0/1 分开记忆，默认不透明）
  double _spectrumBarOpacity = 1.0;
  double _spectrumCurveOpacity = 1.0;
  // 偏好读取前先关闭取色，避免启动期多发一次封面请求；读取后恢复用户设置。
  bool _spectrumDynamicColor = false;

  /// 频谱颜色：独立开关「频谱动态取色」开启且已提取到封面主色时，
  /// 用 50% 白 + 50% 取色混合（与歌词动态取色相同的兜底：抬升明度避免深色）；
  /// 否则用 AM 风格白色（动态取色仅 AM 播放器生效）。
  Color get _spectrumColor {
    final accent = _lyricAccentColor;
    if (_spectrumDynamicColor && accent != null) {
      final mixed = Color.lerp(Colors.white, accent, 0.5)!;
      final hsl = HSLColor.fromColor(mixed);
      return hsl.withLightness(math.max(hsl.lightness, 0.78)).toColor();
    }
    return Colors.white;
  }

  /// 当前频谱透明度（按样式分开记忆）
  double get _spectrumOpacity =>
      _spectrumStyle == 1 ? _spectrumCurveOpacity : _spectrumBarOpacity;

  @override
  void initState() {
    super.initState();
    if (kTvBuild && !widget.dockMode) {
      // tv: 注册全局返回键兜底（见 [TvPlayerBackFallback]）——焦点丢回路由
      // FocusScope 时页内拦截器收不到按键，由 `_handleTvBack` 在 pop 前咨询本页。
      TvPlayerBackFallback.instance.register(_tvHandleBackFallback);
    }
    // 音乐震动「播放页启用」范围以本页在场为准（含拖拽覆盖层实例；
    // 覆盖层与接管的页面路由可能短暂并存，服务侧用计数消化，勿改回布尔）。
    MusicHapticsService.instance.setPlayerPageActive(true);
    WidgetsBinding.instance.addObserver(this);
    // MD3Music fork v31：歌词命令口改注册集合（先注册的存活实例不再被
    // 后注册实例的注销挤掉，重放"进了但停的不是歌词页"即不会在拖拽
    // 路径复活）。
    registerPlayerLyricsCommand(_goDockLyrics);
    if (Platform.isWindows) {
      SettingsRepository.windowsLiveSettingsRevision.addListener(
        _reloadWindowsPlayerSettings,
      );
    }
    // 默认停在专辑 tab（index 1，播放列表 tab 在左侧）；
    // 但拖拽覆盖层里的是**另一个** FullPlayer 实例，必须从全局信号取下标，
    // 否则下拉时会把界面跳回封面 tab、并让形变资格误判「封面可见」。
    // 详见 [playerTabIndex] 的说明。
    _tabController = TabController(
      length: _tabLayout.length,
      vsync: this,
      initialIndex: playerTabIndex.value.clamp(0, _tabLayout.length - 1),
    );
    // 同步给全局信号；拖拽覆盖层据此从同一 tab 打开。
    _tabController.addListener(_publishMorphSignals);
    _publishMorphSignals();
    // 桌面歌词状态变化时刷新 UI（同步歌词按钮 icon）
    _onDesktopLyricChanged = () {
      if (mounted) setState(() {});
    };
    DesktopLyricService.instance.addListener(_onDesktopLyricChanged);
    // 动态字体颜色开关变化（设置页）时补提取封面主色
    LyricPreferences.instance.addListener(_onLyricPrefsChanged);
    // 「横屏控制面板独立页」开关变化（设置页）：宽屏 tab 结构随之增删控制页
    kLandscapeDetachedControlsEnabled.addListener(
      _onDetachedControlsSettingChanged,
    );
    // 「横屏左右对称分栏」开关变化（设置页）：宽屏左右栏 1:1 / 4:6 重新分
    // （分栏变化不影响 tab 结构，直接 setState 即可）。
    kSymmetricWidePaneEnabled.addListener(_onSymmetricPaneSettingChanged);
    // 「自定义宽屏边距」滑条变化（设置页）：宽屏左栏内衬（含顶栏尾部胶囊）
    // 重算，同样不影响 tab 结构，与对称分栏共用同一个 setState 回调。
    kWidePaneMarginOverride.addListener(_onSymmetricPaneSettingChanged);
    // 「忽略挖孔避让」开关变化（设置页）：宽屏挖孔对称补偿重算，共用 setState 回调。
    kWidePaneIgnoreCutoutEnabled.addListener(_onSymmetricPaneSettingChanged);
    _artworkFadeController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _artworkFadeAnimation = CurvedAnimation(
      parent: _artworkFadeController,
      curve: Curves.easeInOut,
    );
    _artworkFadeController.value = 1.0;
    _zenController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _zenAnimation = CurvedAnimation(
      parent: _zenController,
      curve: Curves.easeInOut,
    );
    _zenPressController = AnimationController(
      duration: _zenPressDuration,
      reverseDuration: const Duration(milliseconds: 220),
      vsync: this,
    )..addListener(_onZenPressProgress);
    // 记录初始物理尺寸，避免首次 didChangeMetrics 因 _lastPhysicalSize==null 误判方向变化
    _lastPhysicalSize =
        WidgetsBinding.instance.platformDispatcher.views.first.physicalSize;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncTabLayout();
      context.read<PlayerProvider>().addListener(_onPlayerSongChanged);
      PlayerZenBridge.instance.register(_zenToggleHandler);
      final route = ModalRoute.of(context);
      if (route is DraggablePlayerRoute && route.usesLightweightDesktopEntry &&
          route.animation?.status != AnimationStatus.completed) {
        _pendingEntryAnimation = route.animation
          ?..addStatusListener(_onEntryAnimationStatus);
        return;
      }
      _loadInitialPlayerContent();
    });
  }

  void _onEntryAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _pendingEntryAnimation?.removeStatusListener(_onEntryAnimationStatus);
    _pendingEntryAnimation = null;
    if (mounted) _loadInitialPlayerContent();
  }

  /// 避开 Windows AM 入场首帧集中解析歌词、回填设置引发的重建。
  /// 动画结束后读当前歌曲，不能使用点击时捕获的旧歌曲。
  void _loadInitialPlayerContent() {
      final song = context.read<PlayerProvider>().currentSong;
      if (song != null) {
        _fetchLyrics(song);
        // 登记初始下标：首次切歌的方向判定需要「从哪来」
        _lastCoverFlipIndex = context.read<PlayerProvider>().currentIndex;
      }
      _loadSpectrumSetting();
      _loadZenPressSetting();
      _loadDynamicCoverSetting();
      // 右栏边缘渐隐开关：读盘回填内存镜像（build 里经 ValueListenableBuilder
      // 订阅 SettingsRepository.amLandscapeEdgeFade，回填与后续修改均即时生效）。
      _loadEdgeFadeSetting();
      // Windows F11 → Zen：全局按键处理层经此回调找到本页（见 PlayerZenBridge）。
      // F11 命令口在首帧已注册，不必等待这些异步工作。
  }

  /// 从设置回填「横屏播放页边缘渐隐」内存镜像。
  /// getter 读盘后写回 [SettingsRepository.amLandscapeEdgeFade]，
  /// 订阅它的右栏遮罩随即刷新，无需 setState。
  Future<void> _loadEdgeFadeSetting() async {
    await SettingsRepository().getAmLandscapeEdgeFade();
  }

  /// 从设置加载「长按封面进入 Zen 模式」开关。
  Future<void> _loadZenPressSetting() async {
    final enabled = await SettingsRepository().getZenCoverLongPress();
    if (!mounted) return;
    setState(() => _zenLongPressEnabled = enabled);
  }

  /// 从设置加载「专辑动态封面」开关（默认开启）。
  Future<void> _loadDynamicCoverSetting() async {
    final enabled = await SettingsRepository().getDynamicAlbumCover();
    if (!mounted || enabled == _dynamicCoverEnabled) return;
    setState(() => _dynamicCoverEnabled = enabled);
  }

  void _reloadWindowsPlayerSettings() {
    _loadZenPressSetting();
    _loadDynamicCoverSetting();
  }

  /// 刷新「界面设置」菜单里的动态封面开关与当前歌曲状态。
  ///
  /// 顺带重读开关值（用户可能刚在设置页改过），保证菜单与设置一致；
  /// 状态优先用 [DynamicCoverService.lastKnownResult] 即时展示，
  /// 未探测过才发一次请求，失败时显示「未获取到」而不是「无」。
  Future<void> _refreshDyCoverMenuState() async {
    final player = context.read<PlayerProvider>();
    final song = player.currentSong;
    final isOnline = song is Song && song.isOnline;
    final albumAudioId = (song is Song ? song.albumAudioId : null) ?? '';

    await _loadDynamicCoverSetting();
    if (!mounted) return;

    if (!isOnline || albumAudioId.isEmpty) {
      _dyCoverStatus.value = dyCoverStatusText(
        isOnline: false,
        albumAudioId: '',
        known: null,
      );
      return;
    }

    final known = DynamicCoverService.instance.lastKnownResult(albumAudioId);
    if (known != null) {
      _dyCoverStatus.value = dyCoverStatusText(
        isOnline: true,
        albumAudioId: albumAudioId,
        known: known,
      );
      return;
    }

    _dyCoverStatus.value = dyCoverStatusText(
      isOnline: true,
      albumAudioId: albumAudioId,
      known: null,
      probing: true,
    );
    await DynamicCoverService.instance.hasDynamicCover(albumAudioId);
    if (!mounted) return;
    _dyCoverStatus.value = dyCoverStatusText(
      isOnline: true,
      albumAudioId: albumAudioId,
      known: DynamicCoverService.instance.lastKnownResult(albumAudioId),
    );
  }

  /// 从设置加载频谱开关状态
  Future<void> _loadSpectrumSetting() async {
    final enabled = await SettingsRepository().getSpectrumEnabled();
    final bandCount = await SettingsRepository().getSpectrumBandCount();
    final style = await SettingsRepository().getSpectrumStyle();
    final bgOpacity = await SettingsRepository().getSpectrumBgOpacity();
    final bgHeight = await SettingsRepository().getSpectrumBgHeight();
    final barOpacity = await SettingsRepository().getSpectrumBarOpacity();
    final curveOpacity = await SettingsRepository().getSpectrumCurveOpacity();
    final dynamicColor = await SettingsRepository().getSpectrumDynamicColor();
    final visualizerFallback =
        await SettingsRepository().getSpectrumVisualizerFallback();
    if (!mounted) return;
    SpectrumService.instance.bandCount = bandCount;
    setState(() {
      _spectrumEnabled = enabled;
      _spectrumStyle = style;
      _spectrumBgOpacity = bgOpacity;
      _spectrumBgHeight = bgHeight;
      _spectrumBarOpacity = barOpacity;
      _spectrumCurveOpacity = curveOpacity;
      _spectrumDynamicColor = dynamicColor;
      _spectrumVisualizerFallback = visualizerFallback;
    });
    if (enabled) {
      SpectrumService.instance.simulatedNotifier.addListener(
        _onSpectrumSimulated,
      );
      if (_isDragOverlay) {
        // 拖拽覆盖层（非路由）：只显示频谱 UI、不启动服务。
        // 采集由接管的播放器路由持有，覆盖层不重复注册。
        return;
      }
      // RECORD_AUDIO 只服务于 Visualizer 兜底；默认走 PCM 截取，无需任何权限
      if (Platform.isAndroid && _spectrumVisualizerFallback) {
        await Permission.microphone.request();
      }
      final isPlaying = context.read<PlayerProvider>().isPlaying;
      await _tryStartSpectrum(isPlaying: isPlaying);
    }
    // 频谱动态取色开启时补提取当前歌曲封面主色（歌词开关可能未开）
    if (dynamicColor && _lyricAccentColor == null && mounted) {
      final song = context.read<PlayerProvider>().currentSong;
      if (song != null) _updateLyricAccent(song.artworkUri);
    }
  }

  Future<void> _tryStartSpectrum({bool isPlaying = false}) async {
    // Android（PCM/Visualizer）与 Windows（WASAPI 环回）都有原生采集通路。
    if (!supportsMusicSpectrum ||
        !mounted ||
        _isDragOverlay ||
        !_spectrumEnabled) {
      return;
    }
    if (_spectrumStarted) return;
    // 未在播放时不启动（PCM 截取在 AudioSink 层，播放才会产生数据）
    if (!isPlaying) return;
    final sessionId = AudioService().androidAudioSessionId ?? 0;
    final ok = await SpectrumService.instance.start(
      sessionId,
      _spectrumOwner,
      // visualizerFallback：关闭时原生端不挂 Visualizer（无需录音权限）
      _spectrumVisualizerFallback,
    );
    if (!mounted || !_spectrumEnabled) {
      await SpectrumService.instance.stop(_spectrumOwner);
      return;
    }
    if (ok) {
      _spectrumStarted = true;
    }
  }

  Future<void> _stopSpectrum() async {
    _spectrumStarted = false;
    await SpectrumService.instance.stop(_spectrumOwner);
  }

  Future<void> _toggleSpectrum() async {
    AppHaptics.lightImpact(HapticCategory.control);
    final newEnabled = !_spectrumEnabled;
    setState(() => _spectrumEnabled = newEnabled);
    await SettingsRepository().setSpectrumEnabled(newEnabled);
    if (!mounted || newEnabled != _spectrumEnabled) return;
    if (newEnabled) {
      // 仅在启用 Visualizer 兜底时才要录音权限（PCM 截取不需要）
      if (Platform.isAndroid && _spectrumVisualizerFallback) {
        final status = await Permission.microphone.request();
        if (!status.isGranted && mounted) {
          showToast('未授予录音权限，Visualizer 兜底不可用', long: true);
        }
      }
      if (!mounted || newEnabled != _spectrumEnabled) return;
      final isPlaying = context.read<PlayerProvider>().isPlaying;
      await _tryStartSpectrum(isPlaying: isPlaying);
      if (!mounted || newEnabled != _spectrumEnabled) return;
      SpectrumService.instance.simulatedNotifier.addListener(
        _onSpectrumSimulated,
      );
    } else {
      SpectrumService.instance.simulatedNotifier.removeListener(
        _onSpectrumSimulated,
      );
      await _stopSpectrum();
    }
  }

  void _onSpectrumSimulated() {
    if (!mounted) return;
    if (SpectrumService.instance.simulatedNotifier.value) {
      showToast('实时频谱暂不可用，已切换到模拟模式', long: true);
      setState(() {});
    }
  }

  /// 重算并应用当前 tab 结构：
  /// - 宽屏（横屏/平板，宽度 >= 600 或设备本身是平板）无封面 tab
  ///   （封面常驻左栏、歌名固定在封面下方）；
  /// - 本地歌曲且开启了「关闭本地音乐评论区」时无评论 tab。
  ///
  /// 把形变相关的全局信号刷新一遍：当前 tab 下标 + 结构资格。
  ///
  /// - [playerTabIndex]：拖拽覆盖层里的 FullPlayer 是**另一个实例**，靠它才能
  ///   从同一个 tab 打开（否则下拉会把界面跳回封面 tab）。
  /// - [playerCoverVisible]：形变资格里与实例无关的那部分。**必须在绘制那一刻
  ///   可读**——竖屏停在歌词 / 评论 tab 时封面槽位根本不构建，把判定写在槽位里
  ///   等于永远不求值，`eligible` 会停在过期值，下拉照样飞出封面和歌名。
  ///
  ///   这里必须写**结构门**（[_morphStructuralEligible]）而不是
  ///   [_coverMorphEligible]：该信号被封面与文字两侧共用（`willDraw` /
  ///   `textWillDraw` 都读它），写成封面那一侧会把写真等封面独有的压制
  ///   **连带压掉文字连贯** —— 表现为「封面不飞了，歌名也跟着不飞了」。
  void _publishMorphSignals() {
    final i = _tabController.index;
    if (playerTabIndex.value != i) playerTabIndex.value = i;
    playerCoverVisible.value = _morphStructuralEligible;
  }

  /// 重算并应用当前 tab 结构：
  /// - 宽屏（横屏/平板，宽度 >= 600 或设备本身是平板）无封面 tab
  ///   （封面常驻左栏、歌名固定在封面下方）；
  /// - 本地歌曲且开启了「关闭本地音乐评论区」时无评论 tab。
  ///
  /// 结构变化时才重建 TabController（旧实例必须 dispose）。**必须在 build 之前
  /// 调用**：TabBarView.children 由 [_tabLayout] 派生，controller.length 与
  /// children 数量不一致会让 TabBarView 直接抛断言。
  void _syncTabLayout() {
    if (!mounted) return;
    final width = MediaQuery.sizeOf(context).width;
    final deviceIsPad = isPadLayout(context);
    // 页签结构按面板实际宽度决定：车机/嵌入面板也可能进入宽分栏，
    // 此时封面常驻左栏，必须同步移除多余的封面 tab。
    final isWideLayout = isWidePlayerTabLayout(
      dockMode: widget.dockMode,
      deviceIsPad: deviceIsPad,
      width: width,
    );
    final player = context.read<PlayerProvider>();
    final song = player.currentSong;
    final isLocalSong = song != null && !song.isOnline;
    final next = resolvePlayerTabLayout(
      isWideLayout: isWideLayout,
      isLocalSong: isLocalSong,
      closeLocalMusicComments: player.closeLocalMusicComments,
      // 与右栏底部挂不挂常驻带同源（[_detachedControls]），两处必须同一个表达式。
      showControlsPage: _detachedControls,
    );
    // 必须比较完整结构：同为 3 个 tab 也可能是「无封面」或「无评论」，
    // 只比长度会漏掉这种变化。
    if (next == _tabLayout) return;

    final oldIndex = _tabController.index;
    final oldLayout = _tabLayout;
    // 结构变化会把控制页整体摘掉（转回竖屏 / 运行中关掉开关）：手指若还压在滑条上，
    // 那一行的 onPointerUp 就永远不会送达，锁会卡住 —— 表现是**所有页**都滑不动。
    _controlsPageGestureLock.value = false;
    _tabController.dispose();
    _tabLayout = next;
    _tabController = TabController(
      length: next.length,
      vsync: this,
      initialIndex: next.indexAfterChangeFrom(oldIndex, oldLayout),
    );
    _tabController.addListener(_publishMorphSignals);
    _publishMorphSignals();
    setState(() {});
  }

  /// 「横屏控制面板独立页」开关变化：宽屏 tab 结构随之增删控制页。
  void _onDetachedControlsSettingChanged() {
    if (!mounted) return;
    _syncTabLayout();
  }

  /// 「横屏左右对称分栏」开关 / 「自定义宽屏边距」滑条变化：
  /// 分栏比例随之在 1:1 / 4:6 间切换、左栏内衬随之按覆盖值重算。
  /// 两者都只影响 Row 的 flex 与内衬宽度，不动 tab 结构，直接 setState 重算。
  void _onSymmetricPaneSettingChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTabLayout();
    // 系统栏/沉浸模式初始化：只在首次依赖建立时执行一次。
    // ModalRoute.of 依赖 _ModalScopeStatus（inherited widget），
    // 不能在 initState 中调用，否则报 dependOnInheritedWidgetOfExactType 错误
    if (_systemUiInitialized) return;
    _systemUiInitialized = true;
    final route = ModalRoute.of(context);
    if (route is DraggablePlayerRoute && route.isDragMode) {
      // 拖拽路由：延迟到展开完成后再切换沉浸，避免拖动过程系统栏提前闪烁
      _dragRoute = route;
      route.controller.addStatusListener(_onDragRouteStatus);
    } else if (route == null) {
      // 拖拽覆盖层（非路由）：不切换系统栏，展开后由路由接管
      _dragRoute = null;
      _systemUiModified = false;
    } else if (widget.dockMode) {
      // 车机常驻面板：面板内的 ModalRoute 是 CarModePanel 的宿主路由，
      // 不是全屏页，不接管系统栏也不设横屏沉浸标志。
      _dragRoute = null;
      _systemUiModified = false;
    } else {
      // 点击打开 / 普通路由：立即应用沉浸模式
      _dragRoute = null;
      applyImmersiveForOrientation();
      _systemUiModified = true;
      _syncLandscapeImmersiveFlag();
    }
  }

  void _onPlayerSongChanged() {
    if (!mounted) return;
    // 切歌可能在本地/在线之间切换 → 评论 tab 有无随之变化；
    // 设置页改「关闭本地音乐评论区」也会经 PlayerProvider 通知走到这里。
    _syncTabLayout();
    // 设置页可能改过动态封面开关 → 切歌时同步一次（幂等，值未变不触发重建）
    // ignore: discarded_futures
    _loadDynamicCoverSetting();
    final player = context.read<PlayerProvider>();
    final song = player.currentSong;
    if (song != null && song.id != _lastSongId) {
      // 背景淡入淡出（封面走翻转过渡，见 CoverFlipCrossfade）
      if (_previousArtworkUrl != null &&
          _previousArtworkUrl != song.artworkUri) {
        final newUrl = song.artworkUri;
        _artworkFadeController
          ..reset()
          ..forward().then((_) {
            if (mounted) _previousArtworkUrl = newUrl;
          });
      } else {
        _previousArtworkUrl = song.artworkUri;
      }
      // 翻转方向：下一曲 / 上一曲镜像（按播放列表下标变化判定；
      // 随机跳转等方向不明时沿用上一次的方向）。
      final playlist = player.playlist;
      final idx = player.currentIndex;
      final flipDir = coverSlideDirectionForIndexChange(
        fromIndex: _lastCoverFlipIndex ?? idx,
        toIndex: idx,
        playlistLength: playlist.length,
      );
      if (flipDir != 0) _coverFlipDirection = flipDir;
      _lastCoverFlipIndex = idx;
      _fetchLyrics(song);
      // 预加载上一首和下一首的封面，防止切换时白屏。
      // 错峰后移：切歌瞬间正并发封面翻转（500ms）+ 背景交叉淡，预载的
      // 网络取数与源图解码若同刻执行会抬高瞬时负载（抢 UI/IO 线程）；
      // 其目的是暖「下一次切歌」的缓存，晚 ~600ms 无损作用。
      // Timer 覆盖式重建：快速连切时只保留最后一轮，不堆积。
      _preloadNeighborTimer?.cancel();
      _preloadNeighborTimer = Timer(
        const Duration(milliseconds: 600),
        () {
          if (!mounted) return;
          final idx2 = context.read<PlayerProvider>().currentIndex;
          final list = context.read<PlayerProvider>().playlist;
          if (idx2 > 0) _preloadArtwork(list[idx2 - 1].artworkUri);
          if (idx2 < list.length - 1) _preloadArtwork(list[idx2 + 1].artworkUri);
        },
      );
    }
    // 元数据补齐后的歌词强制重取：键含时长与专辑 id，富化回写（id 不变）
    // 也会触发；首取时键未登记，靠首个 _fetchLyrics 调用处同步登记
    if (song != null) {
      final metadataKey =
          '${song.id}:${song.duration.inSeconds}:${song.albumAudioId ?? ''}';
      if (song.id == _lastSongId &&
          _lastLyricMetadataKey.isNotEmpty &&
          metadataKey != _lastLyricMetadataKey) {
        _fetchLyrics(song);
      }
      if (song.id == _lastSongId) _lastLyricMetadataKey = metadataKey;
    }
    // 频谱启停
    if (_spectrumEnabled && player.isPlaying && !_spectrumStarted) {
      _tryStartSpectrum(isPlaying: true);
    }
    SpectrumService.instance.setPlaying(player.isPlaying);
    // 切歌重建会经 AnnotatedRegion 重新调用 setSystemUIOverlayStyle，
    // 在 Android 上把 Zen/横屏沉浸的状态栏重新唤出；本帧结束后再隐藏一次。
    if (_zenMode || _landscapeImmersiveNeeded()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (_zenMode || _landscapeImmersiveNeeded())) {
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        }
      });
    }
  }

  @override
  void didChangeMetrics() {
    // 延迟一帧再检测方向，确保 physicalSize 已更新为新方向
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final current = view.physicalSize;
      // 防抖：仅在物理尺寸（方向）真正变化时才重新应用沉浸模式
      // 避免 immersiveSticky 下用户触摸边缘唤醒系统栏等 insets 抖动
      // 引发无效的 applyImmersiveForOrientation 调用导致系统栏闪烁
      if (_lastPhysicalSize == current) return;
      _lastPhysicalSize = current;
      // 车机面板不接管系统栏：方向变化时什么都不做
      // （面板宽度变化也不会走 didChangeMetrics，它量的是设备物理屏）。
      if (widget.dockMode) return;
      if (_zenMode) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        applyImmersiveForOrientation();
      }
      _syncLandscapeImmersiveFlag();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 亮屏/回前台：Android 可能清除 sticky 标志，Zen 或横屏沉浸中需重新隐藏系统栏。
    if (state == AppLifecycleState.resumed &&
        mounted &&
        (_zenMode || _landscapeImmersiveNeeded())) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  void didUpdateWidget(covariant AmStyleFullPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final song = context.read<PlayerProvider>().currentSong;
    if (song != null && song.id != _lastSongId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _fetchLyrics(song);
      });
    }
  }

  /// tv: 全局返回键兜底（`app.dart::_handleTvBack` 在 pop 前调用）。
  ///
  /// 只在「本页确实在场」时接手：拖拽覆盖层实例（`_isDragOverlay`）不参与——
  /// 它只是跟手过程的预览，真正接管的是路由实例，两者同时挂载时让路由那份处理。
  /// 返回 false = 没救（焦点已在控制 chrome 区 / 桥里无播放键），调用方照常 pop。
  bool _tvHandleBackFallback() {
    if (!mounted || _isDragOverlay) return false;
    return tvPlayerTryFocusPlay();
  }

  @override
  void dispose() {
    _pendingEntryAnimation?.removeStatusListener(_onEntryAnimationStatus);
    if (kTvBuild && !widget.dockMode) {
      TvPlayerBackFallback.instance.unregister(_tvHandleBackFallback);
    }
    PlayerZenBridge.instance.unregister(_zenToggleHandler);
    // 与 initState 的命令口注册成对：集合 remove 只摘除自己的注册，
    // 存活实例（路由/面板）不受影响。
    unregisterPlayerLyricsCommand(_goDockLyrics);
    if (Platform.isWindows) {
      SettingsRepository.windowsLiveSettingsRevision.removeListener(
        _reloadWindowsPlayerSettings,
      );
    }
    // 未完成展开就收起时，移除拖拽展开的监听（未切换系统栏，无需恢复）
    _dragRoute?.controller.removeStatusListener(_onDragRouteStatus);
    _zenPressController.dispose();
    try {
      context.read<PlayerProvider>().removeListener(_onPlayerSongChanged);
    } catch (_) {}
    DesktopLyricService.instance.removeListener(_onDesktopLyricChanged);
    LyricPreferences.instance.removeListener(_onLyricPrefsChanged);
    kLandscapeDetachedControlsEnabled.removeListener(
      _onDetachedControlsSettingChanged,
    );
    kSymmetricWidePaneEnabled.removeListener(_onSymmetricPaneSettingChanged);
    kWidePaneMarginOverride.removeListener(_onSymmetricPaneSettingChanged);
    kWidePaneIgnoreCutoutEnabled.removeListener(_onSymmetricPaneSettingChanged);
    _controlsPageGestureLock.dispose();
    _lyricBatcher.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _artworkFadeController.dispose();
    _zenPeekTimer?.cancel();
    _preloadNeighborTimer?.cancel();
    _zenChromeDim.dispose();
    _zenController.dispose();
    _tabController.dispose();
    _photoController.dispose();
    // 仅当自己仍是抑制标志的 owner 时复位：拖拽交接后覆盖层 dispose 时，
    // 路由实例已接管 owner，此时复位会在整个 fling 期间放开封面形变
    // （真机日志实锤 morph cover DRAW suppressed=false）。
    if (identical(PlayerCoverMorphBus.instance.coverSuppressOwner, this)) {
      PlayerCoverMorphBus.instance
        ..coverSuppressed = false
        ..coverSuppressOwner = null;
    }
    // 退出播放器时停止频谱采集
    SpectrumService.instance.simulatedNotifier.removeListener(
      _onSpectrumSimulated,
    );
    // 播放页离场：音乐震动的「播放页启用」计数减一
    MusicHapticsService.instance.setPlayerPageActive(false);
    _stopSpectrum();
    // 播放器卸载：若仍在 Zen 中，清除全局标志，避免主界面 _SystemUiUpdater 被永久短路
    if (_zenMode) kPlayerZenImmersiveActive.value = false;
    // Windows 窗口全屏兜底：peek 中途 / 直接关播放页都可能没走 _exitZenMode。
    // 无 Zen 持有的快照时是 no-op，不会误关用户手动开的全屏。
    WindowsFullscreen.exitZen();
    kPlayerLandscapeImmersiveActive.value = false;
    // 退出播放器时恢复系统栏；若仍处于封面流页横屏沉浸（从封面流进入播放器后返回），
    // 则保持沉浸，避免返回后状态栏闪现。
    // 拖拽覆盖层（非路由）从未修改系统栏，无需恢复
    if (_systemUiModified) {
      if (kCoverFlowImmersiveActive.value) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        restoreSystemUi();
      }
    }
    _playlistScroll.dispose();
    super.dispose();
  }

  /// 当前是否横屏（物理尺寸判定，与 applyImmersiveForOrientation 口径一致）。
  bool _isLandscapeNow() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return view.physicalSize.width > view.physicalSize.height;
  }

  /// 当前是否需要横屏沉浸：横屏且设置开关（横屏隐藏状态栏）开启。
  /// 车机模式下恒为 false：面板只是屏幕的一部分，不该让整个 App 的系统栏消失。
  bool _landscapeImmersiveNeeded() =>
      !widget.dockMode && _isLandscapeNow() && kLandscapeImmersiveEnabled;

  /// 同步全局「横屏沉浸生效」标志：仅非 Zen 且开关开启的横屏为 true，供主界面 _SystemUiUpdater 短路。
  void _syncLandscapeImmersiveFlag() {
    kPlayerLandscapeImmersiveActive.value =
        !_zenMode && _landscapeImmersiveNeeded();
  }

  /// 进入 Zen 沉浸模式：隐藏顶栏、控件、系统栏，拓宽歌词/封面视图。
  ///
  /// [windowFullscreen]：是否顺带把 Windows 窗口切成无边框全屏。
  /// 长按封面与 F11 沿用历史行为（true）；右键封面传 false —— 用户要的是
  /// 「沉浸但保留原窗口大小」，此时绝不能调 `enterZen()`（它立刻 `setFullscreen(true)`）。
  /// 不调也天然安全：退出路径的 `exitZen()` 在快照为 null 时是 no-op，不会误关
  /// 用户自己手动开的 F11 全屏（W2 快照模型）。
  void _enterZenMode({bool windowFullscreen = true}) {
    // 停在控制页时**不**切走：控制页是 pager 的子页，ZenFade 只淡出底部导航条，
    // 进度条/传输行/音量条不会随之消失，切去歌词页反而会打断用户正在用的这页。
    if (_zenMode) return;
    // 车机模式：面板常驻不会 dispose，而 Zen 会设全局沉浸标志
    // kPlayerZenImmersiveActive；面板一旦进入 Zen 就没有兜底清理点，
    // 会让主界面 _SystemUiUpdater 被永久短路。
    if (widget.dockMode) return;
    _zenWindowFullscreen = windowFullscreen;
    setState(() => _zenMode = true);
    _zenController.forward();
    // tv: 控件随 _ZenFade 淡出（P-F），先释放焦点避免遥控焦点残留在
    // 已隐藏的 TabBar/控件上。
    if (kTvBuild) FocusManager.instance.primaryFocus?.unfocus();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Windows 桌面：immersiveSticky 无实现，真全屏要靠原生窗口样式
    // （否则任务栏与边框照旧可见 = 「Zen 不能完全全屏」）。
    // 右键进入的沉浸刻意跳过这一步：窗口保持原尺寸/位置/最大化态。
    if (_zenWindowFullscreen) WindowsFullscreen.enterZen();
    kPlayerZenImmersiveActive.value = true;
    _syncLandscapeImmersiveFlag();
  }

  /// 退出 Zen 沉浸模式：恢复所有 UI 元素和系统栏。
  ///
  /// [keepWindowFullscreen]：peek（单击封面唤出 chrome）的临时退出用它 ——
  /// 4 秒后会自动回 Zen，若此时跟着退全屏，窗口会缩小再放大两次。
  void _exitZenMode({bool keepWindowFullscreen = false}) {
    // 显式退出要终止「唤出 4 秒后自动收回」的倒计时，否则用户刚长按退出、
    // 定时器又把 chrome 收回去。放在 !_zenMode 守卫之前：peek 期间 _zenMode
    // 已经是 false，守卫会直接 return、取消不到。
    _zenPeekTimer?.cancel();
    _zenPeekTimer = null;
    // 同样必须在 !_zenMode 守卫之前复位：peek 期间 _zenMode 已是 false，放守卫后面
    // 会残留 0.2 的压暗因子，下次唤出 chrome 时它直接是暗的。
    _zenChromeDim.value = 1.0;
    // Windows 窗口全屏的恢复同样必须在守卫之前：peek 期间 _zenMode 已是 false，
    // 放守卫后面会让 peek 中途按 F11 退不出全屏。
    if (!keepWindowFullscreen) WindowsFullscreen.exitZen();
    if (!_zenMode) return;
    setState(() => _zenMode = false);
    _zenController.reverse();
    kPlayerZenImmersiveActive.value = false;
    applyImmersiveForOrientation();
    _syncLandscapeImmersiveFlag();
  }

  /// Windows F11：播放页在场且在最上层时切换 Zen，返回 true 表示消费了本次按键。
  ///
  /// 拖拽覆盖层实例（`_isDragOverlay`）与车机面板都不接管：前者只是跟手预览，
  /// 后者不是全屏页（不接管窗口）。被歌单页等盖住时（`!isCurrent`）也不接管，
  /// 否则用户按 F11 切窗口全屏会莫名把背景里的播放页切进 Zen。
  bool _f11ToggleZen() {
    if (!mounted || _isDragOverlay || widget.dockMode) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    if (context.read<PlayerProvider>().currentSong == null) return false;
    // peek 期间（chrome 已临时唤出、4s 后自动回 Zen）：F11 视为「彻底退出 Zen」，
    // 同时取消倒计时与压暗因子，否则定时器会在已回 Zen 后再把因子按到 0.2。
    if (_zenPeekTimer != null) {
      _exitZenMode();
      return true;
    }
    if (_zenMode) {
      _exitZenMode();
    } else {
      _enterZenMode();
    }
    return true;
  }

  /// Windows 右键封面：进入 / 退出「不持窗口全屏的 Zen」。
  ///
  /// 与 F11 的唯一差别是进入时的 [windowFullscreen]：右键只让 Flutter 侧 chrome
  /// 淡出，窗口尺寸、位置、最大化/全屏状态一律不动。
  /// 门控与 F11 同口径：拖拽覆盖层只是跟手预览（不是真页面），车机面板不是全屏页。
  /// 无歌时封面根本不存在（build 走「暂无播放」占位），故不必再判 currentSong。
  void _toggleZenBySecondaryClick() {
    if (!mounted || _isDragOverlay || widget.dockMode) return;
    // peek 期间 `_zenMode` 已是 false（chrome 临时唤出、4s 后自动收回），必须先看
    // 倒计时：此时右键的语义应当是「彻底退出」，与 F11 在 peek 中按键一致。
    // 顺序反过来会让右键变成「再进一次 Zen」，用户按不出退出。
    if (_zenPeekTimer != null || _zenMode) {
      _exitZenMode();
    } else {
      _enterZenMode(windowFullscreen: false);
    }
  }

  /// Zen 下单击封面：唤出 chrome，[_zenPeekDuration] 后自动收回（计划 §2.2 ③）。
  ///
  /// 用 Timer 不用 Ticker —— 这不是跟手动效，没必要按 vsync 产帧（AGENTS §10.1）。
  /// 整段停留同时在渐隐：不透明度从 100% 线性降到 [_zenPeekEndDim]，抵达那一档即收回。
  void _peekChromeFromZen() {
    if (!_zenMode) return;
    // 窗口保持全屏：4 秒后自动回 Zen，跟着退全屏会看到窗口缩小再放大。
    _exitZenMode(keepWindowFullscreen: true);
    _zenPeekStep = 0;
    // 斜坡与收回共用一个 tick：抵达 [_zenPeekEndDim] 的那一帧就是恢复 Zen 的那一帧。
    _zenPeekTimer = Timer.periodic(_zenPeekInterval, (timer) {
      _zenPeekStep++;
      if (_zenPeekStep >= _zenPeekSteps) {
        timer.cancel();
        _zenPeekTimer = null;
        _zenChromeDim.value = _zenPeekEndDim;
        if (mounted) _enterZenMode(windowFullscreen: _zenWindowFullscreen);
      } else {
        _zenChromeDim.value =
            1.0 - (1.0 - _zenPeekEndDim) * _zenPeekStep / _zenPeekSteps;
      }
    });
  }

  /// 宽屏封面点击：先吞掉「长按满 2s 后松手也被认作一次点按」，其余交给 peek。
  void _onWideArtworkTap() {
    if (_consumeZenPressTap()) return;
    _peekChromeFromZen();
  }

  /// 长按专辑封面 [_zenPressDuration] 切换 Zen 模式（未进入则进入，已进入则退出）。
  /// 通过 Listener 的 onPointerDown/Move/Up 直接跟踪指针，
  /// 精确实现 2000ms 长按（不依赖系统 500ms 长按识别延迟），
  /// 同时不与 TabBarView 的水平滑动抢手势。
  void _onArtworkPointerDown(PointerDownEvent event) {
    // 只跟踪主键。右键由 _toggleZenBySecondaryClick 负责；这里若也起 2000ms 长按
    // ticker，右键按住 2 秒会再切一次 Zen（进→立即退），按下期间还会误亮提示层。
    // 只看按键位、不看设备类型：触屏/触控板点按的 down 事件 buttons 恒为
    // kPrimaryButton（kTouchContact == kPrimaryButton），Android 长按完全不受影响；
    // 加 `kind == mouse` 反而会漏掉触控板。
    if ((event.buttons & kPrimaryButton) == 0) return;
    _zenPressOrigin = event.position;
    _zenHintHapticFired = false;
    // 兜底复位：上一次的 tap 可能被竖直拖拽等手势抢走、没走到 onTap
    _zenPressConsumedTap = false;
    _zenPressController.forward(from: 0.0).then((_) {
      // 中途松手/滑动取消时 TickerFuture 同样会完成，用进度判断是否真的按满
      if (!mounted || _zenPressController.value < 1.0) return;
      _zenPressOrigin = null;
      // 中震：确认长按达到 2000ms，切换 Zen 模式
      AppHaptics.mediumImpact(HapticCategory.gesture);
      if (_zenMode) {
        _exitZenMode();
      } else {
        _enterZenMode();
      }
      // 提示层与封面内缩随 Zen 转场一起回弹淡出
      _zenPressController.reverse();
    });
  }

  /// 指针位移超过 [_zenPressSlop]：判定为滑动（切 tab / 拖拽），取消长按。
  void _onArtworkPointerMove(PointerMoveEvent event) {
    final origin = _zenPressOrigin;
    if (origin == null) return;
    if ((event.position - origin).distance > _zenPressSlop) {
      _cancelArtworkPress();
    }
  }

  /// 松手 / 手势取消 / 判定为滑动：回弹按压动效并淡出提示层。
  void _cancelArtworkPress() {
    if (_zenPressOrigin == null) return;
    _zenPressOrigin = null;
    _zenHintHapticFired = false;
    if (_zenPressController.value > 0.0) {
      _zenPressController.reverse();
    } else {
      // 同一帧内完成的点按（鼠标快击 / 事件合并）：进度还是 0，reverse() 走不到
      // 这里，ticker 会继续跑满 2000ms 把页面误切进 Zen。必须显式停掉。
      _zenPressController.stop();
    }
  }

  /// 按压进度回调：跨过 [_zenHintStart]（提示层开始淡入）时轻震一次，
  /// 并标记这次按压已是长按语义、松手不再触发封面 tab 的点击跳转。
  /// 封面内缩与提示层由 AnimatedBuilder 监听 controller 重建，此处只管震动。
  void _onZenPressProgress() {
    if (_zenHintHapticFired || _zenPressController.value < _zenHintStart) {
      return;
    }
    _zenHintHapticFired = true;
    _zenPressConsumedTap = true;
    AppHaptics.lightImpact(HapticCategory.gesture);
  }

  /// 封面 tab 的 onTap 入口：本次按压已被 Zen 长按消费则放弃这次点击。
  bool _consumeZenPressTap() {
    if (!_zenPressConsumedTap) return false;
    _zenPressConsumedTap = false;
    return true;
  }

  /// 封面长按包装：指针监听 + 按压内缩动效 + Zen 长按引导提示层。
  /// [child] 为原封面内容（含播放/暂停缩放动画）。
  /// [allowShrink] 为 false 时关闭按压内缩（写真封面缩小会露底，见调用处）。
  Widget _wrapArtworkZenPress({
    required Widget child,
    bool allowShrink = true,
  }) {
    Widget result = child;
    // 车机模式禁用长按进 Zen：见 _enterZenMode 的说明。
    // 这一处是主守卫（连长按提示层与按压动效一并去掉）。
    if (_zenLongPressEnabled && !widget.dockMode) {
      result = Listener(
        onPointerDown: _onArtworkPointerDown,
        onPointerMove: _onArtworkPointerMove,
        onPointerUp: (_) => _cancelArtworkPress(),
        onPointerCancel: (_) => _cancelArtworkPress(),
        child: AnimatedBuilder(
          animation: _zenPressController,
          child: result,
          builder: (context, artwork) {
            final progress = _zenPressController.value;
            // 按压时封面轻微内缩（1.0 → 0.94），松手回弹。
            // 写真封面（allowShrink=false）：缩小会露出底下页面背景（真机反馈），
            // 按压只保留引导提示动效。
            final press = allowShrink
                ? Curves.easeOut.transform(progress)
                : 0.0;
            return Stack(
              // 与 MD3 同口径：Stack 默认 hardEdge 会把封面投影裁掉（投影画在布局盒
              // 外侧），必须 Clip.none。提示层是 Positioned.fill，不受影响。
              clipBehavior: Clip.none,
              children: [
                Transform.scale(scale: 1.0 - 0.06 * press, child: artwork),
                _buildZenPressHint(progress),
              ],
            );
          },
        ),
      );
    }
    // Windows 鼠标右键：进入 / 退出「不持窗口全屏的 Zen」（见
    // [_toggleZenBySecondaryClick]）。**必须挂在上面长按门控之外**：设置里关掉的
    // 是「长按封面」这条手势，右键与 F11 一样不受它约束。
    //
    // behavior: opaque 不拦截事件下发（RenderProxyBoxWithHitTestBehavior 先
    // hitTestChildren），后代一切照旧：DepthCoverHost 的 MouseRegion
    // （translucent + opaque:false，W12.3）继续收 hover，外层的 onTap /
    // onVerticalDrag* 也照常工作（次键根本不进主键识别器的候选集）。
    // 必须自建 SecondaryTapGestureRecognizer（onSecondaryTap）而不是用 Listener
    // 收 buttons 位：它比外层封面的 GestureDetector 更**深**，指针抬起时 arena
    // sweep 取 members.first —— 正好补上「次键没有 no-op onTap 顶着，右键会掉进
    // 外层竖向拖拽的零位移分支、表现为播放页闪回收起」这个洞。
    if (isWindowsDesktop && !widget.dockMode) {
      result = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTap: _toggleZenBySecondaryClick,
        child: result,
      );
    }
    return result;
  }

  /// Zen 长按引导提示层：覆盖在封面上，半透明黑底 + 进度环 + 图标 + 文案。
  /// [progress] 为按压进度（0→1）：跨过 [_zenHintStart] 后淡入，
  /// 进度环显示距切换还差多少。IgnorePointer 避免拦截指针事件。
  Widget _buildZenPressHint(double progress) {
    final opacity = ((progress - _zenHintStart) / 0.15).clamp(0.0, 1.0);
    if (opacity == 0.0) return const SizedBox.shrink();
    final ring = ((progress - _zenHintStart) / (1.0 - _zenHintStart)).clamp(
      0.0,
      1.0,
    );
    return Positioned.fill(
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: _zenPressSurface(
            child: Container(
              color: Colors.black.withValues(alpha: 0.6),
              alignment: Alignment.center,
              padding: const EdgeInsets.all(8),
              // 与 MD3 同口径：窄横屏（800×360）里进度尺与播放键搬进左栏后封面盒只剩
              // ~73dp，环 40 + 8 + 文案（>60）放不下会顶出 RenderFlex 溢出。
              // 盒子不够高就只留进度环 —— 环本身就是进度。
              child: LayoutBuilder(
                builder: (context, box) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 40,
                      height: 40,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CircularProgressIndicator(
                            value: ring,
                            strokeWidth: 3,
                            backgroundColor: Colors.white24,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                          ),
                          Icon(
                            _zenMode
                                ? Icons.exit_to_app
                                : Icons.self_improvement,
                            color: Colors.white,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                    if (box.maxHeight >= 96) ...[
                      const SizedBox(height: 8),
                      Text(
                        _zenMode ? '继续长按退出 Zen 模式' : '继续长按进入 Zen 模式',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 提示层外形：圆角方形封面裁 16px 圆角；圆盘封面（频谱 0/1）的外框还包含
  /// 环形频谱柱，可见圆形只占外框的 `1 - 2 * barReserveRatio`，故先按同一比例
  /// 内缩再裁圆——否则黑底会显成压在圆封面上的一块矩形。
  /// 写真封面是全出血的矩形（此时圆盘分支并未渲染），仍按矩形裁。
  Widget _zenPressSurface({required Widget child}) {
    if (!_isDiscCover || _photoCoverActive) {
      return ClipRRect(borderRadius: BorderRadius.circular(16), child: child);
    }
    return LayoutBuilder(
      builder: (context, constraints) => Padding(
        padding: EdgeInsets.all(
          constraints.biggest.shortestSide * SpectrumArtwork.barReserveRatio,
        ),
        child: ClipOval(child: child),
      ),
    );
  }

  /// 切歌时异步提取专辑封面主色，供歌词「动态字体颜色」与频谱动态取色混色使用。
  ///
  /// 复用流光背景的提取思路（PaletteGenerator + 过滤 + 饱和度归一化）。
  /// 提取完成后若已切到别的歌（url 变化）则丢弃结果。
  Future<void> _updateLyricAccent(String? url) async {
    // 仅歌词动态取色或频谱动态取色任一开启时才需要提取（默认关闭，避免每次
    // 进播放器都多一次封面下载 + 解码 + PaletteGenerator 分析的无谓开销）
    if (!LyricPreferences.instance.useDynamicLyricColor &&
        !_spectrumDynamicColor) {
      return;
    }
    if (url == _lastAccentUrl) return;
    _lastAccentUrl = url;
    final color = await ArtworkColorExtractor.extract(url);
    _lyricBatcher.schedule(() {
      if (!mounted || _lastAccentUrl != url) return;
      setState(() => _lyricAccentColor = color);
    });
  }

  /// LyricPreferences 变化回调：播放器存活期间在设置页打开「歌词动态颜色」
  /// 开关时，立即为当前歌曲补提取封面主色（首次打开时 _fetchLyrics 的提取
  /// 因开关关闭已被跳过）。
  void _onLyricPrefsChanged() {
    // 「屏蔽歌词作者信息」开关/正则变化：从 raw 列表即时重派生显示列表（不重取词）。
    // filterLines 无命中或关闭时返回原引用，AppleLyricsView 的行缓存不会被打穿。
    final filterEnabled = LyricCreditFilter.enabled;
    final filterPattern = LyricPreferences.instance.creditPattern;
    if ((filterEnabled != _derivedFilterEnabled ||
            filterPattern != _derivedFilterPattern) &&
        mounted) {
      _derivedFilterEnabled = filterEnabled;
      _derivedFilterPattern = filterPattern;
      setState(
          () => _parsedLyrics = LyricCreditFilter.filterLines(_parsedLyricsRaw));
    }
    if ((LyricPreferences.instance.useDynamicLyricColor ||
            _spectrumDynamicColor) &&
        _lyricAccentColor == null &&
        mounted) {
      final song = context.read<PlayerProvider>().currentSong;
      if (song != null) _updateLyricAccent(song.artworkUri);
    }
  }

  int _lyricFetchGeneration = 0;

  Future<void> _fetchLyrics(dynamic song) async {
    // 入场期间的歌曲更新由收敛后的初始化读取最新值，避免缓存歌词同步解析抢帧。
    if (_pendingEntryAnimation != null) return;
    // 转场期间**连取词的启动都不做**：落位后这个闭包会把自己再调进来一次。
    // 为什么不能只推迟提交：真机实测覆盖层实例在转场第 1 帧就建页并发起取词，松手交接后
    // 路由实例又取一遍——同一首歌两次取词两次解析，其中一次压在飞行帧上
    // （那两段 gapMax 66.4ms / 89.5ms、page=5 inst=2 firstAt=1）。
    // 转场中多个调用点重复进来也不要紧：延后执行时第一个会正常登记元数据键，
    // 其余被下面「同键不重取」那条判定吃掉。
    if (_lyricBatcher.isInFlight) {
      _lyricBatcher.schedule(() => _fetchLyrics(song));
      return;
    }
    // 同步登记元数据键（含时长与专辑 id）：防止切歌分支绕过监听里的
    // 键比对判定，同键不重取；取词失败时键已登记、与原 id 判重语义一致
    final songId = song.id as String;
    final metadataKey = '${song.id}:${song.duration.inSeconds}:${song.albumAudioId ?? ''}';
    if (songId == _lastSongId && metadataKey == _lastLyricMetadataKey) return;
    _lastLyricMetadataKey = metadataKey;
    _lastSongId = songId;
    final generation = ++_lyricFetchGeneration;

    // 切歌时同步提取封面主色（动态字体颜色用，fire-and-forget）
    _updateLyricAccent(song.artworkUri);

    _lyricBatcher.schedule(() {
      setState(() {
        _isLoadingLyrics = true;
        _parsedLyrics = const [];
        _parsedLyricsRaw = const [];
        _lyricFormat = null;
      });
    });

    // 正文首包和最终补全共用展示入口，旧歌曲的回调不能覆盖当前歌词。
    void showLyrics(String lyricText, {String? translationText, String? romaText}) {
      _lyricBatcher.schedule(() {
        if (!mounted || generation != _lyricFetchGeneration) return;
        setState(() {
          _isLoadingLyrics = false;
          // 先解析（增强型 LRC / KRC 的翻译、罗马音可能在解析后合并进每行）
          _parsedLyricsRaw = LyricParserChain.parse(
            lyricText,
            translationText: translationText,
            romaText: romaText,
          );
          // 「屏蔽歌词作者信息」开启时剔除制作名单/版权声明行（见 LyricCreditFilter）
          _parsedLyrics = LyricCreditFilter.filterLines(_parsedLyricsRaw);
          _derivedFilterEnabled = LyricCreditFilter.enabled;
          _derivedFilterPattern = LyricPreferences.instance.creditPattern;
          _lyricFormat = LyricParserChain.detectFormat(lyricText);
          // 副行可用性 = 外部翻译文本非空 或 解析后任一行携带翻译/罗马音
          // （增强型 LRC 把同时间戳翻译行合并进 LyricLine.translation，
          // 需据此判断，否则播放页不显示翻译开关）。用**未过滤**列表判定：
          // 名单行被过滤不应连带副行开关消失。
          _hasTranslation =
              (translationText != null && translationText.isNotEmpty) ||
              _parsedLyricsRaw.any(
                (l) => l.translation != null && l.translation!.isNotEmpty,
              );
          _hasRoma =
              (romaText != null && romaText.isNotEmpty) ||
              _parsedLyricsRaw.any((l) => l.roma != null && l.roma!.isNotEmpty);
          debugPrint(
            '[RomaToggle] 歌词加载: translationText=${translationText == null ? 'null' : (translationText.isEmpty ? '空串' : 'len=${translationText.length}')} romaText=${romaText == null ? 'null' : (romaText.isEmpty ? '空串' : 'len=${romaText.length}')} → hasTranslation=$_hasTranslation hasRoma=$_hasRoma',
          );
        });
      });
    }

    try {
      String lyricText = '';
      String? translationText;
      String? romaText;

      // 这首歌自己的匹配记录：hash 精确检索 + 单曲偏好「使用在线歌词」
      // 云盘歌曲同样可持有匹配记忆（云盘 hash 非官方 hash）
      if (song is Song) {
        await SongMatchRepository().ensureLoaded();
      }
      final matchInfo = song is Song ? matchInfoForSong(song) : null;
      final preferOnlineLyrics = matchInfo?.preferOnlineLyrics == true;

      // 本地歌曲优先读取内嵌歌词（ID3 USLT / SYLT / Vorbis LYRICS / MP4 ©lyr）；
      // 单曲偏好开启时跳过，直接走在线。云盘歌曲无本地文件，跳过内嵌读取。
      if (song is Song && !song.isOnline && !song.isCloud && !preferOnlineLyrics) {
        final localPath = song.localPath;
        if (localPath != null && localPath.isNotEmpty) {
          // file:// URI 或 content:// 需要提取真实路径
          String filePath = localPath;
          if (filePath.startsWith('file://')) {
            filePath = Uri.parse(filePath).toFilePath();
          }
          final embedded = await LocalLyricLoader.loadForAudioAsync(filePath);
          if (embedded != null && embedded.isNotEmpty) {
            lyricText = embedded;
          }
        }
      }

      // 内嵌歌词为空（或偏好在线）时回退到酷狗 API
      if (lyricText.isEmpty) {
        if (!mounted || generation != _lyricFetchGeneration) return;
        final kugouProvider = context.read<KugouProvider>();
        // 本地/云盘歌曲：命中匹配记忆时用在线 hash 精确检索；未命中传空 hash
        // 让酷狗 API 完全基于 songName 搜索歌词
        final matchedHash =
            (matchInfo != null && matchInfo.isMatched) ? matchInfo.hash : null;
        final lyricHash = matchedHash ??
            ((song is Song && !song.isOnline) ? '' : songId);
        // 搜索关键词用"歌名 艺术家"提高匹配准确度
        final searchName = (song is Song && song.artist != '未知艺术家')
            ? '${song.title} ${song.artist}'
            : song.title;
        final lyric = await kugouProvider.getLyric(lyricHash, songName: searchName,
          onProgress: (partial) => showLyrics(
            partial.displayKrcLyric ?? partial.displayLrcLyric ?? partial.displayLyric ?? '',
            translationText: partial.translatedContent, romaText: partial.romaContent,
          ),
        );

        if (mounted && generation == _lyricFetchGeneration) {
          lyricText =
              lyric?.displayKrcLyric ??
              lyric?.displayLrcLyric ??
              lyric?.displayLyric ??
              '';
          translationText = lyric?.translatedContent;
          romaText = lyric?.romaContent;
        }
      }

      showLyrics(lyricText, translationText: translationText, romaText: romaText);
    } catch (e) {
      _lyricBatcher.schedule(() {
        if (!mounted || generation != _lyricFetchGeneration) return;
        setState(() {
          _isLoadingLyrics = false;
          _parsedLyrics = const [];
          _parsedLyricsRaw = const [];
          _lyricFormat = null;
        });
      });
    }
  }

  /// 判断当前歌曲是否为本地歌曲且歌词为 LRC 逐行格式（无字级时间戳）。
  ///
  /// 这种情况禁用 AppleLyricsView 的间奏点（节奏点）动画：
  /// LRC 逐行没有逐字时间戳，行间节奏点与真实节拍不易对齐，
  /// 本地歌曲的 LRC 又常常缺少精确时间戳，体验较差，禁用后更干净。
  ///
  /// 若是字级 LRC（含逐字时间戳），行起始时间戳精确到毫秒，
  /// 间奏点可以正常对齐节拍，应保留。
  /// 在线歌曲 / KRC 逐字歌词 / 静态歌词不受影响。
  bool _isLocalLrcLyricWithoutWordTiming(dynamic currentSong) {
    if (currentSong is! Song || currentSong.isOnline) return false;
    if (_lyricFormat != LyricFormat.lrc) return false;
    // 任意一行有字级时间戳即视为字级 LRC（混合场景按字级处理）
    return !_parsedLyricsRaw.any((line) => line.hasWordTiming);
  }

  /// 构建横屏布局的封面内容：style 0/1 用 SpectrumArtwork（白色），style 2 用原封面
  Widget _buildLandscapeArtworkContent(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
  ) {
    if (_isDiscCover) {
      return SpectrumArtwork(
        artworkUri: currentSong.artworkUri,
        fallbackFilePath: currentSong.localPath,
        isPlaying: playerProvider.isPlaying,
        bandCount: SpectrumService.instance.bandCount,
        style: _spectrumStyle,
        barColor: _spectrumColor,
        opacity: _spectrumOpacity,
        // 与 MiniPlayer 交接期间让位环形柱（交接后 350ms 淡入回来）。
        morphProgress: playerExpansion,
      );
    }
    return Selector<PlayerProvider, (String?, String?)>(
      selector: (_, p) => (p.currentSong?.artworkUri, p.currentSong?.localPath),
      builder: (context, data, __) => _buildArtworkWithDynamicCover(
        currentSong,
        colorScheme,
        // 必须用内层 Selector 的快照值，不能读 currentSong：同一首歌的封面
        // 稍后被富化补齐时 songId 不变、外层 Selector 不重建，闭包里的
        // currentSong 是过期实例，封面会刷不新。
        artworkUri: data.$1,
        fallbackFilePath: data.$2,
        iconSize: 48,
      ),
    );
  }

  /// 封面切歌过渡：模糊 + 纵轴翻转（观感对齐参考视频）。
  ///
  /// 三个封面渲染点（竖屏封面 tab 展开/非展开、横屏左栏）都经本函数，
  /// 行为自动一致。频谱圆盘与写真在调用方之前分流，不走这里。
  ///
  /// [artworkUri] / [fallbackFilePath] 必须由调用方传入**它原本使用的来源**
  /// （横屏左栏走内层 `Selector` 的快照值，另外两处直接用 `currentSong` 的
  /// 字段）——同一首歌封面稍后被富化补齐时 songId 不变、外层 Selector 不
  /// 重建，闭包持有过期实例会刷不新；[CoverFlipCrossfade] 的 `version`
  /// 也依赖这里拿到新 URI 才能触发翻转。
  ///
  /// [dynamicCover]（动态封面视频层）与静态封面作为**同一张卡面**交给翻转
  /// widget：新图就绪等待期间整张卡面不在树上，新歌视频不会提前淡入压在旧
  /// 封面上；就绪后随卡面一起翻入（视频 400ms 淡入晚于 300ms 翻转，落在
  /// 稳定态上）。
  Widget _buildCrossfadeArtwork(
    String? artworkUrl,
    ColorScheme colorScheme, {
    double iconSize = 48.0,
    String? fallbackFilePath,
    Widget? dynamicCover,
  }) {
    // 3D 深度封面宿主：开关关闭/生成未完成时内部回退为平面封面，
    // 保留 AM 风格的白底占位与过渡效果；与动态封面互斥由
    // _buildArtworkWithDynamicCover 的分流保证（有动态封面时不会走到这里）。
    final artwork = DepthCoverHost(
      artworkUri: artworkUrl,
      fallbackFilePath: fallbackFilePath,
      fit: BoxFit.cover,
      iconSize: iconSize,
      backgroundColor: Colors.white12,
      iconColor: Colors.white54,
    );
    return CoverFlipCrossfade(
      // 身份键 = 封面图 URI：图没变不演过渡（与视频一致），
      // 封面迟到补齐（同歌换图）也演。
      version: artworkUrl,
      fallbackFilePath: fallbackFilePath,
      iconSize: iconSize,
      // 每层各自先裁圆角再旋转：旋转中封面探出静止边界时不被裁掉边缘。
      radius: kCoverMorphFullRadius,
      // 翻转方向：下一曲 / 上一曲镜像（_onPlayerSongChanged 按下标变化判定）。
      direction: _coverFlipDirection,
      // 新封面没就绪不翻：等待期继续显示旧封面（与视频「封面到位才翻」一致），
      // 超时/失败则放弃动画直接换图。与渲染层同键（ResizeImage 档位）探测。
      readinessProbe: (uri, width, dpr) => isPlayerArtworkReady(
        artworkUri: uri,
        settledLogicalWidth: width,
        devicePixelRatio: dpr,
      ),
      child: dynamicCover == null
          ? artwork
          : Stack(
              fit: StackFit.expand,
              children: [artwork, dynamicCover],
            ),
    );
  }

  /// AM 播放器封面统一入口：静态封面 + 动态封面叠加。
  ///
  /// 3 处封面渲染点（横屏左栏、竖屏封面 tab 展开/非展开）都调用本函数，
  /// 保证行为一致。`isPlaying` 由 [DynamicCoverView] 自己订阅，故此处不传。
  ///
  /// [artworkUri] / [fallbackFilePath] 必须由调用方传入**它原本使用的来源**：
  /// 横屏左栏走内层 `Selector` 的 `(artworkUri, localPath)` 快照值，另外两处
  /// 直接用 `currentSong` 的字段。若统一改成读 `currentSong`，遇到「同一首歌的
  /// 封面稍后被富化补齐」（songId 不变 → 外层 Selector 不重建 → 闭包持有过期
  /// 实例）时封面会刷不新。
  Widget _buildArtworkWithDynamicCover(
    dynamic currentSong,
    ColorScheme colorScheme, {
    required String? artworkUri,
    required String? fallbackFilePath,
    double iconSize = 48.0,
  }) {
    return PlayerCoverShadow.wrap(
      shadowColor: colorScheme.shadow,
      // 不在这层裁圆角：改由 CoverFlipCrossfade 每层各自「先裁圆角再旋转」，
      // 旋转中封面（透视近端放大）探出静止边界时不会被裁掉上下边缘。
      // Stack 用 Clip.none：投影画在盒外，默认 hardEdge 会把它裁掉
      // （PlayerCoverShadow 契约）。
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          _buildCrossfadeArtwork(
            artworkUri,
            colorScheme,
            iconSize: iconSize,
            fallbackFilePath: fallbackFilePath,
            dynamicCover:
                (currentSong is Song && currentSong.isOnline)
                    ? DynamicCoverView(
                        song: currentSong,
                        enabled: _dynamicCoverEnabled,
                      )
                    : null,
          ),
        ],
      ),
    );
  }

  /// 模糊背景淡入淡出（无 alpha 渐变；渐变移到 AppleLyricsView 歌词界面边界）。
  /// [sigma] 为用户可调模糊强度（0~200），0 时跳过滤镜直接渲染原图。
  /// 仅在动态流光关闭时被调用（调用点有条件判断）。
  ///
  /// sigma>0 且达到 [kLowResBlurMinSigma]（30，即用户默认值）时，每层用
  /// [LowResBlurCover] 走「低分辨率模糊快照」：全屏高斯收敛为 ≤96px 小图上的
  /// 一次卷积（双线性铺满），切歌/调强度不再触发全屏重卷积——切歌瞬间与封面
  /// 翻转并发的最大一笔模糊突发被消掉。**低于 30 不启用**：弱模糊保留中频
  /// 结构（封面轮廓、色块边界），96px 放大到全屏会暴露插值网格穿帮，由
  /// LowResBlurCover 的强度闸门保证，调用点也据此跳过 widget 包装。
  /// 源解析不了（内嵌封面等）时同样自动回退原「ImageFiltered 全屏滤镜 +
  /// RepaintBoundary 缓存」路径，行为与优化前一致。
  Widget _buildCrossfadeBlurredBackground(
    String? artworkUrl, {
    String? fallbackFilePath,
    required double sigma,
  }) {
    // 背景层共用的原图渲染（fallback 与快照路径共用，避免两处漂移）。
    Widget artwork(String? uri) => PlayerArtworkImage(
      artworkUri: uri,
      fallbackFilePath: fallbackFilePath,
      isFill: true,
      fit: BoxFit.cover,
      backgroundColor: Colors.black,
      iconColor: Colors.white24,
    );
    Widget fullResFiltered(String? uri) => ImageFiltered(
      // sigma 随设置变化（0~200）；RepaintBoundary 缓存的
      // 已模糊栅格只在 sigma 变更时重算一次，切歌动画
      // 仍只做 alpha 混合（保持 2026-09-01 性能优化结构）
      imageFilter: ImageFilter.blur(
        sigmaX: tvBlurSigma(sigma),
        sigmaY: tvBlurSigma(sigma),
        // Impeller 下未指定 tileMode 时默认 decal：图层外
        // 透明黑被卷进卷积核 → 屏幕四周一圈暗晕（与
        // am_artist_photo_cover 同坑）。clamp 以边缘像素
        // 延续，黑圈消失。
        tileMode: TileMode.clamp,
      ),
      child: artwork(uri),
    );
    // 闸门与滤镜都用钳制后的有效 σ：TV 构建把用户 30 钳到 12，若按原始值
    // 判断会在弱 GPU 上误走低分辨率路径（穿帮风险更高的正是弱设备）。
    final effectiveSigma = tvBlurSigma(sigma);
    Widget blurred(String? uri, Key roleKey) {
      if (sigma <= 0) return artwork(uri);
      if (effectiveSigma < kLowResBlurMinSigma) return fullResFiltered(uri);
      return LowResBlurCover(
        // 按**角色**加键而非按 URI：① 旧层是条件渲染（首帧切换会让 Stack
        // 子项移位，无 key 时新旧层状态串位）；② URI 键会让 State 随切歌
        // 重建、丢掉旧快照——角色键让 State 跨切歌存续，旧快照继续顶显示
        // 到新快照就绪（post-frame + 缓存命中,约 1~2 帧），全程无全屏卷积。
        key: roleKey,
        artworkUri: uri,
        blurSigma: effectiveSigma,
        fallback: fullResFiltered(uri),
      );
    }

    return AnimatedBuilder(
      animation: _artworkFadeAnimation,
      builder: (context, _) {
        final oldOpacity = 1.0 - _artworkFadeAnimation.value;
        final newOpacity = _artworkFadeAnimation.value;
        return Stack(
          children: [
            if (_previousArtworkUrl != null && _previousArtworkUrl!.isNotEmpty)
              Positioned.fill(
                child: Opacity(
                  opacity: oldOpacity,
                  child: RepaintBoundary(
                    // sigma=0（用户调为不模糊）：跳过滤镜，省一层 GPU 合成
                    child: blurred(_previousArtworkUrl, const ValueKey('prev')),
                  ),
                ),
              ),
            Positioned.fill(
              child: Opacity(
                opacity: newOpacity,
                child: RepaintBoundary(
                  child: blurred(artworkUrl, const ValueKey('current')),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // === 按钮 / 下拉箭头收起入口（顶栏向下拖拽收起见下方 _onTopBarDrag*，
  //     系统返回键走 PopScope） ===

  /// 播放列表处于编辑模式时消费本次「退出播放页」请求：先退出编辑。
  ///
  /// 返回 true 表示已消费（调用方必须直接 return，不要继续收起播放页）。
  /// 面板不在当前页签时 `currentState` 为 null —— 此时面板连同编辑状态已被
  /// PageView 销毁，直接放行。系统返回键与顶栏收起按钮共用本判定。
  bool _exitPlaylistEditModeIfActive() =>
      _playlistKey.currentState?.exitEditModeIfActive() ?? false;

  /// 点击下拉按钮直接收起（保留原 _buildTopBar 的 IconButton 行为）。
  void _collapseByButton() {
    // 车机模式：面板常驻，任何入口都不得收起。
    // 这里必须早返回：面板内的 ModalRoute 是 CarModePanel 自带的
    // MaterialPageRoute（不是 DraggablePlayerRoute），会走到下面的 else 分支
    // `Navigator.of(context).maybePop()` 把面板那一页 pop 掉 → 面板永久空白。
    if (widget.dockMode) return;
    final route = ModalRoute.of(context);
    if (route is DraggablePlayerRoute) {
      _isDismissing = true;
      route.dismiss();
    } else if (route == null) {
      // 拖拽覆盖层（非路由）：收起覆盖层，回到 MiniPlayer
      _isDismissing = true;
      playerDragActive.value = false;
      playerExpansion.value = 0.0;
    } else {
      Navigator.of(context).maybePop();
    }
  }

  /// 面板内「整页跳转」的目标 Navigator。
  ///
  /// 车机模式下必须走根 Navigator：面板自带一层 Navigator，按原逻辑
  /// `Navigator.of(context)` 会把专辑页 / 歌手页 / MV 等 pushed 到面板内部，
  /// 把常驻播放器顶掉（视觉上「面板被换成了专辑页」）。
  /// 与 DlnaCastingOverlay 通过 appNavigatorKey 跳转的做法一致。
  NavigatorState? _pageNavigator(BuildContext context) {
    if (widget.dockMode) return appNavigatorKey.currentState;
    return Navigator.maybeOf(context);
  }

  /// 车机模式顶栏左侧按钮：二次确认后退出车机模式（整块面板随之卸载）。
  ///
  /// 车机面板不可收起，所以这里是面板内唯一的「退出」入口；必须走二次确认，
  /// 避免误触后常驻播放器突然消失、用户不知发生了什么。
  Future<void> _confirmExitCarMode() async {
    final exited = await confirmExitCarMode(context);
    if (exited) showToast('已退出车机模式');
  }

  // ── 顶栏向下拖拽原路返回（与上滑展开镜像） ──

  /// Windows 桌面禁用**顶栏**下拉收起：顶栏是窗口拖动区，下拉手势会与拖动
  /// 窗口冲突，收起入口保留左上箭头 / Esc。Android / TV 行为不变。
  bool get _pullToCollapseEnabled => !widget.dockMode && !isWindowsDesktop;

  /// 封面（含竖屏封面 tab）向下拖拽收起：保留原来「拖封面回迷你条」的全平台行为。
  ///
  /// Windows 只禁用顶栏下拉（见 [_pullToCollapseEnabled]），封面不在窗口拖动
  /// 范围内，因此这里恢复；车机面板仍不可收起。
  bool get _coverPullToCollapseEnabled => !widget.dockMode;

  /// Windows 播放页顶栏即窗口标题栏：竖向拖动交给原生窗口移动。
  void _startWindowDrag(DragStartDetails details) {
    WindowsWindowControls.startDrag();
  }

  /// 窗口模式 Zen 的窗口拖拽带是否可见（与 MD 版 full_player.dart 同口径）：
  /// Zen 折叠掉顶栏（唯一拖动区）后，右键进入的沉浸窗口仍是普通窗口，
  /// 没有拖动区就挪不动。长按 / F11 进的 Zen 已真全屏、peek 中 _zenMode 已
  /// 翻回 false、先手动全屏再右键进 Zen 会被原生 fullscreen_ 守卫忽略 ——
  /// 三种情况都不需要 / 不生效。
  bool get _zenWindowDragStripVisible =>
      isWindowsDesktop && !widget.dockMode && _zenMode && !_zenWindowFullscreen;

  /// 窗口模式 Zen 下贴窗口顶边的透明拖拽带：只补一条 startDrag 通道，
  /// 不改 ZenFade 的收起语义（W14：不要动收起语义）。
  Widget _buildZenWindowDragStrip() {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: _startWindowDrag,
      child: const SizedBox(height: 24, width: double.infinity),
    );
  }

  /// 顶栏向下拖拽开始：接管路由 controller（路由已存在，无 push 事件流风险）。
  /// Zen 模式下禁用拖拽收起（退出需长按专辑图），避免误触直接关闭播放器。
  void _onTopBarDragStart(DragStartDetails details) {
    final route = ModalRoute.of(context);
    if (route is! DraggablePlayerRoute || _zenMode) return;
    _topBarDragRoute = route;
    // 停掉可能仍在进行的松手动画、重置 dismiss 标志，并从全屏开始拖拽：
    // 1) 修复连续拖拽不跟手（手指已移动一段才收到首个 update，若不停动画
    //    播放页会从动画中的位置跳变到拖拽位置）；
    // 2) 修复上一次 dismiss 动画中再拖拽时 _isDismissing=true 残留，
    //    导致松手 settleToFull 被吞掉、动画状态错乱。
    route.beginDrag();
    route.controller.value = 1.0;
    // 完整收起距离：拖拽模式用 MiniPlayer 顶端；tap 模式（点击进入）用全局
    // 记录的 MiniPlayer 顶端，让播放页沿「展开路径」原路下滑（1:1 跟手）
    final total = route.dragOriginTop ?? playerDragOriginTop;
    _topBarDragTotal = total > 0 ? total : MediaQuery.sizeOf(context).height;
    route.topBarDragging = true;
    route.topBarDragTotal = _topBarDragTotal;
    _topBarDragDistance = 0.0;
    _topBarDragLastY = toDisplaySpace(context, details.globalPosition).dy;
    _topBarDragLastTime = null;
    _topBarDragVelocity = 0.0;
  }

  /// 顶栏向下拖拽：播放页跟随手指原路下滑（向下为正，向上忽略）。
  void _onTopBarDragUpdate(DragUpdateDetails details) {
    final route = _topBarDragRoute;
    if (route == null) return;
    _topBarDragDistance = (_topBarDragDistance +
            toDisplaySpaceDelta(context, details.delta).dy)
        .clamp(
      0.0,
      double.infinity,
    );
    // 速度估计（按事件时间戳差分，向下为正）
    final ts = details.sourceTimeStamp;
    if (ts != null && _topBarDragLastTime != null && _topBarDragLastY != null) {
      final dt = (ts - _topBarDragLastTime!).inMicroseconds / 1e6;
      if (dt > 0) {
        _topBarDragVelocity =
            (toDisplaySpace(context, details.globalPosition).dy -
                    _topBarDragLastY!) /
                dt;
      }
    }
    _topBarDragLastY = toDisplaySpace(context, details.globalPosition).dy;
    _topBarDragLastTime = ts;
    // 完整收起距离 = MiniPlayer 顶端（与展开镜像）；value 从 1（全屏）→ 0（MiniPlayer）
    final total = _topBarDragTotal;
    if (total <= 0) return;
    final progress = (1.0 - _topBarDragDistance / total).clamp(0.0, 1.0);
    route.controller.stop();
    route.controller.value = progress;
  }

  /// 顶栏向下拖拽松手：下拉达标（距离/速度）且未向上回拉才收起，否则弹回全屏。
  void _onTopBarDragEnd(DragEndDetails details) {
    final route = _topBarDragRoute;
    _topBarDragRoute = null;
    if (route == null) return;
    route.topBarDragging = false;
    // 注意：不在此处清空 topBarDragTotal —— 松手动画（dismiss/settleToFull）
    // 期间保持「原路返回映射」，由 settleToFull 在动画完成时恢复；dismiss 则
    // 随路由销毁。避免映射切换导致播放页跳变、出现「两次下滑动画」
    final threshold =
        MediaQuery.sizeOf(context).height * kPlayerExpandDistanceRatio;
    final downVelocity = details.primaryVelocity ?? _topBarDragVelocity;
    // 回拉判据优先，与上滑展开侧 shouldExpandPlayer 镜像：松手瞬间手指仍向上
    // 运动（下拉后又往上推回去）即视为取消收起，此时即使累计下拉距离已过
    // 阈值也不 dismiss，否则出现「拉下来一截又推回去，结果还是被收起」的误触。
    final collapse =
        downVelocity >= -kPlayerPullBackVelocityThreshold &&
        (_topBarDragDistance >= threshold ||
            downVelocity > kPlayerFlingVelocityThreshold);
    if (collapse) {
      // 只在收起成立时震动（与上滑展开 commit 的触觉对称）；弹回全屏那侧不给——
      // 未发生状态跃迁，震了会把「手势被拒」也报成「手势成功」。
      AppHaptics.lightImpact(HapticCategory.gesture);
      route.dismiss(); // 原路返回：reverse 到 0 + removeRoute
    } else {
      route.settleToFull(); // 弹回全屏
    }
  }

  /// 顶栏拖拽被系统取消（来电/手势中断等）：停在半途时弹回全屏，防御状态残留。
  void _onTopBarDragCancel() {
    final route = _topBarDragRoute;
    _topBarDragRoute = null;
    if (route == null) return;
    route.topBarDragging = false;
    if (route.controller.value < 1.0) {
      route.settleToFull(); // 弹回动画结束时由路由恢复映射
    } else {
      route.topBarDragTotal = null; // 没拖，直接恢复原映射
    }
  }

  /// 拖拽展开完成：切换沉浸模式并移除监听。
  void _onDragRouteStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    applyImmersiveForOrientation();
    _systemUiModified = true;
    _syncLandscapeImmersiveFlag();
    _dragRoute?.controller.removeStatusListener(_onDragRouteStatus);
    _dragRoute = null;
    if (mounted) setState(() {});
  }

  /// 跳转到当前歌曲所在专辑页。
  /// 若 song.albumId 为空（如本地歌曲缺少元数据），提示用户无专辑信息。
  /// 本地/云盘歌曲命中匹配记忆时返回对应的在线歌曲（专辑/歌手跳转用在线 id）。
  /// 纯在线歌曲或未匹配时原样返回。
  Song _resolveMatchedSong(Song song) {
    if (song.isOnline && !song.isCloud) return song;
    final info = SongMatchRepository().get(song.id);
    return (info != null && info.isMatched) ? info.toSong() : song;
  }

  /// 长按标题区：复制「歌名 歌手-专辑」完整信息（如 `晴天 周杰伦-叶惠美`）。
  ///
  /// TV 端无长按语义（接线处已用 kTvBuild 门控为 null），这里不再判平台。
  /// 本地/云盘歌曲命中匹配记忆时用在线元数据，与专辑跳转同口径
  /// （本地文件的 artist/album 常是「未知艺术家/未知专辑」占位）。
  void _copySongInfoToClipboard(Song song) {
    final text = formatSongFullCopyText(_resolveMatchedSong(song));
    if (text.isEmpty) {
      showToast('暂无可复制的歌曲信息', long: true);
      return;
    }
    AppHaptics.click(HapticCategory.listItem);
    Clipboard.setData(ClipboardData(text: text));
    showToast('已复制: $text');
  }

  void _navigateToAlbum(Song song) {
    // 本地歌曲命中匹配记忆时用在线专辑信息（本地文件通常无 albumId）
    final resolved = _resolveMatchedSong(song);
    final albumId = resolved.albumId;
    if (albumId == null || albumId.isEmpty) {
      showToast('暂无专辑信息', long: true);
      return;
    }
    final album = Album(
      id: albumId,
      name: resolved.album.isNotEmpty ? resolved.album : song.album,
      artist: resolved.artist.isNotEmpty ? resolved.artist : song.artist,
      artworkUri: resolved.artworkUri ?? song.artworkUri,
      songCount: 0,
    );
    // 先 dismiss FullPlayer，再 push 专辑页。
    // 注意：必须在 dismiss 之前捕获 navigatorState 引用，因为 dismiss 后
    // widget 会被 dispose，State.mounted 变为 false，原来的 if (mounted) 检查会失败。
    final navigatorState = _pageNavigator(context);
    final route = ModalRoute.of(context);
    if (route is DraggablePlayerRoute) {
      _isDismissing = true;
      route.dismiss();
      Future.delayed(const Duration(milliseconds: 300), () {
        navigatorState?.push(
          MaterialPageRoute(builder: (_) => AlbumDetailPage(album: album)),
        );
      });
    } else {
      navigatorState?.push(
        MaterialPageRoute(builder: (_) => AlbumDetailPage(album: album)),
      );
    }
  }

  /// 拆分歌手名列表：见 `splitSongArtistNames`（与歌手页写真选键同源，勿再各写一份）。
  List<String> _splitArtistNames(String artist) => splitSongArtistNames(artist);

  /// 跳转到当前歌曲所在歌手页。
  /// 若 song.artistId 为空（如本地歌曲缺少元数据），提示用户无歌手信息。
  /// 跳转前先 dismiss FullPlayer，让 MiniPlayer 恢复显示。
  /// 若有多位歌手，弹出二级菜单让用户选择具体某位歌手。
  void _navigateToArtist(Song song) {
    // 本地歌曲命中匹配记忆时用在线歌手信息（本地文件通常无 artistId）
    final resolved = _resolveMatchedSong(song);
    final artists = _splitArtistNames(resolved.artist);
    if (artists.isEmpty) {
      showToast('暂无歌手信息', long: true);
      return;
    }
    // 单歌手：直接跳转
    if (artists.length == 1) {
      _pushArtistPage(resolved.artistId, artists.first);
      return;
    }
    // 多位歌手：弹出二级菜单让用户选择
    _showArtistSelector(context, resolved, artists);
  }

  /// 弹出歌手选择 BottomSheet（多位歌手场景）。
  /// 第一位歌手直接使用 song.artistId 跳转；
  /// 其他歌手通过 searchArtists 接口查询 ID 后跳转。
  void _showArtistSelector(
    BuildContext context,
    Song song,
    List<String> artists,
  ) {
    showM3EModalBottomSheet(
      context: context,
      // 播放页所有弹层统一用实色背景（全局 M3E 主题默认 0.97 alpha 让背景图透出，
      // 压在封面/壁纸上时内容会透底难辨），逐个调用点显式覆盖。
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '选择歌手',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ...artists.map((name) {
                return ListTile(
                  leading: const Icon(Icons.person),
                  title: Text(name),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    // 第一位歌手直接用 song.artistId（数据已存在）
                    if (name == artists.first) {
                      _pushArtistPage(song.artistId, name);
                    } else {
                      // 其他歌手需要先搜索查询 ID
                      _pushArtistPageByName(name);
                    }
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  /// 通过歌手名搜索后跳转歌手详情页。
  /// 显示 loading → 调用 searchArtists → 取第一个匹配 → 跳转
  Future<void> _pushArtistPageByName(String name) async {
    // 显示 loading（AM 风格：白色，与深色模糊背景协调）
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          const Center(child: M3ELoadingIndicator(color: Colors.white)),
    );
    // showDialog 装在根 Navigator 上，且 State dispose 后拿不到 context，必须在 await 前捕获引用
    final navigator = Navigator.of(context, rootNavigator: true);
    void Function()? pendingPush;
    try {
      final api = KugouApiClient();
      final result = await api.searchArtists(name, pagesize: 5);
      if (result == null || result.isEmpty) {
        showToast('未找到歌手「$name」', long: true);
        return;
      }
      final artist = result.first;
      if (!mounted) return;
      // 跳转要用 context，且必须等 loading 关掉后再 push，故先存起来
      pendingPush = () => _pushArtistPage(artist.id, artist.name);
    } catch (e) {
      // showToast 不需要 context，State 已 dispose 也要把失败告知用户
      showToast('搜索歌手失败：$e', long: true);
    } finally {
      navigator.pop(); // 关闭 loading —— 必须在 dispose 后也能关掉
    }
    pendingPush?.call();
  }

  /// 实际 push 歌手详情页。先 dismiss FullPlayer，再 push。
  void _pushArtistPage(String? artistId, String artistName) {
    if (artistId == null || artistId.isEmpty) {
      showToast('暂无歌手信息', long: true);
      return;
    }
    // 注意：必须在 dismiss 之前捕获 navigatorState 引用，因为 dismiss 后
    // widget 会被 dispose，State.mounted 变为 false，原来的 if (mounted) 检查会失败。
    final navigatorState = _pageNavigator(context);
    final route = ModalRoute.of(context);
    if (route is DraggablePlayerRoute) {
      _isDismissing = true;
      route.dismiss();
      Future.delayed(const Duration(milliseconds: 300), () {
        navigatorState?.push(
          MaterialPageRoute(
            builder: (_) => ArtistDetailPage(
              artistId: artistId,
              artistName: artistName,
              avatarUrl: null,
            ),
          ),
        );
      });
    } else {
      navigatorState?.push(
        MaterialPageRoute(
          builder: (_) => ArtistDetailPage(
            artistId: artistId,
            artistName: artistName,
            avatarUrl: null,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // 转场取证用：整页 build 次数。**期望 0** —— 页面应当作为 `child` 被复用、
    // 只由面板裁剪，转场期间整页不该重建。
    coverMorphCountPageBuild(this);
    return ZenChromeDim(
      notifier: _zenChromeDim,
      child: Builder(
        builder: (context) => _tvMenuKeyScope(context, _buildPlayer(context)),
      ),
    );
  }

  /// tv: 播放页按键拦截层（仅 TV 构建）：返回键两层语义 + 遥控菜单键 → 更多菜单。
  ///
  /// 1. [TvPlayerBackInterceptor]：焦点**不在**播放控制 chrome 区（即停在 tab
  ///    内容区 / 遥控 TabBar / 封面区）时，返回键只把焦点交回**播放键**并消费掉
  ///    这次返回；焦点已在控制 chrome 区时才放行给 `_handleTvBack` 退出播放页
  ///    （用户 2026-10-18 / 2026-10-20 真机口径：先退焦点、再按才退页）。
  ///    chrome 区的标记见 [_tvWrapChromeScope]，页签条故意不包。
  /// 2. [TvMenuKeyShortcuts] → 更多菜单（与顶栏「更多」按钮同源 [_showMoreMenu]）：
  ///    CallbackShortcuts 的 Focus 不可聚焦、不参与遍历，只拦 contextMenu；菜单
  ///    bottom sheet 打开后焦点在其路由子树内（非本页子孙），菜单键不会重复触发。
  ///
  /// 其余按键（方向 / OK）原样穿透给 dpad 引擎。
  Widget _tvMenuKeyScope(BuildContext context, Widget child) {
    if (!kTvBuild) return child;
    return TvPlayerBackInterceptor(
      child: TvMenuKeyShortcuts(
        onMenu: () => _showMoreMenu(context),
        child: child,
      ),
    );
  }

  Widget _buildPlayer(BuildContext context) {
    // v4 优化：父级 build 只在切歌（currentSong.id 变化）或播放/暂停（isPlaying）时执行。
    // position 更新（200ms）通过 AppleLyricsView 与进度条自身的 Selector 注入，不触发父级重建。
    return Selector<
      PlayerProvider,
      ({String? songId, bool isPlaying, AudioQuality audioQuality})
    >(
      selector: (_, p) => (
        songId: p.currentSong?.id,
        isPlaying: p.isPlaying,
        audioQuality: p.audioQuality,
      ),
      builder: (context, _, __) {
        final playerProvider = context.read<PlayerProvider>();
        final lyricDoubleTap = context
            .watch<ThemeProvider>()
            .lyricDoubleTapToJump;
        // 播放页背景模糊强度：watch 让设置页改动即时重建本节点，
        // 已模糊栅格随 sigma 变化重算一次（RepaintBoundary 结构保持不变）
        final amBlur = context.watch<ThemeProvider>().amPlayerBlur;
        final currentSong = playerProvider.currentSong;
        final colorScheme = Theme.of(context).colorScheme;

        if (currentSong == null) {
          return Scaffold(
            backgroundColor: colorScheme.surface,
            appBar: AppBar(leading: const BackButton()),
            body: const Center(child: Text('暂无播放')),
          );
        }

        // 初始化封面 URL（首次进入或 null→有值）
        if (_previousArtworkUrl == null && currentSong.artworkUri != null) {
          _previousArtworkUrl = currentSong.artworkUri;
        }

        // 拦截系统返回键：先播放 reverse 动画（mini player 淡入），
        // 动画完成后用 removeRoute 移除路由（绕过 PopScope 避免死循环）。
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop || _isDismissing) return;
            // 车机面板常驻，返回键不得让它消失
            if (widget.dockMode) return;
            if (_zenMode) {
              _exitZenMode();
              return;
            }
            // 播放列表编辑模式优先：返回键先退出编辑，而不是收起播放页
            // （与歌单页多选同口径）。面板不在当前 tab 时 currentState 为 null，
            // 其编辑状态也随之销毁，直接放行。
            if (_exitPlaylistEditModeIfActive()) return;
            // tv: 焦点不在控制 chrome 区时，返回键先把焦点交还播放键并消费本次
            // 返回（与 MD 播放页同一口径；`PopScope` 是真机上覆盖全部返回路径的
            // 那个收口点，见 `full_player.dart` 的同款接线）。
            if (kTvBuild && tvPlayerTryFocusPlay()) return;
            _collapseByButton();
          },
          child: _buildFullLayout(
            playerProvider,
            currentSong,
            colorScheme,
            lyricDoubleTap,
            amBlur,
          ),
        );
      },
    );
  }

  /// 全屏 Apple Music 风格布局：模糊封面背景 + 蒙版 + 三套响应式布局。
  /// 对应 spec.md "Requirement: 模糊封面背景"。
  Widget _buildFullLayout(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
    bool lyricDoubleTap,
    double amBlur,
  ) {
    // extendBody: true 让内容延伸到系统导航栏后面，实现沉浸效果
    // 拖拽展开模式下系统栏样式跟随展开进度，避免拖动过程提前切换（见 PlayerSystemUiScope）
    // 歌手写真：开关开 + 在线歌曲才加载（本地歌没有写真数据）。
    // 写真只进封面位置，不进页面背景——背景 Stack 恢复 09d705d 之前的形态。
    final theme = context.watch<ThemeProvider>();
    final usePhotoBg = theme.useArtistPhotoBackground;
    final wantedPhotoHash =
        usePhotoBg && currentSong.isOnline ? currentSong.id : '';
    final photoInterval = theme.artistPhotoInterval;
    // 设置页「写真背景透明度」是**遮罩浓度**（值越大写真越淡），这里换算成
    // 写真层自身的不透明度。与 MD3 播放页读的是同一个 ThemeProvider 值。
    final photoOpacity = 1.0 - theme.artistPhotoOpacity;
    if (wantedPhotoHash != _photoScheduledHash) {
      _photoScheduledHash = wantedPhotoHash;
      _photoIntervalApplied = photoInterval;
      // 路由接管首帧：同步吃 static 缓存，杜绝方封面闪一帧（见 seedFromCache）
      _photoController.seedFromCache(wantedPhotoHash);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          // ignore: discarded_futures
          _photoController.setHash(
            wantedPhotoHash,
            intervalSeconds: photoInterval,
          );
        }
      });
    } else if (photoInterval != _photoIntervalApplied) {
      // 同一首歌播放中改「轮播间隔」：只按新间隔重起定时器，不清图、不重拉
      // （重跑 setHash 会清空图集并重新请求，画面闪空白）；否则要等下一首才生效。
      _photoIntervalApplied = photoInterval;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _photoController.setInterval(photoInterval);
      });
    }
    // 写真功能开着 → 关闭封面形变（文字形变保留）。每次 build 现写，
    // 覆盖层/路由两个实例交替时判据始终跟随最新的排期意图（不依赖异步落地）。
    // owner 令牌：dispose 只允许当前 owner 复位，防止交接时后销毁的
    // 覆盖层把路由刚写上的 true 抹掉（真机 fling 展开封面复飞的根因）。
    PlayerCoverMorphBus.instance
      ..coverSuppressed = _photoWanted
      ..coverSuppressOwner = this;
    return PlayerSystemUiScope(
      dragRoute: _dragRoute,
      // 拖拽覆盖层（非路由）期间系统栏恒为主页面样式；
      // 车机面板也不是全屏页，同样一律沿用主页面样式。
      forceMainStyle: _isDragOverlay || widget.dockMode,
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBody: true,
        // 键盘弹出时不重排整页：评论托盘自己处理输入框抬升，
        // 底部传输栏/导航条保持原位（否则打字时会被顶上去）
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            // 1. 模糊封面背景层（Apple Music 风格，带淡入淡出）
            //    开启动态流光时不渲染模糊层，只保留流光层（省 GPU 且画面更纯净）
            // RepaintBoundary 隔离：tab 切换/控制栏 setState/评论透传这类整页重建不再连坐本层重绘
            if (!LyricPreferences.instance.useFlowingBackground)
              RepaintBoundary(
                child: _buildCrossfadeBlurredBackground(
                  currentSong.artworkUri,
                  fallbackFilePath: currentSong.localPath,
                  sigma: amBlur,
                ),
              ),
            // 2. 动态流光背景层（可选，从专辑封面提取色彩流动）
            //    playingStream 必须传：本页会被封面形变系统缓存复用（pageBuilds=1），
            //    播放/暂停不重建整页 → 只给 isPlaying 快照会让流光永远停在挂载那
            //    一刻的播放态（真机 [FlowingBG] 日志实证 t 恒 0.00、驱动从未 bind）。
            if (LyricPreferences.instance.useFlowingBackground)
              FlowingBackground(
                artworkUrl: currentSong.artworkUri,
                isPlaying: playerProvider.isPlaying,
                playingStream: AudioService().playingStream,
              ),
            // 3. 半透明蒙版 rgba(0,0,0,0.35)
            _buildDarkOverlay(),
            // 写真统一放在页面背景层：紧凑手机覆盖顶栏到控制区，避免 PageView 与相邻区域的裁剪边缘露线。
            // 宽屏仍只铺左栏，并在左右外缘羽化；两种布局共用控制器与加载状态。
            // 紧凑手机另加一层门控：**只在本页为封面页时显示**（见
            // [_buildCompactPhotoBackground]）——滑到歌单/歌词/评论后歌词页不该
            // 再有写真背景。
            if (getScreenType(MediaQuery.sizeOf(context).width) ==
                ScreenType.compact)
              Positioned.fill(
                child: _buildCompactPhotoBackground(photoOpacity),
              ),
            if (getScreenType(MediaQuery.sizeOf(context).width) !=
                ScreenType.compact)
              // 滤镜/遮罩整页绘制，只限制图片内容宽度；不在 40% 分栏处裁剪滤镜层。
              Positioned.fill(
                child: ListenableBuilder(
                  listenable: _photoController,
                  builder: (context, _) => _photoCoverActive
                      ? RepaintBoundary(
                          child: IgnorePointer(
                            child: AmArtistPhotoCover(
                              currentUrl: _photoController.currentUrl,
                              feather: AmPhotoFeather.rightEdge,
                              photoWidthFraction: 0.4,
                              opacity: photoOpacity,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            // MD3Music fork v51：宽屏写真生效时封面盒不渲染，弹幕宿主随之消失
            // （真机实测：横屏开歌手写真无弹幕，竖屏正常——竖屏封面 tab 的
            // 封面盒仍在）。在写真层之上补一个左栏区域（与写真
            // photoWidthFraction 同宽）的弹幕层；写真关闭时封面盒路径自带
            // 弹幕，两层互斥不会双份。不套 IgnorePointer：弹幕绘制层本身无
            // 手势，右下角"发弹幕"按钮需要可点（与竖屏行为一致）。
            if (getScreenType(MediaQuery.sizeOf(context).width) !=
                ScreenType.compact)
              Positioned.fill(
                child: ListenableBuilder(
                  listenable: _photoController,
                  builder: (context, _) => _photoCoverActive
                      ? FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: 0.4,
                          child: const SongDanmakuHost(
                            cover: SizedBox.expand(),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            // 3.5 频谱背景层：style=2 时显示底部条形频谱图（播放时淡入、暂停时淡出）
            if (_spectrumEnabled && _spectrumStyle == 2)
              SpectrumBackground(
                color: _spectrumColor,
                opacity: _spectrumBgOpacity,
                heightRatio: _spectrumBgHeight,
                visible: playerProvider.isPlaying,
              ),
            // 4. 主体内容（保留原有 compact/landscape/expanded 三套布局）
            ResponsiveLayout(
              compact: (_) => _buildCompactLayout(
                playerProvider,
                currentSong,
                colorScheme,
                lyricDoubleTap,
              ),
              medium: (_) => _buildLandscapeLayout(
                playerProvider,
                currentSong,
                colorScheme,
                lyricDoubleTap,
              ),
              expanded: (_) => _buildExpandedLayout(
                playerProvider,
                currentSong,
                colorScheme,
                lyricDoubleTap,
              ),
            ),
            // tv: 键位提示条——焦点落在带遥控语义的控件上时，于画面下沿提示按键。
            // TvHintBar 自身是 Align(bottomCenter)+SafeArea，只需放在 Stack 最后一位。
            if (kTvBuild) const TvHintBar(),
            // Windows 窗口模式 Zen：顶栏折叠后唯一拖动区消失，贴顶补一条
            // 透明 startDrag 带（不参与布局，不影响 ZenFade 折叠后的居中）。
            if (_zenWindowDragStripVisible)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _buildZenWindowDragStrip(),
              ),
          ],
        ),
      ),
    );
  }

  /// 紧凑手机（竖屏）的写真背景层：**只在本页为封面页时绘制**。
  ///
  /// 写真照旧铺满整页（背景层形态与羽化调校都不动），但页位置一旦离开封面页就
  /// 不再渲染——用户要求「歌词界面没有写真背景，只在封面页显示」。
  /// 判据取 [TabController.animation] 的连续值（= index + offset，由
  /// [PlayerTabPager] 逐帧镜像写入），因此跟手滑走时写真随之淡出，
  /// 不会在下标翻页那一帧硬切。宽屏没有封面 tab（`coverIndex == -1`），
  /// 封面常驻左栏，不走本方法。
  Widget _buildCompactPhotoBackground(double photoOpacity) {
    final tabAnimation = _tabController.animation;
    final coverPage = _tabLayout.coverIndex.toDouble();
    return AnimatedBuilder(
      // 只用它驱动「离封面页多远」的重算；写真本体由 child 传入，不随帧重建。
      animation: tabAnimation ?? const AlwaysStoppedAnimation<double>(0.0),
      builder: (context, child) {
        final t = tabAnimation == null
            ? 0.0
            : (tabAnimation.value - coverPage).abs().clamp(0.0, 1.0);
        // 已离开封面页一整页（歌单 / 歌词 / 评论）：整层不构建，
        // 连模糊底与图片层一起省掉。
        if (t >= 1.0) return const SizedBox.shrink();
        // 0..1 之间跟手淡出：下标在滑程 50% 处才翻页，硬切会看到一次跳变。
        return Opacity(opacity: 1 - t, child: child!);
      },
      child: ListenableBuilder(
        listenable: _photoController,
        builder: (context, _) => _photoCoverActive
            ? RepaintBoundary(
                child: IgnorePointer(
                  child: AmArtistPhotoCover(
                    currentUrl: _photoController.currentUrl,
                    feather: AmPhotoFeather.vertical,
                    opacity: photoOpacity,
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  /// 半透明蒙版层，叠加在模糊封面背景之上。
  ///
  /// 颜色 rgba(0,0,0,0.35) 对应 `Color(0x59000000)`
  /// （0x59 = 89 ≈ 0.35 * 255）。
  Widget _buildDarkOverlay() {
    return const Positioned.fill(child: ColoredBox(color: Color(0x59000000)));
  }

  Widget _buildCompactLayout(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
    bool lyricDoubleTap,
  ) {
    // 竖屏 edgeToEdge 模式：底部系统栏留白与设计留白都收在 _buildControls 里
    // （baseBottom 是控件块整体上移量的唯一来源）。

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          ZenFade(
            animation: _zenAnimation,
            // 「顶栏页签圆点」开关只改变竖屏顶栏中段（圆点 / 空 Spacer），
            // 订阅它让设置页改完回来即时换形态，不需要重进路由。
            child: ListenableBuilder(
              listenable: kTopBarTabDotsEnabled,
              builder: (context, _) => _buildTopBar(playerProvider),
            ),
          ),
          Expanded(
            child: PlayerTabPager(
            key: _pagerKey,
            tabController: _tabController,
            lightweightDesktopSwitch: isWindowsDesktop,
              children: [
                // 播放列表面板（index 0，专辑封面 tab 左侧）
                // 左滑切页：列表卡片吃掉了水平拖拽，靠面板内的指针判定回调补齐
                PlayerPlaylistView(
                  key: _playlistKey,
                  scrollAnchor: _playlistScroll,
                  useDisplayName: true,
                  // 左滑跟手：面板逐帧上报进度，driver 写进 TabController
                  onSwipeStart: _playlistSwipe.start,
                  onSwipeProgress: _playlistSwipe.update,
                  onSwipeRelease: (velocity, width) => _playlistSwipe.settle(
                    velocityPxPerSec: velocity,
                    panelWidth: width,
                  ),
                ),
                // 封面 tab：宽屏/平板不存在（封面常驻左栏）
                if (_tabLayout.hasCover)
                  GestureDetector(
                    onTap: () {
                      // 长按封面切 Zen 模式后松手不再当作点击跳歌词页
                      if (_consumeZenPressTap()) return;
                      _goToTab(_tabLayout.lyricsIndex);
                    },
                    behavior: HitTestBehavior.opaque,
                    // 封面 tab 支持向下拖拽原路返回关闭播放器（全平台恢复：
                    // Windows 的窗口拖动只占顶栏中段，与封面手势不冲突）
                    // 车机模式：封面不参与「下拉原路收起」，否则手势会被白白吃掉
                    // （_onTopBarDragStart 内部会因 route 不是 DraggablePlayerRoute 而早返回，
                    // 但仍是注册了手势识别器）。
                    onVerticalDragStart: _coverPullToCollapseEnabled
                        ? _onTopBarDragStart
                        : null,
                    onVerticalDragUpdate: _coverPullToCollapseEnabled
                        ? _onTopBarDragUpdate
                        : null,
                    onVerticalDragEnd: _coverPullToCollapseEnabled
                        ? _onTopBarDragEnd
                        : null,
                    onVerticalDragCancel: _coverPullToCollapseEnabled
                        ? _onTopBarDragCancel
                        : null,
                    // Selector 让 _buildArtworkView 仅在 currentSong / isPlaying 变化时重建，
                    // 不再每 200ms 因 position 变化重建（封面 AnimatedScale 是隐式动画，需要 isPlaying 触发）
                    child:
                        Selector<
                          PlayerProvider,
                          ({String? songId, bool isPlaying})
                        >(
                          selector: (_, p) => (
                            songId: p.currentSong?.id,
                            isPlaying: p.isPlaying,
                          ),
                          builder: (context, _, __) => ListenableBuilder(
                            listenable: _photoController,
                            builder: (context, _) => _buildArtworkView(
                              playerProvider,
                              currentSong,
                              colorScheme,
                              isExpanded: true,
                            ),
                          ),
                        ),
                  ),
                GestureDetector(
                  onTap: () => _goToTab(1),
                  behavior: HitTestBehavior.translucent,
                  // RepaintBoundary 隔离 AppleLyricsView 每帧 setState 的重绘范围，
                  // 避免父级 TabBarView/Column 被牵连重建
                  child: _wrapLyricsWithTranslateToggle(
                    RepaintBoundary(
                      child: _isLoadingLyrics
                          // AM 风格：歌词 loading 改为白色，与深色背景协调
                          ? const Center(
                              child: M3ELoadingIndicator(color: Colors.white),
                            )
                          // 取词失败/酷狗无词（_parsedLyrics 为空）：给出"暂无歌词"提示，避免空白
                          // 样式与评论区"暂无评论"空状态一致：同字重（titleMedium w500）与同亮度（白 70%）
                          : _parsedLyrics.isEmpty
                          ? _buildAmEmptyLyrics(context)
                          // P0: 用 ListenableBuilder 同时订阅 positionNotifier（高频 200ms）
                          // 与 playerProvider（播放/暂停切换等低频通知）。
                          // 修复：暂停后 positionStream 只发相同值 → ValueNotifier 不通知 →
                          // AppleLyricsView 的 isPlaying 停留旧值 → 内部 Ticker 永不收敛停止 → 120fps。
                          // 监听 provider 后，暂停瞬间 notifyListeners → 重建 → isPlaying 更新。
                          : ListenableBuilder(
                              // 解耦：仅订阅 playerProvider 低频通知（播放/暂停/切歌等），
                              // 高频 positionNotifier 由 AppleLyricsView 内部订阅，
                              // 不再每 200ms 全量重建歌词组件树
                              listenable: playerProvider,
                              builder: (context, _) {
                                return AppleLyricsView(
                                  lines: _parsedLyrics,
                                  currentTimeMs: 0,
                                  positionListenable:
                                      playerProvider.positionNotifier,
                                  adaptTimeMs: _adjustedLyricTimeMs,
                                  isPlaying: playerProvider.isPlaying,
                                  playbackNotReady:
                                      playerProvider.isPlaybackNotReady,
                                  forceDarkBackground: true,
                                  // 本地歌曲 + LRC 逐行歌词：禁用间奏点（节奏点）
                                  enableInterludeDots:
                                      !_isLocalLrcLyricWithoutWordTiming(
                                        currentSong,
                                      ),
                                  doubleTapToJump: lyricDoubleTap,
                                  accentColor: _lyricAccentColor,
                                  // 歌曲 BPM（本地标签/接口，可空）：用于快慢歌辉光阈值
                                  songBpm: currentSong?.bpm,
                                  onSeek: _seekToLyric,
                                );
                              },
                            ),
                    ),
                  ),
                ),
                // 评论 tab：本地歌曲且开启了「关闭本地音乐评论区」时不存在
                if (_tabLayout.hasComments)
                  // Selector 让 CommentsView 仅在切歌时重建（脱离 200ms 通知路径）
                  Selector<PlayerProvider, String?>(
                    selector: (_, p) => p.currentSong?.id,
                    builder: (_, _, __) => CommentsView(
                      songHash: currentSong.id,
                      song: currentSong,
                      albumAudioId: currentSong.albumAudioId,
                      artworkUri: currentSong.artworkUri,
                      isAmStyle: true,
                      // 输入不在播放器里：长按评论段/点「回复」弹出仅输入框的托盘
                      showComposer: false,
                      onReplyComment: _openComposeSheet,
                    ),
                  ),
              ],
            ),
          ),
          ZenFade(
            animation: _zenAnimation,
            // 车机面板是窄容器：用紧凑档控件（传输行 164dp，见
            // MD3ETransportRow），否则 212dp 的传输行 + 40dp 内边距
            // 在 20% 宽的面板里必然 RenderFlex overflow。
            // 与顶栏同一个开关：关闭时页签条回到这一列底部（原形态），
            // 所以两处都得订阅，否则只有半边会跟着换。
            child: ListenableBuilder(
              listenable: kTopBarTabDotsEnabled,
              builder: (context, _) => _buildControls(
                playerProvider,
                colorScheme,
                isExpanded: widget.dockMode,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 右栏内容区（PlayerTabPager）左右边缘渐隐遮罩。
  ///
  /// AM 横屏 / Pad 宽屏右栏的内容（播放列表 / 歌词 / 评论）滚动贴边时被生硬
  /// 裁切，包一层透明度渐隐（EdgeFadeMask）让边缘淡出。遮罩**常驻**，
  /// 不监听 PageController 偏移。开关走 [SettingsRepository.amLandscapeEdgeFade]
  /// 内存镜像：设置页修改后即时生效，无需重进播放页。
  /// TV 不做渐隐（遥控翻页场景边缘淡出反而伤可读性），编译期剔除。
  /// 只包 pager 本体，不包含底部导航条 / 控制带（chrome 不该被雾化）。
  Widget _wrapRightPaneEdgeFade(Widget child) {
    if (kTvBuild) return child;
    return ValueListenableBuilder<bool>(
      valueListenable: SettingsRepository.amLandscapeEdgeFade,
      builder: (context, enabled, _) =>
          EdgeFadeMask(enabled: enabled, child: child),
    );
  }

  /// 手机横屏 / 小尺寸宽屏布局：左侧封面，右侧信息+歌词/评论+控制栏
  Widget _buildLandscapeLayout(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
    bool lyricDoubleTap,
  ) {
    // 横屏/竖屏 edgeToEdge 模式：底部需要额外 padding 避免被导航栏遮挡
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom + 8;

    // 挖孔对称补偿：SafeArea 默认左吃左、右吃右，挖孔只在一侧时左右起点不齐。
    // 这里取左右安全区较大者统一加在两侧（异常值在 cutoutSymmetricInset 内钳制），
    // 再把 MediaQuery 的左右 padding 摘掉，内层 SafeArea 只保留纵向语义。
    // Windows / 无挖孔设备 inset=0，行为与原来一致。
    // 「自定义宽屏边距」开启且用户选择「忽略挖孔避让」时 inset=0：内容完全
    // 贴边（可延伸到挖孔/刘海区域），挖孔遮挡由用户自担。
    final mq = MediaQuery.of(context);
    final cutoutInset =
        (kWidePaneMarginOverride.value != null && kWidePaneIgnoreCutoutEnabled.value)
            ? 0.0
            : PlayerWidePane.cutoutSymmetricInset(mq);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: cutoutInset),
      child: MediaQuery.removePadding(
        context: context,
        removeLeft: true,
        removeRight: true,
        child: SafeArea(
          bottom: false,
          left: false,
          right: false,
          child: Column(
            children: [
              // 顶部栏放在最外层，占据整行：返回按钮真正在屏幕最左上角
              ZenFade(
                animation: _zenAnimation,
                child: _buildTopBar(playerProvider, wide: true),
              ),
          Expanded(
            child: LayoutBuilder(
              // 常驻控制带按**右栏局部**宽高分档：右栏宽 = 内容区 × (1 − 左栏占比)，
              // 占比来自「横屏左右对称分栏」开关（1:1 → 右栏 1/2；关闭 → 4:6），
              // 高即内容区高（顶栏在它上方，不参与分档）。判定不读
              // platformDispatcher 物理快照 —— 转屏动画途中那是旧值，会让 tab 结构
              // 与孩子数量对不上（计划 §2.3 / R4）。
              builder: (context, content) {
                final symmetric = _symmetricPane;
                final leftFraction = PlayerWidePane.leftPaneFraction(symmetric);
                final tier = resolvePlayerDockTier(
                  paneWidth: content.maxWidth * (1 - leftFraction),
                  paneHeight: content.maxHeight,
                  dockMode: widget.dockMode,
                );
                // 左栏的比例内衬、以及「尺与播放键装不装得进左栏」都在这一处判定：
                // 左栏和右栏底部那条 chrome 必须读到**同一个结论**，否则进度尺要么
                // 挂两遍、要么一处都没有。
                final gutter = PlayerWidePane.gutter(
                  content.maxWidth * leftFraction,
                  // 「自定义宽屏边距」覆盖值：非 null 时完全取代比例算法
                  override: kWidePaneMarginOverride.value,
                );
                final bandInLeftPane =
                    !_detachedControls &&
                    !widget.dockMode &&
                    PlayerWidePane.bandFits(
                      innerHeight: content.maxHeight - gutter * 2,
                    );
                return Row(
              children: [
                // ── 左侧：封面 + 歌曲信息 ──
                Expanded(
                  flex: symmetric ? 5 : 4,
                  child: Builder(
                    builder: (context) {
                      // 封面 / 曲名 / 进度尺 / 播放键共用**同一个内容盒**：左右内衬只按
                      // 栏宽取一次比例（外层判定好的 `gutter`，此处不再重算），四件都贴
                      // 这条边线（改造前各吃各的：栏内衬写死 16、曲名按封面边长、
                      // 播放键按自然宽、尺还额外叠一层控制带的 16，左右边缘根本对不齐）。
                      // 刘海由外层 SafeArea 让出，这里只保留等距内衬；
                      // 纵向居中令上下留白相等。
                      final g = gutter;
                      return Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: gutter,
                          vertical: gutter,
                        ),
                        child: AnimatedBuilder(
                          // Zen 淡出途中逐帧重算封面边长：曲名 / 尺 / 播放键被
                          // `ZenFade` 折成 0 高之后，那条 chrome 预留必须跟着归零，
                          // 否则让出来的高度一分都不补给封面（与 MD3 版同口径，
                          // 详见 full_player.dart `_buildLandscapeLayout` 的注释）。
                          // 一次性状态转场，跑完即停，不挂常驻 Ticker（AGENTS §10.1）。
                          animation: _zenAnimation,
                          builder: (context, _) => LayoutBuilder(
                          builder: (context, constraints) {
                            // 封面正方形边长：宽、高两个方向取小的那个。chrome 取
                            // 「实际排在曲名下方那几件」的实测预留，预留准了封面边长
                            // 才等于下面曲名盒的宽度，四件才共用一条左右边线。
                            final chrome = (bandInLeftPane
                                ? PlayerWidePane.bandChrome()
                                : _detachedControls
                                ? PlayerWidePane.titleChrome()
                                : PlayerWidePane.clusterChrome()) *
                                (1 - _zenAnimation.value);
                            final size = PlayerWidePane.coverSize(
                              innerWidth: constraints.maxWidth,
                              innerHeight: constraints.maxHeight,
                              chrome: chrome,
                            );
                            return ListenableBuilder(
                              listenable: _photoController,
                              builder: (context, _) => _photoCoverActive
                                  // 写真已作为出血层铺在背景：左栏只留标题，
                                  // 贴左下（与竖屏「标题叠在写真下缘」同语义）。
                                  ? Align(
                                      alignment: Alignment.bottomLeft,
                                      child: Padding(
                                        // 外层 Padding 已让出 g，这里再补一层：
                                        // 标题离左/下边缘 2g，与旧「外 clamp + 内 +g」等价。
                                        padding: EdgeInsets.only(
                                          left: g,
                                          bottom: g,
                                        ),
                                        child: SizedBox(
                                          width: size,
                                          // 标题块内是无 mainAxisSize 的 Column：
                                          // Align 传入有界高度会被撑满、文字顶到顶上
                                          // （竖屏写真分支同款坑，见 _buildArtworkView），
                                          // 用 min Column 收成内容高再贴左下。
                                          // Zen：写真分支的左栏只剩这块标题（曲名/艺人·专辑），
                                          // 与封面分支同源淡出后整栏让给写真。
                                          child: ZenFade(
                                            animation: _zenAnimation,
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                _buildTitleBlockMorph(
                                                  playerProvider,
                                                  currentSong,
                                                  isExpanded: true,
                                                  alignment:
                                                      CrossAxisAlignment.start,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    )
                                  : Align(
                                      alignment: Alignment.center,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          Flexible(
                                            // 封面定正方形且**按 size 收宽**：与下面的曲名盒同宽，
                                            // 左栏四件（封面/曲名/尺/播放键）才共用同一条左右边线。
                                            // chrome 预留按实测算，故这里不会被压成非方形。
                                            child: SizedBox.square(
                                              dimension: size,
                                              // 封面支持向下拖拽原路返回关闭播放器（横屏/pad 与竖屏一致），
                                              // 同时保留长按封面进入/退出 Zen 模式（按压内缩 + 引导提示）
                                              child: GestureDetector(
                                                behavior: HitTestBehavior.opaque,
                                                // 横屏封面仅注册竖向拖拽时，静止点击会被唯一的
                                                // VerticalDragGestureRecognizer 通过 arena sweep 认领，
                                                // 走进 _onTopBarDrag* 的微拖拽收起路径（曾表现为「点击封面闪回」）。
                                                // 加一个 no-op onTap，让静止点击被 TapGestureRecognizer 赢下手势竞技场。
                                                onTap: _onWideArtworkTap,
                                                // 车机模式：封面不参与「下拉原路收起」，否则手势会被白白吃掉。
                                                onVerticalDragStart:
                                                    _coverPullToCollapseEnabled
                                                        ? _onTopBarDragStart
                                                        : null,
                                                onVerticalDragUpdate:
                                                    _coverPullToCollapseEnabled
                                                        ? _onTopBarDragUpdate
                                                        : null,
                                                onVerticalDragEnd:
                                                    _coverPullToCollapseEnabled
                                                        ? _onTopBarDragEnd
                                                        : null,
                                                onVerticalDragCancel:
                                                    _coverPullToCollapseEnabled
                                                        ? _onTopBarDragCancel
                                                        : null,
                                                child: _wrapArtworkZenPress(
                                                  child: _landscapeCoverBody(
                                                    playerProvider,
                                                    currentSong,
                                                    colorScheme,
                                                  ),
                                                ),
                                              ),
                                            )
                                          ),
                                          // Zen 收起时这段 chrome 连同它的 16 / 12 / 12 三条行距一起折成 0：
                                          // 行距若留在 ZenFade 外层，Zen 收起后封面下面仍占着 40px，
                                          // 整列居中就等于把封面往上顶（上下留白不等）。
                                          ZenFade(
                                            animation: _zenAnimation,
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const SizedBox(
                                                  height: PlayerWidePane.titleGap,
                                                ),
                                                // 歌名 / 艺人·专辑：三种横屏形态（手机横屏、平板竖屏、
                                                // 平板横屏）都固定在封面正下方，**居中**于封面、
                                                // 宽度取封面布局盒 size 与封面同轴；常驻档再往下就是
                                                // 进度尺与播放键，整列一起居中。
                                                // Zen 与传输簇同源淡出：曲名/艺人·专辑也是 chrome，
                                                // 留在屏幕上会与「只剩封面与歌词」的 Zen 语义冲突。
                                                SizedBox(
                                                  width: size,
                                                  child: _buildTitleBlockMorph(
                                                    playerProvider,
                                                    currentSong,
                                                    isExpanded: true,
                                                    alignment:
                                                        CrossAxisAlignment.center,
                                                  ),
                                                ),
                                                // 常驻档（未开「横屏控制面板独立页」）：进度尺与播放键
                                                // 都落在曲名正下方（尺在上、簇在下），横贯左栏内容宽 ——
                                                // dock 传 paddingHorizontal = 0，它自带的那层 16 与左栏
                                                // 比例内衬叠加会让尺比封面/曲名窄一截，边线又对不齐。
                                                // 栏高不够（640×300 这类小横屏）时 bandInLeftPane 为假，
                                                // 尺退回右栏底部那条 chrome，免得封面被压成扁方块。
                                                if (!_detachedControls) ...[
                                                  if (bandInLeftPane) ...[
                                                    const SizedBox(
                                                      height: PlayerWidePane.rowGap,
                                                    ),
                                                    _buildControlDock(
                                                      tier,
                                                      playerProvider,
                                                      colorScheme,
                                                      leftPane: true,
                                                    ),
                                                  ],
                                                  const SizedBox(
                                                    height: PlayerWidePane.rowGap,
                                                  ),
                                                  _buildTransportCluster(
                                                    playerProvider,
                                                    colorScheme,
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                            );
                          },
                        ),
                        ),
                      );
                    },
                  ),
                ),
                // ── 右侧：Tab + 内容 + 控制 ──
                Expanded(
                  flex: symmetric ? 5 : 6,
                  child: Column(
                    children: [
                      // 内容区（播放列表 / 封面信息 / 歌词 / 评论 / 控制?）
                      // 与手机端统一：4 个 tab，ActionBar 按钮索引对齐
                      // 右栏内容区：左右边缘渐隐遮罩（设置项可关，TV 不编入）
                      Expanded(
                        child: _wrapRightPaneEdgeFade(
                          ValueListenableBuilder<bool>(
                            valueListenable: _controlsPageGestureLock,
                            builder: (context, locked, _) => PlayerTabPager(
                              key: _pagerKey,
                              tabController: _tabController,
                              lightweightDesktopSwitch: isWindowsDesktop,
                              // 控制页内按下期间锁横滑：进度条/音量条的水平拖动优先于切页
                              physics: locked
                                  ? const NeverScrollableScrollPhysics()
                                  : null,
                              children: [
                                // 播放列表面板（index 0，封面信息 tab 左侧）
                                // 左滑切页：列表卡片吃掉了水平拖拽，靠面板内的指针判定回调补齐
                                PlayerPlaylistView(
                                  key: _playlistKey,
                                  scrollAnchor: _playlistScroll,
                                  useDisplayName: true,
                                  // 左滑跟手：面板逐帧上报进度，driver 写进 TabController
                                  onSwipeStart: _playlistSwipe.start,
                                  onSwipeProgress: _playlistSwipe.update,
                                  onSwipeRelease: (velocity, width) =>
                                      _playlistSwipe.settle(
                                        velocityPxPerSec: velocity,
                                        panelWidth: width,
                                      ),
                                ),
                                // 控制 tab：宽屏且开启「横屏控制面板独立页」时存在
                                // （进度条 + 传输行 + 音量条，见 _buildLandscapeControlPage）。
                                // 排在歌词之前：播放列表 / 控制 / 歌词 / 评论，
                                // 从歌单左滑一下即达，不必越过歌词与评论。
                                if (_tabLayout.hasControls)
                                  _buildLandscapeControlPage(
                                    playerProvider,
                                    colorScheme,
                                  ),
                                _wrapLyricsWithTranslateToggle(
                                  _isLoadingLyrics
                                      // AM 风格：歌词 loading 改为白色，与深色背景协调
                                      ? const Center(
                                          child: M3ELoadingIndicator(
                                            color: Colors.white,
                                          ),
                                        )
                                      : RepaintBoundary(
                                          // P0: ListenableBuilder 同时订阅 positionNotifier（高频 200ms）
                                          // 与 playerProvider（播放/暂停切换低频通知），保证暂停时
                                          // AppleLyricsView 的 isPlaying 更新、Ticker 收敛后停止
                                          child: ListenableBuilder(
                                            // 解耦：位置走组件内部订阅（同竖屏）
                                            listenable: playerProvider,
                                            builder: (context, _) =>
                                                AppleLyricsView(
                                                  lines: _parsedLyrics,
                                                  currentTimeMs: 0,
                                                  adaptTimeMs: _adjustedLyricTimeMs,
                                                  positionListenable:
                                                      playerProvider
                                                          .positionNotifier,
                                                  isPlaying:
                                                      playerProvider.isPlaying,
                                                  playbackNotReady:
                                                      playerProvider
                                                          .isPlaybackNotReady,
                                                  forceDarkBackground: true,
                                                  // 本地歌曲 + LRC 逐行歌词：禁用间奏点（节奏点）
                                                  enableInterludeDots:
                                                      !_isLocalLrcLyricWithoutWordTiming(
                                                        currentSong,
                                                      ),
                                                  doubleTapToJump:
                                                      lyricDoubleTap,
                                                  accentColor:
                                                      _lyricAccentColor,
                                                  onSeek: _seekToLyric,
                                                ),
                                          ),
                                        ),
                                ),
                                // 评论 tab：本地歌曲且开启了「关闭本地音乐评论区」时不存在
                                if (_tabLayout.hasComments)
                                  // Selector 让 CommentsView 仅在切歌时重建（脱离 200ms 通知路径）
                                  Selector<PlayerProvider, String?>(
                                    selector: (_, p) => p.currentSong?.id,
                                    builder: (_, _, __) => CommentsView(
                                      songHash: currentSong.id,
                                      song: currentSong,
                                      albumAudioId: currentSong.albumAudioId,
                                      artworkUri: currentSong.artworkUri,
                                      isAmStyle: true,
                                      // 输入不在播放器里：长按评论段/点「回复」弹出仅输入框的托盘
                                      showComposer: false,
                                      onReplyComment: _openComposeSheet,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // 导航条从原控制面板中提出常驻：控制面板搬进「控制」页后，
                      // 它必须留在外面，否则进入控制页后无法点击离开（只能滑动）。
                      // 常驻档只有尺装不进左栏（bandInLeftPane 为假）时，
                      // 才在导航条下面追加这条控制带。
                      _buildChromeBottom(
                        tier: tier,
                        playerProvider: playerProvider,
                        showBand: !_detachedControls && !bandInLeftPane,
                        colorScheme: colorScheme,
                        bottomPadding: bottomPadding,
                      ),
                    ],
                  ),
                ),
              ],
            );
              },
            ),
          ),
        ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpandedLayout(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
    bool lyricDoubleTap,
  ) {
    // 横屏/竖屏 edgeToEdge 模式：底部需要额外 padding 避免被导航栏遮挡
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom + 8;

    // 挖孔对称补偿：SafeArea 默认左吃左、右吃右，挖孔只在一侧时左右起点不齐。
    // 这里取左右安全区较大者统一加在两侧（异常值在 cutoutSymmetricInset 内钳制），
    // 再把 MediaQuery 的左右 padding 摘掉，内层 SafeArea 只保留纵向语义。
    // Windows / 无挖孔设备 inset=0，行为与原来一致。
    // 「自定义宽屏边距」开启且用户选择「忽略挖孔避让」时 inset=0：内容完全
    // 贴边（可延伸到挖孔/刘海区域），挖孔遮挡由用户自担。
    final mq = MediaQuery.of(context);
    final cutoutInset =
        (kWidePaneMarginOverride.value != null && kWidePaneIgnoreCutoutEnabled.value)
            ? 0.0
            : PlayerWidePane.cutoutSymmetricInset(mq);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: cutoutInset),
      child: MediaQuery.removePadding(
        context: context,
        removeLeft: true,
        removeRight: true,
        child: SafeArea(
          bottom: false,
          left: false,
          right: false,
          child: Column(
            children: [
              // 顶部栏放在最外层，占据整行：返回按钮真正在屏幕最左上角
              ZenFade(
                animation: _zenAnimation,
                child: _buildTopBar(playerProvider, wide: true),
              ),
          Expanded(
            child: LayoutBuilder(
              // 与 _buildLandscapeLayout 同款档位换算（计划 §2.3 / R4）。
              // 分栏占比同样读「横屏左右对称分栏」开关：1:1 或 4:6。
              builder: (context, content) {
                final symmetric = _symmetricPane;
                final leftFraction = PlayerWidePane.leftPaneFraction(symmetric);
                final tier = resolvePlayerDockTier(
                  paneWidth: content.maxWidth * (1 - leftFraction),
                  paneHeight: content.maxHeight,
                  dockMode: widget.dockMode,
                );
                // 左栏的比例内衬、以及「尺与播放键装不装得进左栏」都在这一处判定：
                // 左栏和右栏底部那条 chrome 必须读到**同一个结论**，否则进度尺要么
                // 挂两遍、要么一处都没有。
                final gutter = PlayerWidePane.gutter(
                  content.maxWidth * leftFraction,
                  // 「自定义宽屏边距」覆盖值：非 null 时完全取代比例算法
                  override: kWidePaneMarginOverride.value,
                );
                final bandInLeftPane =
                    !_detachedControls &&
                    !widget.dockMode &&
                    PlayerWidePane.bandFits(
                      innerHeight: content.maxHeight - gutter * 2,
                    );
                return Row(
              children: [
                Expanded(
                  flex: symmetric ? 5 : 4,
                  child: Builder(
                    builder: (context) {
                      // 封面 + 曲名 +（常驻档的尺与播放键）共用同一个内容盒，
                      // **水平居中**于左栏：内衬直接用外层判定好的 `gutter`，
                      // 四件贴同一条左右边线（口径与 _buildLandscapeLayout 完全一致）。
                      // 刘海由外层 SafeArea 让出，这里只保留等距的内边距；
                      // 纵向居中令上下留白相等。
                      final g = gutter;
                      return Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: gutter,
                          vertical: gutter,
                        ),
                        child: AnimatedBuilder(
                          // 与本页横屏形态同一条口径：chrome 按 Zen 进度折算。
                          animation: _zenAnimation,
                          builder: (context, _) => LayoutBuilder(
                          builder: (context, constraints) {
                            // 正方形边长 = min(栏内宽, 栏内高 − chrome 实测预留)。
                            // 不再封顶 380：封了顶封面就比横贯栏宽的进度尺窄一截，
                            // 左右边线又对不齐。
                            final chrome = (bandInLeftPane
                                ? PlayerWidePane.bandChrome()
                                : _detachedControls
                                ? PlayerWidePane.titleChrome()
                                : PlayerWidePane.clusterChrome()) *
                                (1 - _zenAnimation.value);
                            final maxSize = PlayerWidePane.coverSize(
                              innerWidth: constraints.maxWidth,
                              innerHeight: constraints.maxHeight,
                              chrome: chrome,
                            );
                            return ListenableBuilder(
                              listenable: _photoController,
                              builder: (context, _) => _photoCoverActive
                                  // 写真已作为出血层铺在背景：左栏只留标题，
                                  // 贴左下（与竖屏「标题叠在写真下缘」同语义）。
                                  ? Align(
                                      alignment: Alignment.bottomLeft,
                                      child: Padding(
                                        // 外层 Padding 已让出 g，这里再补一层：
                                        // 标题离左/下边缘 2g，与旧「外 clamp + 内 +g」等价。
                                        padding: EdgeInsets.only(
                                          left: g,
                                          bottom: g,
                                        ),
                                        child: SizedBox(
                                          width: maxSize,
                                          // 标题块内是无 mainAxisSize 的 Column：
                                          // Align 传入有界高度会被撑满、文字顶到顶上
                                          // （竖屏写真分支同款坑，见 _buildArtworkView），
                                          // 用 min Column 收成内容高再贴左下。
                                          // Zen：写真分支的左栏只剩这块标题（曲名/艺人·专辑），
                                          // 与封面分支同源淡出后整栏让给写真。
                                          child: ZenFade(
                                            animation: _zenAnimation,
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                _buildTitleBlockMorph(
                                                  playerProvider,
                                                  currentSong,
                                                  isExpanded: true,
                                                  alignment:
                                                      CrossAxisAlignment.start,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    )
                                  : Align(
                                      alignment: Alignment.center,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          Flexible(
                                            // 与 _buildLandscapeLayout 同口径：封面按 maxSize 定
                                            // 正方形，与曲名/尺/播放键共用一条左右边线。
                                            child: SizedBox.square(
                                              dimension: maxSize,
                                              // 封面支持向下拖拽原路返回关闭播放器（横屏/pad 与竖屏一致），
                                              // 同时保留长按封面进入/退出 Zen 模式（按压内缩 + 引导提示）
                                              child: GestureDetector(
                                                behavior: HitTestBehavior.opaque,
                                                // 见上：no-op onTap 让静止点击被 Tap 识别器赢下竞技场，
                                                // 避免唯一竖向拖拽识别器把点击误判为微拖拽收起（「点击封面闪回」）。
                                                onTap: _onWideArtworkTap,
                                                // 车机模式：封面不参与「下拉原路收起」，否则手势会被白白吃掉。
                                                onVerticalDragStart:
                                                    _coverPullToCollapseEnabled
                                                        ? _onTopBarDragStart
                                                        : null,
                                                onVerticalDragUpdate:
                                                    _coverPullToCollapseEnabled
                                                        ? _onTopBarDragUpdate
                                                        : null,
                                                onVerticalDragEnd:
                                                    _coverPullToCollapseEnabled
                                                        ? _onTopBarDragEnd
                                                        : null,
                                                onVerticalDragCancel:
                                                    _coverPullToCollapseEnabled
                                                        ? _onTopBarDragCancel
                                                        : null,
                                                child: _wrapArtworkZenPress(
                                                  child: _landscapeCoverBody(
                                                    playerProvider,
                                                    currentSong,
                                                    colorScheme,
                                                  ),
                                                ),
                                              ),
                                            )
                                          ),
                                          // 与 _buildLandscapeLayout 同一套收口：16 / 12 / 12 三条行距
                                          // 留在 ZenFade 外层会在 Zen 下残留 40px，把封面顶离纵向中心。
                                          ZenFade(
                                            animation: _zenAnimation,
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const SizedBox(
                                                  height: PlayerWidePane.titleGap,
                                                ),
                                                // 歌名 / 艺人·专辑：固定在封面正下方（三种横屏形态一致），
                                                // **居中**于封面、宽度取封面布局盒 maxSize 与封面同轴；
                                                // 常驻档再往下就是控制带，整列一起居中。
                                                // Zen 与传输簇同源淡出：曲名/艺人·专辑也是 chrome，
                                                // 留在屏幕上会与「只剩封面与歌词」的 Zen 语义冲突。
                                                SizedBox(
                                                  width: maxSize,
                                                  child: _buildTitleBlockMorph(
                                                    playerProvider,
                                                    currentSong,
                                                    isExpanded: true,
                                                    alignment:
                                                        CrossAxisAlignment.center,
                                                  ),
                                                ),
                                                // 常驻档（未开「横屏控制面板独立页」）：进度尺与播放键
                                                // 都落在曲名正下方（尺在上、簇在下），横贯左栏内容宽 ——
                                                // dock 传 paddingHorizontal = 0，它自带的那层 16 与左栏
                                                // 比例内衬叠加会让尺比封面/曲名窄一截，边线又对不齐。
                                                // 栏高不够（640×300 这类小横屏）时 bandInLeftPane 为假，
                                                // 尺退回右栏底部那条 chrome，免得封面被压成扁方块。
                                                if (!_detachedControls) ...[
                                                  if (bandInLeftPane) ...[
                                                    const SizedBox(
                                                      height: PlayerWidePane.rowGap,
                                                    ),
                                                    _buildControlDock(
                                                      tier,
                                                      playerProvider,
                                                      colorScheme,
                                                      leftPane: true,
                                                    ),
                                                  ],
                                                  const SizedBox(
                                                    height: PlayerWidePane.rowGap,
                                                  ),
                                                  _buildTransportCluster(
                                                    playerProvider,
                                                    colorScheme,
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                            );
                          },
                        ),
                        ),
                      );
                    },
                  ),
                ),
                Expanded(
                  flex: symmetric ? 5 : 6,
                  child: Column(
                    children: [
                      // 右栏内容区：左右边缘渐隐遮罩（设置项可关，TV 不编入）
                      Expanded(
                        child: _wrapRightPaneEdgeFade(
                          ValueListenableBuilder<bool>(
                            valueListenable: _controlsPageGestureLock,
                            builder: (context, locked, _) => PlayerTabPager(
                              key: _pagerKey,
                              tabController: _tabController,
                              lightweightDesktopSwitch: isWindowsDesktop,
                              // 控制页内按下期间锁横滑：进度条/音量条的水平拖动优先于切页
                              physics: locked
                                  ? const NeverScrollableScrollPhysics()
                                  : null,
                              children: [
                                // 播放列表面板（index 0，封面信息 tab 左侧）
                                // 左滑切页：列表卡片吃掉了水平拖拽，靠面板内的指针判定回调补齐
                                PlayerPlaylistView(
                                  key: _playlistKey,
                                  scrollAnchor: _playlistScroll,
                                  useDisplayName: true,
                                  // 左滑跟手：面板逐帧上报进度，driver 写进 TabController
                                  onSwipeStart: _playlistSwipe.start,
                                  onSwipeProgress: _playlistSwipe.update,
                                  onSwipeRelease: (velocity, width) =>
                                      _playlistSwipe.settle(
                                        velocityPxPerSec: velocity,
                                        panelWidth: width,
                                      ),
                                ),
                                // 控制 tab：宽屏且开启「横屏控制面板独立页」时存在
                                // （进度条 + 传输行 + 音量条，见 _buildLandscapeControlPage）。
                                // 排在歌词之前：播放列表 / 控制 / 歌词 / 评论，
                                // 从歌单左滑一下即达，不必越过歌词与评论。
                                if (_tabLayout.hasControls)
                                  _buildLandscapeControlPage(
                                    playerProvider,
                                    colorScheme,
                                  ),
                                _wrapLyricsWithTranslateToggle(
                                  _isLoadingLyrics
                                      // AM 风格：歌词 loading 改为白色，与深色背景协调
                                      ? const Center(
                                          child: M3ELoadingIndicator(
                                            color: Colors.white,
                                          ),
                                        )
                                      : RepaintBoundary(
                                          // 解耦：位置走组件内部订阅（同竖屏）
                                          child: ListenableBuilder(
                                            listenable: playerProvider,
                                            builder: (context, _) =>
                                                AppleLyricsView(
                                                  lines: _parsedLyrics,
                                                  currentTimeMs: 0,
                                                  adaptTimeMs: _adjustedLyricTimeMs,
                                                  positionListenable:
                                                      playerProvider
                                                          .positionNotifier,
                                                  isPlaying:
                                                      playerProvider.isPlaying,
                                                  playbackNotReady:
                                                      playerProvider
                                                          .isPlaybackNotReady,
                                                  forceDarkBackground: true,
                                                  // 本地歌曲 + LRC 逐行歌词：禁用间奏点（节奏点）
                                                  enableInterludeDots:
                                                      !_isLocalLrcLyricWithoutWordTiming(
                                                        currentSong,
                                                      ),
                                                  doubleTapToJump:
                                                      lyricDoubleTap,
                                                  accentColor:
                                                      _lyricAccentColor,
                                                  onSeek: _seekToLyric,
                                                ),
                                          ),
                                        ),
                                ),
                                // 评论 tab：本地歌曲且开启了「关闭本地音乐评论区」时不存在
                                if (_tabLayout.hasComments)
                                  // Selector 让 CommentsView 仅在切歌时重建（脱离 200ms 通知路径）
                                  Selector<PlayerProvider, String?>(
                                    selector: (_, p) => p.currentSong?.id,
                                    builder: (_, _, __) => CommentsView(
                                      songHash: currentSong.id,
                                      song: currentSong,
                                      albumAudioId: currentSong.albumAudioId,
                                      artworkUri: currentSong.artworkUri,
                                      isAmStyle: true,
                                      // 输入不在播放器里：长按评论段/点「回复」弹出仅输入框的托盘
                                      showComposer: false,
                                      onReplyComment: _openComposeSheet,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // 导航条从原控制面板中提出常驻：控制面板搬进「控制」页后，
                      // 它必须留在外面，否则进入控制页后无法点击离开（只能滑动）。
                      // 常驻档只有尺装不进左栏（bandInLeftPane 为假）时，
                      // 才在导航条下面追加这条控制带。
                      _buildChromeBottom(
                        tier: tier,
                        playerProvider: playerProvider,
                        showBand: !_detachedControls && !bandInLeftPane,
                        colorScheme: colorScheme,
                        bottomPadding: bottomPadding,
                      ),
                    ],
                  ),
                ),
              ],
            );
              },
            ),
          ),
        ],
          ),
        ),
      ),
    );
  }

  /// 顶部栏。**竖屏**时中间那排圆点就是页签条（[PlayerTopBarTabDots] 占中段，
  /// 尾部胶囊变宽时它左移、再挤就压缩）；宽屏的页签条在右栏底部（见
  /// [_buildChromeBottom]），顶栏不再重复渲染。
  ///
  /// 音质胶囊：竖屏与独立控制页跟着进度条走，落在进度条两侧时间数字的同一行；
  /// 宽屏**常驻档**那一行要留给刻度尺的时间数字，于是回到顶栏。
  Widget _buildTopBar(PlayerProvider playerProvider, {bool wide = false}) {
    // AM 风格顶部栏：返回 + 页签圆点 + 睡眠药丸 + 更多菜单，无把手、无 TabBar。
    // 「歌曲信息 / 播放速度」等原先散落在顶栏与底部胶囊的入口统一收进更多菜单。
    // 颜色：白色 + 透明度区分（与 MD 风格的莫奈色对应）
    // 整个顶栏支持向下拖拽原路返回（点击按钮仍由子元素处理，竞技场自动区分）。
    // tv: 顶栏 = 控制 chrome 区（返回 / 页签圆点 / 睡眠 / 更多）——焦点停在这些
    // 段上按返回键应放行收起播放页，而不是被交还到播放键。圆点形态的
    // PlayerTabStrip 是触屏控件（TV 下不是焦点停点），不会误伤遥控 TabBar。
    // Windows 桌面：顶栏就是窗口标题栏（拖动移动窗口），
    // 下拉收起由 _pullToCollapseEnabled 关闭，最大化/还原与关闭交给右上角三键。
    // **窗口拖动只挂在中段空白区**（见 playerTopBarTabMiddle 的 onWindowDrag）：
    // 整条顶栏接管拖动时，从左上收起键或右上三键上起手的按压会被原生
    // HTCAPTION 抢走 —— 最大化时尤其明显（拖动会把窗口还原，收起键像「点不到」）。
    final bool desktopWindowDrag = isWindowsDesktop && !widget.dockMode;
    final bar = _tvWrapChromeScope(
      GestureDetector(
      behavior: HitTestBehavior.translucent,
      // 车机模式：顶栏不参与「下拉原路收起」，否则手势会被白白吃掉
      // （_onTopBarDragStart 内部会因 route 不是 DraggablePlayerRoute 而早返回，
      // 但仍是注册了手势识别器）。
      onVerticalDragStart: desktopWindowDrag
          ? null
          : (_pullToCollapseEnabled ? _onTopBarDragStart : null),
      onVerticalDragUpdate: desktopWindowDrag
          ? null
          : (_pullToCollapseEnabled ? _onTopBarDragUpdate : null),
      onVerticalDragEnd: desktopWindowDrag
          ? null
          : (_pullToCollapseEnabled ? _onTopBarDragEnd : null),
      onVerticalDragCancel: desktopWindowDrag
          ? null
          : (_pullToCollapseEnabled ? _onTopBarDragCancel : null),
      child: LayoutBuilder(
        // 宽屏（横屏 / Pad）的尾部胶囊贴**页面比例内衬**：顶栏与下方 Row 同宽，
        // 所以按左栏占比取到的 gutter 与左栏封面/曲名/进度尺用的是同一个值
        // （分栏 1:1 时即内容区 1/2，4:6 时即左栏 0.4 倍）。
        // 竖屏沿用原来的 8，不受影响。
        builder: (context, box) => Padding(
          padding: EdgeInsets.only(
            // Windows 顶栏即窗口标题栏：左右不内缩，收起键 / 窗口三键的
            // 命中区才能贴住窗口左右边缘（最大化 / 全屏时可直接点屏幕角落）。
            left: desktopWindowDrag ? 0 : 8,
            right: desktopWindowDrag
                ? 0
                : (wide
                    ? PlayerWidePane.gutter(
                        box.maxWidth * PlayerWidePane.leftPaneFraction(
                          _symmetricPane,
                        ),
                        // 「自定义宽屏边距」覆盖值：与左栏同一来源，保持对齐
                        override: kWidePaneMarginOverride.value,
                      )
                    : 8),
            // Windows 顶栏即窗口标题栏：纵向不内缩，左上收起键的命中区才能
            // 一直顶到窗口上沿（最大化时用户常直接点屏幕左上角）。
            top: desktopWindowDrag ? 0 : 4,
            bottom: desktopWindowDrag ? 0 : 4,
          ),
          child: Row(
          children: [
            // 车机模式：面板不可收起，左侧按钮改为「退出车机模式」（二次确认）
            if (widget.dockMode)
              IconButton(
                icon: const Icon(Icons.close_fullscreen, color: Colors.white),
                tooltip: '退出车机模式',
                onPressed: _confirmExitCarMode,
              )
            else
              // 固定 48×48 命中盒：Windows 顶栏左侧内衬为 0 时，收起键的
              // 命中区一直顶到窗口左上角（最大化时可直接点屏幕角落）。
              SizedBox(
                width: kPlayerTopBarDragZoneHeight,
                height: kPlayerTopBarDragZoneHeight,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(
                    Icons.keyboard_arrow_down,
                    color: Colors.white,
                  ),
                  // 编辑模式下先退出编辑，与系统返回键同口径
                  onPressed: () {
                    if (_exitPlaylistEditModeIfActive()) return;
                    _collapseByButton();
                  },
                ),
              ),
            // 页签条位置由「顶栏页签圆点」开关决定（默认关闭 = 留在底部，见 _buildControls）；
            // 判断口径收在 playerTopBarTabMiddle 里，宽屏恒为 Spacer。
            // Windows：中段空白区同时是窗口拖动区（不吞左右两端的按钮）。
            playerTopBarTabMiddle(
              wide: wide,
              segmentCount: _tabLayout.length,
              strip: () => _buildTabStrip(variant: PlayerTabStripVariant.dots),
              onWindowDrag: desktopWindowDrag ? _startWindowDrag : null,
            ),
            // 顶栏尾部四件事：音质、睡眠定时、一起听、更多。
            // 外层订阅 provider（模式/音质，低频），内层只订阅剩余时间通道（每秒走字），
            // 顶栏整体不跟着逐秒重建。有文案的几格共用**同一颗连体底色**（不再各垫
            // 一块），⋯ 在那层底色之外的裸图标：
            // 竖屏默认只露图标，点任意一枚擦出文案、**按到胶囊以外才收回**（不再有
            // 3 秒定时）；宽屏（与关掉「胶囊按钮收缩」时）文案常显、点一下就直接执行。
            // ⋯ 与长按恒为一步。TV 恒为常显一步。
            // 音质那格标了 collapseOnlyWithPeers：只有睡眠/一起听也在场时才缩成音符，
            // 单独一颗「♪」比「无损音质」难认，那时顶栏也有地方。
            // 车机面板不带它 —— ~20% 宽的窄容器塞不下，徽章留在进度条那一行。
            ListenableBuilder(
              listenable: playerProvider,
              builder: (context, _) => ValueListenableBuilder<Duration?>(
                valueListenable: playerProvider.sleepTimerRemainingNotifier,
                builder: (context, remaining, _) {
                  final style = SleepTimerPillStyle.amOf();
                  final sleep = sleepTimerTopBarSegment(
                    remaining: remaining,
                    mode: playerProvider.sleepTimerMode,
                    onTap: () => showSleepTimerSheet(
                      context: context,
                      player: playerProvider,
                    ),
                  );
                  final listen = listenTogetherTopBarSegment(context);
                  return TopBarTrailingCapsule(
                    segments: [
                      if (!widget.dockMode) ?_qualityTopBarSegment(playerProvider),
                      ?sleep,
                      ?listen,
                    ],
                    background: style.backgroundColor,
                    foreground: style.foregroundColor,
                    // 横屏裸化：不画连体底色。AM 的前景本来就是白（深色蒙版上的
                    // 裸 chrome 取色），所以只关背景、不换色。
                    showBackground: !wide,
                    dotColor: Theme.of(context).colorScheme.error,
                    collapsible: !wide,
                    // AM 顶栏是深色蒙版，没格可展开时那颗裸 ⋯ 要显式给白色
                    moreIconColor: Colors.white,
                    onMore: () => _showMoreMenu(context),
                  );
                },
              ),
            ),
            // Windows：右上角窗口三键（最小化 / 最大化-还原 / 关闭）。
            // AM 顶栏是黑底深色蒙版，图标固定白色；全屏时最大化键自动变为「退出全屏」。
            // 窄窗口放不下时退回「更多」菜单里的同名三项，避免 Row 溢出。
            if (desktopWindowDrag && box.maxWidth >= _kTopBarCaptionMinWidth)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: WindowsCaptionButtonRow(
                  keyPrefix: 'player_window',
                  // 与中段拖动区同高：按钮上下缘贴住窗口上沿，右缘贴住右缘。
                  height: kPlayerTopBarDragZoneHeight,
                  foreground: Colors.white,
                ),
              ),
          ],
        ),
        ),
      ),
    ),
    );

    return bar;
  }

  /// 顶栏尾部胶囊里的「音质」一格 —— 与睡眠定时、一起听、⋯ 共用同一颗连体背景。
  ///
  /// 语义与原独立徽章逐条对齐：本地歌曲屏蔽点击（`onTap` 给 null，胶囊据此让整格
  /// 不响应也不出涟漪）；在线歌曲点开**播放与输出面板**（投屏 / 音量 / 音质同屏，
  /// 面板底部就是四档音质），长按仍复用 [_showVolumeDialog]。
  /// `collapseOnlyWithPeers` = 旁边还有睡眠/一起听时才缩成一颗音符。
  TopBarTrailingSegment _qualityTopBarSegment(PlayerProvider playerProvider) {
    final song = playerProvider.currentSong;
    final isLocal = song is Song && !song.isOnline;
    return TopBarTrailingSegment(
      icon: Icons.music_note,
      label: playerProvider.currentQualityLabel,
      semanticsLabel: '播放与输出',
      collapseOnlyWithPeers: true,
      onTap: isLocal ? null : () => showPlaybackCenterSheet(context),
      onLongPress: () => _showVolumeDialog(playerProvider),
    );
  }

  /// AM v2 质量徽章 — 白色 15% 透明度背景 + StadiumBorder + 图标 + 文字。
  /// 本地歌曲：只读显示码率推断的音质，禁用点击切换。
  /// 在线歌曲：点击复用 showAudioQualityDialog，长按复用 _showVolumeDialog。
  ///
  /// **已知对比度欠账（本轮按决定不动配色）**：白 15% 底 + 纯白前景压在浅色封面或
  /// 自定义壁纸上约 2.3:1，`faded`（8%）更低，均不足图标 3:1 / 文字 4.5:1。
  /// 保留的理由是 AM 深色蒙版的既定观感；真要修，最小改动是在文字下面再压一层暗底托，
  /// 而不是提 alpha（提了就把「透封面」的玻璃感一起丢了）。
  /// [faded] = **淡化**形态，用于进度条下方那一行（车机面板）：只把白色蒙版底降到
  /// 8% alpha，图标与文字保持纯白满色。那一行的时间数字靠各自的 `AnimatedOpacity`
  /// 压暗，徽章若跟着整块合成到封面上就会发灰发暗（看着像禁用）——
  /// 淡是它自己变轻，不是被压暗。
  Widget _buildQualityPill(PlayerProvider playerProvider, {bool faded = false}) {
    final textTheme = Theme.of(context).textTheme;
    final song = playerProvider.currentSong;
    final isLocal = song is Song && !song.isOnline;
    // AM 风格：深色背景蒙版（0.35 黑色）上用白色 15% 透明度作 pill 底
    final pill = Material(
      color: Colors.white.withValues(alpha: faded ? 0.08 : 0.15),
      shape: const StadiumBorder(),
      child: InkWell(
        // 本地歌曲屏蔽音质选择
        onTap: isLocal
            ? null
            : () => showAudioQualityDialog(
                context: context,
                qualities: kPlayerAudioQualities,
                selected: playerProvider.audioQuality,
                onSelected: playerProvider.setAudioQuality,
              ),
        onLongPress: () => _showVolumeDialog(playerProvider),
        customBorder: const StadiumBorder(),
        // 几何取 AppCapsule 的徽章档（与 MD3 版徽章、发现页问候胶囊同一刻度）：
        // 32 的图标方块内含 16 的图标，文案左 2 右 12。
        // 配色按既有决定保持「白 15% 底 + 纯白前景」，见 _buildQualityPill 上方注释。
        child: SizedBox(
          height: AppCapsule.badgeSize,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: AppCapsule.badgeSize,
                child: const Center(
                  child: Icon(
                    Icons.music_note,
                    size: AppCapsule.badgeIcon,
                    color: Colors.white,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(
                  left: AppCapsule.labelLeftPad,
                  right: AppCapsule.labelRightPad,
                ),
                child: Text(
                  // 本地歌曲显示基于码率推断的音质标签
                  playerProvider.currentQualityLabel,
                  style: textTheme.labelMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // tv: 音质药丸 D-pad 单停点（P-A）：OK=音质选择（本地歌曲禁用），
    // OK 长按=音量面板（与触屏 onLongPress 同语义）。
    if (kTvBuild) {
      return DpadFocusable(
        debugLabel: 'am_full_player_quality_pill',
        enabled: !isLocal,
        onSelect: () => showAudioQualityDialog(
          context: context,
          qualities: kPlayerAudioQualities,
          selected: playerProvider.audioQuality,
          onSelected: playerProvider.setAudioQuality,
        ),
        onLongSelect: () => _showVolumeDialog(playerProvider),
        child: pill,
      );
    }
    return pill;
  }

  /// 歌曲弹幕宿主：把弹幕**只盖在封面盒本身**上（不改动封面的尺寸约束）。
  ///
  /// AM 的封面内容没有共同的最底层构建器（宽屏走 `_buildLandscapeArtworkContent`、
  /// 竖屏走 `SpectrumArtwork`/`_buildArtworkWithDynamicCover`、写真走
  /// `AmArtistPhotoCover`），所以三处形态各包一次；MD3 只需包
  /// `_buildCrossfadeArtworkWrapper` 一处。
  Widget _withDanmaku(Widget cover) => SongDanmakuHost(cover: cover);

  /// 横屏/平板左栏封面内容：「形变槽位 + 暂停缩放 + 频谱圆盘/动态封面」原链路。
  /// 写真生效时写真**不再进左栏**——它已移到 `_buildFullLayout` 背景 Stack 的
  /// 出血层，左栏此时只渲染贴左下的标题块（见横屏/平板两处布局的写真分支）。
  /// 两处调用点（手机横屏 / 平板）共用本方法，避免三份拷贝漂移。
  Widget _landscapeCoverBody(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
  ) {
    final cover = PlayerCoverSlot(
      songId: currentSong.id,
      artworkUri: currentSong.artworkUri,
      fallbackFilePath: currentSong.localPath,
      iconSize: 48,
      placeholderColor: Colors.white12,
      shadowColor: colorScheme.shadow,
      eligible: () => _coverMorphEligible,
      // 与下面 AnimatedScale 的稳定态严格一致：
      // 形变层据此把终点落到暂停态的真实矩形，
      // 交接时不需要再补一段缩放动画。
      settledScale: _isDiscCover
          ? 1.0
          : (playerProvider.isPlaying ? 1.0 : 0.85),
      settledAnchor: Alignment.center,
      settledInsetRatio: _coverMorphSettledInset,
      child: AnimatedScale(
        // 频谱模式（style 0/1 圆形旋转封面）不需要封面的放大缩小动画
        scale: _isDiscCover
            ? 1.0
            : (playerProvider.isPlaying ? 1.0 : 0.85),
        // 缩放锚点=中心：宽屏标题居中于封面下方，暂停内缩必须绕同一个视觉中心收，
        // 否则缩到 0.85 的封面偏向左下，与标题、页签圆点不再同轴，四边留白立刻不等。
        // （曾用 bottomLeft：那是标题左对齐年代为「标题左缘贴封面可见左缘」而设。）
        alignment: Alignment.center,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutBack,
        child: _buildLandscapeArtworkContent(
          playerProvider,
          currentSong,
          colorScheme,
        ),
      ),
    );
    return _withDanmaku(cover);
  }

  Widget _buildArtworkView(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme, {
    bool isExpanded = false,
  }) {
    final horizontalPadding = isExpanded ? 16.0 : 32.0;
    final verticalPadding = isExpanded ? 8.0 : 16.0;
    final textSpacing = isExpanded ? 8.0 : 24.0;
    final iconSize = isExpanded ? 48.0 : 64.0;

    // 全屏写真由 _buildFullLayout 的背景层统一绘制；此处只叠加标题，避免 PageView 上下边界形成接缝。
    if (_photoCoverActive) {
      // v44：写真背景分支也包弹幕宿主——此前此分支无封面子树、弹幕宿主未挂，
      // 开启"歌手写真背景"时 AM 风格整页无弹幕（MD3 风格恒有，风格差异实测根因）。
      // 弹幕滚动区锚在容器顶部 45%，写真模式下即全屏背景的上部，位置合理。
      return _withDanmaku(
        Stack(
          fit: StackFit.expand,
          children: [
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: horizontalPadding,
                  vertical: verticalPadding,
                ),
                // 标题块内部是无 mainAxisSize 的 Column（默认 max）：正常布局里它
                // 从父 Column 拿到**无界**高度所以收成内容高；本分支经 Align 传入
                // 有界约束会被撑满整屏、文字顶到顶上。外层再包一个 min Column 把
                // 无界高度传进去，标题恢复按内容高并贴底。
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTitleBlockMorph(
                      playerProvider,
                      currentSong,
                      isExpanded: isExpanded,
                      alignment: CrossAxisAlignment.center,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: verticalPadding,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (!isExpanded) const Spacer(),
          if (isExpanded) ...[
            // 用 Expanded 包一层，让 LayoutBuilder 拿到**有界**的高度：
            // 原实现靠上下两个 Spacer 撑居中，Column 给非 flex 子级的高度约束
            // 是 infinity，于是正方形封面只能按宽度取边长，短屏（车机面板、
            // 横屏手机）下会顶破剩余高度 → RenderFlex overflow。
            // 改后 maxSize 同时受可用高度约束，居中由 Center 保证，长屏观感不变。
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final maxSize = (constraints.maxWidth - 32)
                      .clamp(0.0, 380.0)
                      .clamp(
                        0.0,
                        (constraints.maxHeight - 72).clamp(
                          0.0,
                          double.infinity,
                        ),
                      );
                  // 长按封面进入/退出 Zen 模式：精确 2000ms + 按压内缩与引导提示
                  return Center(
                    child: _wrapArtworkZenPress(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: maxSize,
                          maxHeight: maxSize,
                        ),
                        child: AspectRatio(
                          aspectRatio: 1,
                          // 槽位包在 AnimatedScale 外层：探针上报的矩形会带上
                          // 全部祖先变换，暂停的 0.85 缩放不能混进去。
                          child: _withDanmaku(PlayerCoverSlot(
                            songId: currentSong.id,
                            artworkUri: currentSong.artworkUri,
                            fallbackFilePath: currentSong.localPath,
                            iconSize: iconSize,
                            placeholderColor: Colors.white12,
                            shadowColor: colorScheme.shadow,
                            eligible: () => _coverMorphEligible,
                            // 与下面 AnimatedScale 的稳定态严格一致
                            // （此处 AnimatedScale 无 alignment → 默认 center）
                            settledScale: _isDiscCover
                                ? 1.0
                                : (playerProvider.isPlaying ? 1.0 : 0.85),
                            settledAnchor: Alignment.center,
                            settledInsetRatio: _coverMorphSettledInset,
                            child: AnimatedScale(
                              // 频谱模式（style 0/1 圆形旋转封面）不需要封面的放大缩小动画
                              scale: _isDiscCover
                                  ? 1.0
                                  : (playerProvider.isPlaying ? 1.0 : 0.85),
                              duration: const Duration(milliseconds: 500),
                              curve: Curves.easeOutBack,
                              // 频谱模式：style 0/1 白色圆形旋转封面 + 环形频谱
                              child: _isDiscCover
                                  ? SpectrumArtwork(
                                      artworkUri: currentSong.artworkUri,
                                      fallbackFilePath: currentSong.localPath,
                                      isPlaying: playerProvider.isPlaying,
                                      bandCount:
                                          SpectrumService.instance.bandCount,
                                      style: _spectrumStyle,
                                      barColor: _spectrumColor,
                                      opacity: _spectrumOpacity,
                                      // 与 MiniPlayer 交接期间让位环形柱（交接后 350ms 淡入回来）。
                                      morphProgress: playerExpansion,
                                    )
                                  : _buildArtworkWithDynamicCover(
                                      currentSong,
                                      colorScheme,
                                      artworkUri: currentSong.artworkUri,
                                      fallbackFilePath: currentSong.localPath,
                                      iconSize: iconSize,
                                    ),
                            ),
                          )),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ] else
            Expanded(
              child: AspectRatio(
                aspectRatio: 1,
                // 该分支没有 AnimatedScale（不随暂停缩放），槽位直接包住内容。
                child: _withDanmaku(PlayerCoverSlot(
                  songId: currentSong.id,
                  artworkUri: currentSong.artworkUri,
                  fallbackFilePath: currentSong.localPath,
                  iconSize: iconSize,
                  placeholderColor: Colors.white12,
                  shadowColor: colorScheme.shadow,
                  eligible: () => _coverMorphEligible,
                  // 该分支没有 AnimatedScale（不随暂停缩放）→ 稳定态恒为 1.0
                  settledScale: 1.0,
                  settledAnchor: Alignment.center,
                  settledInsetRatio: _coverMorphSettledInset,
                  child: _isDiscCover
                      ? SpectrumArtwork(
                          artworkUri: currentSong.artworkUri,
                          fallbackFilePath: currentSong.localPath,
                          isPlaying: playerProvider.isPlaying,
                          bandCount: SpectrumService.instance.bandCount,
                          style: _spectrumStyle,
                          barColor: _spectrumColor,
                          opacity: _spectrumOpacity,
                          // 与 MiniPlayer 交接期间让位环形柱（交接后 350ms 淡入回来）。
                          morphProgress: playerExpansion,
                        )
                      : _buildArtworkWithDynamicCover(
                          currentSong,
                          colorScheme,
                          artworkUri: currentSong.artworkUri,
                          fallbackFilePath: currentSong.localPath,
                          iconSize: iconSize,
                        ),
                )),
              ),
            ),
          SizedBox(height: textSpacing),
          // 竖屏标题居中（封面居中显示，标题与封面保持同一中轴）
          _buildTitleBlockMorph(
            playerProvider,
            currentSong,
            isExpanded: isExpanded,
            alignment: CrossAxisAlignment.center,
          ),
          if (!isExpanded) const Spacer(),
        ],
      ),
    );
  }

  /// 播放页标题块的**文字清单**：内容 + 两套样式 + 水平对齐。
  ///
  /// 单独抽出来是为了让 [_buildTitleBlock] 与形变槽位 `PlayerTitleSlot` 用
  /// **同一份**内容与样式——两处各算一次迟早会漂移，形变飞行途中与终点对不上。
  ///
  /// 注意这是 **AM 风格**，与 MD 侧不同，不要照抄 MD：
  /// - 歌名**不转大写**（MD 侧是 `.toUpperCase()`）；
  /// - 标题 `Colors.white` + `w600`（`isExpanded` 时降一号到 `titleMedium`）；
  /// - 副标题 `Colors.white70`，且**副标题恒为 `bodyMedium`**（不随 isExpanded 变）。
  ({
    String title,
    String subtitle,
    TextStyle? titleStyle,
    TextStyle? subtitleStyle,
    Alignment align,
  })
  _titleSpec(
    dynamic currentSong, {
    bool isExpanded = false,
    CrossAxisAlignment alignment = CrossAxisAlignment.stretch,
  }) {
    final textTheme = Theme.of(context).textTheme;
    return (
      // AM 不做大写转换
      title: currentSong.displayName,
      subtitle: currentSong.album.toString().isEmpty
          ? currentSong.artist.toString()
          : '${currentSong.artist} · ${currentSong.album}',
      titleStyle: (isExpanded ? textTheme.titleMedium : textTheme.titleLarge)
          ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
      subtitleStyle: textTheme.bodyMedium?.copyWith(color: Colors.white70),
      // 形变层用它做「迷你条左对齐 → 播放页」的水平对齐插值：
      // 居中档（竖屏 / 圆盘封面）给 center，其余给 centerLeft。
      align: alignment == CrossAxisAlignment.center
          ? Alignment.center
          : Alignment.centerLeft,
    );
  }

  /// 包了文字形变槽位的标题块。
  ///
  /// 槽位只负责上报矩形并在形变期间让位，真实排版仍由 [_buildTitleBlock] 承担
  /// ——`CoverGeometryProbe` 是 `RenderProxyBox`、外层只多一个 `Opacity`，
  /// 都不改变布局，所以包与不包排版完全一致。
  Widget _buildTitleBlockMorph(
    PlayerProvider playerProvider,
    dynamic currentSong, {
    bool isExpanded = false,
    CrossAxisAlignment alignment = CrossAxisAlignment.stretch,
  }) {
    final spec = _titleSpec(
      currentSong,
      isExpanded: isExpanded,
      alignment: alignment,
    );
    return PlayerTitleSlot(
      title: spec.title,
      subtitle: spec.subtitle,
      titleStyle: spec.titleStyle,
      subtitleStyle: spec.subtitleStyle,
      align: spec.align,
      // 文字形变只看结构资格：写真生效时封面不飞，但文字照旧飞
      // （封面侧的让位由 _coverMorphEligible + bus.coverSuppressed 双重把关）。
      eligible: () => _morphStructuralEligible,
      child: _buildTitleBlock(
        playerProvider,
        currentSong,
        isExpanded: isExpanded,
        alignment: alignment,
      ),
    );
  }

  /// 标题区 —— 两行元数据（标题 + 艺人·专辑）。
  ///
  /// 原先「标题 / 艺人 / 专辑」三行居中堆叠。改为 Apple Music 的左对齐布局，
  /// 艺人与专辑合并成一行（同为元数据）。倍速状态与调节入口都在传输行左端。
  /// [alignment] 为 [CrossAxisAlignment.center] 时文字同时居中对齐
  /// （竖屏 Zen 模式），其余形态一律左对齐。
  ///
  /// 内容与样式全部取自 [_titleSpec]，与形变槽位共用同一份，避免两处漂移。
  Widget _buildTitleBlock(
    PlayerProvider playerProvider,
    dynamic currentSong, {
    bool isExpanded = false,
    CrossAxisAlignment alignment = CrossAxisAlignment.stretch,
  }) {
    final spec = _titleSpec(
      currentSong,
      isExpanded: isExpanded,
      alignment: alignment,
    );
    final textAlign = alignment == CrossAxisAlignment.center
        ? TextAlign.center
        : TextAlign.left;
    return Column(
      crossAxisAlignment: alignment,
      children: [
        InkWell(
          onTap: () => _navigateToAlbum(currentSong as Song),
          // 长按任意一行 = 复制完整歌曲信息（TV 端无长按语义，不接线）
          onLongPress: kTvBuild
              ? null
              : () => _copySongInfoToClipboard(currentSong as Song),
          borderRadius: BorderRadius.circular(4),
          // 标题过长时优雅滚动（起停往返 + 边缘渐隐），不换行也不截断。
          child: GentleScrollingText(
            spec.title,
            textAlign: textAlign,
            style: spec.titleStyle,
          ),
        ),
        const SizedBox(height: 2),
        InkWell(
          onTap: () => _navigateToAlbum(currentSong as Song),
          onLongPress: kTvBuild
              ? null
              : () => _copySongInfoToClipboard(currentSong as Song),
          borderRadius: BorderRadius.circular(4),
          child: GentleScrollingText(
            spec.subtitle,
            textAlign: textAlign,
            style: spec.subtitleStyle,
          ),
        ),
      ],
    );
  }

  /// tv: 把「播放控制 chrome 区」标出来——返回键据此判断「焦点已在控制区」
  /// （放行 → 收起播放页）与「焦点在右侧区域 / 页签条」（交还播放键）。
  /// 见 `tv_player_back_focus.dart` 的 `TvPlayerChromeScope`。
  ///
  /// **页签条不包**：`_buildChromeBottom` 里的遥控 TabBar 正是返回键要救的对象，
  /// 包了它焦点停在 tab 栏段时返回键又会被放行成 pop 页面。
  /// 非 TV 构建原样返回，触屏路径零变化。
  Widget _tvWrapChromeScope(Widget child) {
    if (!kTvBuild) return child;
    return TvPlayerChromeScope(child: child);
  }

  /// 底部控制区 —— 三层等权重的旧结构（进度行 / 传输行 / 操作胶囊）压成两层：
  /// 进度（信息）+ 传输（动作），导航独立成一条极简指示条。
  /// 仅竖屏（compact）与车机面板使用；宽屏布局改用 _buildLandscapeControlPage + _buildTabNavBar。
  Widget _buildControls(
    PlayerProvider playerProvider,
    ColorScheme colorScheme, {
    bool isExpanded = false,
  }) {
    final horizontalPadding = isExpanded ? 16.0 : 20.0;
    // 底部的两笔留白：导航栏 inset 是安全区、不算设计留白，baseBottom 才是设计留白。
    // 控件块整体上移多少、内容区因此让出多少高度，**只由 baseBottom 决定**：
    //   传输行下边缘 = 屏底 − 导航栏 inset − baseBottom
    // （进度条与传输行同在一条底锚定的 Column 里，所以两者等量同步移动，相对间距不变。）
    // baseBottom 由「顶栏页签圆点」开关两态决定（关闭：竖屏 10 / 面板 16；开启：均 40），
    // 见 playerBottomDesignInset —— 关闭时页签条就在这一列最底部撑开了视觉下缘，10 即可；
    // 开启后它升到顶栏、传输行成了最底元素，同一个 10 会贴住屏底。
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    final baseBottom = playerBottomDesignInset(expanded: isExpanded);
    final baseGap = isExpanded ? 8.0 : 28.0;

    return Padding(
      padding: EdgeInsets.only(
        left: horizontalPadding,
        right: horizontalPadding,
        bottom: _zenMode ? 16 : bottomInset + baseBottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // tv: **只把控制块这一截**（提示条 / 进度尺 / 传输行）标为控制 chrome。
          // 页签条必须留在作用域之外 —— 遥控 TabBar 正是返回键要救的对象
          // （见 [_tvWrapChromeScope] 与 `_buildChromeBottom` 的同款处置）。
          _tvWrapChromeScope(
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const PlaybackStatusFeedback(amStyle: true),
                // 与上方 tab 内容拉开距离：进度条拖动时时间标签会向上浮出 16px
                SizedBox(height: isExpanded ? 4 : 8),
                // P0: 进度条监听 positionNotifier（高频 200ms）+ provider（duration/切歌等低频），
                // 不再依赖 provider 全量通知更新 position
                ListenableBuilder(
                  listenable: Listenable.merge([
                    playerProvider.positionNotifier,
                    playerProvider,
                    // 「音频过渡中」提示：交叉淡化起止只改这一个 notifier
                    //（见 playback_hint_pills.dart）
                    playerProvider.crossfadeActiveNotifier,
                    // 「伴唱中」提示：伴唱开关只改这一个 notifier
                    playerProvider.accompanyActiveNotifier,
                    // 「伴唱加载中」提示：加载阶段只改这一个 notifier
                    playerProvider.accompanyLoadingNotifier,
                  ]),
                  builder: (context, _) => _buildProgressBar(
                    playerProvider,
                    playerProvider.position,
                    playerProvider.duration ?? Duration.zero,
                    colorScheme,
                  ),
                ),
                // 进度条与播放控件之间留白：竖屏拉到 28，让「时间数字那一行」与按钮
                // 不粘在一起（拖动时时间标签上移 16px，低于这个留白就会压到按钮上）。
                SizedBox(height: baseGap),
                // Selector 让主控制按钮仅在 isPlaying / 播放模式变化时重建，
                // 不再每 200ms 因 position 变化重建
                Selector<
                  PlayerProvider,
                  ({bool isPlaying, bool shuffleEnabled, AppLoopMode loopMode})
                >(
                  selector: (_, p) => (
                    isPlaying: p.isPlaying,
                    shuffleEnabled: p.shuffleEnabled,
                    loopMode: p.loopMode,
                  ),
                  builder: (context, state, _) => _buildMainControls(
                    playerProvider,
                    colorScheme,
                    isExpanded: isExpanded,
                    isPlaying: state.isPlaying,
                    shuffleEnabled: state.shuffleEnabled,
                    loopMode: state.loopMode,
                  ),
                ),
              ],
            ),
          ),
          // 页签条：默认（「顶栏页签圆点」关闭）留在这里，且是**原 icon + 指示线**
          // 形态 —— 底部是一条独立带，图标比圆点认得出页。开启后它升到顶栏中央并
          // 换成圆点，底部让出来的 ~44dp 全部还给内容区。
          ...playerBottomTabSlot(
            isExpanded: isExpanded,
            strip: () => _buildTabStrip(variant: PlayerTabStripVariant.icons),
          ),
        ],
      ),
    );
  }

  /// 宽屏形态是否把控制带做成独立「控制」页（用户开关）。
  ///
  /// **与 [_syncTabLayout] 的 `showControlsPage` 同一个表达式**：tab 结构
  /// （有没有控制页）与右栏底部（挂不挂常驻带）必须同源，否则 pager 的 children
  /// 数量与 TabController.length 不一致会直接抛断言（计划 R4）。
  bool get _detachedControls =>
      !widget.dockMode && kLandscapeDetachedControlsEnabled.value;

  /// 宽屏左右分栏是否对称（1:1）。用户开关；车机模式（dockMode）固定单栏，
  /// 与分栏无关，跟 [_detachedControls] 一样先排除。
  bool get _symmetricPane =>
      !widget.dockMode && kSymmetricWidePaneEnabled.value;

  /// 常驻档的**进度尺带**。`leftPane` 决定它挂在哪一栏，并连带两件事：
  ///
  /// - `paddingHorizontal`：左栏已经按 [PlayerWidePane.gutter] 内衬过一次，dock 默认
  ///   那层 16 再叠上去，尺就比封面/曲名窄一截，左右边线对不齐；右栏那条 chrome
  ///   没有这层内衬，仍用 dock 默认值。
  /// - `showStatusFeedback`：加载/失败提示条约 50dp 高，只能待在右栏（它上面是
  ///   `Expanded` 内容区，撑高自己吸收）；左栏 chrome 全是不定高的非 flex 子项，
  ///   塞进去就吃掉封面甚至溢出（800×360 + 1.3 倍字 + 报错实测会炸）。
  ///
  /// 不传 `swipeLock`：尺与 pager 是兄弟节点，拖动滑条不会抢走翻页手势，
  /// 再上锁只会让整页滑不动（计划 §2.2 ①、§1.6 的手势锁 checklist 在本档退役）。
  Widget _buildControlDock(
    PlayerDockTier tier,
    PlayerProvider playerProvider,
    ColorScheme colorScheme, {
    required bool leftPane,
  }) {
    return PlayerControlDock(
      tier: tier,
      skin: DockSkin.am,
      playerProvider: playerProvider,
      colorScheme: colorScheme,
      visible: !_zenMode,
      paddingHorizontal: leftPane ? 0 : null,
      showStatusFeedback: !leftPane,
      // 徽章与传输簇都不进带：常驻档徽章回到顶栏（见 _buildTopBar）、传输簇由宿主
      // 排在尺的下方（见 _buildTransportCluster），二者在此均取默认值。
      // 独立控制页才由 dock 自己排（放大档），音质徽章挂回时间数字同一行 ——
      // 常驻档的那一行要给刻度尺与剩余时长留出宽度。
      transport: null,
    );
  }

  /// 传输簇：常驻档把它放在左栏曲名正下方；独立控制页由 dock 自己排（放大档）。
  ///
  /// 与 _buildControls 同款 Selector：主控制按钮仅在播放态/模式变化时重建。
  Widget _buildTransportCluster(
    PlayerProvider playerProvider,
    ColorScheme colorScheme,
  ) {
    return Selector<
      PlayerProvider,
      ({bool isPlaying, bool shuffleEnabled, AppLoopMode loopMode})
    >(
      selector: (_, p) => (
        isPlaying: p.isPlaying,
        shuffleEnabled: p.shuffleEnabled,
        loopMode: p.loopMode,
      ),
      builder: (context, state, _) => _buildMainControls(
        playerProvider,
        colorScheme,
        isExpanded: true,
        isPlaying: state.isPlaying,
        shuffleEnabled: state.shuffleEnabled,
        loopMode: state.loopMode,
      ),
    );
  }

  /// 宽屏右栏底部 chrome：页签条，外加**装不进左栏时**的进度尺带。
  ///
  /// 常驻档的尺与播放键都在左栏曲名下方（`showBand` 为假，这里只剩页签条）；只有
  /// 栏高不够（640×300 这类小横屏，见 [PlayerWidePane.bandFits]）时尺才留在这条
  /// chrome 里。detached 档的控制带在「控制」页里，此处同样不挂。
  /// 整体由 [ZenFade] 淡出。
  ///
  /// 页签条的形态与竖屏底部同源 —— 由「顶栏页签圆点」开关决定，见
  /// [playerWideTabStripVariant]。
  Widget _buildChromeBottom({
    required PlayerDockTier tier,
    required PlayerProvider playerProvider,
    required bool showBand,
    required ColorScheme colorScheme,
    required double bottomPadding,
  }) {
    return ZenFade(
      animation: _zenAnimation,
      child: Padding(
        padding: EdgeInsets.only(bottom: _zenMode ? 8 : bottomPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // tv: **只把尺带 / 提示条这一截**标为控制 chrome。页签条必须留在
            // 作用域之外 —— 遥控 TabBar 正是返回键要救的对象（见 [_tvWrapChromeScope]
            // 与 `_buildControls` 的同款处置）。
            _tvWrapChromeScope(
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showBand)
                    _buildControlDock(
                      tier,
                      playerProvider,
                      colorScheme,
                      leftPane: false,
                    )
                  else if (!_detachedControls)
                    const PlaybackStatusFeedback(amStyle: true),
                ],
              ),
            ),
            // 宽屏右栏底部的形态与竖屏底部同源（关 = icon + 指示线，开 = 圆点），
            // 见 playerWideTabStripVariant；位置不变，横屏恒在右栏底部。
            // 订阅开关让设置页改完回到播放页即时换形态，不必重进路由。
            ListenableBuilder(
              listenable: kTopBarTabDotsEnabled,
              builder: (context, _) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _buildTabStrip(variant: playerWideTabStripVariant()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 宽屏「控制」页：进度条 + 传输行 + 音量条，布局与皮肤由 [PlayerControlDock]
  /// 统一实现（MD/AM 共用一份，内容收窄 420 居中、纵向撑满等口径见该文件）。
  ///
  /// 这里只注入本版的传输簇与横滑手势锁。手势锁罩在两条滑条所在的行上（见
  /// [_lockSliderRowSwipe]）：罩住整页会让「在控制页左右滑动切页」彻底失效。
  Widget _buildLandscapeControlPage(
    PlayerProvider playerProvider,
    ColorScheme colorScheme,
  ) {
    // tv: 独立「控制」页整页都是控制 chrome —— 焦点停在这里按返回键应放行
    // （收起播放页），而不是被交还到播放键（见 [_tvWrapChromeScope]）。
    return _tvWrapChromeScope(
      PlayerControlDock(
        tier: PlayerDockTier.detached,
        skin: DockSkin.am,
        playerProvider: playerProvider,
        colorScheme: colorScheme,
        // 独立控制页不再挂音质徽章：它与其它形态同规则，统一在顶栏（见 _buildTopBar）。
        // 与 _buildControls 同款 Selector：主控制按钮仅在播放态/模式变化时重建
        // 独立控制页有整页高度：中间三控件用不加窄的全尺寸档
        // （skip 38 / play 54 / 间距 12，比常驻档的 30/44 明显放大）
        transport: Selector<
          PlayerProvider,
          ({bool isPlaying, bool shuffleEnabled, AppLoopMode loopMode})
        >(
          selector: (_, p) => (
            isPlaying: p.isPlaying,
            shuffleEnabled: p.shuffleEnabled,
            loopMode: p.loopMode,
          ),
          builder: (context, state, _) => _buildMainControls(
            playerProvider,
            colorScheme,
            isExpanded: false,
            isPlaying: state.isPlaying,
            shuffleEnabled: state.shuffleEnabled,
            loopMode: state.loopMode,
          ),
        ),
        swipeLock: _lockSliderRowSwipe,
      ),
    );
  }

  /// 把横滑手势锁罩住一行：按住期间 pager 不可横滑，松手还原。
  ///
  /// 置位时机是**指针按下**而不是滑条自己的拖拽起手——那要晚一帧以上，
  /// PageView 可能已在手势竞技场里把这次拖拽认领走（见 [_controlsPageGestureLock]）。
  Widget _lockSliderRowSwipe(Widget child) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _controlsPageGestureLock.value = true,
      onPointerUp: (_) => _controlsPageGestureLock.value = false,
      onPointerCancel: (_) => _controlsPageGestureLock.value = false,
      child: child,
    );
  }

  /// 进度条 —— AM 皮肤用纯细线，无手柄；按下时轨道膨胀并浮出时间数字。
  Widget _buildProgressBar(
    PlayerProvider playerProvider,
    Duration position,
    Duration duration,
    ColorScheme colorScheme,
  ) {
    final song = playerProvider.currentSong;
    // 一起听听众端：进度条可拖动，拖动即进入脱离态（本地自由播放），
    // 恢复跟随走房间页中央按钮 / 广场横幅（见 RoomSession.detachBySeek）。
    return PlayerSeekBar(
      position: position,
      duration: duration,
      isPlaying: playerProvider.isPlaying,
      md3Style: false,
      speed: playerProvider.speed,
      activeColor: Colors.white,
      inactiveColor: Colors.white24,
      labelColor: Colors.white70,
      climaxStart: song?.climaxStart?.toDouble(),
      // 只有车机窄面板把徽章留在时间数字这一行；其余形态统一在顶栏（见 _buildTopBar），
      // 这里再挂一枚就是同一个信息出现两次。
      labelRowBadge: widget.dockMode
          ? _buildQualityPill(playerProvider, faded: true)
          : null,
      // 时间行中央的瞬时状态提示（「缓冲中」/「音频过渡中」）：居中于两个时间
      // 数字之间，与徽章共用中央组；无提示时传 null，时间行保持原 14dp 定高。
      labelRowHints: playerHintPillsFor(playerProvider, amStyle: true),
      climaxEnd: song?.climaxEnd?.toDouble(),
      onSeekStart: () {
        _wasPlayingBeforeDrag = playerProvider.isPlaying;
        if (_wasPlayingBeforeDrag) {
          playerProvider.pauseForSeek();
        }
      },
      onSeekEnd: (value) async {
        AppHaptics.tick(HapticCategory.transport);
        // forceNotify：松手是用户显式动作，远端纠偏的抑制窗口不得吞掉通告
        // （否则听众的「拖动即脱离」会被静默吞掉并被纠偏拉回）
        await playerProvider.seek(value, forceNotify: true);
        if (_wasPlayingBeforeDrag) {
          playerProvider.resume();
        }
      },
    );
  }

  /// 传输行 —— 中央 prev/play/next，左端播放模式、右端收藏。
  ///
  /// 播放模式把原先分开的 shuffle 与 loop 合成一个循环按钮
  /// （不循环 → 列表循环 → 单曲循环 → 随机），传输行因此从 5 个目标回到 3 个，
  /// 播放键得以放大；模式与收藏落在居中留下的左右空白里，不额外占纵向高度。
  /// 倍速与投屏都在右上角的更多菜单里。
  Widget _buildMainControls(
    PlayerProvider playerProvider,
    ColorScheme colorScheme, {
    bool isExpanded = false,
    required bool isPlaying,
    required bool shuffleEnabled,
    required AppLoopMode loopMode,
  }) {
    // Apple Music HIG 风格：大按钮居中，白色图标，圆形白色播放按钮
    final spacing = isExpanded ? 8.0 : 12.0;
    final skipIconSize = isExpanded ? 30.0 : 38.0;
    final playIconSize = isExpanded ? 44.0 : 54.0;
    // 传输按钮线宽跟随同一页的「已播放进度条」：AM 页进度条是 md3Style=false 的
    // 2px 常态轨道（见 _buildProgressBar；PlayerSeekBar 的 _idleFlatHeight），
    // 所以按钮线宽取它的 2 倍（侧键 4px）与 3 倍（播放键 6px），保留「播放键比
    // 侧键更粗」的层级。strokeWidth 是 24 基准 viewBox 单位、渲染时按 size/24
    // 缩放（iconic_morph 的 _StaticIconPainter），故必须按各自图标尺寸反算成
    // viewBox 值，常态档与停靠档的屏幕线宽才都恒为 4px / 6px。
    const double amProgressBarStroke = 2.0;
    final skipStrokeWidth = amProgressBarStroke * 2 * 24 / skipIconSize;
    final song = playerProvider.currentSong;
    // 根据歌曲来源（本地/在线）选择对应的收藏 Provider
    final isOnline = song is Song && song.isOnline;
    final isFavorited =
        song != null &&
        (isOnline
            ? context.watch<FavoritesProvider>().isFavorite(song.id)
            : context.watch<LocalFavoritesProvider>().isFavorite(song.id));

    // tv: 传输三键 + 播放模式 + 收藏 = 控制 chrome 的核心，整行包进作用域。
    // 左栏常驻簇（_buildTransportCluster）、独立控制页都经这里出去，一处接线
    // 覆盖两条路径。非 TV 构建原样返回 Row，触屏路径零变化。
    return _tvWrapChromeScope(
      Row(
        children: [
        // 左端：播放模式（不循环 → 列表循环 → 单曲循环 → 随机，单键循环切换）
        // AM 风格：不加任何底色，只用图标亮度区分是否处于非默认模式
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: _buildEdgeAction(
              debugLabel: 'tv/play-mode',
              icon: _playModeIcon(shuffleEnabled, loopMode),
              color: (!shuffleEnabled && loopMode == AppLoopMode.off)
                  ? Colors.white.withValues(alpha: 0.45)
                  : Colors.white,
              onTap: () {
                AppHaptics.tick(HapticCategory.transport);
                playerProvider.cyclePlayMode();
              },
            ),
          ),
        ),
        // 上一曲 / 播放暂停 / 下一曲：中央为 PlayPauseMorphIcon 双轨实心形变，
        // prev/next 点击描边重绘
        AMTransportControls(
          isPlaying: isPlaying,
          skipIconSize: skipIconSize,
          playIconSize: playIconSize,
          spacing: spacing,
          strokeWidth: skipStrokeWidth,
          onPrevious: () {
            AppHaptics.click(HapticCategory.transport);
            playerProvider.previous();
          },
          onPlayPause: () {
            AppHaptics.click(HapticCategory.transport);
            if (isPlaying) {
              playerProvider.pause();
            } else {
              playerProvider.resume();
            }
          },
          onNext: () {
            AppHaptics.click(HapticCategory.transport);
            playerProvider.next();
          },
        ),
        // 右端：收藏
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: _buildEdgeAction(
              debugLabel: 'tv/favorite',
              icon: isFavorited ? Icons.favorite : Icons.favorite_border,
              // 收藏激活时用红色强调（与 MD 风格一致）
              color: isFavorited ? Colors.redAccent : Colors.white,
              onTap: song == null
                  ? null
                  : () {
                      if (isFavorited) {
                        AppHaptics.click(HapticCategory.transport);
                      } else {
                        AppHaptics.heavy(HapticCategory.transport);
                      }
                      if (isOnline) {
                        context.read<FavoritesProvider>().toggleFavorite(song);
                      } else {
                        context.read<LocalFavoritesProvider>().toggleFavorite(
                          song.id,
                        );
                      }
                    },
              // 长按：在线歌曲弹出 AI 推荐歌曲面板
              onLongPress: song != null && isOnline
                  ? () => showAiRecommendSheet(context, song)
                  : null,
            ),
          ),
        ),
        ],
      ),
    );
  }

  /// 传输行两端的次要动作：48dp 圆形触达区，无容器背景。
  /// 不挂 Tooltip：长按只执行长按动作（如收藏长按开 AI 推荐），不弹按钮说明。
  ///
  /// tv: TV 构建换 [TvPlayerEdgeAction]（`DpadFocusable` 单停点）——裸 `InkWell`
  /// 在 TV 上落不下焦点（见该组件类注释）。非 TV 构建原样返回 `InkWell`，
  /// 触屏路径零变化。
  Widget _buildEdgeAction({
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
    String? debugLabel,
  }) {
    final body = SizedBox(
      width: 48,
      height: 48,
      child: Center(child: Icon(icon, size: 24, color: color)),
    );
    if (kTvBuild) {
      return TvPlayerEdgeAction(
        icon: icon,
        color: color,
        debugLabel: debugLabel,
        onSelect: onTap,
        onLongSelect: onLongPress,
      );
    }
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      customBorder: const CircleBorder(),
      child: body,
    );
  }

  /// 合并后的播放模式图标：随机优先，其次看循环模式。
  IconData _playModeIcon(bool shuffleEnabled, AppLoopMode loopMode) {
    if (shuffleEnabled) return Icons.shuffle;
    switch (loopMode) {
      case AppLoopMode.off:
        // 不循环：空心箭头（播完即停）
        return Icons.repeat_outlined;
      case AppLoopMode.one:
        // 单曲循环：带数字 1
        return Icons.repeat_one;
      case AppLoopMode.all:
        // 列表循环：实心箭头，播完回到第一首
        return Icons.repeat;
    }
  }

  /// 底部导航条 —— 只做页面切换这一件事（原先与倍速/收藏/翻译混装在一条胶囊里）。
  ///
  /// 段序与各项语义见 [buildPlayerTabItems]（MD/AM 共用一份，本函数只供配色与回调）。
  /// 封面/评论 tab 是否存在由 [_tabLayout] 决定：**不能用 `length == 4` 反推**，
  /// 隐藏评论 tab 后竖屏长度同样会变成 3，反推会连带误删封面 tab。
  /// items 随之裁剪，指示线分段宽度由 [PlayerTabStrip] 按实际段数计算。
  Widget _buildTabStrip({required PlayerTabStripVariant variant}) {
    // tv: 遥控构建下换成遥控专属 TabBar（P-E）：PlayerTabStrip 是拖拽驱动的
    // 触屏控件，D-pad 无法聚焦其分段；Material TabBar 的段是 InkWell，
    // 聚焦后 OK 键经 TabController.animateTo 切页（PlayerTabPager 监听
    // controller 跟随）。三处布局（竖屏/横屏/展开）共用本方法，一处分支全覆盖。
    // 圆点 / icon 两种形态在 TV 下不存在，故 variant 参数在这条分支上不被读取。
    if (kTvBuild) return _buildRemoteTabBar();
    final song = context.read<PlayerProvider>().currentSong;
    final isOnline = song is Song && song.isOnline;
    return PlayerTabStrip(
      controller: _tabController,
      activeColor: Colors.white,
      // 0.62 而不是 0.45：AM 版背景是封面模糊/流光壁纸，0.45 的白点在中亮背景
      // 上基本看不见，未选中态会整片消失（只剩一颗大白点）。
      inactiveColor: Colors.white.withValues(alpha: 0.62),
      variant: variant,
      instantDesktopTap: isWindowsDesktop,
      onSegmentWidth: (w) => _tabDragBtnW = w,
      onDragStart: _onTabDragStart,
      onDragUpdate: _onTabDragUpdate,
      onDragEnd: _onTabDragEnd,
      items: buildPlayerTabItems(
        hasCover: _tabLayout.hasCover,
        hasControls: _tabLayout.hasControls,
        hasComments: _tabLayout.hasComments,
        desktopLyricEnabled: DesktopLyricService.instance.enabled,
        coverOnLongPress:
            song != null &&
                    isOnline &&
                    AmStyleFullPlayer.coverLongPressCallback != null
            ? () {
                AppHaptics.lightImpact(HapticCategory.navigation);
                AmStyleFullPlayer.coverLongPressCallback!(context, song);
              }
            : null,
        lyricsOnLongPress: _toggleDesktopLyric,
        commentsOnLongPress: () => _openComposeSheet(),
      ),
    );
  }

  /// tv: 遥控专属底部 TabBar（P-E）：左右方向键直接切页，无需 OK。
  /// labels 由 [_tabLayout] 的 tabKinds 派生（顺序唯一真值）。
  /// 配色沿用本文件 PlayerTabStrip 的 AM 深色底白系（既有风格，非新增硬编码）。
  Widget _buildRemoteTabBar() {
    return AnimatedBuilder(
      animation: _tabController,
      builder: (context, _) => TvPlayerTabBar(
        labels: [
          for (final kind in _tabLayout.tabKinds)
            switch (kind) {
              PlayerTabKind.playlist => '列表',
              PlayerTabKind.cover => '封面',
              PlayerTabKind.controls => '控制',
              PlayerTabKind.lyrics => '歌词',
              PlayerTabKind.comments => '评论',
            }
        ],
        currentIndex: _tabController.index,
        activeColor: Colors.white,
        inactiveColor: Colors.white.withValues(alpha: 0.45),
        onSelected: (index) => _tabController.animateTo(index),
      ),
    );
  }

  /// 长按评论段：弹出仅含输入框的评论托盘（主题色设计，不显示评论列表）。
  ///
  /// [replyTo] 非空表示由评论项「回复」进入，发送的是该评论下的楼层回复。
  /// 播放器内不驻留任何输入控件。
  void _openComposeSheet([CommentReplyTarget? target]) {
    AppHaptics.lightImpact(HapticCategory.navigation);
    final player = context.read<PlayerProvider>();
    final song = player.currentSong;
    if (song == null) return;
    showCommentComposeSheet(
      context,
      song: song,
      target: target,
      // 与 MD3 风格播放页同一口径：只有「顶层模式 + 在线歌曲」才给评论/弹幕切换。
      onDanmakuSent: target == null && songDanmakuUsable(song)
          ? (text) =>
              SongDanmakuHost.deliverText(text, song.id, player.position)
          : null,
    );
  }

  /// 长按歌词段：开关桌面歌词，并同步通知栏的「桌面歌词」按钮状态。
  Future<void> _toggleDesktopLyric() async {
    AppHaptics.lightImpact(HapticCategory.navigation);
    await DesktopLyricService.instance.toggle();
    if (!mounted) return;
    final player = context.read<PlayerProvider>();
    final curSong = player.currentSong;
    // 收藏状态需实时查询，避免暂停时显示为未收藏
    bool isFavorited = false;
    if (curSong != null) {
      try {
        isFavorited = context.read<FavoritesProvider>().isFavorite(curSong.id);
      } catch (_) {}
    }
    await MediaNotificationService.updateNotification(
      // 用 displayName 剥离 .mp3 等后缀，避免标题显示文件名
      title: curSong?.displayName ?? '',
      artist: curSong?.artist ?? '',
      artUrl: curSong?.artworkUri,
      isPlaying: player.isPlaying,
      position: player.position,
      // 时长兜底：_duration 为空时用曲目元数据自带的总时长（见
      // PlayerProvider._pushNotification 的同口径注释）。
      duration: player.duration ?? curSong?.duration ?? Duration.zero,
      desktopLyricEnabled: DesktopLyricService.instance.enabled,
      isFavorited: isFavorited,
      // 与 PlayerProvider._pushNotification 同口径：Windows 侧发布到 SMTC，
      // 供第三方任务栏歌词工具做身份/匹配/时间轴外推。
      album: curSong?.album ?? '',
      albumArtist: curSong?.artist ?? '',
      playbackRate: player.speed,
      loopMode: player.loopMode.name,
      shuffleEnabled: player.shuffleEnabled,
    );
  }

  /// 给歌词页右下角挂一个翻译/罗马音开关。
  ///
  /// 原先这个按钮常驻在底部操作胶囊里，但它只作用于歌词副行；
  /// 移到歌词内容自身的角落后，其它 tab 不再为它付出常驻空间，
  /// 短按开关副行、长按在「翻译 / 罗马音」间切换的交互保持不变。
  /// 落在歌词区右下角（紧贴进度条上方），拇指可达且不压住首行歌词；
  /// 无容器底色，只靠图标亮度区分开关态；Zen 模式下随其它控件一起隐藏。
  /// 图标外再扩 [_kTranslateTogglePadding] 透明安全区，吸收"点偏"点击，
  /// 防止穿透到歌词区被判定为跳转行。
  Widget _wrapLyricsWithTranslateToggle(Widget child) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        // 伴唱按钮：翻译按钮**上方**（伴唱是歌词页的第二个开关）。
        // 叠在翻译按钮之上，两枚按钮沿右边缘竖排（伴唱在上、翻译在下）。
        Positioned(
          // 翻译按钮占据 bottom 4、自身 40+2×8=56 高；伴唱按钮整体高 56，
          // 故底边抬高 56，使两枚按钮不重叠。
          bottom: 4 - _kTranslateTogglePadding + 40 + _kTranslateTogglePadding * 2,
          right: 8 - _kTranslateTogglePadding,
          child: buildAccompanyToggle(
            context: context,
            amStyle: true,
            zenMode: _zenMode,
          ),
        ),
        Positioned(
          // 减去 _kTranslateTogglePadding 抵消 InkWell 安全区外扩，
          // 保证图标可见位置仍是距右 8 / 距底 4 像素
          bottom: 4 - _kTranslateTogglePadding,
          right: 8 - _kTranslateTogglePadding,
          child: ListenableBuilder(
            listenable: LyricPreferences.instance,
            builder: (context, _) {
              if (_zenMode || (!_hasTranslation && !_hasRoma)) {
                return const SizedBox.shrink();
              }
              final on = LyricPreferences.instance.showTranslation;
              return InkWell(
                onTap: () => LyricPreferences.instance.setShowTranslation(!on),
                onLongPress: _switchLyricSubLineMode,
                customBorder: const CircleBorder(),
                // 安全区：外层额外一圈透明热区吸收点击，避免命中歌词行触发跳转
                child: Padding(
                  padding: const EdgeInsets.all(_kTranslateTogglePadding),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: Center(
                      child: Icon(
                        // 罗马音模式用 Icons.abc 区分，翻译模式用 Icons.translate
                        LyricPreferences.instance.displayMode ==
                                LyricDisplayMode.roma
                            ? Icons.abc
                            : Icons.translate,
                        size: 20,
                        // 开启时纯白，关闭时 45% 白（与导航条未选中态一致）
                        color: on
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 长按翻译按钮：在「翻译」与「罗马音」显示模式间切换。
  ///
  /// 判定按目标模式的数据可用性：粤语/纯音译歌常只有罗马音无翻译
  /// （旧逻辑要求两者同时存在，导致有罗马音也切不了）。
  void _switchLyricSubLineMode() {
    AppHaptics.lightImpact(HapticCategory.control);
    final next =
        LyricPreferences.instance.displayMode == LyricDisplayMode.translation
        ? LyricDisplayMode.roma
        : LyricDisplayMode.translation;
    if (next == LyricDisplayMode.roma && !_hasRoma) {
      showToast('当前歌曲暂无罗马音');
      return;
    }
    if (next == LyricDisplayMode.translation && !_hasTranslation) {
      showToast('当前歌曲暂无翻译');
      return;
    }
    // 副行渲染受 showTranslation 开关控制：关掉副行后切模式仍不显示，
    // 因此切模式时强制打开副行，保证生效。
    if (!LyricPreferences.instance.showTranslation) {
      LyricPreferences.instance.setShowTranslation(true);
    }
    LyricPreferences.instance.setDisplayMode(next);
    showToast(next == LyricDisplayMode.roma ? '已切换到罗马音' : '已切换到翻译');
  }

  /// 导航条拖动开始：把可能残留的页内余量归零，再开始 1:1 拖动。
  void _onTabDragStart(DragStartDetails d) {
    _pagerKey.currentState?.settleIndicator();
  }

  /// 导航条拖动中：跟手拖动，页面与指示线由 pager 一起 1:1 跟随。
  ///
  /// 这里不再直写 TabController.index/offset——本 SDK 的 TabBarView 只在
  /// indexIsChanging 时才同步，直写 offset 内容页不会动半分（详见
  /// player_tab_pager.dart 顶部说明）。改由 pager 按像素推进页位置。
  void _onTabDragUpdate(DragUpdateDetails d) {
    _pagerKey.currentState?.dragBySegment(d.delta.dx, _tabDragBtnW);
  }

  /// 导航条拖动结束：吸附到最近 tab
  void _onTabDragEnd() {
    _pagerKey.currentState?.settleNearest();
  }

  /// 卡片深链在车机模式下的落点：指挥本面板实例切到歌词页。统一 postFrame：
  /// 命令可能在面板实例 initState 后、pager 未就绪的当帧到达，此时 goToPage
  /// 是 no-op，落一帧等它就位再切。
  void _goDockLyrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _goToTab(_tabLayout.lyricsIndex);
    });
  }

  /// 程序化切页（封面页点击、歌词页点击等）。
  void _goToTab(int index) => _pagerKey.currentState?.goToPage(index);

  /// 歌词为空时的「暂无歌词」空状态（AM 深色背景，白 70% 图标 + 文字）。
  Widget _buildAmEmptyLyrics(BuildContext context) {
    final emptyColor = Colors.white70; // 与评论区深色背景的 secondaryTextColor 一致
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lyrics_outlined, size: 48, color: emptyColor),
          const SizedBox(height: 12),
          Text(
            '暂无歌词',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: emptyColor),
          ),
        ],
      ),
    );
  }

  /// 长按音质徽章的音量弹窗：三态判据与文案统一收口在 [PlayerVolumeState]
  /// （与横屏控制页的常驻音量条 PlayerVolumeBar 共用同一套，AGENTS §4.11）。
  /// 此前 AM 版缺 unity 分支：Direct PCM（unity 音量）下
  /// PlayerProvider.setVolume 会把拖动值拦下改记 1.0，滑块拖动失灵 ——
  /// 现与 MD 版对齐，unity 档改渲染 [PlayerVolumeUnityNotice]。
  void _showVolumeDialog(PlayerProvider playerProvider) {
    final state = PlayerVolumeState.of(playerProvider);
    showDialog(
      context: context,
      builder: (context) {
        // 拖动过程值：apply 只轻量下发（persist: false，不写盘），
        // provider 通知不进这个闭包，本地变量 + StatefulBuilder 跟进滑块位置。
        var volume = state.value;
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: !state.interactive
                  ? // unity 锁定：滑块失灵，明确提示 + 一键关闭该档
                      PlayerVolumeUnityNotice(
                        onDisabled: () => Navigator.of(context).pop(),
                      )
                  : StatefulBuilder(
                      builder: (context, setState) {
                        final usbExclusive =
                            state.source == PlayerVolumeSource.usbExclusive;
                        final colorScheme = Theme.of(context).colorScheme;
                        final accent = usbExclusive
                            ? Colors.green
                            : colorScheme.primary;
                        final percent = (volume * 100).round();
                        final icon = volume <= 0
                            ? Icons.volume_off
                            : volume < 0.5
                            ? Icons.volume_down
                            : Icons.volume_up;
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 模式标识：独占状态 / 普通状态
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                state.chipLabel,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: accent,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Icon(icon, size: 32, color: colorScheme.primary),
                            const SizedBox(height: 8),
                            // tv: TV 构建换 RemoteSlider——M3ESlider 自带 Focus 吞四方向键；
                            // TV 分支丢 M3ESliderDecoration（触觉/装饰参数无法透传），只保功能性参数（P-C）。
                            // 三态下发仍走 PlayerVolumeState.apply，与触屏共用同一份判据。
                            kTvBuild
                                ? RemoteSlider(
                                    value: volume,
                                    onChanged: (value) {
                                      state.apply(playerProvider, value, persist: false);
                                      setState(() => volume = value);
                                    },
                                    // 松手才落盘（拖动中只实时下发，与触屏同口径）
                                    onChangeEnd: (value) =>
                                        state.apply(playerProvider, value, persist: true),
                                  )
                            : M3ESlider(
                                value: volume,
                                // 不传 divisions = 无级调节（无节点）
                                decoration: const M3ESliderDecoration(
                                  // divisions 为空时组件默认取连续触觉（10ms 最小间隔），
                                  // 拖动会高频震动，故显式改为离散配置
                                  haptic: M3EHapticFeedback.medium,
                                  hapticConfig: M3EHapticConfig.discrete(),
                                ),
                                onChanged: (value) {
                                  state.apply(
                                    playerProvider,
                                    value,
                                    persist: false,
                                  );
                                  setState(() => volume = value);
                                },
                                // 松手才落盘（拖动中只实时下发，persist:false）
                                onChangeEnd: (value) {
                                  state.apply(
                                    playerProvider,
                                    value,
                                    persist: true,
                                  );
                                },
                            ),
                            Text(
                              '$percent%',
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              state.hintLabel,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ),
        );
      },
    );
  }

  /// 歌词渲染偏移：歌词偏移 + 端侧分离的固定算法延迟。
  ///
  /// 分离结果比播放位置晚 [StemSeparationService.kStemSeparateLatencyMs] 才出声，
  /// 不补偿就会「歌词比声音早约 100ms」。
  int get _lyricOffsetMs =>
      (context.read<PlayerProvider>().currentSong?.isOnline == true
          ? SettingsRepository.lyricTimeOffsetMs.value
          : 0) +
      StemSeparationService.instance.latencyCompensationMs;

  int _adjustedLyricTimeMs(Duration position) =>
      lyricDisplayPosition(position, offsetMs: _lyricOffsetMs).inMilliseconds;

  void _seekToLyric(int timestampMs) {
    context.read<PlayerProvider>().seek(lyricSeekPosition(
      Duration(milliseconds: timestampMs),
      offsetMs: _lyricOffsetMs,
    ));
  }

  void _showMoreMenu(BuildContext rootContext) {
    final song = context.read<PlayerProvider>().currentSong;
    if (song == null) return;

    // 动态标题原为 ListTile 文案（专辑名/歌手名截断），改宫格后不再需要。
    showM3EModalBottomSheet(
      context: rootContext,
      isScrollControlled: true,
      sheetAnimationStyle: isWindowsDesktop
          ? (MediaQuery.disableAnimationsOf(rootContext)
                ? AnimationStyle.noAnimation
                : const AnimationStyle(
                    duration: Duration(milliseconds: 180),
                    reverseDuration: Duration(milliseconds: 160),
                  ))
          : null,
      // 顶栏「更多」菜单改为实色：全局 M3E 弹层主题默认用 0.97 alpha 让背景图
      // 透出，这里显式给不透明色，避免菜单压在封面/壁纸上时内容难以辨认。
      backgroundColor: Theme.of(rootContext).colorScheme.surfaceContainerLow,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Windows 播放页没有标题栏：窗口操作收在这里，避免挤占顶栏尾部。
                if (isWindowsDesktop) ...[
                  ListTile(
                    leading: const Icon(Icons.minimize),
                    title: const Text('最小化窗口'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      WindowsWindowControls.minimize();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.crop_square),
                    title: Text(
                      WindowsFullscreen.active.value
                          ? '退出全屏'
                          : '最大化 / 还原窗口',
                    ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      WindowsWindowControls.toggleMaximize();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.close),
                    title: const Text('关闭窗口'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      WindowsWindowControls.closeWindow();
                    },
                  ),
                ],
                // 本地歌曲 / 云盘歌曲：匹配在线歌曲，补充封面兜底/歌词精确检索/评论区
                if ((!song.isOnline && song.localPath != null) || song.isCloud)
                  ListTile(
                    leading: const Icon(Icons.manage_search),
                    title: const Text('匹配在线信息'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      showSongMatchSheet(rootContext, song);
                    },
                  ),
                if (song.isOnline)
                  ListTile(
                    leading: const Icon(Icons.playlist_add),
                    title: const Text('添加到歌单'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      showAddToPlaylistDialog(rootContext, song);
                    },
                  ),
                // 歌曲信息：安卓手机入口已移进「播放与输出」面板输出页的
                // 「USB 独占」行（supportsUsbExclusive 门控，见
                // playback_center_sheet.dart 的 UsbExclusiveTrayRow）；
                // Windows/TV 无 USB 独占与等价的格式明细展示，此处保留入口。
                if (!supportsUsbExclusive)
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('歌曲信息'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _pageNavigator(rootContext)?.push(
                        MaterialPageRoute(builder: (_) => const SongInfoPage()),
                      );
                    },
                  ),
                // 音量：收进「播放与输出」面板（顶栏音质格进入），这里不再放常驻条。
                // 宫格组合容器：上行 MV/专辑/歌手/曲谱（一行四格），分割线，
                // 下行 均衡器/音效/定时关闭/播放速度（原 ListTile 收进行内）。
                // 与标准版 full_player 同款。
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    children: [
                      // 上行：导航宫格。曲谱依赖 album_audio_id（/sheet/song
                      // 查询键），缺失时隐藏。
                      Row(
                        children: [
                          // 查看 MV：仅在线歌曲显示
                          if (song.isOnline == true)
                            MenuActionCell(
                              icon: Icons.music_video_outlined,
                              label: 'MV',
                              active: false,
                              onTap: () {
                                Navigator.pop(sheetContext);
                                _pageNavigator(rootContext)?.push(
                                  MaterialPageRoute(
                                    builder: (_) => MvPlayerPage(song: song),
                                  ),
                                );
                              },
                            ),
                          MenuActionCell(
                            icon: Icons.album,
                            label: '专辑',
                            active: false,
                            onTap: () {
                              Navigator.pop(sheetContext);
                              _navigateToAlbum(song);
                            },
                          ),
                          MenuActionCell(
                            icon: Icons.person,
                            label: '歌手',
                            active: false,
                            onTap: () {
                              Navigator.pop(sheetContext);
                              _navigateToArtist(song);
                            },
                          ),
                          if (song.albumAudioId != null &&
                              song.albumAudioId!.isNotEmpty)
                            MenuActionCell(
                              icon: Icons.library_music_outlined,
                              label: '曲谱',
                              active: false,
                              onTap: () {
                                Navigator.pop(sheetContext);
                                showSongSheetSheet(rootContext, song);
                              },
                            ),
                        ],
                      ),
                      // 两行之间的分割线（与容器左右内边距对齐）
                      Container(
                        height: 1,
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        color: colorScheme.outlineVariant.withValues(
                          alpha: 0.5,
                        ),
                      ),
                      // 下行：均衡器 / 音效 / 定时关闭 / 投屏。均衡器/音效依赖
                      // EqualizerService 的 Android AudioSession 绑定，桌面端
                      // tryBind() 直接 return false（假成功），故桌面端整格隐藏。
                      Row(
                        children: [
                          if (supportsSystemAudioEffects) ...[
                            ListenableBuilder(
                              listenable: EqualizerService.instance,
                              builder: (context, _) {
                                final eq = EqualizerService.instance;
                                return MenuActionCell(
                                  icon: Icons.graphic_eq,
                                  label: '均衡器',
                                  active: eq.enabled,
                                  enabled: !eq.systemEffectsDisabled,
                                  onTap: () {
                                    Navigator.pop(sheetContext);
                                    _pageNavigator(rootContext)?.push(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            const EqualizerSettingsPage(),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                            ListenableBuilder(
                              listenable: EqualizerService.instance,
                              builder: (context, _) {
                                final eq = EqualizerService.instance;
                                return MenuActionCell(
                                  icon: Icons.spatial_audio_off,
                                  label: '音效',
                                  active: false,
                                  enabled: !eq.systemEffectsDisabled,
                                  onTap: () {
                                    Navigator.pop(sheetContext);
                                    _pageNavigator(rootContext)?.push(
                                      MaterialPageRoute(
                                        builder: (_) => const SoundsPage(),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                          ],
                          ListenableBuilder(
                            listenable: context.read<PlayerProvider>(),
                            builder: (context, _) {
                              final player = context.read<PlayerProvider>();
                              return MenuActionCell(
                                icon: Icons.timer_outlined,
                                label: '定时关闭',
                                active: player.isSleepTimerActive,
                                onTap: () {
                                  Navigator.pop(sheetContext);
                                  showSleepTimerSheet(
                                    context: rootContext,
                                    player: player,
                                  );
                                },
                              );
                            },
                          ),
                          // 播放速度：与定时关闭同一栏，非 1.0x 时高亮
                          ListenableBuilder(
                            listenable: context.read<PlayerProvider>(),
                            builder: (context, _) {
                              final player = context.read<PlayerProvider>();
                              return MenuActionCell(
                                icon: Icons.speed,
                                label: '播放速度',
                                active: player.speed != 1.0,
                                onTap: () {
                                  Navigator.pop(sheetContext);
                                  showSpeedPickerDialog(
                                    context: rootContext,
                                    currentSpeed: player.speed,
                                    onSelected: player.setSpeed,
                                  );
                                },
                              );
                            },
                          ),
                          // 车机面板没有「播放与输出」入口（窄容器塞不下），
                          // 投屏只能留这一格；触屏形态一律走顶栏音质格打开的面板。
                          if (widget.dockMode)
                            MenuActionCell(
                              icon: Icons.cast,
                              label: '投屏',
                              active: false,
                              onTap: () {
                                Navigator.pop(sheetContext);
                                _showDlnaCastSheet(rootContext);
                              },
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                // 置底：界面设置入口 → 打开二级菜单
                ListTile(
                  leading: const Icon(Icons.tune),
                  title: const Text('界面设置'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    // 打开二级菜单前刷新动态封面开关与当前歌曲状态
                    // ignore: discarded_futures
                    _refreshDyCoverMenuState();
                    _showMoreSettingsSheet(rootContext);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 界面设置：二级菜单弹层（歌词类型 / 歌词显示设置 / 评论设置 / 音乐频谱）。
  void _showMoreSettingsSheet(BuildContext rootContext) {
    showM3EModalBottomSheet(
      context: rootContext,
      isScrollControlled: true,
      sheetAnimationStyle: isWindowsDesktop
          ? (MediaQuery.disableAnimationsOf(rootContext)
                ? AnimationStyle.noAnimation
                : const AnimationStyle(
                    duration: Duration(milliseconds: 180),
                    reverseDuration: Duration(milliseconds: 160),
                  ))
          : null,
      // 与一级「更多」菜单保持一致：二级菜单同样用实色背景。
      backgroundColor: Theme.of(rootContext).colorScheme.surfaceContainerLow,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        // 歌词类型标签：KRC / LRC 逐字 / LRC 行级 / 静态 / 未加载
        // LRC 内部细分：任意一行含字级时间戳即视为"逐字"，否则为"行级"
        final hasWordTiming = _parsedLyricsRaw.any((line) => line.hasWordTiming);
        final lyricTypeLabel = switch (_lyricFormat) {
          LyricFormat.krc => 'KRC 逐字歌词',
          LyricFormat.lrc => hasWordTiming ? 'LRC 逐字歌词' : 'LRC 行级歌词',
          LyricFormat.ttml => 'TTML 逐字歌词',
          LyricFormat.plaintext => '静态歌词',
          null => _isLoadingLyrics ? '歌词加载中' : '未加载',
        };
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) => SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // MD3E 拖拽把手
                  Container(
                    width: 32,
                    height: 4,
                    margin: const EdgeInsets.only(top: 12, bottom: 4),
                    decoration: BoxDecoration(
                      color: colorScheme.outline.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '界面设置',
                        style: Theme.of(sheetContext).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  // 歌词类型展示（只读，trailing 显示类型，点击无操作）
                  ListTile(
                    leading: const Icon(Icons.label_outline),
                    title: const Text('歌词类型'),
                    trailing: Text(
                      lyricTypeLabel,
                      style: Theme.of(sheetContext).textTheme.bodyMedium
                          ?.copyWith(
                            color: Theme.of(sheetContext).colorScheme.primary,
                          ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.lyrics),
                    title: const Text('歌词显示设置'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _showLyricPreferencesSheet(rootContext);
                    },
                  ),
                  ListenableBuilder(
                    listenable: context.read<CommentDisplayProvider>(),
                    builder: (context, _) {
                      final display = context.read<CommentDisplayProvider>();
                      return ListTile(
                        leading: const Icon(Icons.comment_outlined),
                        title: const Text('评论设置'),
                        subtitle: Text(
                          '楼主 ${display.commentFontSize.toStringAsFixed(0)} 号 · 楼中楼 ${display.commentReplyFontSize.toStringAsFixed(0)} 号',
                        ),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          _showCommentDisplaySheet(rootContext);
                        },
                      );
                    },
                  ),
                  // 与设置页共享状态，开关即时更新写真封面和背景。
                  Consumer<ThemeProvider>(
                    builder: (context, theme, _) => SwitchListTile(
                      title: const Text('歌手写真背景'),
                      value: theme.useArtistPhotoBackground,
                      onChanged: theme.setUseArtistPhotoBackground,
                    ),
                  ),
                  // 歌曲弹幕：与设置页「屏幕与视频」、MD3 播放页是同一个开关。
                  // 读静态镜像 ValueNotifier —— setter 写盘前就更新它，所以弹层
                  // 与封面区弹幕层同时生效，不需要 setState/setSheetState。
                  // tv: 弹幕正文输入依赖软键盘，TV 包不挂载弹幕层，故此处也不显示。
                  if (!kTvBuild)
                    ValueListenableBuilder<bool>(
                      valueListenable: SettingsRepository.songDanmakuEnabled,
                      builder: (context, enabled, _) => SwitchListTile(
                        title: const Text('歌曲弹幕'),
                        subtitle: Text(
                          enabled
                              ? '已开启 · 弹幕在封面区顶部滚动'
                              : '封面区顶部滚动显示这首歌的弹幕（本地歌曲无弹幕池）',
                        ),
                        value: enabled,
                        onChanged: (v) {
                          AppHaptics.lightImpact(HapticCategory.control);
                          // ignore: discarded_futures
                          SettingsRepository().setSongDanmakuEnabled(v);
                        },
                      ),
                    ),
                  // 音乐频谱环绕：Android / Windows 都支持（同一套通道协议）
                  if (supportsMusicSpectrum)
                    SwitchListTile(
                      title: const Text('音乐频谱环绕'),
                      subtitle: Text(
                        _spectrumEnabled
                            ? SpectrumService.instance.isSimulated
                                  ? '已开启 · 模拟模式（实时采集暂不可用）'
                                  : '已开启 · 实时频谱'
                            : '封面裁圆旋转，频谱环绕跳动',
                      ),
                      value: _spectrumEnabled,
                      onChanged: (v) async {
                        final update = _toggleSpectrum();
                        setSheetState(() {});
                        await update;
                        if (sheetContext.mounted) setSheetState(() {});
                      },
                    ),
                  // 专辑动态封面：开关（与设置页「播放页样式」联动，关闭即时生效）
                  // + 当前歌曲是否有动态封面的状态
                  ValueListenableBuilder<String?>(
                    valueListenable: _dyCoverStatus,
                    builder: (context, status, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SwitchListTile(
                          title: const Text('专辑动态封面'),
                          subtitle: const Text('封面播放专辑动态封面短视频'),
                          value: _dynamicCoverEnabled,
                          onChanged: (v) {
                            AppHaptics.lightImpact(HapticCategory.control);
                            setState(() => _dynamicCoverEnabled = v);
                            setSheetState(() {});
                            // ignore: discarded_futures
                            SettingsRepository().setDynamicAlbumCover(v);
                          },
                        ),
                        ListTile(
                          leading: const Icon(Icons.album_outlined),
                          title: const Text('当前歌曲动态封面'),
                          trailing: Text(
                            status ?? '检测中…',
                            style: Theme.of(sheetContext).textTheme.bodyMedium
                                ?.copyWith(color: colorScheme.primary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 仅 3D 包显示，与设置页使用同一编译期开关。
                  if (kDepthCoverAvailable)
                    StatefulBuilder(
                      builder: (context, setSheetState) => FutureBuilder<bool>(
                        future: SettingsRepository().getDepthCoverEnabled(),
                        builder: (context, snap) => SwitchListTile(
                          title: const Text('3D 封面'),
                          value: snap.data ?? false,
                          onChanged: (v) {
                            AppHaptics.lightImpact(HapticCategory.control);
                            setSheetState(() {});
                            // ignore: discarded_futures
                            SettingsRepository().setDepthCoverEnabled(v);
                            DepthCoverService.enabledSignal.value = v;
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 评论显示设置：调节楼主 / 楼中楼字体大小。
  /// 与 MD 风格面板保持一致：全部使用主题标准色（onSurface / onSurfaceVariant /
  /// primary），由主题自动适配深色/浅色模式，不再硬编码白色文字。
  void _showCommentDisplaySheet(BuildContext rootContext) {
    showM3EModalBottomSheet(
      context: rootContext,
      isScrollControlled: true,
      backgroundColor: Theme.of(rootContext).colorScheme.surfaceContainerLow,
      builder: (sheetCtx) {
        return SafeArea(
          child: Consumer<CommentDisplayProvider>(
            builder: (context, display, _) {
              final colorScheme = Theme.of(context).colorScheme;
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 32,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: colorScheme.outline.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Text(
                      '评论显示设置',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '楼中楼回复字号 = 楼主 − 3',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Text(
                          '楼主',
                          style: TextStyle(
                            fontSize: 14,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${display.commentFontSize.toStringAsFixed(0)} 号',
                          style: TextStyle(
                            fontSize: display.commentFontSize,
                            fontWeight: FontWeight.w500,
                            color: colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    // min 12：正文可读下限，低于它选不出不可读的字号
                    // tv: TV 构建换 RemoteSlider（P-C，同上）
                    kTvBuild
                        ? RemoteSlider(
                            value: display.commentFontSize,
                            min: 12.0,
                            max: 24.0,
                            divisions: 12,
                            label: display.commentFontSize.toStringAsFixed(0),
                            onChanged: (v) => display.setCommentFontSize(v),
                          )
                        : M3ESlider(
                            value: display.commentFontSize,
                            min: 12.0,
                            max: 24.0,
                            divisions: 12,
                            label: display.commentFontSize.toStringAsFixed(0),
                            onChanged: (v) => display.setCommentFontSize(v),
                          ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest.withValues(
                          alpha: 0.4,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                radius: 12,
                                backgroundColor: colorScheme.primary.withValues(
                                  alpha: 0.15,
                                ),
                                child: const Icon(
                                  Icons.person,
                                  size: 14,
                                  color: Colors.grey,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '楼主',
                                      style: TextStyle(
                                        fontSize: math.max(
                                          12.0,
                                          display.commentFontSize - 2,
                                        ),
                                        color: colorScheme.primary,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '这是一条楼主评论的内容示例。',
                                      style: TextStyle(
                                        fontSize: display.commentFontSize,
                                        height: 1.3,
                                        color: colorScheme.onSurface,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(
                                  radius: 10,
                                  backgroundColor: colorScheme.primary
                                      .withValues(alpha: 0.15),
                                  child: const Icon(
                                    Icons.person,
                                    size: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '楼中楼',
                                        style: TextStyle(
                                          fontSize: math.max(
                                            12.0,
                                            display.commentReplyFontSize - 2,
                                          ),
                                          color: colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(height: 1),
                                      Text(
                                        '这是一条楼中楼回复示例。',
                                        style: TextStyle(
                                          fontSize:
                                              display.commentReplyFontSize,
                                          height: 1.3,
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => display.resetToDefault(),
                          child: const Text('恢复默认'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => Navigator.pop(sheetCtx),
                          child: const Text('完成'),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// 弹出 DLNA 投屏二级菜单（设备选择 + 传输控制）。
  void _showDlnaCastSheet(BuildContext context) {
    showM3EModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      builder: (context) => const DlnaCastSheet(),
    );
  }

  /// 弹出歌词字号/行间距调节面板（从播放页右上角菜单进入）。
  void _showLyricPreferencesSheet(BuildContext context) {
    showM3EModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      builder: (context) => SafeArea(child: const LyricPreferencesPanel()),
    );
  }
}
