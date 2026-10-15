import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:dpad/dpad.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/platform_capabilities.dart';
import '../../core/remote/tv_menu_key_shortcuts.dart';
import '../../core/layout/responsive_layout.dart';
import '../../core/remote/remote_slider.dart';
import '../../core/services/audio_service.dart';
import '../../core/services/desktop_lyric_service.dart';
import '../../core/services/depth_cover_feature.dart';
import '../../core/services/dynamic_cover_service.dart';
import '../../core/services/equalizer_service.dart';
import '../../core/services/media_notification_service.dart';
import '../../core/services/music_haptics_service.dart';
import '../../core/services/spectrum_service.dart';
import '../../core/theme/app_dimens.dart';
import '../../widgets/depth_cover_host.dart';
import '../../widgets/marquee_text.dart';
import '../../widgets/player_top_bar_actions.dart';
import '../../widgets/player_top_bar_tab_dots.dart';
import '../../core/utils/local_lyric_loader.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/utils/app_toast.dart';
import '../../widgets/add_to_playlist_dialog.dart';
import '../../main.dart';
import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../data/repositories/settings_repository.dart';
import '../album/album_detail_page.dart';
import '../artist/artist_detail_page.dart';
import '../coverflow/coverflow_page.dart';
import '../listen_together/widgets/listen_together_trailing.dart';
import '../settings/equalizer_settings_page.dart';
import '../library/song_match_sheet.dart';
import '../sound/sounds_page.dart';
import 'artist_photo_background.dart';
import 'audio_quality_dialog.dart';
import 'mv_player_page.dart';
import 'sleep_timer_sheet.dart';
import 'speed_picker_sheet.dart';
import 'song_info_page.dart';
import '../../providers/favorites_provider.dart';
import '../../data/repositories/song_match_repository.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/local_favorites_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/theme_provider.dart';
import '../../providers/comment_display_provider.dart';
import '../../services/depth_cover_service.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/comment_reply_target.dart';
import 'comment_compose_sheet.dart';
import 'comments_view.dart';
import 'lyrics_view.dart';
import 'player_tab_layout.dart';
import 'player_tab_pager.dart';
import 'player_volume_state.dart';
import 'player_wide_pane.dart';
import 'playlist_swipe_driver.dart';
import '../../widgets/apple_lyrics/parsers/lyric_parser_chain.dart';
import 'package:md3music/widgets/apple_lyrics/models/lyric_line.dart';
import '../../utils/landscape_immersive.dart';
import '../../widgets/md3_lyric_preferences.dart';
import '../../widgets/md3_lyric_preferences_panel.dart';
import '../../widgets/ai_recommend_sheet.dart';
import '../../widgets/md3e_transport_row.dart';
import '../../widgets/menu_action_cell.dart';
import '../../widgets/dynamic_cover_view.dart';
import '../../widgets/player_artwork_image.dart';
import '../../widgets/player_seek_bar.dart';
import '../../widgets/player_tab_strip.dart';
import '../../widgets/player_dock/dock_skin.dart';
import '../../widgets/player_dock/player_control_dock.dart';
import '../../widgets/player_dock/zen_fade.dart';
import '../../widgets/player_volume_bar.dart';
import '../../widgets/player_playlist_view.dart';
import '../../widgets/playback_status_feedback.dart';
import '../../widgets/spectrum_artwork.dart';
import '../../widgets/spectrum_background.dart';
import 'car_mode_exit.dart';
import 'dlna_cast_sheet.dart';
import 'full_player_route.dart';
import 'lyric_flight_batcher.dart';
// 只引入形变槽位：PlayerCoverSlot 内部转发到 player_cover_morph.dart 的登记簿，
// 本文件不直接用登记簿或纯函数，少引一个包就少一条 unused_import。
import 'player_cover_morph.dart';
import 'player_cover_shadow.dart';
import 'player_cover_morph_layer.dart';
import 'player_page_role.dart';
import 'widgets/song_danmaku_host.dart';

/// 预加载封面图片到磁盘缓存，防止切换时白屏
void _preloadArtwork(String? url) {
  preloadPlayerArtwork(url);
}

class FullPlayer extends StatefulWidget {
  /// 可选扩展：封面长按回调（默认关闭，由私有构建注入，用于下载等旁路操作）。
  static void Function(BuildContext context, dynamic song)?
  coverLongPressCallback;

  /// 车机模式常驻面板：由 CarModePanel 以普通 widget 形式嵌在侧边面板里渲染，
  /// 不是路由、也不可收起。此模式下：
  ///   * 不显示「收起」按钮、不响应任何收起手势，返回键也不收起；
  ///   * 不接管系统栏（面板只是屏幕的一部分，不是全屏页）；
  ///   * 禁止 Zen 模式与横屏沉浸（两者都会劫持全局系统栏，而面板常驻不会
  ///     dispose，没有兜底清理点）；
  ///   * 面板内的整页跳转改推根 Navigator（否则页面会顶掉面板内容）；
  ///   * tab 结构恒按窄屏判定（保留封面 tab）。
  ///
  /// 默认 false：既有 `const FullPlayer()` 调用点（player_drag_overlay.dart、
  /// full_player_route.dart）行为完全不变。
  final bool dockMode;

  const FullPlayer({super.key, this.dockMode = false});

  @override
  State<FullPlayer> createState() => _FullPlayerState();
}

class _FullPlayerState extends State<FullPlayer>
    with TickerProviderStateMixin, WidgetsBindingObserver {
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

  /// 播放列表的滚动归属（控制器 + 「为哪首歌定位过」）。
  ///
  /// 必须活在本 State 而不是面板里：pager 是 `PageView(children:)` 且
  /// cacheExtent=0，切到歌词/评论页签时面板整棵子树会被销毁。同一时刻只有一个
  /// 分支挂着面板（见 [_pagerKey] 的说明），所以三个挂载点共用这一份是安全的。
  final PlaylistScrollAnchor _playlistScroll = PlaylistScrollAnchor();

  /// 控制页手势锁：进度条 / 音量条都是水平拖动，按下期间必须锁掉
  /// PageView 的横滑，否则滑条与切页抢手势（滑到一半页面被切走）。
  /// 由滑条那一行的 Listener（[_lockSliderRowSwipe]）置位复位，pager 的 physics
  /// 随之在 NeverScrollable 与默认之间切换；**只罩滑条行**，控制页其他地方仍要能滑。
  final ValueNotifier<bool> _controlsPageGestureLock = ValueNotifier<bool>(
    false,
  );

  int _lyricFetchGeneration = 0;
  String _lyrics = '';
  List<LyricLine> _lyricMetadata = const [];
  bool _hasTranslation = false;
  bool _hasRoma = false;
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

  // 导航条拖动切换：拖动时页面跟随，松手吸附到最近 tab。
  // _tabDragBtnW 是导航条一段的宽度，「一段 = 一页」是导航条的固有语义。
  double _tabDragBtnW = 0;

  // 封面淡入淡出动画
  late final AnimationController _artworkFadeController;

  // 桌面歌词状态监听：长按歌词按钮 toggle 后同步 icon
  late final VoidCallback _onDesktopLyricChanged;
  late final Animation<double> _artworkFadeAnimation;
  String? _previousArtworkUrl;

  /// 当前生效的 tab 结构（含封面 tab / 含评论 tab）。
  /// TabController.length、TabBarView.children、底部导航条 items 全部由它派生；
  /// 任一输入变化（屏幕宽度、切歌、设置开关）都必须先调用 [_syncTabLayout]
  /// 重算，保证三者始终一致。
  PlayerTabLayout _tabLayout =
      (hasCover: true, hasComments: true, hasControls: false);
  // 写真背景是否实际有图片可显示：写真无图时不隐藏左侧封面，避免封面消失
  bool _photoBgHasImages = false;

  /// 防止 PopScope 回调与 dismiss() 重复触发。
  bool _isDismissing = false;

  /// 拖拽展开模式下的源路由：展开完成前延迟应用沉浸模式，
  /// 避免拖动过程系统栏提前切换造成闪烁。
  DraggablePlayerRoute? _dragRoute;

  /// 系统栏/沉浸模式初始化是否已完成。
  /// 需在 [didChangeDependencies] 中执行一次（[ModalRoute.of] 依赖
  /// `_ModalScopeStatus` inherited widget，initState 阶段不可用）。
  bool _systemUiInitialized = false;

  /// 是否为拖拽覆盖层（非路由）场景：拖拽期间由 Navigator 之上的
  /// PlayerDragOverlay 渲染，无 ModalRoute；系统栏与收起行为需走覆盖层逻辑。
  /// 本页当前的身份，见 [PlayerPageRole]。显式 [PlayerPageRoleScope] 优先，
  /// 没标注时由 `PlayerPageRole.of` 退回旧推导（`ModalRoute` 缺失 + 拖拽激活），
  /// 所以本步改动与之前逐位等价；`dormant` 留给常驻预建那一步使用。
  PlayerPageRole get _pageRole => PlayerPageRole.of(context);

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

  /// Zen 下单击封面唤出 chrome 的停留时长，到点前一路渐隐、抵达 [_zenPeekEndDim] 时收回。
  static const Duration _zenPeekDuration = Duration(seconds: 4);

  /// 上述停留的倒计时兼渐隐斜坡的节拍；dispose 与退出 Zen 两处都要 cancel。
  Timer? _zenPeekTimer;

  /// peek 期间 chrome 的额外压暗因子：1.0 = 不压暗， [_zenPeekDuration] 内线性降到 [_zenPeekEndDim]。
  final ValueNotifier<double> _zenChromeDim = ValueNotifier<double>(1.0);

  /// 渐隐终点：不透明度降到 20% 的同一刻恢复 Zen（余下由 ZenFade 的 400ms 补到 0）。
  static const double _zenPeekEndDim = 0.2;

  /// 斜坡节拍：100ms 一档，四秒 40 档，每档 Δ0.02 看不出阶梯（AGENTS §10.2 选档判据）。
  static const Duration _zenPeekInterval = Duration(milliseconds: 100);

  /// 档数：Duration 没有 `Duration / Duration`，只能按毫秒整除（4000ms / 100ms = 40 档）。
  int get _zenPeekSteps =>
      _zenPeekDuration.inMilliseconds ~/ _zenPeekInterval.inMilliseconds;
  int _zenPeekStep = 0;
  // 长按封面进入 Zen 模式开关（设置→播放，默认开启；关闭后禁用长按）
  bool _zenLongPressEnabled = true;
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
  /// - 封面此刻是否真的可见（竖屏停在歌单 / 歌词 / 评论 tab，见下）。
  ///
  /// **刻意不含频谱圆盘**：文字块与封面形状无关，频谱圆盘开着时歌名照飞
  /// （用户要求）。封面一侧另有 [_coverMorphEligible]，两者**故意不同源**。
  ///
  /// **刻意不含「3D 深度封面 / 动态封面视频是否已就绪」**：它们只在播放页挂载
  /// 之后才异步就绪（实测约 250ms，正好落在拖拽途中）。放进资格判定有两个致命
  /// 问题：实时求值会在形变飞到一半时把它判成「不合格」而中断（横屏必现）；
  /// 加锁存也救不了——锁存是在挂载那一刻取的，那时它们必然还没就绪，等于门控只对
  /// 收起方向生效，进入方向永远不生效，两个方向行为不一致。
  /// 而且形变期间真实封面本就被槽位隐藏（`PlayerCoverSlot` 的 Opacity=0），
  /// 视频 / 3D 图层不显示；交接点上 `DynamicCoverView` 自带淡入，由平面图切回
  /// 视频层也不会硬跳。故这两层不参与资格判定。
  bool get _morphTextEligible =>
      !widget.dockMode &&
      // 封面此刻是否真的可见：
      // - 窄屏（手机竖屏）封面只在封面 tab 里。切到歌单 / 歌词 / 评论后封面并不
      //   显示，此时若还做形变，下拉收起就会「凭空飞出一个封面和歌名」。
      // - 宽屏（横屏 / 平板）没有封面 tab（`coverIndex == -1`），封面常驻左栏、
      //   与 tab 无关，永远可见，故不受此限。
      (_tabLayout.coverIndex < 0 ||
          _tabController.index == _tabLayout.coverIndex);

  /// **封面**连贯是否接管本次转场。
  ///
  /// 在 [_morphTextEligible] 之上再压一条频谱圆盘：圆形裁切 + 旋转封面，
  /// 形变层画的是一张平面方图，还原不出这个形状（真机表现：方封面一路飞到
  /// 播放页中段才突然变圆）。
  ///
  /// 读 [kSpectrumDiscCoverActive] 同步镜像，保证跟手覆盖层第一帧的锁存就拿到
  /// 真值 —— 早前直接读本页的 `_spectrumEnabled`，覆盖层首帧恒为 false，
  /// 锁存把「频谱开着」误判成「可形变」，于是**每次上滑都会飞出方封面**。
  bool get _coverMorphEligible => _morphTextEligible && !_isDiscCover;

  // 进度条拖动状态：记录拖动前是否正在播放，拖动结束后恢复
  bool _wasPlayingBeforeDrag = false;

  // ── 音乐频谱环绕显示 ──
  // 是否开启频谱模式（从设置读取，默认关闭）。仅 Android 生效
  bool _spectrumEnabled = false;
  // 是否允许原生端挂 Visualizer 兜底（默认关闭）。关闭时走 PCM 截取，不需要录音权限
  bool _spectrumVisualizerFallback = false;
  // SpectrumService 是否已启动（避免重复 start）
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
    _topBarDragLastY = details.globalPosition.dy;
    _topBarDragLastTime = null;
    _topBarDragVelocity = 0.0;
  }

  /// 顶栏向下拖拽：播放页跟随手指原路下滑（向下为正，向上忽略）。
  void _onTopBarDragUpdate(DragUpdateDetails details) {
    final route = _topBarDragRoute;
    if (route == null) return;
    _topBarDragDistance = (_topBarDragDistance + details.delta.dy).clamp(
      0.0,
      double.infinity,
    );
    // 速度估计（按事件时间戳差分，向下为正）
    final ts = details.sourceTimeStamp;
    if (ts != null && _topBarDragLastTime != null && _topBarDragLastY != null) {
      final dt = (ts - _topBarDragLastTime!).inMicroseconds / 1e6;
      if (dt > 0) {
        _topBarDragVelocity =
            (details.globalPosition.dy - _topBarDragLastY!) / dt;
      }
    }
    _topBarDragLastY = details.globalPosition.dy;
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
  /// 跳转前先 dismiss FullPlayer，让 MiniPlayer 恢复显示。
  /// 本地歌曲命中匹配记忆时返回对应的在线歌曲（专辑/歌手跳转用在线 id）。
  /// 在线歌曲或未匹配时原样返回。
  Song _resolveMatchedSong(Song song) {
    if (song.isOnline) return song;
    final info = SongMatchRepository().get(song.id);
    return (info != null && info.isMatched) ? info.toSong() : song;
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
      // 等待 FullPlayer 淡出动画完成（约 250ms）后再 push 专辑页
      Future.delayed(const Duration(milliseconds: 300), () {
        navigatorState?.push(
          MaterialPageRoute(builder: (_) => AlbumDetailPage(album: album)),
        );
      });
    } else {
      // 车机模式会走到这里：route 是面板宿主路由（非 DraggablePlayerRoute），
      // navigatorState 已是根 Navigator，专辑页铺满主内容区、面板保持常驻。
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
    // 显示 loading
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: M3ELoadingIndicator()),
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
  void initState() {
    super.initState();
    // 音乐震动「播放页启用」范围以本页在场为准（含拖拽覆盖层实例；
    // 覆盖层与接管的页面路由可能短暂并存，服务侧用计数消化，勿改回布尔）。
    MusicHapticsService.instance.setPlayerPageActive(true);
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows) {
      SettingsRepository.windowsLiveSettingsRevision.addListener(
        _reloadWindowsPlayerSettings,
      );
    }
    _tabController = TabController(
      length: _tabLayout.length,
      vsync: this,
      // 从全局信号取初始下标：拖拽覆盖层里的是**另一个** FullPlayer 实例，
      // 固定从封面 tab 开始会让下拉时跳回封面，并让形变资格误判「封面可见」。
      // 详见 [playerTabIndex] 的说明。
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
    // 「横屏控制面板独立页」开关变化：宽屏 tab 结构随之增删控制页
    // （回调内部走 _syncTabLayout，结构有变化才 setState）。
    kLandscapeDetachedControlsEnabled.addListener(
      _onDetachedControlsSettingChanged,
    );
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
      _syncTabLayout();
      final song = context.read<PlayerProvider>().currentSong;
      if (song != null) {
        _fetchLyrics(song);
      }
      context.read<PlayerProvider>().addListener(_onPlayerSongChanged);
      _loadSpectrumSetting();
      _loadZenPressSetting();
      _loadDynamicCoverSetting();
    });
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

  /// 从设置加载「长按封面进入 Zen 模式」开关。
  Future<void> _loadZenPressSetting() async {
    final enabled = await SettingsRepository().getZenCoverLongPress();
    if (!mounted) return;
    setState(() => _zenLongPressEnabled = enabled);
  }

  /// 从设置加载频谱开关状态，开启时尝试启动 SpectrumService
  Future<void> _loadSpectrumSetting() async {
    final enabled = await SettingsRepository().getSpectrumEnabled();
    final bandCount = await SettingsRepository().getSpectrumBandCount();
    final style = await SettingsRepository().getSpectrumStyle();
    final bgOpacity = await SettingsRepository().getSpectrumBgOpacity();
    final bgHeight = await SettingsRepository().getSpectrumBgHeight();
    final barOpacity = await SettingsRepository().getSpectrumBarOpacity();
    final curveOpacity = await SettingsRepository().getSpectrumCurveOpacity();
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
      _spectrumVisualizerFallback = visualizerFallback;
    });
    if (enabled) {
      // 已开启频谱时注册降级监听
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
        // 确保权限已请求（可能用户上次未授权）
        await Permission.microphone.request();
      }
      final isPlaying = context.read<PlayerProvider>().isPlaying;
      await _tryStartSpectrum(isPlaying: isPlaying);
    }
  }

  /// 尝试启动 SpectrumService。
  /// Visualizer 需要 AudioFlinger 有活跃音频轨道才能初始化，
  /// 因此仅在播放时调用。Kotlin 端先尝试特定 sessionId，失败回退到 0。
  Future<void> _tryStartSpectrum({bool isPlaying = false}) async {
    if (!Platform.isAndroid || !mounted || _isDragOverlay || !_spectrumEnabled) {
      return;
    }
    if (_spectrumStarted) return;
    // 未在播放时不启动（PCM 截取在 AudioSink 层，播放才会产生数据）
    if (!isPlaying) return;
    // 传入 just_audio 的实际 audioSessionId，Kotlin 端会先尝试绑定它
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

  /// 停止 SpectrumService（频谱关闭、暂停或离开播放器时调用）
  Future<void> _stopSpectrum() async {
    _spectrumStarted = false;
    await SpectrumService.instance.stop(_spectrumOwner);
  }

  /// 切换频谱模式开关：同步设置 + 请求权限 + 启停服务 + UI 刷新
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
      // 监听降级模式通知
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

  /// 频谱降级到模拟模式时的通知回调
  void _onSpectrumSimulated() {
    if (!mounted) return;
    if (SpectrumService.instance.simulatedNotifier.value) {
      showToast('实时频谱暂不可用，已切换到模拟模式', long: true);
      setState(() {}); // 刷新菜单 subtitle
    }
  }

  /// 把形变相关的全局信号刷新一遍：当前 tab 下标 + 结构资格。
  ///
  /// - [playerTabIndex]：拖拽覆盖层里的 FullPlayer 是**另一个实例**，靠它才能
  ///   从同一个 tab 打开（否则下拉会把界面跳回封面 tab）。
  /// - [playerCoverVisible]：形变资格里与实例无关的那部分。**必须在绘制那一刻
  ///   可读**——竖屏停在歌词 / 评论 tab 时封面槽位根本不构建，把判定写在槽位里
  ///   等于永远不求值，`eligible` 会停在过期值，下拉照样飞出封面和歌名。
  ///
  ///   这里必须写**结构门**（[_morphTextEligible]）而不是 [_coverMorphEligible]：
  ///   该信号被封面与文字两侧共用（`willDraw` / `textWillDraw` 都读它），写成封面
  ///   那一侧会把频谱圆盘 / 写真对封面的压制**连带压掉文字连贯** —— 表现为
  ///   「封面不飞了，歌名也跟着不飞了」，与「只关封面、文字照飞」的要求相反。
  void _publishMorphSignals() {
    final i = _tabController.index;
    if (playerTabIndex.value != i) playerTabIndex.value = i;
    playerCoverVisible.value = _morphTextEligible;
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
    // 车机模式恒按窄屏处理：面板宽度已由 CarModePanel 覆盖到 MediaQuery.size，
    // 但用户若在设置里把「设备类型」手动选成平板，isPadLayout 仍会返回 true，
    // 那会让 tab 结构删掉封面 tab —— 而面板走的是 compact 分支、没有左栏封面，
    // 封面会彻底不可达。所以这里显式短路。
    final isWideLayout = !widget.dockMode && (deviceIsPad || width >= 600);
    final player = context.read<PlayerProvider>();
    final song = player.currentSong;
    final isLocalSong = song != null && !song.isOnline;
    final next = resolvePlayerTabLayout(
      isWideLayout: isWideLayout,
      isLocalSong: isLocalSong,
      closeLocalMusicComments: player.closeLocalMusicComments,
      // 宽屏且用户开启「横屏控制面板独立页」时，控制面板从底部常驻区
      // 搬进独立页签（resolve 内部还会与 isWideLayout 求与，控制页只在宽屏存在）。
      // dockMode=车机面板恒窄屏，沿用既有短路语义。
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
      // 封面淡入淡出：song 已经是新歌，_previousArtworkUrl 是上一首的封面
      if (_previousArtworkUrl != null &&
          _previousArtworkUrl != song.artworkUri) {
        final newUrl = song.artworkUri;
        _artworkFadeController
          ..reset()
          ..forward().then((_) {
            // 动画结束后才更新，确保淡出期间旧封面引用不丢失
            if (mounted) _previousArtworkUrl = newUrl;
          });
      } else {
        _previousArtworkUrl = song.artworkUri;
      }
      _fetchLyrics(song);
      // 预加载上一首和下一首的封面，防止切换时白屏
      final playlist = player.playlist;
      final idx = player.currentIndex;
      if (idx > 0) _preloadArtwork(playlist[idx - 1].artworkUri);
      if (idx < playlist.length - 1)
        _preloadArtwork(playlist[idx + 1].artworkUri);
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
    // 频谱启动：开启频谱且播放中时才启动（Visualizer(0) 需要活跃音频轨道）
    if (_spectrumEnabled && player.isPlaying && !_spectrumStarted) {
      _tryStartSpectrum(isPlaying: true);
    }
    // 同步播放状态到 SpectrumService（模拟模式用：播放时跳动、暂停时静止）
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
  void didUpdateWidget(covariant FullPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final song = context.read<PlayerProvider>().currentSong;
    if (song != null && song.id != _lastSongId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _fetchLyrics(song);
      });
    }
  }

  @override
  void dispose() {
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
    kLandscapeDetachedControlsEnabled.removeListener(
      _onDetachedControlsSettingChanged,
    );
    WidgetsBinding.instance.removeObserver(this);
    // 播放页离场：音乐震动的「播放页启用」计数减一
    MusicHapticsService.instance.setPlayerPageActive(false);
    _artworkFadeController.dispose();
    _zenPeekTimer?.cancel();
    _zenChromeDim.dispose();
    _zenController.dispose();
    _tabController.dispose();
    _controlsPageGestureLock.dispose();
    _lyricBatcher.dispose();
    // 退出播放器时停止频谱采集，释放原生 Visualizer
    SpectrumService.instance.simulatedNotifier.removeListener(
      _onSpectrumSimulated,
    );
    _stopSpectrum();
    // 播放器卸载：若仍在 Zen 中，清除全局标志，避免主界面 _SystemUiUpdater 被永久短路
    if (_zenMode) kPlayerZenImmersiveActive.value = false;
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
  void _enterZenMode() {
    if (_zenMode) return;
    // 车机模式：面板常驻不会 dispose，而 Zen 会设全局沉浸标志
    // kPlayerZenImmersiveActive；面板一旦进入 Zen 就没有兜底清理点，
    // 会让主界面 _SystemUiUpdater 被永久短路。
    if (widget.dockMode) return;
    // 停在控制页时**不**切走：控制页是 pager 的子页，ZenFade 只淡出底部导航条，
    // 进度条/传输行/音量条不会随之消失，切去歌词页反而会打断用户正在用的这页。
    setState(() => _zenMode = true);
    _zenController.forward();
    // tv: 控件随 _ZenFade 淡出（P-F），先释放焦点避免遥控焦点残留在
    // 已隐藏的 TabBar/控件上。
    if (kTvBuild) FocusManager.instance.primaryFocus?.unfocus();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    kPlayerZenImmersiveActive.value = true;
    _syncLandscapeImmersiveFlag();
  }

  /// 退出 Zen 沉浸模式：恢复所有 UI 元素和系统栏。
  void _exitZenMode() {
    // 显式退出要终止「唤出 4 秒后自动收回」的倒计时，否则用户刚长按退出、
    // 定时器又把 chrome 收回去。放在 !_zenMode 守卫之前：peek 期间 _zenMode
    // 已经是 false，守卫会直接 return、取消不到。
    _zenPeekTimer?.cancel();
    _zenPeekTimer = null;
    // 同样必须在守卫之前复位：peek 期间 _zenMode 已是 false，放守卫后面会残留 0.2
    // 的压暗因子，下次唤出 chrome 时它直接是暗的。
    _zenChromeDim.value = 1.0;
    if (!_zenMode) return;
    setState(() => _zenMode = false);
    _zenController.reverse();
    kPlayerZenImmersiveActive.value = false;
    applyImmersiveForOrientation();
    _syncLandscapeImmersiveFlag();
  }

  /// Zen 下单击封面：唤出 chrome，[_zenPeekDuration] 后自动收回（计划 §2.2 ③）。
  ///
  /// 用 Timer 不用 Ticker —— 这不是跟手动效，没必要按 vsync 产帧（AGENTS §10.1）。
  /// 整段停留同时在渐隐：不透明度从 100% 线性降到 [_zenPeekEndDim]，抵达的那一帧即收回。
  void _peekChromeFromZen() {
    if (!_zenMode) return;
    _exitZenMode();
    _zenPeekStep = 0;
    // 斜坡与收回共用一个 tick：抵达 [_zenPeekEndDim] 的那一帧就是恢复 Zen 的那一帧。
    _zenPeekTimer = Timer.periodic(_zenPeekInterval, (timer) {
      _zenPeekStep++;
      if (_zenPeekStep >= _zenPeekSteps) {
        timer.cancel();
        _zenPeekTimer = null;
        _zenChromeDim.value = _zenPeekEndDim;
        if (mounted) _enterZenMode();
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
    if (_zenPressController.value > 0.0) _zenPressController.reverse();
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
  Widget _wrapArtworkZenPress({required Widget child}) {
    // 车机模式禁用长按进 Zen：见 _enterZenMode 的说明。
    // 这一处是主守卫（连长按提示层与按压动效一并去掉）。
    if (!_zenLongPressEnabled || widget.dockMode) return child;
    return Listener(
      onPointerDown: _onArtworkPointerDown,
      onPointerMove: _onArtworkPointerMove,
      onPointerUp: (_) => _cancelArtworkPress(),
      onPointerCancel: (_) => _cancelArtworkPress(),
      child: AnimatedBuilder(
        animation: _zenPressController,
        child: child,
        builder: (context, artwork) {
          final progress = _zenPressController.value;
          // 按压时封面轻微内缩（1.0 → 0.94），松手回弹
          final press = Curves.easeOut.transform(progress);
          return Stack(
            // Stack 默认 hardEdge 会把子树裁回封面布局盒，而封面投影正是画在盒子
            // 外侧的那一圈模糊 —— 不关掉裁剪，投影就等于没加。
            // 提示层是 Positioned.fill（本就等于盒大小），关掉裁剪不影响它。
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
              // 窄横屏（800×360）里进度尺与播放键搬进左栏后，封面盒只剩 ~73dp：
              // 环 40 + 8 + 两行文案（>60）放不下，Stack 会被顶出 RenderFlex 溢出。
              // 盒子不够高就只留进度环 —— 环本身就是进度，文案是锦上添花。
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
  Widget _zenPressSurface({required Widget child}) {
    if (!_isDiscCover) {
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

  Future<void> _fetchLyrics(dynamic song) async {
    // 转场期间**连取词的启动都不做**（与 AM 页同一处理，成因见 `lyric_flight_batcher.dart`）：
    // 覆盖层实例会在转场第 1 帧建页并发起取词，交接后路由实例又取一遍，
    // 两次取词里有一次压在飞行帧上。落位后闭包把自己再调进来一次，只留一次取词。
    // 转场中多个调用点重复进来也不要紧：延后执行时第一个正常登记元数据键，
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

    _lyricBatcher.schedule(() {
      setState(() {
        _isLoadingLyrics = true;
        _lyrics = '';
        _lyricMetadata = const [];
        _hasTranslation = false;
        _hasRoma = false;
      });
    });

    // 正文首包和最终补全共用展示入口，旧歌曲的回调不能覆盖当前歌词。
    void showLyrics(String lyricText, {String? translationText, String? romaText}) {
      _lyricBatcher.schedule(() {
        if (!mounted || generation != _lyricFetchGeneration) return;
        final parsedLyrics = LyricParserChain.parse(
          lyricText,
          translationText: translationText,
          romaText: romaText,
        );
        setState(() {
          _isLoadingLyrics = false;
          // MD3 渲染器（LyricsView）内置的 LRC/KRC 正则无法解析 TTML 与
          // 增强型 LRC（尖括号逐字）。统一用 LyricParserChain 解析得到主歌词行，
          // 再序列化为标准 LRC 文本交给 LyricsView（保持其滚动/换行/点击逻辑不变）。
          _lyrics = _toLyricsViewText(lyricText);
          _lyricMetadata = parsedLyrics;
          _hasTranslation = parsedLyrics.any(
            (line) => line.translation != null && line.translation!.isNotEmpty,
          );
          _hasRoma = parsedLyrics.any(
            (line) => line.roma != null && line.roma!.isNotEmpty,
          );
        });
      });
    }

    try {
      String lyricText = '';
      String? translationText;
      String? romaText;

      // 这首歌自己的匹配记录：hash 精确检索 + 单曲偏好「使用在线歌词」
      if (song is Song && !song.isOnline) {
        await SongMatchRepository().ensureLoaded();
      }
      final matchInfo = (song is Song && !song.isOnline)
          ? SongMatchRepository().get(song.id)
          : null;
      final preferOnlineLyrics = matchInfo?.preferOnlineLyrics == true;

      // 本地歌曲优先读取内嵌歌词（ID3 USLT / SYLT / Vorbis LYRICS / MP4 ©lyr）；
      // 单曲偏好开启时跳过，直接走在线
      if (song is Song && !song.isOnline && !preferOnlineLyrics) {
        final localPath = song.localPath;
        if (localPath != null && localPath.isNotEmpty) {
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
        // 本地歌曲：命中匹配记忆时用在线 hash 精确检索；未命中传空 hash
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
          _lyrics = '';
          _lyricMetadata = const [];
          _hasTranslation = false;
          _hasRoma = false;
        });
      });
    }
  }

  /// 把原始歌词文本转换为 LyricsView 能识别的标准 LRC 行文本。
  ///
  /// LyricsView 内置的 LRC/KRC 正则无法解析 TTML（XML）与增强型 LRC（尖括号
  /// `<mm:ss.xx>` / `<offset,duration,...>` 逐字）。这里用 LyricParserChain
  /// 统一解析，仅取主歌词行
  /// （text + 行起始时间），序列化为 `[mm:ss.fff]主歌词` 文本交给 LyricsView，
  /// 保留其滚动、换行、点击跳转逻辑不变。
  /// 若 LyricsView 本身已能解析（普通 LRC / KRC），直接原样返回，避免任何行为变化。
  String _toLyricsViewText(String raw) {
    if (raw.trim().isEmpty) return raw;
    final format = LyricParserChain.detectFormat(raw);
    // 增强型 LRC：行首 `[mm:ss]` 会误判为 lrc，但其尖括号逐字时间戳无法由
    // LyricsView 直接处理。MD3 不需要逐字动态效果，因此先剥离内层标签，
    // 保留行首时间戳并转换为普通 LRC。
    if (_isEnhancedLrcText(raw)) {
      final normalized = raw.replaceAll(_inlineLyricTagRegex, '');
      return _serializeLines(LyricParserChain.parse(normalized));
    }
    // 个别本地文件把 KRC 的 `<offset,duration,...>` 标签嵌在 LRC 行中。
    // 这种混合格式会被自动检测为 LRC，必须先移除内层标签，否则它们会
    // 被 LyricsView 当成正文显示。
    if (format == LyricFormat.lrc && _krcWordTagRegex.hasMatch(raw)) {
      final normalized = raw.replaceAll(_krcWordTagRegex, '');
      return _serializeLines(LyricParserChain.parse(normalized));
    }
    // 普通 LRC / KRC 由 LyricsView 原生支持，原样透传
    if (format == LyricFormat.lrc || format == LyricFormat.krc) {
      return raw;
    }
    return _serializeLines(LyricParserChain.parse(raw));
  }

  /// 增强型 LRC 的内层逐字时间标签，允许一位到三位分钟数。
  static final RegExp _angleTimeRegex = RegExp(r'<\d{1,3}:\d{2}\.\d{2,3}>');
  static final RegExp _krcWordTagRegex = RegExp(r'<-?\d+(?:,-?\d+)+>');
  static final RegExp _inlineLyricTagRegex = RegExp(
    r'<(?:\d{1,3}:\d{2}\.\d{2,3}|-?\d+(?:,-?\d+)+)>',
  );
  static bool _isEnhancedLrcText(String raw) => _angleTimeRegex.hasMatch(raw);

  /// 把解析后的主歌词行序列化为 LyricsView 可识别的 `[mm:ss.fff]主歌词` 文本。
  String _serializeLines(List<LyricLine> lines) {
    if (lines.isEmpty) return '';
    final sb = StringBuffer();
    for (final l in lines) {
      if (l.text.isEmpty) continue;
      final ms = l.startTime;
      final mm = (ms ~/ 60000).toString().padLeft(2, '0');
      final ss = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
      final mmm = (ms % 1000).toString().padLeft(3, '0');
      sb.write('[$mm:$ss.$mmm]${l.text}\n');
    }
    return sb.toString();
  }

  /// 封面淡入淡出：旧封面淡出 + 新封面淡入，400ms easeInOut。
  Widget _buildCrossfadeArtwork(
    String? artworkUrl,
    ColorScheme colorScheme, {
    double iconSize = 48.0,
    String? fallbackFilePath,
  }) {
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
                  child: PlayerArtworkImage(
                    artworkUri: _previousArtworkUrl,
                    fallbackFilePath: fallbackFilePath,
                    fit: BoxFit.cover,
                    iconSize: iconSize,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                    iconColor: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            Positioned.fill(
              child: Opacity(
                opacity: newOpacity,
                child: DepthCoverHost(
                  artworkUri: artworkUrl,
                  fallbackFilePath: fallbackFilePath,
                  fit: BoxFit.cover,
                  iconSize: iconSize,
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  iconColor: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 转场取证用：整页 build 次数。**期望 0** —— 页面应当作为 `child` 被复用、
    // 只由面板裁剪；一旦转场期间它还在涨，UI 侧的大头就是整页逐帧重建。
    coverMorphCountPageBuild(this);
    return ZenChromeDim(
      notifier: _zenChromeDim,
      child: Builder(
        builder: (context) => _tvMenuKeyScope(context, _buildPlayer(context)),
      ),
    );
  }

  /// tv: 遥控菜单键 → 更多菜单（与顶栏「更多」按钮同源 [_showMoreMenu]）。
  /// CallbackShortcuts 的 Focus 不可聚焦、不参与遍历，只拦 contextMenu，
  /// 其余按键（方向/OK/BACK）原样穿透给 dpad 引擎。更多菜单 bottom sheet
  /// 打开后焦点在其路由子树内（非本页子孙），菜单键不会重复触发。
  Widget _tvMenuKeyScope(BuildContext context, Widget child) {
    if (!kTvBuild) return child;
    return TvMenuKeyShortcuts(onMenu: () => _showMoreMenu(context), child: child);
  }

  Widget _buildPlayer(BuildContext context) {
    final playerProvider = context.watch<PlayerProvider>();
    final themeProvider = context.watch<ThemeProvider>();
    final usePhotoBg = themeProvider.useArtistPhotoBackground;
    final lyricDoubleTap = themeProvider.lyricDoubleTapToJump;
    final currentSong = playerProvider.currentSong;
    final colorScheme = Theme.of(context).colorScheme;

    // 初始化封面 URL（首次进入或 null→有值）
    if (_previousArtworkUrl == null && currentSong?.artworkUri != null) {
      _previousArtworkUrl = currentSong!.artworkUri;
    }

    if (currentSong == null) {
      return Scaffold(
        backgroundColor: colorScheme.surface,
        appBar: AppBar(leading: const BackButton()),
        body: const Center(child: Text('暂无播放')),
      );
    }

    // 拦截系统返回键：先播放 reverse 动画（mini player 淡入），
    // 动画完成后用 removeRoute 移除路由（绕过 PopScope 避免死循环）。
    // 引用 kPlayerOverlayStyle 与 applyImmersiveForOrientation 共用同一 const 实例
    // 避免 SystemUiOverlayStyle 引用不等触发平台 channel 真实调用导致闪烁
    // 拖拽展开模式下系统栏样式跟随展开进度，避免拖动过程提前切换（见 PlayerSystemUiScope）
    // md 播放器背景跟随主题：状态栏文字需按主题亮度（浅色主题黑字 / 深色主题白字）
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mdOverlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: isDark
          ? Brightness.light
          : Brightness.dark,
    );
    return PlayerSystemUiScope(
      dragRoute: _dragRoute,
      // 拖拽覆盖层（非路由）期间系统栏恒为主页面样式；
      // 车机面板也不是全屏页，同样一律沿用主页面样式。
      forceMainStyle: _isDragOverlay || widget.dockMode,
      expandedOverlayStyle: mdOverlayStyle,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop || _isDismissing) return;
          // 车机面板常驻，返回键不得让它消失
          if (widget.dockMode) return;
          if (_zenMode) {
            _exitZenMode();
            return;
          }
          _collapseByButton();
        },
        child: Scaffold(
          backgroundColor: colorScheme.surface,
          // 键盘弹出时不重排整页：评论托盘自己处理输入框抬升，
          // 底部传输栏/导航条保持原位（否则打字时会被顶上去）
          resizeToAvoidBottomInset: false,
          body: Stack(
            fit: StackFit.expand,
            children: [
              // 歌手写真背景轮播（开关开启 + 在线歌曲时显示）
              if (usePhotoBg && currentSong!.isOnline)
                ArtistPhotoBackground(
                  hash: currentSong.id,
                  onHasImages: (hasImages) {
                    if (_photoBgHasImages != hasImages) {
                      setState(() => _photoBgHasImages = hasImages);
                    }
                  },
                ),
              // 频谱背景层：style=2 时显示底部条形频谱图（播放时淡入、暂停时淡出）
              if (_spectrumEnabled && _spectrumStyle == 2)
                SpectrumBackground(
                  color: colorScheme.primary,
                  opacity: _spectrumBgOpacity,
                  heightRatio: _spectrumBgHeight,
                  visible: playerProvider.isPlaying,
                ),
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
            ],
          ),
        ),
      ),
    ); // AnnotatedRegion
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
              children: [
                // 播放列表面板（index 0，最左侧，与 AM 一致）
                // 左滑切页：列表卡片吃掉了水平拖拽，靠面板内的指针判定回调补齐
                PlayerPlaylistView(
                  scrollAnchor: _playlistScroll,
                  useAmColors: false,
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
                    // 封面 tab 与顶栏一样支持向下拖拽原路返回关闭播放器
                    onVerticalDragStart: widget.dockMode
                        ? null
                        : _onTopBarDragStart,
                    onVerticalDragUpdate: widget.dockMode
                        ? null
                        : _onTopBarDragUpdate,
                    onVerticalDragEnd: widget.dockMode
                        ? null
                        : _onTopBarDragEnd,
                    onVerticalDragCancel: widget.dockMode
                        ? null
                        : _onTopBarDragCancel,
                    child: _buildArtworkView(
                      playerProvider,
                      currentSong,
                      colorScheme,
                      isExpanded: true,
                    ),
                  ),
                GestureDetector(
                  onTap: () => _goToTab(1),
                  behavior: HitTestBehavior.translucent,
                  child: _wrapMd3LyricsWithAuxToggle(
                    _isLoadingLyrics
                        ? Center(
                            child: M3ELoadingIndicator(
                              color: colorScheme.primary,
                            ),
                          )
                        // P0: 歌词时间只订阅 positionNotifier（高频 200ms），
                        // 不再因 positionStream 触发整页重建
                        : RepaintBoundary(
                            child: LyricsView(
                              lyrics: _lyrics,
                              parsedLyrics: _lyricMetadata,
                              position: Duration.zero,
                              positionListenable:
                                  playerProvider.positionNotifier,
                              adaptPosition: (position) =>
                                  _adjustedLyricPosition(position, currentSong),
                              doubleTapToJump: lyricDoubleTap,
                              onSeek: (duration) {
                                playerProvider.seek(duration);
                              },
                            ),
                          ),
                  ),
                ),
                // 评论 tab：本地歌曲且开启了「关闭本地音乐评论区」时不存在
                if (_tabLayout.hasComments)
                  CommentsView(
                    songHash: currentSong.id,
                    albumAudioId: currentSong.albumAudioId,
                    // 输入不在播放器里：长按评论段/点「回复」弹出仅输入框的托盘
                    showComposer: false,
                    onReplyComment: _openComposeSheet,
                  ),
              ],
            ),
          ),
          ZenFade(
            animation: _zenAnimation,
            // 与顶栏同一个开关：关闭时页签条回到这一列底部（原形态），
            // 所以两处都得订阅，否则只有半边会跟着换。
            child: ListenableBuilder(
              listenable: kTopBarTabDotsEnabled,
              builder: (context, _) => _buildControls(
                playerProvider,
                colorScheme,
                // 车机面板是窄容器：用紧凑档控件（传输行 164dp，见
                // MD3ETransportRow），否则 212dp 的传输行 + 40dp 内边距
                // 在 20% 宽的面板里必然 RenderFlex overflow。
                isExpanded: widget.dockMode,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 手机横屏 / Pad 竖屏布局：左侧封面，右侧信息+歌词/评论+控制栏。
  /// 顶部栏放在最外层 Column，使返回按钮真正位于屏幕最左上角。
  Widget _buildLandscapeLayout(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme,
    bool lyricDoubleTap,
  ) {
    // 横屏/竖屏 edgeToEdge 模式：底部需要额外 padding 避免被导航栏遮挡
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom + 8;
    // 横屏 + 写真背景开启时，写真已铺满全屏作为背景，隐藏左侧封面避免视觉重复。
    // 关闭写真背景或 Zen 模式时恢复显示封面。
    // 写真实际无图时（_photoBgHasImages=false）也恢复显示封面，避免封面消失。
    final usePhotoBg = context.watch<ThemeProvider>().useArtistPhotoBackground;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final hideArtworkForPhotoBg =
        isLandscape &&
        usePhotoBg &&
        _photoBgHasImages &&
        currentSong.isOnline &&
        !_zenMode;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          // 顶部栏放在最外层，占据整行：返回按钮真正在屏幕最左上角
          ZenFade(
            animation: _zenAnimation,
            child: _buildTopBar(playerProvider, wide: true),
          ),
          Expanded(
            child: LayoutBuilder(
              // 常驻控制带按**右栏局部**宽高分档：4/6 分栏 → 右栏宽 = 内容区 6/10，
              // 高即内容区高（顶栏在它上方，不参与分档）。判定不读
              // platformDispatcher 物理快照 —— 转屏动画途中那是旧值，会让 tab 结构
              // 与孩子数量对不上（计划 §2.3 / R4）。
              builder: (context, content) {
                final tier = resolvePlayerDockTier(
                  paneWidth: content.maxWidth * 6 / 10,
                  paneHeight: content.maxHeight,
                  dockMode: widget.dockMode,
                );
                // 左栏的比例内衬、以及「尺与播放键装不装得进左栏」都在这一处判定：
                // 左栏和右栏底部那条 chrome 必须读到**同一个结论**，否则进度尺要么
                // 挂两遍、要么一处都没有。
                final gutter = PlayerWidePane.gutter(content.maxWidth * 4 / 10);
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
                  flex: 4,
                  child: Builder(
                    builder: (context) {
                      // 封面 / 曲名 / 进度尺 / 播放键共用**同一个内容盒**：左右内衬只按
                      // 栏宽取一次比例，四件都贴这条边线（改造前各吃各的：栏内衬写死 16、
                      // 曲名按封面边长、播放键按自然宽、尺还额外叠一层控制带的 16，
                      // 实测 800×360 上 147 / 120 / 164 三种宽度并存，边缘对不齐）。
                      // 纵向居中令上下留白相等。
                      return Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: gutter,
                          vertical: gutter,
                        ),
                        child: AnimatedBuilder(
                          // Zen 淡出途中逐帧重算封面边长（见下方 chrome 的折算）。
                          // 这条动画是**一次性状态转场**，不是常驻循环（AGENTS §10.1
                          // 的合法例外）：跑完就停，不挂常驻 Ticker。
                          animation: _zenAnimation,
                          builder: (context, _) => LayoutBuilder(
                          builder: (context, constraints) {
                            // 封面正方形边长：宽、高两个方向取小的那个。chrome 取
                            // 「实际排在曲名下方那几件」的实测预留，预留准了封面边长
                            // 才等于曲名盒的宽度，四件才共用一条左右边线。
                            //
                            // **chrome 要按 Zen 进度折算**：曲名 / 进度尺 / 播放键在
                            // Zen 下被 `ZenFade` 的 SizeTransition 折成 0 高，空间确实
                            // 让出来了；预留若不跟着归零，`coverSize` 就照旧扣掉整条
                            // chrome，让出来的 190dp 一分都不补给封面 —— 表现为「进 Zen
                            // 封面不再变大、横屏手机上明显比旧版小」。读的是**同一个**
                            // _zenAnimation，所以折叠与长大在同一帧序列里，不会出现
                            // 「预留先归零、Flexible 把封面压成扁方块」的中间态。
                            // 注意 `bandFits` 不吃这个折算：它决定尺挂在哪一栏，
                            // 跟着 Zen 翻脸会在淡出途中整块重排。
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
                            return Align(
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  // 封面：横屏 + 写真背景开启时隐藏（避免与背景写真重复）
                                  if (!hideArtworkForPhotoBg)
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
                                          // 加一个 no-op onTap，让静止点击被 TapGestureRecognizer 赢下手势竞技场
                                          // （与竖屏封面一致）；拖动仍由竖向拖拽识别器接管。
                                          onTap: _onWideArtworkTap,
                                          onVerticalDragStart: widget.dockMode
                                              ? null
                                              : _onTopBarDragStart,
                                          onVerticalDragUpdate: widget.dockMode
                                              ? null
                                              : _onTopBarDragUpdate,
                                          onVerticalDragEnd: widget.dockMode
                                              ? null
                                              : _onTopBarDragEnd,
                                          onVerticalDragCancel: widget.dockMode
                                              ? null
                                              : _onTopBarDragCancel,
                                          child: _wrapArtworkZenPress(
                                            // PlayerCoverSlot 必须在 AnimatedScale
                                            // **外层**：槽位里的探针用
                                            // 「实测屏幕矩形 / 自身布局尺寸」反推
                                            // pageToScreen（页面本地 → 屏幕）。
                                            // 一旦被关在 AnimatedScale 内层，暂停时的
                                            // 0.85 会被算进这个比值，它就不再是页面→
                                            // 屏幕的缩放比，settledRect 的位移抵消随之
                                            // 失真（暂停态下拉收起会闪一帧）。
                                            // AnimatedScale 只改绘制不改布局，
                                            // 两者对调不改变任何布局尺寸与视觉。
                                            child: PlayerCoverSlot(
                                              songId: currentSong.id,
                                              artworkUri: currentSong.artworkUri,
                                              fallbackFilePath:
                                                  currentSong.localPath,
                                              iconSize: 48,
                                              placeholderColor: colorScheme
                                                  .surfaceContainerHighest,
                                              shadowColor: colorScheme.shadow,
                                              eligible: () => _coverMorphEligible,
                                              // 暂停态的稳定态缩放 / 锚点：形变层终点
                                              // 要落在**真实封面可见的位置**上，否则
                                              // 暂停时从 MiniPlayer 上滑，飞行终点是满
                                              // 尺寸，松手后 AnimatedScale 再从 1.0 缩到
                                              // 0.85，会多出一段看得见的收缩动画。
                                              // 必须与下面 AnimatedScale 的表达式一致。
                                              settledScale: _isDiscCover
                                                  ? 1.0
                                                  : (playerProvider.isPlaying
                                                      ? 1.0
                                                      : 0.85),
                                              settledAnchor: Alignment.center,
                                              child: AnimatedScale(
                                                // 频谱模式（style 0/1 圆形旋转封面）不需要封面的放大缩小动画
                                                scale: _isDiscCover
                                                    ? 1.0
                                                    : (playerProvider.isPlaying
                                                        ? 1.0
                                                        : 0.85),
                                                // 缩放锚点=中心：宽屏标题本就居中于封面下方，
                                                // 暂停内缩也必须绕同一个视觉中心收，否则缩到
                                                // 0.85 的封面会向左下偏移，四边留白立刻不等。
                                                // （曾用 bottomLeft：那是标题左对齐年代为了
                                                //  让标题左缘贴封面可见左缘，如今该前提不成立。）
                                                alignment: Alignment.center,
                                                duration: const Duration(
                                                  milliseconds: 500,
                                                ),
                                                curve: Curves.easeOutBack,
                                                child:
                                                    _buildCrossfadeArtworkWrapper(
                                                  currentSong,
                                                  colorScheme,
                                                  iconSize: 48,
                                                  isPlaying:
                                                      playerProvider.isPlaying,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      )
                                    ),
                                  // 封面下方这段 chrome（曲名 + 常驻档的尺与播放键）连同它的
                                  // 16 / 12 / 12 三条行距一起折成 0：行距若留在 ZenFade 外层，
                                  // Zen 收起后封面下面仍占着 40px，整列居中就等于把封面
                                  // 往上顶 —— 上下留白不等（实测 16/16/146/174）。
                                  ZenFade(
                                    animation: _zenAnimation,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const SizedBox(
                                          height: PlayerWidePane.titleGap,
                                        ),
                                        // 歌名 / 艺人·专辑：横屏一律**居中**于封面下方，
                                        // 宽度取封面布局盒 size（写真背景隐封面时退回整栏宽），
                                        // 与封面同轴；常驻档再往下就是控制带，整列一起居中。
                                        // Zen 与传输簇同源淡出：曲名/艺人·专辑也是 chrome，
                                        // 留在屏幕上会与「只剩封面与歌词」的 Zen 语义冲突。
                                        SizedBox(
                                          width: hideArtworkForPhotoBg
                                              ? null
                                              : size,
                                          child: _buildTitleBlockMorph(
                                            playerProvider,
                                            currentSong,
                                            colorScheme,
                                            alignment: CrossAxisAlignment.center,
                                            dense: true,
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
                  flex: 6,
                  child: Column(
                    children: [
                      // 内容区（播放列表 / 封面信息 / 歌词 / 评论 / 控制?）
                      // Pad模式下无封面Tab；手机横屏保留封面Tab
                      Expanded(
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _controlsPageGestureLock,
                          builder: (context, locked, _) => PlayerTabPager(
                            key: _pagerKey,
                            tabController: _tabController,
                            // 控制页内按下期间锁横滑：进度条/音量条的水平拖动
                            // 优先于切页（R1 手势锁，见 _controlsPageGestureLock）
                            physics: locked
                                ? const NeverScrollableScrollPhysics()
                                : null,
                            children: [
                              // 播放列表面板（index 0，最左侧，与 AM 一致）
                              // 左滑切页：列表卡片吃掉了水平拖拽，靠面板内的指针判定回调补齐
                              PlayerPlaylistView(
                                scrollAnchor: _playlistScroll,
                                useAmColors: false,
                                // 左滑跟手：面板逐帧上报进度，driver 写进 TabController
                                onSwipeStart: _playlistSwipe.start,
                                onSwipeProgress: _playlistSwipe.update,
                                onSwipeRelease: (velocity, width) =>
                                    _playlistSwipe.settle(
                                  velocityPxPerSec: velocity,
                                  panelWidth: width,
                                ),
                              ),
                              // 控制 tab：进度/传输/音量搬进独立页签（宽屏 +
                              // 「横屏控制面板独立页」开启时存在，与 _buildTabStrip
                              // 的 hasControls 分支同源，都只读 _tabLayout）。
                              // 排在歌词之前：播放列表 / 控制 / 歌词 / 评论，
                              // 从歌单左滑一下即达，不必越过歌词与评论。
                              if (_tabLayout.hasControls)
                                _buildLandscapeControlPage(
                                  playerProvider,
                                  colorScheme,
                                ),
                              _wrapMd3LyricsWithAuxToggle(
                                _isLoadingLyrics
                                    ? Center(
                                        child: M3ELoadingIndicator(
                                          color: colorScheme.primary,
                                        ),
                                      )
                                    // P0: 歌词时间只订阅 positionNotifier（高频 200ms）
                                    : RepaintBoundary(
                                        child: LyricsView(
                                          lyrics: _lyrics,
                                          parsedLyrics: _lyricMetadata,
                                          position: Duration.zero,
                                          positionListenable:
                                              playerProvider.positionNotifier,
                                          adaptPosition: (position) =>
                                              _adjustedLyricPosition(
                                                position,
                                                currentSong,
                                              ),
                                          doubleTapToJump: lyricDoubleTap,
                                          onSeek: (duration) {
                                            playerProvider.seek(duration);
                                          },
                                        ),
                                      ),
                              ),
                              // 评论 tab：本地歌曲且开启了「关闭本地音乐评论区」时不存在
                              if (_tabLayout.hasComments)
                                CommentsView(
                                  songHash: currentSong.id,
                                  albumAudioId: currentSong.albumAudioId,
                                  // 输入不在播放器里：长按评论段/点「回复」弹出仅输入框的托盘
                                  showComposer: false,
                                  onReplyComment: _openComposeSheet,
                                ),
                            ],
                          ),
                        ),
                      ),
                      // 导航条从原控制面板中提出常驻：控制面板搬进「控制」页后，
                      // 它必须留在外面，否则进入控制页后无法点击离开（只能滑动）。
                      // 常驻档（开关关闭）在导航条下面追加控制带。
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
    // 横屏 + 写真背景开启时，写真已铺满全屏作为背景，隐藏左侧封面避免视觉重复。
    // 关闭写真背景或 Zen 模式时恢复显示封面。
    // 写真实际无图时（_photoBgHasImages=false）也恢复显示封面，避免封面消失。
    final usePhotoBg = context.watch<ThemeProvider>().useArtistPhotoBackground;
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final hideArtworkForPhotoBg =
        isLandscape &&
        usePhotoBg &&
        _photoBgHasImages &&
        currentSong.isOnline &&
        !_zenMode;

    return SafeArea(
      bottom: false,
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
              builder: (context, content) {
                final tier = resolvePlayerDockTier(
                  paneWidth: content.maxWidth * 6 / 10,
                  paneHeight: content.maxHeight,
                  dockMode: widget.dockMode,
                );
                // 左栏的比例内衬、以及「尺与播放键装不装得进左栏」都在这一处判定：
                // 左栏和右栏底部那条 chrome 必须读到**同一个结论**，否则进度尺要么
                // 挂两遍、要么一处都没有。
                final gutter = PlayerWidePane.gutter(content.maxWidth * 4 / 10);
                final bandInLeftPane =
                    !_detachedControls &&
                    !widget.dockMode &&
                    PlayerWidePane.bandFits(
                      innerHeight: content.maxHeight - gutter * 2,
                    );
                return Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Builder(
                    builder: (context) {
                      // 封面 + 曲名 +（常驻档的尺与播放键）共用同一个内容盒，
                      // **水平居中**于左栏：内衬按栏宽取比例，四件贴同一条左右边线
                      // （口径与 _buildLandscapeLayout 完全一致）。
                      return Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: gutter,
                          vertical: gutter,
                        ),
                        child: AnimatedBuilder(
                          // 与 _buildLandscapeLayout 同一条口径：chrome 按 Zen 进度折算，
                          // 让 ZenFade 折出来的高度真的补给封面（理由见那处的长注释）。
                          animation: _zenAnimation,
                          builder: (context, _) => LayoutBuilder(
                          builder: (context, constraints) {
                            // 正方形边长 = min(栏内宽, 栏内高 − chrome 实测预留)。
                            // 不再封顶 380：封了顶封面就比横贯栏宽的进度尺窄一截，
                            // 实测 1280×800 上会退回「封面 380 / 尺 464」的对不齐。
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
                            return Align(
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  // 封面：横屏 + 写真背景开启时隐藏（避免与背景写真重复）
                                  if (!hideArtworkForPhotoBg)
                                    Flexible(
                                      // 与 _buildLandscapeLayout 同口径：封面按 maxSize 定方
                                      // 正方形，与曲名/尺/播放键共用一条左右边线。
                                      child: SizedBox.square(
                                        dimension: maxSize,
                                        // 封面支持向下拖拽原路返回关闭播放器（横屏/pad 与竖屏一致），
                                        // 同时保留长按封面进入/退出 Zen 模式（按压内缩 + 引导提示）
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          // 见上：no-op onTap 让静止点击被 Tap 识别器赢下竞技场，
                                          // 避免唯一竖向拖拽识别器把点击误判为微拖拽收起（「点击封面闪回」）。
                                          onTap: () {
                                            _consumeZenPressTap();
                                          },
                                          onVerticalDragStart: widget.dockMode
                                              ? null
                                              : _onTopBarDragStart,
                                          onVerticalDragUpdate: widget.dockMode
                                              ? null
                                              : _onTopBarDragUpdate,
                                          onVerticalDragEnd: widget.dockMode
                                              ? null
                                              : _onTopBarDragEnd,
                                          onVerticalDragCancel: widget.dockMode
                                              ? null
                                              : _onTopBarDragCancel,
                                          child: _wrapArtworkZenPress(
                                            // PlayerCoverSlot 必须在 AnimatedScale
                                            // **外层**：槽位里的探针用
                                            // 「实测屏幕矩形 / 自身布局尺寸」反推
                                            // pageToScreen（页面本地 → 屏幕）。
                                            // 一旦被关在 AnimatedScale 内层，暂停时的
                                            // 0.85 会被算进这个比值，它就不再是页面→
                                            // 屏幕的缩放比，settledRect 的位移抵消随之
                                            // 失真（暂停态下拉收起会闪一帧）。
                                            // AnimatedScale 只改绘制不改布局，
                                            // 两者对调不改变任何布局尺寸与视觉。
                                            child: PlayerCoverSlot(
                                              songId: currentSong.id,
                                              artworkUri: currentSong.artworkUri,
                                              fallbackFilePath:
                                                  currentSong.localPath,
                                              iconSize: 48,
                                              placeholderColor: colorScheme
                                                  .surfaceContainerHighest,
                                              shadowColor: colorScheme.shadow,
                                              eligible: () => _coverMorphEligible,
                                              // 暂停态的稳定态缩放 / 锚点：与下面
                                              // AnimatedScale 一致，理由见左栏 A 处注释。
                                              settledScale: _isDiscCover
                                                  ? 1.0
                                                  : (playerProvider.isPlaying
                                                      ? 1.0
                                                      : 0.85),
                                              settledAnchor: Alignment.center,
                                              child: AnimatedScale(
                                                // 频谱模式（style 0/1 圆形旋转封面）不需要封面的放大缩小动画
                                                scale: _isDiscCover
                                                    ? 1.0
                                                    : (playerProvider.isPlaying
                                                        ? 1.0
                                                        : 0.85),
                                                // 锚点=中心：与 _buildLandscapeLayout 同口径，
                                                // 暂停内缩绕封面视觉中心收，四边留白才相等。
                                                alignment: Alignment.center,
                                                duration: const Duration(
                                                  milliseconds: 500,
                                                ),
                                                curve: Curves.easeOutBack,
                                                child:
                                                    _buildCrossfadeArtworkWrapper(
                                                  currentSong,
                                                  colorScheme,
                                                  iconSize: 48,
                                                  isPlaying: playerProvider
                                                      .isPlaying,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  // 与 _buildLandscapeLayout 同一套收口：行距留在 ZenFade
                                  // 外层会在 Zen 下残留 40px，把封面顶离纵向中心。
                                  ZenFade(
                                    animation: _zenAnimation,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const SizedBox(
                                          height: PlayerWidePane.titleGap,
                                        ),
                                        // 歌名 / 艺人·专辑：横屏一律**居中**于封面下方，
                                        // 宽度取封面布局盒 maxSize（写真背景隐封面时退回整栏宽），
                                        // 与封面同轴；常驻档再往下就是控制带，整列一起居中。
                                        // Zen 与传输簇同源淡出：曲名/艺人·专辑也是 chrome，
                                        // 留在屏幕上会与「只剩封面与歌词」的 Zen 语义冲突。
                                        SizedBox(
                                          width: hideArtworkForPhotoBg
                                              ? null
                                              : maxSize,
                                          child: _buildTitleBlockMorph(
                                            playerProvider,
                                            currentSong,
                                            colorScheme,
                                            alignment: CrossAxisAlignment.center,
                                            dense: true,
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
                            );
                          },
                        ),
                        ),
                      );
                    },
                  ),
                ),
                Expanded(
                  flex: 6,
                  child: Column(
                    children: [
                      // 与 _buildLandscapeLayout 同构：平板/折叠展开也把控制面板
                      // 搬进「控制」页，导航条常驻底部。
                      Expanded(
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _controlsPageGestureLock,
                          builder: (context, locked, _) => PlayerTabPager(
                            key: _pagerKey,
                            tabController: _tabController,
                            // 控制页内按下期间锁横滑：进度条/音量条的水平拖动
                            // 优先于切页（R1 手势锁，见 _controlsPageGestureLock）
                            physics: locked
                                ? const NeverScrollableScrollPhysics()
                                : null,
                            children: [
                              // 播放列表面板（index 0，最左侧，与 AM 一致）
                              // 左滑切页：列表卡片吃掉了水平拖拽，靠面板内的指针判定回调补齐
                              PlayerPlaylistView(
                                scrollAnchor: _playlistScroll,
                                useAmColors: false,
                                // 左滑跟手：面板逐帧上报进度，driver 写进 TabController
                                onSwipeStart: _playlistSwipe.start,
                                onSwipeProgress: _playlistSwipe.update,
                                onSwipeRelease: (velocity, width) =>
                                    _playlistSwipe.settle(
                                  velocityPxPerSec: velocity,
                                  panelWidth: width,
                                ),
                              ),
                              // 控制 tab：进度/传输/音量搬进独立页签（宽屏 +
                              // 「横屏控制面板独立页」开启时存在，与 _buildTabStrip
                              // 的 hasControls 分支同源，都只读 _tabLayout）。
                              // 排在歌词之前：播放列表 / 控制 / 歌词 / 评论，
                              // 从歌单左滑一下即达，不必越过歌词与评论。
                              if (_tabLayout.hasControls)
                                _buildLandscapeControlPage(
                                  playerProvider,
                                  colorScheme,
                                ),
                              _wrapMd3LyricsWithAuxToggle(
                                _isLoadingLyrics
                                    ? Center(
                                        child: M3ELoadingIndicator(
                                          color: colorScheme.primary,
                                        ),
                                      )
                                    // P0: 歌词时间只订阅 positionNotifier（高频 200ms）
                                    : RepaintBoundary(
                                        child: LyricsView(
                                          lyrics: _lyrics,
                                          parsedLyrics: _lyricMetadata,
                                          position: Duration.zero,
                                          positionListenable:
                                              playerProvider.positionNotifier,
                                          adaptPosition: (position) =>
                                              _adjustedLyricPosition(
                                                position,
                                                currentSong,
                                              ),
                                          doubleTapToJump: lyricDoubleTap,
                                          onSeek: (duration) {
                                            playerProvider.seek(duration);
                                          },
                                        ),
                                      ),
                              ),
                              // 评论 tab：本地歌曲且开启了「关闭本地音乐评论区」时不存在
                              if (_tabLayout.hasComments)
                                CommentsView(
                                  songHash: currentSong.id,
                                  albumAudioId: currentSong.albumAudioId,
                                  // 输入不在播放器里：长按评论段/点「回复」弹出仅输入框的托盘
                                  showComposer: false,
                                  onReplyComment: _openComposeSheet,
                                ),
                            ],
                          ),
                        ),
                      ),
                      // 导航条从原控制面板中提出常驻：控制面板搬进「控制」页后，
                      // 它必须留在外面，否则进入控制页后无法点击离开（只能滑动）。
                      // 底部 padding 包含导航栏高度；常驻档在导航条下面追加控制带。
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
    );
  }

  /// 顶部栏：返回 + 页签圆点（竖屏占中段）+ 音质胶囊（宽屏常驻档）+ 尾部胶囊。
  ///
  /// 音质胶囊：竖屏与独立控制页跟着进度条走，落在进度条两侧时间数字的同一行；
  /// 宽屏**常驻档**那一行要留给刻度尺的时间数字，于是回到顶栏。
  ///
  /// [wide] 表示这一版顶栏服务的是宽屏（横屏/平板）形态。**竖屏**的页签圆点坐在
  /// 返回键与尾部之间的中段里，并由 [PlayerTopBarTabDots] 给尾部胶囊让位（左移→压缩）；
  /// 宽屏的页签条在右栏底部（见 [_buildChromeBottom]），顶栏不再渲染，否则同一个
  /// TabController 会被两处实例抢用。
  Widget _buildTopBar(PlayerProvider playerProvider, {bool wide = false}) {
    // 「歌曲信息 / 播放速度」等原先散落在顶栏与底部胶囊的入口统一收进更多菜单，
    // 顶栏尾部从 4 个元素回到 2 个。
    // 整个顶栏支持向下拖拽原路返回（点击按钮仍由子元素处理，竞技场自动区分）
    final bar = GestureDetector(
      behavior: HitTestBehavior.translucent,
      // 车机模式：顶栏不参与「下拉原路收起」，否则手势会被白白吃掉
      // （_onTopBarDragStart 内部会因 route 不是 DraggablePlayerRoute 而早返回，
      // 但仍是注册了手势识别器）。
      onVerticalDragStart: widget.dockMode ? null : _onTopBarDragStart,
      onVerticalDragUpdate: widget.dockMode ? null : _onTopBarDragUpdate,
      onVerticalDragEnd: widget.dockMode ? null : _onTopBarDragEnd,
      onVerticalDragCancel: widget.dockMode ? null : _onTopBarDragCancel,
      child: LayoutBuilder(
        // 宽屏（横屏 / Pad）的尾部胶囊贴**页面比例内衬**：顶栏与下方 Row 同宽，
        // 所以这里按 4/10 取到的 gutter 与左栏封面/曲名/进度尺用的是同一个值。
        // 竖屏沿用原来的 8，不受影响。
        builder: (context, box) => Padding(
          padding: EdgeInsets.only(
            left: 8,
            right: wide ? PlayerWidePane.gutter(box.maxWidth * 4 / 10) : 8,
            top: 4,
            bottom: 4,
          ),
          child: Row(
          children: [
            // 车机模式：面板不可收起，左侧按钮改为「退出车机模式」（二次确认）
            if (widget.dockMode)
              IconButton(
                icon: const Icon(Icons.close_fullscreen),
                tooltip: '退出车机模式',
                onPressed: _confirmExitCarMode,
              )
            else
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down),
                onPressed: _collapseByButton,
              ),
            // 页签条位置由「顶栏页签圆点」开关决定（默认关闭 = 留在底部，见 _buildControls）；
            // 判断口径收在 playerTopBarTabMiddle 里，宽屏恒为 Spacer。
            playerTopBarTabMiddle(
              wide: wide,
              segmentCount: _tabLayout.length,
              strip: () => _buildTabStrip(
                Theme.of(context).colorScheme,
                variant: PlayerTabStripVariant.dots,
              ),
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
                  final style = SleepTimerPillStyle.standardOf(context);
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
                      if (!widget.dockMode) _qualityTopBarSegment(playerProvider),
                      ?sleep,
                      ?listen,
                    ],
                    background: style.backgroundColor,
                    // 宽屏/横屏不带底色，前景也就不能再用「贴在容器上」的那套色：
                    // onPrimaryContainer 压在页面背景/壁纸上会发灰，改吃 onSurface
                    // （与 ⋯ 用的 onSurfaceVariant 同一套裸 chrome 取色）。
                    foreground:
                        wide
                            ? Theme.of(context).colorScheme.onSurface
                            : style.foregroundColor,
                    // 横屏裸化：不画那层连体底色，每格与 ⋯ 一样是裸图标 + 文案。
                    showBackground: !wide,
                    dotColor: Theme.of(context).colorScheme.error,
                    // ⋯ 现在是胶囊之外的裸图标，不能再借用底色上的 foreground
                    // （onPrimaryContainer 贴在播放页背景上对比度不够稳），改用
                    // 裸图标惯用的 onSurfaceVariant。
                    moreIconColor: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant,
                    collapsible: !wide,
                    onMore: () => _showMoreMenu(context),
                  );
                },
              ),
            ),
          ],
        ),
        ),
      ),
    );

    return bar;
  }

  /// 顶栏尾部胶囊里的「音质」一格 —— 与睡眠定时、一起听、⋯ 共用同一颗连体背景。
  ///
  /// 语义与原独立徽章逐条对齐：在线歌曲点开音质选择、长按开音量面板、本地歌曲屏蔽
  /// 点击（`onTap` 给 null，胶囊据此让整格不响应也不出涟漪）。
  /// `collapseOnlyWithPeers` = 旁边还有睡眠/一起听时才缩成一颗音符。
  TopBarTrailingSegment _qualityTopBarSegment(PlayerProvider playerProvider) {
    final song = playerProvider.currentSong;
    final isLocal = song is Song && !song.isOnline;
    return TopBarTrailingSegment(
      icon: Icons.music_note,
      label: playerProvider.currentQualityLabel,
      semanticsLabel: '音质',
      collapseOnlyWithPeers: true,
      onTap: isLocal
          ? null
          : () => showAudioQualityDialog(
              context: context,
              qualities: kPlayerAudioQualities,
              selected: playerProvider.audioQuality,
              onSelected: playerProvider.setAudioQuality,
            ),
      onLongPress: () => _showVolumeDialog(playerProvider),
    );
  }

  /// MD3E v2 质量徽章 — primaryContainer 背景 + StadiumBorder + 图标 + 文字。
  /// 本地歌曲：只读显示码率推断的音质，禁用点击切换。
  /// 在线歌曲：点击复用 showAudioQualityDialog。
  ///
  /// [faded] = **淡化**形态，用于进度条下方那一行（车机面板）：只把容器降到 55% alpha，
  /// 图标与文字保持满色。那一行的时间数字靠各自的 `AnimatedOpacity` 压暗，徽章若跟着
  /// 整块合成到封面上就会发灰发暗（看着像禁用）—— 淡是它自己变轻，不是被压暗。
  Widget _buildQualityPill(PlayerProvider playerProvider, {bool faded = false}) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final song = playerProvider.currentSong;
    final isLocal = song is Song && !song.isOnline;
    final pill = Material(
      color: faded
          ? colorScheme.primaryContainer.withValues(alpha: 0.55)
          : colorScheme.primaryContainer,
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
        // 几何取 AppCapsule 的徽章档，与发现页问候胶囊同一刻度：32 的图标方块
        // 内含 16 的图标，文案左 2 右 12。原先是「图标 14 + 内衬 8×4」——
        // 14/4 都是 app_dimens 明令避开的离格值，且与另两枚胶囊各写一套。
        child: SizedBox(
          height: AppCapsule.badgeSize,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: AppCapsule.badgeSize,
                child: Center(
                  child: Icon(
                    Icons.music_note,
                    size: AppCapsule.badgeIcon,
                    color: colorScheme.onPrimaryContainer,
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
                    color: colorScheme.onPrimaryContainer,
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
        debugLabel: 'full_player_quality_pill',
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

  /// 封面区（含频谱圆盘）+ 歌曲弹幕宿主。
  ///
  /// 竖屏封面 tab / 横屏左栏 / 平板左栏 / 车机 dock 四种布局的封面内容都从这里
  /// 出去，所以弹幕层只挂这一处即覆盖全部形态，且天然只盖住封面方盒本身 ——
  /// 右侧内容区（歌词/评论/列表）不会有弹幕飘过去。
  Widget _buildCrossfadeArtworkWrapper(
    dynamic currentSong,
    ColorScheme colorScheme, {
    double iconSize = 48.0,
    required bool isPlaying,
  }) {
    final cover = _buildCoverArtwork(
      currentSong,
      colorScheme,
      iconSize: iconSize,
      isPlaying: isPlaying,
    );
    return SongDanmakuHost(cover: cover);
  }

  Widget _buildCoverArtwork(
    dynamic currentSong,
    ColorScheme colorScheme, {
    double iconSize = 48.0,
    required bool isPlaying,
  }) {
    // 频谱模式：style 0/1 显示环绕频谱，style 2 用原封面（频谱在背景层）
    if (_isDiscCover) {
      return SpectrumArtwork(
        artworkUri: currentSong.artworkUri,
        fallbackFilePath: currentSong.localPath,
        isPlaying: isPlaying,
        bandCount: SpectrumService.instance.bandCount,
        style: _spectrumStyle,
        // 柱状图/曲线透明度分开记忆
        opacity: _spectrumStyle == 1
            ? _spectrumCurveOpacity
            : _spectrumBarOpacity,
      );
    }
    return PlayerCoverShadow.wrap(
      shadowColor: colorScheme.shadow,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(kCoverMorphFullRadius),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 静态封面（原有淡入淡出逻辑保持不变）
            _buildCrossfadeArtwork(
              currentSong.artworkUri,
              colorScheme,
              iconSize: iconSize,
              fallbackFilePath: currentSong.localPath,
            ),
            // 动态封面层：视频就绪后淡入覆盖；无动态封面 / 开关关闭 /
            // 网络不满足 / 加载失败时该层为空，静态封面完全不受影响。
            // 频谱模式（style 0/1）在上方已提前 return SpectrumArtwork，不会走到这里。
            if (currentSong is Song && currentSong.isOnline)
              DynamicCoverView(
                song: currentSong,
                enabled: _dynamicCoverEnabled,
              ),
          ],
        ),
      ),
    );
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
                          child: PlayerCoverSlot(
                            songId: currentSong.id,
                            artworkUri: currentSong.artworkUri,
                            fallbackFilePath: currentSong.localPath,
                            iconSize: iconSize,
                            placeholderColor:
                                colorScheme.surfaceContainerHighest,
                            shadowColor: colorScheme.shadow,
                            eligible: () => _coverMorphEligible,
                            // 暂停态的稳定态缩放 / 锚点：与下面 AnimatedScale
                            // 一致。此处 AnimatedScale 未指定 alignment，默认为
                            // Alignment.center，理由见左栏 A 处注释。
                            settledScale: _isDiscCover
                                ? 1.0
                                : (playerProvider.isPlaying ? 1.0 : 0.85),
                            settledAnchor: Alignment.center,
                            child: AnimatedScale(
                              // 频谱模式（style 0/1 圆形旋转封面）不需要封面的放大缩小动画
                              scale: _isDiscCover
                                  ? 1.0
                                  : (playerProvider.isPlaying ? 1.0 : 0.85),
                              duration: const Duration(milliseconds: 500),
                              curve: Curves.easeOutBack,
                              child: _buildCrossfadeArtworkWrapper(
                                currentSong,
                                colorScheme,
                                iconSize: iconSize,
                                isPlaying: playerProvider.isPlaying,
                              ),
                            ),
                          ),
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
                child: PlayerCoverSlot(
                  songId: currentSong.id,
                  artworkUri: currentSong.artworkUri,
                  fallbackFilePath: currentSong.localPath,
                  iconSize: iconSize,
                  placeholderColor: colorScheme.surfaceContainerHighest,
                  shadowColor: colorScheme.shadow,
                  eligible: () => _coverMorphEligible,
                  // 与上面 isExpanded 分支同理：默认锚点为 Alignment.center。
                  settledScale: _isDiscCover
                      ? 1.0
                      : (playerProvider.isPlaying ? 1.0 : 0.85),
                  settledAnchor: Alignment.center,
                  child: AnimatedScale(
                    // 频谱模式（style 0/1 圆形旋转封面）不需要封面的放大缩小动画
                    scale: _isDiscCover
                        ? 1.0
                        : (playerProvider.isPlaying ? 1.0 : 0.85),
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutBack,
                    child: _buildCrossfadeArtworkWrapper(
                      currentSong,
                      colorScheme,
                      iconSize: iconSize,
                      isPlaying: playerProvider.isPlaying,
                    ),
                  ),
                ),
              ),
            ),
          SizedBox(height: textSpacing),
          // 竖屏标题居中（封面居中显示，标题与封面保持同一中轴）
          _buildTitleBlockMorph(
            playerProvider,
            currentSong,
            colorScheme,
            alignment: CrossAxisAlignment.center,
          ),
          if (!isExpanded) const Spacer(),
        ],
      ),
    );
  }

  /// 播放页标题块的**文字清单**：内容 + 两套样式 + 水平对齐。
  ///
  /// 单独抽出来是为了让 [_buildTitleBlock] 与形变槽位 [PlayerTitleSlot] 用
  /// **同一份**内容与样式——两处各算一次迟早会漂移（改了大写规则或字重只改一边，
  /// 形变起飞/落地的文字就会与真实标题不一致）。
  ({
    String title,
    String subtitle,
    TextStyle? titleStyle,
    TextStyle? subtitleStyle,
    Alignment align,
  })
  _titleSpec(
    dynamic currentSong,
    ColorScheme colorScheme, {
    bool dense = false,
    CrossAxisAlignment alignment = CrossAxisAlignment.stretch,
  }) {
    final textTheme = Theme.of(context).textTheme;
    final subtitle = currentSong.album.toString().isEmpty
        ? currentSong.artist.toString()
        : '${currentSong.artist} · ${currentSong.album.toString().toUpperCase()}';
    return (
      title: currentSong.displayName.toUpperCase(),
      subtitle: subtitle,
      // MD3E v2: 大写 + 粗体 w700 + 字间距 1.5
      titleStyle: (dense ? textTheme.titleMedium : textTheme.headlineSmall)
          ?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: dense ? 1.0 : 1.5,
            height: 1.2,
          ),
      subtitleStyle: (dense ? textTheme.bodySmall : textTheme.bodyMedium)
          ?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
      align: alignment == CrossAxisAlignment.center
          ? Alignment.center
          : Alignment.centerLeft,
    );
  }

  /// 包了标题形变槽位的标题块。
  ///
  /// 形变期间真实标题让位（[PlayerTitleSlot] 内置的 Opacity 门控），显示权交给
  /// `PlayerCoverMorphLayer` 里那块飞行的文字，交接点上两者逐像素对齐。
  /// 槽位只上报矩形与文字，不改布局——`child` 就是原来的 [_buildTitleBlock]，
  /// 外层 `SizedBox(width: ...)` / `Column` 的约束与改动前完全一致。
  Widget _buildTitleBlockMorph(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme, {
    CrossAxisAlignment alignment = CrossAxisAlignment.stretch,
    bool dense = false,
  }) {
    final spec = _titleSpec(
      currentSong,
      colorScheme,
      dense: dense,
      alignment: alignment,
    );
    return PlayerTitleSlot(
      title: spec.title,
      subtitle: spec.subtitle,
      titleStyle: spec.titleStyle,
      subtitleStyle: spec.subtitleStyle,
      align: spec.align,
      // 文字侧只认结构条件：频谱圆盘开着时歌名照飞（封面才不飞）
      eligible: () => _morphTextEligible,
      child: _buildTitleBlock(
        playerProvider,
        currentSong,
        colorScheme,
        alignment: alignment,
        dense: dense,
      ),
    );
  }

  /// 标题区 —— 两行元数据（标题 + 艺人·专辑）。
  ///
  /// 原先「标题 / 艺人 / 专辑」三行同层级堆叠；艺人与专辑同为元数据，合并成一行。
  /// 倍速状态与调节入口都在更多菜单里，这里不再重复显示。
  /// [dense] 用于横屏左栏（宽度只有约 40%），标题降一号字避免频繁换行。
  /// [alignment] 为 [CrossAxisAlignment.center] 时文字同时居中对齐
  /// （竖屏 Zen 模式），其余形态一律左对齐。
  Widget _buildTitleBlock(
    PlayerProvider playerProvider,
    dynamic currentSong,
    ColorScheme colorScheme, {
    CrossAxisAlignment alignment = CrossAxisAlignment.stretch,
    bool dense = false,
  }) {
    // 内容与样式统一从 _titleSpec 取：形变槽位用的是同一份，两处不会漂移。
    final spec = _titleSpec(
      currentSong,
      colorScheme,
      dense: dense,
      alignment: alignment,
    );
    final textAlign = spec.align == Alignment.center
        ? TextAlign.center
        : TextAlign.left;
    return Column(
      crossAxisAlignment: alignment,
      children: [
        InkWell(
          onTap: () => _navigateToAlbum(currentSong as Song),
          borderRadius: BorderRadius.circular(4),
          // 过长歌名不换行，改优雅滚动（两端停顿 + 缓动往返 + 边缘渐隐）。
          child: GentleScrollingText(
            spec.title,
            style: spec.titleStyle,
            textAlign: textAlign,
          ),
        ),
        const SizedBox(height: 2),
        InkWell(
          onTap: () => _navigateToAlbum(currentSong as Song),
          borderRadius: BorderRadius.circular(4),
          child: GentleScrollingText(
            spec.subtitle,
            style: spec.subtitleStyle,
            textAlign: textAlign,
          ),
        ),
      ],
    );
  }

  /// 底部控制区 —— 三层等权重的旧结构（进度行 / 传输行 / 操作胶囊）压成两层：
  /// 进度（信息）+ 传输（动作），导航独立成一条极简指示条。
  /// 收藏与投屏收在传输行居中留下的左右空白里，纵向零成本。
  /// 仅竖屏（compact）与车机面板使用；宽屏布局改用
  /// [_buildLandscapeControlPage] + [_buildTabNavBar]。
  Widget _buildControls(
    PlayerProvider playerProvider,
    ColorScheme colorScheme, {
    bool isExpanded = false,
  }) {
    final duration = playerProvider.duration ?? Duration.zero;
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
          const PlaybackStatusFeedback(),
          // 与上方 tab 内容拉开距离：进度条拖动时时间标签会向上浮出 16px
          SizedBox(height: isExpanded ? 4 : 8),
          // P0: 进度条监听 positionNotifier（高频 200ms）+ provider（duration 等低频），
          // 不再因 positionStream 触发 _buildControls 整体重建
          ListenableBuilder(
            listenable: Listenable.merge([
              playerProvider.positionNotifier,
              playerProvider,
              // 进度条波浪回退开关：切换即重建进度条，不需要 setState
              kSeekBarWaveEnabled,
            ]),
            builder: (context, _) => _buildProgressBar(
              playerProvider,
              playerProvider.position,
              duration,
              colorScheme,
            ),
          ),
          // 进度条与播放控件之间留白：竖屏拉到 28，让「时间数字那一行」与按钮
          // 不粘在一起（拖动时时间标签上移 16px，低于这个留白就会压到按钮上）。
          SizedBox(height: baseGap),
          _buildMainControls(
            playerProvider,
            colorScheme,
            isExpanded: isExpanded,
          ),
          // 页签条：默认（「顶栏页签圆点」关闭）留在这里，且是**原 icon + 指示线**
          // 形态 —— 底部是一条独立带，图标比圆点认得出页。开启后它升到顶栏中央并
          // 换成圆点，底部让出来的 ~44dp 全部还给内容区。
          ...playerBottomTabSlot(
            isExpanded: isExpanded,
            strip: () => _buildTabStrip(
              colorScheme,
              variant: PlayerTabStripVariant.icons,
            ),
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
      skin: DockSkin.md3,
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

  /// 传输簇：常驻档把它放在左栏进度尺正下方；独立控制页由 dock 自己排（放大档）。
  Widget _buildTransportCluster(
    PlayerProvider playerProvider,
    ColorScheme colorScheme,
  ) => _buildMainControls(
    playerProvider,
    colorScheme,
    isExpanded: true,
  );

  /// 宽屏右栏底部 chrome：页签条，外加**装不进左栏时**的进度尺带。
  ///
  /// 常驻档的尺与播放键都在左栏曲名下方（`showBand` 为假，这里只剩页签条）；只有
  /// 栏高不够（640×300 这类小横屏，见 [PlayerWidePane.bandFits]）时尺才留在这条
  /// chrome 里。detached 档的控制带在「控制」页里，此处同样不挂。
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
            if (showBand)
              _buildControlDock(
                tier,
                playerProvider,
                colorScheme,
                leftPane: false,
              )
            else if (!_detachedControls)
              // 尺搬去左栏了，加载/失败提示条留在右栏这一侧：它撑得起来（错误文案
              // 两行 ≈ 50dp），而左栏 chrome 是不定高的非 flex 子项，塞进去就是溢出。
              const PlaybackStatusFeedback(),
            // 宽屏右栏底部的形态与竖屏底部同源（关 = icon + 指示线，开 = 圆点），
            // 见 playerWideTabStripVariant；位置不变，横屏恒在右栏底部。
            // 订阅开关让设置页改完回到播放页即时换形态，不必重进路由。
            ListenableBuilder(
              listenable: kTopBarTabDotsEnabled,
              builder: (context, _) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _buildTabStrip(
                  Theme.of(context).colorScheme,
                  variant: playerWideTabStripVariant(),
                ),
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
  /// [_lockSliderRowSwipe]）：罩住整页会让「在控制页左右滑动切页」彻底失效，
  /// 用户只能靠底部导航条离开这一页。
  Widget _buildLandscapeControlPage(
    PlayerProvider playerProvider,
    ColorScheme colorScheme,
  ) {
    return PlayerControlDock(
      tier: PlayerDockTier.detached,
      skin: DockSkin.md3,
      playerProvider: playerProvider,
      colorScheme: colorScheme,
      // 独立控制页不再挂音质徽章：它与其它形态同规则，统一在顶栏（见 _buildTopBar）。
      // 独立控制页有整页高度：中间三控件用不加窄的全尺寸档
      // （侧键 56 / 播放键 76 / 间距 12，同时把常驻档 44 的侧键命中框抬到 48 以上）
      transport: _buildMainControls(
        playerProvider,
        colorScheme,
        isExpanded: false,
      ),
      swipeLock: _lockSliderRowSwipe,
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

  /// 进度条 —— 常态一条细直线轨道（播放中才上色），按下时膨胀并浮出时间数字
  /// （详见 [PlayerSeekBar]）。
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
      // MD3 皮肤：3px 轨道 + 末端 stop indicator
      md3Style: true,
      // 设置项「进度条波浪起伏」：关闭即回退到直线形态（不订阅共享节拍）
      waveEnabled: kSeekBarWaveEnabled.value,
      speed: playerProvider.speed,
      activeColor: colorScheme.primary,
      inactiveColor: colorScheme.onSurfaceVariant.withValues(alpha: 0.24),
      labelColor: colorScheme.onSurfaceVariant,
      climaxStart: song?.climaxStart?.toDouble(),
      climaxEnd: song?.climaxEnd?.toDouble(),
      // 只有车机窄面板把徽章留在时间数字这一行；其余形态统一在顶栏（见 _buildTopBar），
      // 这里再挂一枚就是同一个信息出现两次。
      labelRowBadge: widget.dockMode
          ? _buildQualityPill(playerProvider, faded: true)
          : null,
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
  }) {
    final song = playerProvider.currentSong;
    // 根据歌曲来源（本地/在线）选择对应的收藏 Provider
    final isOnline = song is Song && song.isOnline;
    final isFavorited =
        song != null &&
        (isOnline
            ? context.watch<FavoritesProvider>().isFavorite(song.id)
            : context.watch<LocalFavoritesProvider>().isFavorite(song.id));

    return Row(
      children: [
        // 左端：播放模式（不循环 → 列表循环 → 单曲循环 → 随机，单键循环切换）
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: _buildEdgeAction(
              icon: _playModeIcon(
                playerProvider.shuffleEnabled,
                playerProvider.loopMode,
              ),
              color: _isDefaultPlayMode(playerProvider)
                  ? colorScheme.onSurfaceVariant
                  : colorScheme.primary,
              onTap: () {
                AppHaptics.tick(HapticCategory.transport);
                playerProvider.cyclePlayMode();
              },
            ),
          ),
        ),
        // Phase 5: 上一曲/暂停/下一曲联合动画控件
        MD3ETransportRow(
          isPlaying: playerProvider.isPlaying,
          sideButtonSize: isExpanded ? 44.0 : 56.0,
          playButtonSize: isExpanded ? 60.0 : 76.0,
          spacing: isExpanded ? 8.0 : 12.0,
          onPrevious: () {
            AppHaptics.click(HapticCategory.transport);
            playerProvider.previous();
          },
          onPlayPause: () {
            AppHaptics.click(HapticCategory.transport);
            if (playerProvider.isPlaying) {
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
              icon: isFavorited ? Icons.favorite : Icons.favorite_border,
              color: isFavorited
                  ? colorScheme.error
                  : colorScheme.onSurfaceVariant,
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
    );
  }

  /// 传输行两端的次要动作：48dp 圆形触达区，无容器背景。
  /// 不挂 Tooltip：长按只执行长按动作（如收藏长按开 AI 推荐），不弹按钮说明。
  Widget _buildEdgeAction({
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      customBorder: const CircleBorder(),
      child: SizedBox(
        width: 48,
        height: 48,
        child: Center(child: Icon(icon, size: 24, color: color)),
      ),
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

  /// 默认模式（不循环、不随机）时按钮不着色，避免常态就有一处高亮。
  bool _isDefaultPlayMode(PlayerProvider playerProvider) =>
      !playerProvider.shuffleEnabled &&
      playerProvider.loopMode == AppLoopMode.off;

  /// 底部导航条 —— 只做页面切换这一件事（原先与倍速/收藏混装在一条胶囊里）。
  ///
  /// 段序与各项语义见 [buildPlayerTabItems]（MD/AM 共用一份，本函数只供配色与回调）。
  /// 封面/评论 tab 是否存在由 [_tabLayout] 决定：**不能用 `length == 4` 反推**，
  /// 隐藏评论 tab 后竖屏长度同样会变成 3，反推会连带误删封面 tab。
  /// items 随之裁剪，指示线分段宽度由 [PlayerTabStrip] 按实际段数计算。
  Widget _buildTabStrip(
    ColorScheme colorScheme, {
    required PlayerTabStripVariant variant,
  }) {
    // tv: 遥控构建下换成遥控专属 TabBar（P-E）：PlayerTabStrip 是拖拽驱动的
    // 触屏控件，D-pad 无法聚焦其分段；Material TabBar 的段是 InkWell，
    // 聚焦后 OK 键经 TabController.animateTo 切页（PlayerTabPager 监听
    // controller 跟随）。三处布局（竖屏/横屏/展开）共用本方法，一处分支全覆盖。
    // 圆点 / icon 两种形态在 TV 下不存在，故 variant 参数在这条分支上不被读取。
    if (kTvBuild) return _buildRemoteTabBar(colorScheme);
    final song = context.read<PlayerProvider>().currentSong;
    final isOnline = song is Song && song.isOnline;
    return PlayerTabStrip(
      controller: _tabController,
      activeColor: colorScheme.primary,
      // 0.7 而不是 0.55：页签条压在动态取色的封面/渐变背景上，0.55 的
      // onSurfaceVariant 在中等明度背景上对比度不足，圆点会「糊」进背景，
      // 选中态只剩大小差别可读（非文本图形需 3:1）。
      inactiveColor: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
      variant: variant,
      onSegmentWidth: (w) => _tabDragBtnW = w,
      onDragStart: _onTabDragStart,
      onDragUpdate: _onTabDragUpdate,
      onDragEnd: _onTabDragEnd,
      items: buildPlayerTabItems(
        hasCover: _tabLayout.hasCover,
        hasControls: _tabLayout.hasControls,
        hasComments: _tabLayout.hasComments,
        desktopLyricEnabled: DesktopLyricService.instance.enabled,
        // 长按封面段：弹出下载音质选择（本地歌曲与钩子缺失时不给回调）
        coverOnLongPress:
            song != null && isOnline && FullPlayer.coverLongPressCallback != null
            ? () {
                AppHaptics.lightImpact(HapticCategory.navigation);
                FullPlayer.coverLongPressCallback!(context, song);
              }
            : null,
        lyricsOnLongPress: _toggleDesktopLyric,
        commentsOnLongPress: () => _openComposeSheet(),
      ),
    );
  }

  /// tv: 遥控专属 TabBar（P-E，移植自 TV 参考实现 `_buildRemoteTabBar`，
  /// 并按本仓 tab 结构适配）——本仓 tab 0 是播放列表，封面/评论 tab 由
  /// [_tabLayout] 条件增删，顺序与 `PlayerTabPager.children` 严格对应。
  /// 段本身是 InkWell：D-pad 聚焦后 OK 键激活（原生 Actions 链路），无需再包
  /// DpadFocusable。配色与 PlayerTabStrip 同源（primary / onSurfaceVariant）。
  /// Zen 模式下随 `_buildControls` 一并淡出。
  Widget _buildRemoteTabBar(ColorScheme colorScheme) {
    return TabBar(
      controller: _tabController,
      dividerColor: Colors.transparent,
      labelColor: colorScheme.primary,
      unselectedLabelColor: colorScheme.onSurfaceVariant,
      tabs: [
        const Tab(text: '列表'),
        if (_tabLayout.hasCover) const Tab(text: '封面'),
        const Tab(text: '歌词'),
        if (_tabLayout.hasComments) const Tab(text: '评论'),
      ],
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
      // 只有「顶层模式 + 在线歌曲」才提供评论/弹幕档位切换（弹幕没有楼层回复
      // 语义，本地歌曲在酷狗也没有弹幕池）。
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
    final song = player.currentSong;
    // 收藏状态需实时查询，避免暂停时显示为未收藏
    bool isFavorited = false;
    if (song != null) {
      try {
        isFavorited = context.read<FavoritesProvider>().isFavorite(song.id);
      } catch (_) {}
    }
    await MediaNotificationService.updateNotification(
      // 用 displayName 剥离 .mp3 等后缀，避免标题显示文件名
      title: song?.displayName ?? '',
      artist: song?.artist ?? '',
      artUrl: song?.artworkUri,
      isPlaying: player.isPlaying,
      position: player.position,
      duration: player.duration ?? Duration.zero,
      desktopLyricEnabled: DesktopLyricService.instance.enabled,
      isFavorited: isFavorited,
    );
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

  /// 程序化切页（封面页点击、歌词页点击等）。
  void _goToTab(int index) => _pagerKey.currentState?.goToPage(index);

  // MD3E v2: 音量调节改为右上角长按音质徽章呼出。
  // 独占开启时控制 USB 独立音量（与设置页同步），否则控制应用音量；带模式标识。
  // 三态判据与常驻音量条同源（PlayerVolumeState），弹窗与横屏控制页不再分叉。
  void _showVolumeDialog(PlayerProvider playerProvider) {
    final state = PlayerVolumeState.of(playerProvider);
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              // Direct PCM 的 unity 音量档：AudioTrack 的 track volume 被固定为
              // 1.0，应用内滑块拖动不会有任何变化（PlayerProvider.setVolume 会
              // 拦下并改记 1.0）。与其让用户对着失灵的滑块困惑，不如明确告知
              // 「用系统音量键」并给一个一键关闭该档的出口（共享组件完整版）。
              child: state.interactive
                  ? StatefulBuilder(
                      builder: (context, setState) {
                        // 每次重建重读三态：onChanged 的 apply 已把新值写进
                        // provider/USB，这里与旧实现一致逐次取最新值
                        //（方法开头的 state 只是打开弹窗瞬间的快照）。
                        final current = PlayerVolumeState.of(playerProvider);
                        final volume = current.value;
                        final percent = (volume * 100).round();
                        final icon = volume <= 0
                            ? Icons.volume_off
                            : volume < 0.5
                            ? Icons.volume_down
                            : Icons.volume_up;
                        final colorScheme = Theme.of(context).colorScheme;
                        final usbExclusive =
                            current.source == PlayerVolumeSource.usbExclusive;
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
                                color: (usbExclusive
                                        ? Colors.green
                                        : colorScheme.primary)
                                    .withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                current.chipLabel,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: usbExclusive
                                      ? Colors.green
                                      : colorScheme.primary,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Icon(icon, size: 32, color: colorScheme.primary),
                            const SizedBox(height: 8),
                            // tv: TV 构建换 RemoteSlider——M3ESlider 自带 Focus 吞四方向键；
                            // TV 分支丢 M3ESliderDecoration（触觉/装饰参数无法透传），只保功能性
                            // 参数（P-C）。三态下发仍走 PlayerVolumeState.apply，与触屏同一份判据。
                            kTvBuild
                                ? RemoteSlider(
                                    value: volume,
                                    onChanged: (value) {
                                      current.apply(playerProvider, value, persist: false);
                                      setState(() {});
                                    },
                                    // 松手才落盘（拖动中只实时下发，与触屏同口径）
                                    onChangeEnd: (value) =>
                                        current.apply(playerProvider, value, persist: true),
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
                                      // 拖动中轻量下发：不写盘（persist 透传，
                                      // 与常驻音量条同一口径，见 PlayerVolumeState）
                                      current.apply(
                                        playerProvider,
                                        value,
                                        persist: false,
                                      );
                                      setState(() {});
                                    },
                                    // 松手才落盘（拖动中只实时下发，persist:false）
                                    onChangeEnd: (value) {
                                      current.apply(
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
                              current.hintLabel,
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
                    )
                  : PlayerVolumeUnityNotice(
                      onDisabled: () {
                        if (context.mounted) Navigator.of(context).pop();
                      },
                    ),
            ),
          ),
        );
      },
    );
  }

  /// 逐字歌词时间偏移（仅在线音乐生效）：渲染位置 = 播放位置 - 偏移。
  /// 每帧读取 [SettingsRepository.lyricTimeOffsetMs] 内存缓存，设置页修改即时生效。
  Duration _adjustedLyricPosition(Duration position, Song? song) {
    final offset = (song != null && song.isOnline)
        ? SettingsRepository.lyricTimeOffsetMs.value
        : 0;
    final rawMs = position.inMilliseconds;
    return Duration(milliseconds: rawMs > offset ? rawMs - offset : 0);
  }

  // 下载功能未移植（公开库不包含下载）：原封面长按入口已移除。

  void _showMoreMenu(BuildContext rootContext) {
    final song = context.read<PlayerProvider>().currentSong;
    if (song == null) return;

    // 动态标题：显示专辑名/歌手名（截断处理）
    final albumTitle = song.album.isEmpty ? '查看专辑' : '查看专辑：${song.album}';
    final artistTitle = song.artist.isEmpty ? '查看歌手' : '查看歌手：${song.artist}';

    showM3EModalBottomSheet(
      context: rootContext,
      isScrollControlled: true,
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
                // 查看 MV：仅在线歌曲显示（原顶栏按钮收纳到菜单，置顶）
                if (song.isOnline == true)
                  ListTile(
                    leading: const Icon(Icons.music_video_outlined),
                    title: const Text('查看 MV'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _pageNavigator(rootContext)?.push(
                        MaterialPageRoute(
                          builder: (_) => MvPlayerPage(song: song),
                        ),
                      );
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.album),
                  title: Text(
                    albumTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _navigateToAlbum(song);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.person),
                  title: Text(
                    artistTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _navigateToArtist(song);
                  },
                ),
                // 本地歌曲：匹配在线歌曲，补充封面兜底/歌词精确检索/评论区
                if (!song.isOnline && song.localPath != null)
                  ListTile(
                    leading: const Icon(Icons.manage_search),
                    title: const Text('匹配在线信息'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      showSongMatchSheet(rootContext, song);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.playlist_add),
                  title: const Text('添加到歌单'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    showAddToPlaylistDialog(rootContext, song);
                  },
                ),
                // 歌曲信息：频率/位深/码率/声道 + USB 独占开关（原顶栏按钮收纳到菜单）
                // 已移除：页内 USB 独占整块已删（桌面端不可用），剩余的格式信息
                // 与播放页已有的封面/码率展示重复，故整个入口一并去掉。
                //
                // ListTile(
                //   leading: const Icon(Icons.info_outline),
                //   title: const Text('歌曲信息'),
                //   onTap: () {
                //     Navigator.pop(sheetContext);
                //     _pageNavigator(rootContext)?.push(
                //       MaterialPageRoute(builder: (_) => const SongInfoPage()),
                //     );
                //   },
                // ),
                // 播放速度：低频动作，不占底部常驻位置
                ListTile(
                  leading: const Icon(Icons.speed),
                  title: const Text('播放速度'),
                  trailing: Text(
                    '${formatPlaybackSpeed(context.read<PlayerProvider>().speed)}x',
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    final player = context.read<PlayerProvider>();
                    showSpeedPickerDialog(
                      context: rootContext,
                      currentSpeed: player.speed,
                      onSelected: player.setSpeed,
                    );
                  },
                ),
                // 音量：常驻控制带已经不放音量，调节入口收进这里。形态与独立
                // 控制页同款 —— 左端小喇叭键切静音、右端大喇叭只标量程、不写百分数。
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: PlayerVolumeBar(amStyle: false),
                ),
                // 均衡器 / 定时关闭 / 投屏：同一行三格宫格，上方 icon 下方文字
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
                  child: Row(
                    children: [
                      // 均衡器 / 音效：依赖 EqualizerService 的 Android
                      // AudioSession 绑定，桌面端 tryBind() 直接 return false，
                      // 开关能开能存盘但没有任何音效被挂载（假成功），
                      // 故桌面端整格隐藏。见 platform_capabilities。
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
                                    builder: (_) => const EqualizerSettingsPage(),
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

  /// 界面设置：二级菜单弹层（歌词显示设置 / 评论设置 / 音乐频谱）。
  void _showMoreSettingsSheet(BuildContext rootContext) {
    showM3EModalBottomSheet(
      context: rootContext,
      isScrollControlled: true,
      // 与一级「更多」菜单保持一致：二级菜单同样用实色背景。
      backgroundColor: Theme.of(rootContext).colorScheme.surfaceContainerLow,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
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
                  // 歌手写真背景（原一级菜单开关收纳到二级菜单）
                  Consumer<ThemeProvider>(
                    builder: (context, theme, _) => SwitchListTile(
                      title: const Text('歌手写真背景'),
                      value: theme.useArtistPhotoBackground,
                      onChanged: theme.setUseArtistPhotoBackground,
                    ),
                  ),
                  // 歌曲弹幕：与设置页「屏幕与视频」是同一个开关。
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
                  // 音乐频谱环绕：仅 Android 显示
                  if (Platform.isAndroid)
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
  /// 楼中楼字号 = 楼主 - 1（自动计算，不暴露独立设置）。
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
              // 文字颜色与其它二级菜单（如歌词显示设置）保持一致：
              // 全部使用主题标准色（onSurface / onSurfaceVariant / primary），
              // 由主题自动适配深色/浅色模式，不做手写黑白。
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
                    // 楼主字号滑块
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
                    // 楼中楼预览
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
                          // 楼主
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
                          // 楼中楼
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

  Widget _wrapMd3LyricsWithAuxToggle(Widget child) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          right: 8,
          bottom: 4,
          child: ListenableBuilder(
            listenable: Md3LyricPreferences.instance,
            builder: (context, _) {
              if (_zenMode || (!_hasTranslation && !_hasRoma)) {
                return const SizedBox.shrink();
              }
              final prefs = Md3LyricPreferences.instance;
              final mode = _effectiveMd3DisplayMode(prefs);
              final on = prefs.showAuxiliary;
              return InkWell(
                onTap: () => prefs.setShowAuxiliary(!on),
                onLongPress: _switchMd3LyricSubLineMode,
                customBorder: const CircleBorder(),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: Icon(
                      mode == Md3LyricDisplayMode.roma
                          ? Icons.abc
                          : Icons.translate,
                      size: 20,
                      color: on
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.45),
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

  Md3LyricDisplayMode _effectiveMd3DisplayMode(Md3LyricPreferences prefs) {
    final preferred = prefs.displayMode;
    if (preferred == Md3LyricDisplayMode.translation && _hasTranslation) {
      return preferred;
    }
    if (preferred == Md3LyricDisplayMode.roma && _hasRoma) {
      return preferred;
    }
    return _hasTranslation
        ? Md3LyricDisplayMode.translation
        : Md3LyricDisplayMode.roma;
  }

  void _switchMd3LyricSubLineMode() {
    AppHaptics.lightImpact(HapticCategory.control);
    final prefs = Md3LyricPreferences.instance;
    final current = _effectiveMd3DisplayMode(prefs);
    final next = current == Md3LyricDisplayMode.translation
        ? Md3LyricDisplayMode.roma
        : Md3LyricDisplayMode.translation;
    if (next == Md3LyricDisplayMode.roma && !_hasRoma) {
      showToast('当前歌曲暂无罗马音');
      return;
    }
    if (next == Md3LyricDisplayMode.translation && !_hasTranslation) {
      showToast('当前歌曲暂无翻译');
      return;
    }
    if (!prefs.showAuxiliary) {
      prefs.setShowAuxiliary(true);
    }
    prefs.setDisplayMode(next);
    showToast(next == Md3LyricDisplayMode.roma ? '已切换到罗马音' : '已切换到翻译');
  }

  /// 弹出 MD3 风格播放页的歌词显示设置面板（字号/行间距/字体）。
  /// 与 Apple Music 风格的 `LyricPreferences` 完全独立。
  void _showLyricPreferencesSheet(BuildContext context) {
    showM3EModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
      builder: (context) => SafeArea(child: const Md3LyricPreferencesPanel()),
    );
  }
}
