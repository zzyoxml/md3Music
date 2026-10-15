import 'dart:async';
import 'dart:ui';

import 'package:dpad/dpad.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:quick_actions/quick_actions.dart';

import 'core/build_flags.dart';
import 'core/layout/adaptive_navigator.dart';
import 'core/layout/desktop_shell.dart';
import 'core/layout/ime_collapse.dart';
import 'core/layout/page_layout.dart';
import 'core/layout/page_title_alignment.dart';
import 'core/layout/responsive_layout.dart';
import 'core/layout/responsive_shell.dart';
import 'core/layout/ui_density.dart';
import 'core/remote/tv_exit_confirm_dialog.dart';
import 'core/remote/tv_focus_highlight.dart';
import 'core/services/external_media_intent_service.dart';
import 'core/services/fm_widget_sync.dart';
import 'core/services/lyricon_provider_service.dart';
import 'core/services/music_haptics_service.dart';
import 'core/services/startup_auto_play.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/motion_constants.dart';
import 'core/utils/artwork_color_extractor.dart';
import 'core/utils/app_toast.dart';
import 'core/widgets/app_background.dart';
import 'core/widgets/safe_insets_guard.dart';
import 'data/models/playlist.dart';
import 'data/models/song.dart';
import 'data/repositories/settings_repository.dart';
import 'services/kugou_api/kugou_api_client.dart';
import 'services/kugou_api/listen_together_models.dart';
import 'main.dart'
    show
        appNavigatorKey,
        handleShortcut,
        pendingShortcutType,
        shortcutTabRequest;
import 'modules/discover/discover_page.dart';
import 'modules/mcp/mcp_app_features.dart';
import 'modules/mcp/mcp_confirm_dialog.dart';
import 'modules/mcp/mcp_local_library.dart';
import 'modules/mcp/mcp_player_control.dart';
import 'modules/mcp/mcp_service.dart';
import 'modules/coverflow/coverflow_page.dart';
import 'modules/coverflow/coverflow_source.dart';
import 'utils/landscape_immersive.dart';
import 'widgets/player_top_bar_actions.dart';
import 'widgets/player_top_bar_tab_dots.dart';
import 'modules/charts/charts_page.dart';
import 'modules/ip/ip_page.dart';
import 'modules/user/user_center_page.dart';
import 'modules/user/favorites_page.dart';
import 'modules/brush/brush_page.dart';
import 'modules/listen_together/listen_together_page.dart';
import 'modules/listen_together/widgets/guest_play_confirm_dialog.dart';

import 'modules/player/full_player.dart';
import 'modules/player/full_player_route.dart';
import 'modules/player/mini_player.dart';
import 'modules/player/bottom_bar_morph_overlay.dart';
import 'modules/player/player_drag_overlay.dart';
import 'widgets/playlist_cover_hero.dart';
import 'widgets/player_seek_bar.dart';
import 'modules/player/player_cover_morph_layer.dart';
import 'widgets/play_next_flight.dart';
import 'modules/player/player_cover_shadow.dart';
import 'modules/player/car_mode_panel.dart';
import 'modules/player/secondary_mini_player.dart';
import 'modules/playlist/playlist_page.dart';
import 'modules/search/search_page.dart';
import 'modules/settings/settings_page.dart';
import 'modules/library/library_page.dart';
import 'modules/launchpad/launchpad_page.dart';
import 'modules/login/login_page.dart';
import 'widgets/app_animation.dart';
import 'modules/onboarding/onboarding_page.dart';
import 'modules/onboarding/user_agreement_page.dart';
import 'modules/personal_fm/personal_fm_page.dart';
import 'modules/audiobook/audiobook_page.dart';
import 'modules/recognition/song_recognition_page.dart';
import 'modules/scene/scene_page.dart';
import 'modules/channel/channel_page.dart';
import 'providers/dlna_provider.dart';
import 'providers/favorites_provider.dart';
import 'providers/blacklist_provider.dart';
import 'providers/cloud_upload_provider.dart';
import 'providers/kugou_provider.dart';
import 'providers/listen_stats_provider.dart';
import 'providers/library_provider.dart';
// ignore: unused_import  // 类型用于 ChangeNotifierProvider(create: ...) 的 T 推断
import 'providers/local_favorites_provider.dart';
import 'providers/player_provider.dart';
import 'providers/remote_control_provider.dart';
import 'providers/remote_storage_provider.dart';
import 'providers/playlist_collection_notifier.dart';
import 'providers/device_provider.dart';
import 'providers/grid_columns_provider.dart';
import 'providers/shortcut_config_provider.dart';
import 'providers/tab_config_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/comment_display_provider.dart';
import 'providers/song_match_provider.dart';
import 'providers/car_mode_provider.dart';
import 'providers/listen_together_provider.dart';
import 'services/kugou_server.dart';
import 'widgets/dlna_casting_overlay.dart';
import 'core/widgets/local_server_down_banner.dart';

/// 主页（`/`）专用的 [MaterialPageRoute] 子类。
///
/// 重写 [buildTransitions]：当 FullPlayer 在栈顶（[playerExpansion] > 0.5）
/// 且 [secondaryAnimation] 驱动时，让 _MainLayout 向上偏移 15% + 淡出
/// （Apple Music 经典效果）；其他路由 push 时走默认 transitions。
///
/// 通过全局 [playerExpansion] 限制只对 FullPlayer 生效，
/// 避免 /search /settings /playlist 等也触发 up-fade。
class _UpFadeMainRoute<T> extends MaterialPageRoute<T> {
  _UpFadeMainRoute({required super.builder});

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 入场动画走默认（_MainLayout 是 initialRoute，入场无动画）
    // 离场动画（被覆盖）：监听 playerExpansion，> 0.5 时 up-fade，否则默认
    return AnimatedBuilder(
      animation: Listenable.merge([secondaryAnimation, playerExpansion]),
      builder: (context, _) {
        if (playerExpansion.value <= 0.5) {
          return super.buildTransitions(
            context,
            animation,
            secondaryAnimation,
            child,
          );
        }
        // FullPlayer 在栈顶：_MainLayout 向上偏移 15% + 淡出
        final offset =
            Tween<Offset>(
              begin: Offset.zero,
              end: const Offset(0, -0.15),
            ).animate(
              CurvedAnimation(
                parent: secondaryAnimation,
                curve: Curves.easeOutCubic,
              ),
            );
        final fade = Tween<double>(begin: 1.0, end: 0.0).animate(
          CurvedAnimation(
            parent: secondaryAnimation,
            curve: Curves.easeOutCubic,
          ),
        );
        return FadeTransition(
          opacity: fade,
          child: SlideTransition(position: offset, child: child),
        );
      },
    );
  }
}

class MyApp extends StatelessWidget {
  final bool showOnboarding;
  final bool showUserAgreement;
  final bool initialUseBackgroundImage;

  /// 可选扩展：额外注册的 Provider 列表（默认无，由私有构建注入，
  /// 用于注册私有功能 Provider）。
  final List<SingleChildWidget>? extraProviders;

  const MyApp({
    super.key,
    this.showOnboarding = false,
    this.showUserAgreement = false,
    this.initialUseBackgroundImage = true,
    this.extraProviders,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => ThemeProvider(
            initialUseBackgroundImage: initialUseBackgroundImage,
          ),
        ),
        ChangeNotifierProvider(create: (_) => DeviceProvider()),
        // TV 构建：遥控器模式总开关。正常构建不编入（kTvBuild=false 时整段树摇剔除）。
        if (kTvBuild) ...[
          ChangeNotifierProvider(create: (_) => RemoteControlProvider()),
        ],
        ChangeNotifierProvider(create: (_) => GridColumnsProvider()),
        ChangeNotifierProvider(create: (_) {
          final player = PlayerProvider();
          // 播放状态 → 音乐节奏震动：「App 内/始终」两档在无播放页时也要拿到
          // 播放/暂停沿。notifyListeners 只在播放/暂停/切歌等低频时机触发
          // （高频位置更新走 positionNotifier），服务内部按值去重，零成本。
          player.addListener(() {
            MusicHapticsService.instance.setPlaybackActive(player.isPlaying);
          });
          return player;
        }),
        // 本地曲库：MCP 构造时要 read 它（本地工具的真实源），故声明在 MCP 之前。
        ChangeNotifierProvider(create: (_) => LibraryProvider()),
        // AI 代理接口（MCP）：默认关闭。非惰性创建——需要在每次冷启动时读取
        // 持久化设置决定是否恢复监听，否则用户开启后必须先进一次设置页才会起服务。
        // 默认关闭时构造只做一次 SharedPreferences 读取即返回，零网络副作用。
        ChangeNotifierProxyProvider<PlayerProvider, McpService>(
          lazy: false,
          create: (context) => McpService(
            playerControl: PlayerProviderBackedControl(
              context.read<PlayerProvider>(),
            ),
            localLibrary: LibraryProviderBackedLocalSource(
              context.read<LibraryProvider>(),
            ),
            appFeatures: PlayerProviderBackedAppFeatures(
              context.read<PlayerProvider>(),
            ),
          ),
          update: (context, player, previous) =>
              previous ??
              McpService(
                playerControl: PlayerProviderBackedControl(player),
                localLibrary: LibraryProviderBackedLocalSource(
                  context.read<LibraryProvider>(),
                ),
                appFeatures: PlayerProviderBackedAppFeatures(player),
              ),
        ),
        ChangeNotifierProvider(create: (_) => RemoteStorageProvider()),
        // 云盘上传队列：应用级常驻，页面退出不中断上传
        ChangeNotifierProvider(create: (_) => CloudUploadProvider()),
        ChangeNotifierProvider(create: (_) => KugouProvider()),
        // 内容黑名单（歌曲「不感兴趣」/ 歌手「屏蔽」）：登录态/账号变化时清空缓存，
        // 防止跨账号串状态；黑名单接口按 token/userid 作用域，缓存不能跨会话复用。
        ChangeNotifierProxyProvider<KugouProvider, BlacklistProvider>(
          create: (_) => BlacklistProvider(),
          update: (_, kugou, blacklist) {
            blacklist!.syncLoginState(
              loggedIn: kugou.isLoggedIn,
              userid: kugou.userid,
            );
            return blacklist;
          },
        ),
        // 云端听歌统计（排行 /user/listen + 最近历史 /user/history）：同样
        // 按 token/userid 作用域，登录态/账号变化时清空缓存防跨账号串状态。
        ChangeNotifierProxyProvider<KugouProvider, ListenStatsProvider>(
          create: (_) => ListenStatsProvider(),
          update: (_, kugou, stats) {
            stats!.syncLoginState(
              loggedIn: kugou.isLoggedIn,
              userid: kugou.userid,
            );
            return stats;
          },
        ),
        ChangeNotifierProvider(create: (_) => FavoritesProvider()),
        ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
        // 跨页面广播「收藏的歌单」变更（详情页 → 我的收藏 tab 立即刷新）
        ChangeNotifierProvider(create: (_) => PlaylistCollectionNotifier()),
        // 主页 Tab 配置（显示/隐藏、排序）
        ChangeNotifierProvider(create: (_) => TabConfigProvider()),
        // 桌面快捷方式配置（Android 长按图标入口的显示/隐藏、排序）
        ChangeNotifierProvider(create: (_) => ShortcutConfigProvider()),
        // DLNA 投屏
        ChangeNotifierProvider(create: (_) => DlnaProvider()),
        // 评论显示设置（字号等）
        ChangeNotifierProvider(create: (_) => CommentDisplayProvider()),
        // 本地歌曲 ↔ 在线歌曲匹配（自动匹配引擎 + 手动候选弹层的状态源）
        ChangeNotifierProvider(create: (_) => SongMatchProvider()),
        // 车机模式（常驻播放器面板的开关 / 宽度 / 停靠位置）
        ChangeNotifierProvider(create: (_) => CarModeProvider()),
        // 一起听（众乐房）：广场列表 + 房间会话（心跳/轮询/播放同步）
        ChangeNotifierProvider(create: (_) => ListenTogetherProvider()),
        // 可选扩展：私有构建注入的额外 Provider（默认无）
        ...?extraProviders,
      ],
      child: _AppView(
        showOnboarding: showOnboarding,
        showUserAgreement: showUserAgreement,
      ),
    );
  }
}

class _AppView extends StatefulWidget {
  final bool showOnboarding;
  final bool showUserAgreement;

  const _AppView({this.showOnboarding = false, this.showUserAgreement = false});

  @override
  State<_AppView> createState() => _AppViewState();
}

class _AppViewState extends State<_AppView> {
  // 封面动态取色桥接：监听 PlayerProvider 切歌 → 提取封面主色 → 注入 ThemeProvider。
  // 持有引用以便 dispose 时移除 listener（provider 销毁顺序晚于 _AppViewState）。
  PlayerProvider? _playerProvider;
  // 上一次已提取/正在提取的封面 url：同一首歌反复 notify 不重复提取，
  // 且异步提取期间切歌时丢弃过期结果（参考 AM 歌词动态取色 _lastAccentUrl 模式）。
  String? _lastCoverUrl;
  // 背景图莫奈取色桥接：监听 ThemeProvider 背景图路径变化 → 提取主色注入 seed 链。
  // 持有引用以便 dispose 时移除 listener。
  ThemeProvider? _backgroundThemeProvider;
  // 上一次已提取/正在提取的背景图路径：同一路径不重复提取。
  String? _lastBackgroundPath;
  // 桌面快捷方式配置：监听变更 → 重新注册 Android 长按图标快捷入口。
  ShortcutConfigProvider? _shortcutConfig;

  @override
  void initState() {
    super.initState();
    // 桌面快捷方式由 ShortcutConfigProvider 配置驱动（支持排序+开关），
    // 监听其变更并重新注册 Android 长按应用图标 Shortcut items。
    // 冷启动时 provider 可能尚未异步加载完成，先按默认配置应用一次，
    // 加载完成后 notifyListeners 会再次触发重应用。
    _shortcutConfig = context.read<ShortcutConfigProvider>();
    _shortcutConfig!.addListener(_applyDesktopShortcuts);
    _applyDesktopShortcuts();
    // 处理冷启动时缓存的 shortcut 类型：
    // QuickActions.initialize 在 runApp 之前注册，但此时 Navigator 尚未就绪，
    // 因此 main.dart 把 shortcut 类型暂存到 pendingShortcutType，
    // 这里在首帧渲染后消费。
    if (pendingShortcutType != null) {
      final type = pendingShortcutType;
      pendingShortcutType = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        handleShortcut(type!);
      });
    }
    // 延迟一帧再建立封面取色桥接：ChangeNotifierProvider 惰性 create，
    // 此时 provider 实例已就绪，且不影响首帧渲染。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupCoverColorBridge();
      _setupBackgroundColorBridge();
      _setupFmWidgetSync();
      // 外部调用（文件管理器「用其他应用打开」）：注册原生推送回调，
      // 并主动拉取一次冷启动期间原生侧积压的待处理音频
      // ignore: discarded_futures
      ExternalMediaIntentService.instance.start();
    });
    // 预测性返回 + 封面连贯过渡：两个开关互斥，冷启动一起载入并纠正历史同开的值
    // （裁决见 resolveCoverBackExclusivity，封面连贯过渡优先）。
    unawaited(_loadCoverAndBackSwitches());
    kPredictiveBackEnabled.addListener(_onPredictiveBackChanged);
  }

  /// 建立私人FM桌面小部件桥接：监听三个 provider 推送快照，并接上原生按钮回调。
  void _setupFmWidgetSync() {
    FmWidgetSync.instance.attach(
      kugou: context.read<KugouProvider>(),
      player: context.read<PlayerProvider>(),
      favorites: context.read<FavoritesProvider>(),
    );
  }

  /// 根据 ShortcutConfigProvider 当前配置，整体替换 Android 桌面快捷方式列表。
  /// type 统一为 `action_open_<tabId>`，由 main.dart handleShortcut 路由到对应页。
  void _applyDesktopShortcuts() {
    final config = context.read<ShortcutConfigProvider>();
    const quickActions = QuickActions();
    quickActions.setShortcutItems([
      for (final s in config.visibleShortcuts)
        ShortcutItem(
          type: 'action_open_${s.id}',
          localizedTitle: s.label,
          icon: s.iconResource,
        ),
    ]);
  }

  /// 建立封面动态取色桥接：监听 PlayerProvider 切歌，把封面主色注入 ThemeProvider。
  void _setupCoverColorBridge() {
    final player = context.read<PlayerProvider>();
    _playerProvider = player;
    player.addListener(_onPlayerChanged);
    // 启动时按当前歌曲提取一次（若 App 有恢复播放）
    _onPlayerChanged();
  }

  /// 切歌回调：当前歌曲封面 url 变化时异步提取主色并注入 ThemeProvider。
  Future<void> _onPlayerChanged() async {
    final url = context.read<PlayerProvider>().currentSong?.artworkUri;
    if (url == null || url == _lastCoverUrl) return;
    _lastCoverUrl = url;
    final color = await ArtworkColorExtractor.extract(url);
    // 过期校验：提取期间已切歌则丢弃结果（参考 AM 歌词动态取色模式）
    if (context.read<PlayerProvider>().currentSong?.artworkUri != url) return;
    context.read<ThemeProvider>().setCoverSeedColor(color);
  }

  /// 建立背景图莫奈取色桥接：监听 ThemeProvider 背景图路径变化 → 提取主色注入 seed 链。
  ///
  /// 启动时按已持久化的背景图提取一次；用户更换/清除背景图时由
  /// setBackgroundImagePath 触发 notify → 重新提取或清空。
  void _setupBackgroundColorBridge() {
    final themeProvider = context.read<ThemeProvider>();
    _backgroundThemeProvider = themeProvider;
    themeProvider.addListener(_onBackgroundChanged);
    _onBackgroundChanged();
  }

  /// 背景图路径变化回调：异步提取主色并注入 ThemeProvider。
  ///
  /// 与封面取色同模式：路径变化时丢弃过期结果；提取失败（返回 null）
  /// 时把 seed 置 null，让 effectiveSeedColor 回落到后续级别。
  Future<void> _onBackgroundChanged() async {
    final themeProvider = context.read<ThemeProvider>();
    final path = themeProvider.backgroundImagePath;
    if (path == null || path.isEmpty) {
      // 清除背景图：重置上次路径与取色结果，允许下次再选同一文件时重新提取
      _lastBackgroundPath = null;
      themeProvider.setBackgroundSeedColor(null);
      return;
    }
    if (path == _lastBackgroundPath) return;
    _lastBackgroundPath = path;
    final color = await ArtworkColorExtractor.extract('file://$path');
    // 过期校验：提取期间背景图已更换/清除则丢弃结果
    if (context.read<ThemeProvider>().backgroundImagePath != path) return;
    context.read<ThemeProvider>().setBackgroundSeedColor(color);
  }

  /// 冷启动一起载入两个互斥开关：预测性返回（写 [kPredictiveBackEnabled]，主题据此
  /// 切 pageTransitionsTheme）与封面连贯过渡（写 [kPlaylistCoverTransitionEnabled]，
  /// `PlaylistCoverHero` 读它决定是否起飞）。
  ///
  /// 两个都开是互斥上线前的存量状态：按 `resolveCoverBackExclusivity` 裁决（封面
  /// 连贯过渡优先），并把修正后的预测性返回**写回持久化**，这样进设置页看到的就是
  /// 互斥后的状态，不会出现「两个都开着但其中一个实际没生效」。
  Future<void> _loadCoverAndBackSwitches() async {
    final repo = SettingsRepository();
    final results = await Future.wait([
      repo.getPredictiveBackEnabled(),
      repo.getPlaylistCoverTransitionEnabled(),
    ]);
    final resolved = resolveCoverBackExclusivity(
      coverTransition: results[1],
      predictiveBack: results[0],
    );
    if (resolved.predictiveBack != results[0]) {
      await repo.setPredictiveBackEnabled(resolved.predictiveBack);
    }
    if (kPredictiveBackEnabled.value != resolved.predictiveBack) {
      kPredictiveBackEnabled.value = resolved.predictiveBack;
    }
    if (kPlaylistCoverTransitionEnabled.value != resolved.coverTransition) {
      kPlaylistCoverTransitionEnabled.value = resolved.coverTransition;
    }
  }

  /// 预测性返回开关变化 → 重建 MaterialApp（换 pageTransitionsTheme）。
  void _onPredictiveBackChanged() {
    if (mounted) setState(() {});
  }

  /// TV 返回键收口：能 pop 则 pop（返回 true 表示已消费）；
  /// 根路由返回 false 交回系统默认 —— 由 [_MainLayout] 根 [PopScope]
  /// 走既有退出流程（回首页 → 双击返回挂后台，不允许一下退出）。
  bool _handleTvBack() {
    final navigator = appNavigatorKey.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
      return true;
    }
    return false;
  }

  /// tv: TV 构建下的内容子树作用域（仅 kTvBuild 分支调用，正常构建树摇剔除）。
  ///
  /// 由外到内两层：
  /// 1. [MediaQuery]：正文缩放下限 [kTvMinTextScale]。上游 [DisplayScaleScope]
  ///    已把系统字体缩放钉在 [1.0, kMaxSystemTextScale]，本层在其结果上再抬
  ///    下限 → 有效区间 [1.15, 1.30]。注意必须在 Builder 内取继承的
  ///    MediaQuery（拿到的是显示大小缩放后的数据），copyWith 只改 textScaler、
  ///    其余字段原样透传，不碰「显示大小」的 FittedBox 缩放体系；
  /// 2. [Dpad.wrap]：dpad 遍历引擎（传参不变，仍收 builder 的 context）。
  /// 3. [TvFocusHighlight]：焦点红框，叠在引擎之上、内容之下（IgnorePointer
  ///    不拦按键）。替代 dpad 的 `debugOverlay`——那个开关是整体的，一开就把
  ///    调试标签（region/尺寸）一起画出来，且 release 下自动关闭导致 release
  ///    包完全没有焦点指示。TV 没有光标，焦点框是硬需求，故自绘并在正式包保留。
  ///
  /// 原先这里还有一层 overscan 安全边距（[kTvOverscanInset]，曾按 10-foot
  /// 指标给内容留 48dp），实测在无过扫描的设备（平板/手机，以及多数现代
  /// 零间隙屏电视）上表现为四条纯黑边，且与铺满整屏的背景层不同色、观感
  /// 突兀，已于 2026-10-04 移除。若日后在真过扫描的老电视上发现边缘被裁，
  /// 优先用比例自适应（按屏宽取约 5%、封顶 [kTvOverscanInset]）而不是固定
  /// 48dp 恢复。焦点特效溢出由 Dpad.wrap 的 scrollPadding(64) 兜底。
  Widget _tvContentScope(BuildContext context, Widget? child) {
    return Builder(
      builder: (mqContext) {
        final mq = MediaQuery.of(mqContext);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: mq.textScaler.clamp(
              minScaleFactor: kTvMinTextScale,
              maxScaleFactor: kMaxSystemTextScale,
            ),
          ),
          child: Stack(
            children: [
              // dpad 遍历引擎。debugOverlay 传 false：它开启后会连同红框一起
              // 画出调试标签（`region: … 112×112`，dpad root.dart:499+），
              // 且该开关是整体的、无法只关标签。焦点框改由下面的
              // [TvFocusHighlight] 自绘（同规格红框、无标签），正式包也保留
              // —— TV 没有光标，焦点可见是硬需求。
              Dpad.wrap(
                theme: const DpadThemeData(
                  // tv: 焦点视觉只保留 [TvFocusHighlight] 的描边框，不再叠加
                  // dpad 自带的辉光阴影——两者并存会在控件外多一圈光晕，
                  // 遮住相邻的细边框/分割线，且滚动时阴影与描边不同步。
                  // 传空列表而非依赖默认值（默认含 scale + border 两项）。
                  effects: <DpadEffect>[],
                  scrollPadding: 64,
                ),
                onBack: _handleTvBack,
              )(context, child),
              // 焦点红框叠在最上层（IgnorePointer，不拦按键）。
              const Positioned.fill(child: TvFocusHighlight()),
            ],
          ),
        );
      },
    );
  }

  /// tv: 遥控媒体键兜底（播放/暂停/切歌）。播放中的媒体键正常由前台 media3
  /// 会话消费（fork AudioPlayer.java onPlayerCommandRequest → App 队列，阶段6），
  /// 不会走到这里；本层覆盖「无活跃会话 / 媒体通知 controller 未连接」时按键
  /// 落到 Activity 窗口、进入 Flutter 按键管线的情形。带 [TvMediaKey] 日志，
  /// 真机上用于判定按键被哪一层消费（AGENTS §0.1：以日志为准）。
  Widget _tvMediaKeyFallback(Widget child) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause):
            _tvMediaTogglePlay,
        const SingleActivator(LogicalKeyboardKey.mediaPlay): _tvMediaPlay,
        const SingleActivator(LogicalKeyboardKey.mediaPause): _tvMediaPause,
        const SingleActivator(LogicalKeyboardKey.mediaTrackNext): () =>
            _tvMediaSkip(next: true),
        const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): () =>
            _tvMediaSkip(next: false),
      },
      child: child,
    );
  }

  void _tvMediaTogglePlay() {
    final p = _playerProvider;
    if (p == null || p.currentSong == null) return;
    // ignore: avoid_print
    print('[TvMediaKey] playPause isPlaying=${p.isPlaying}');
    // ignore: discarded_futures
    p.isPlaying ? p.pause() : p.resume();
  }

  void _tvMediaPlay() {
    final p = _playerProvider;
    if (p == null || p.currentSong == null) return;
    if (p.isPlaying) return;
    // ignore: avoid_print
    print('[TvMediaKey] play');
    // ignore: discarded_futures
    p.resume();
  }

  void _tvMediaPause() {
    final p = _playerProvider;
    if (p == null || p.currentSong == null) return;
    if (!p.isPlaying) return;
    // ignore: avoid_print
    print('[TvMediaKey] pause');
    // ignore: discarded_futures
    p.pause();
  }

  void _tvMediaSkip({required bool next}) {
    final p = _playerProvider;
    if (p == null || p.currentSong == null) return;
    // ignore: avoid_print
    print('[TvMediaKey] skip ${next ? 'next' : 'previous'}');
    if (next) {
      // ignore: discarded_futures
      p.next();
    } else {
      // ignore: discarded_futures
      p.previous();
    }
  }

  @override
  void dispose() {
    _shortcutConfig?.removeListener(_applyDesktopShortcuts);
    _playerProvider?.removeListener(_onPlayerChanged);
    _backgroundThemeProvider?.removeListener(_onBackgroundChanged);
    kPredictiveBackEnabled.removeListener(_onPredictiveBackChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    // 当前生效的 fontFamily：system 模式为 null（让 Flutter 走系统字体链），
    // bundled/custom 模式为对应字体名。加载失败时降级为 null。
    final fontFamily = themeProvider.effectiveFontFamily;
    final predictiveBack = kPredictiveBackEnabled.value;

    return MaterialApp(
      title: 'MD3Music',
      debugShowCheckedModeBanner: false,
      // 同时传 theme 和 darkTheme，并根据 ThemeProvider.effectiveSeedColor
      // 动态生成（支持「莫奈色」开关切换系统主色）。
      // darkTheme 额外接收 useOledBlack 开关，开启时 surface 系列覆盖为纯黑。
      // fontFamily 透传给 ThemeData，影响所有 Material Widget 的默认字体。
      // 启用自定义背景图时，通过 _applyBackgroundOverrides 把主要表面改为透明，
      // 让底层 AppBackgroundLayer 的模糊背景图透出。
      theme: _applyBackgroundOverrides(
        AppTheme.lightThemeFromSeed(
          themeProvider.effectiveSeedColor,
          fontFamily: fontFamily,
          emphasized: themeProvider.emphasizedTypographyEnabled,
          labelBehavior: themeProvider.navLabelBehavior,
          predictiveBack: predictiveBack,
        ),
        themeProvider,
      ),
      darkTheme: _applyBackgroundOverrides(
        AppTheme.darkThemeFromSeed(
          themeProvider.effectiveSeedColor,
          useOledBlack: themeProvider.useOledBlack,
          fontFamily: fontFamily,
          emphasized: themeProvider.emphasizedTypographyEnabled,
          labelBehavior: themeProvider.navLabelBehavior,
          predictiveBack: predictiveBack,
        ),
        themeProvider,
      ),
      themeMode: themeProvider.themeMode,
      // 根据主题设置系统导航栏颜色
      builder: (context, child) {
        // 全局「显示大小」：整个 App 唯一的缩放点，页面侧一律直接写 dp。
        // 包在最外层，所以背景层、Navigator（全部路由）、Overlay（对话框 /
        // 底部弹层 / 菜单）、DLNA 与拖拽覆盖层都在作用域内。
        // MCP 写操作确认弹窗宿主：覆盖在整棵 App 之上（含全部路由与 Overlay），
        // 外部 AI 触发需要二次确认的写工具时在此弹出裁决对话框。
        return McpConfirmationDialogHost(
          child: DisplayScaleScope(
            scale: context.watch<ThemeProvider>().displayScale,
            child: SafeInsetsGuard(
              child: _SystemUiUpdater(
                child: Stack(
                  children: [
                    // 全局背景层（主页/底层背景）：复用 AppBackground 组件。
                    // 二级页面由路由过渡内嵌 AppBackground，随页面位移入场。
                    Positioned.fill(child: AppBackground()),
                    // 车机模式：把整棵 Navigator 与常驻播放器面板并排。
                    // 必须包在 Navigator **之外**（就是这里）——面板要同时覆盖
                    // push 出来的所有二级页面，放进任何路由内部都覆盖不到。
                    // 未开启车机模式（或当前页面声明抑制）时本组件原样返回 child，
                    // 布局与改动前完全一致。
                    // material_ui 兼容桥：chewie / dynamic_color / cached_network_image 等第三方包
                    // 仍导入 package:flutter/material.dart，其 Theme.of(context) 取不到本项目的
                    // material_ui 主题。本桥把 ThemeData / MaterialLocalizations 提供给它们。
                    // 官方定位为过渡工具，待依赖全部迁移到 material_ui 后移除。
                    CarModePanel(
                      // ignore: deprecated_member_use
                      child: MaterialUiCompatibilityBridge(
                        // TV 构建：dpad 遍历引擎（区域记忆 + 束流遍历 + 聚焦特效 +
                        // 返回键收口 + debugOverlay 调试高亮）。正常构建不包。
                        // tv: TV 构建再叠加 10-foot 内容作用域（overscan 安全边距
                        // + 正文缩放下限，见 [_tvContentScope]），Dpad 引擎包在
                        // 最内层。正常构建仍走 child! 原分支，树与改动前一致。
                        child: kTvBuild
                            ? _tvMediaKeyFallback(
                                _tvContentScope(context, child))
                            : child!,
                      ),
                    ),
                    const DlnaCastingOverlay(),
                    // 底栏形态交叉过渡浮层（一级常驻条 ↔ 二级悬浮胶囊）：挂在
                    // Navigator 之上、`PlayerDragOverlay` **之前** —— 形变层 /
                    // 封面层必须盖在它上面。只在飞行窗口渲染，静止时零成本。
                    const BottomBarMorphOverlay(),
                    // 上滑拖拽跟手覆盖层（在 Navigator 之上，拖拽期间显示预览）
                    const PlayerDragOverlay(),
                    // 封面连贯形变层：必须排在 PlayerDragOverlay **之后**，
                    // 否则形变中的封面会被跟手预览页盖住。
                    const PlayerCoverMorphLayer(),
                    // 歌单封面连贯过渡的 pane 路径飞行层（详情面板嵌套
                    // Navigator 内的 push 没有 HeroController 观察者，框架
                    // Hero 不飞，由该层自绘；根 Navigator 路径走框架 Hero）。
                    const PlaylistCoverFlightLayer(),
                    // 「下一首播放」封面跳水动画层：与形变层同处设计像素空间，
                    // 必须排在最末（球要画在最上面，越过形变层与歌单封面飞行层）。
                    const PlayNextFlightLayer(),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      navigatorKey: appNavigatorKey,
      // 优先级：未同意协议 → 协议页；否则未完成新手引导 → 引导页；否则主页
      initialRoute: widget.showUserAgreement
          ? '/user_agreement'
          : (widget.showOnboarding ? '/onboarding' : '/'),
      routes: {
        // '/' 不在 routes 注册，改在 onGenerateRoute 用 _UpFadeMainRoute 创建，
        // 以便 push FullPlayer 时主页面向上淡出（仅 FullPlayer 生效）
        '/search': (_) => const SearchPage(),
        '/library': (_) => const LibraryPage(),
        '/settings': (_) => const SettingsPage(),
        // 发现页右上角头像点击跳转入口（push 独立路由，与底部 tab 中的实例并存无冲突）
        '/user': (_) => const UserCenterPage(),
        '/player': (_) => const FullPlayer(),
        '/personal_fm': (_) => const PersonalFmPage(),
      },
      onGenerateRoute: (settings) {
        if (settings.name == '/onboarding') {
          return PageRouteBuilder(
            pageBuilder: (_, _, _) => const OnboardingPage(),
            transitionsBuilder: (_, animation, _, child) {
              return FadeTransition(opacity: animation, child: child);
            },
            transitionDuration: M3ExpressiveMotion.emphasisDuration,
          );
        }
        if (settings.name == '/user_agreement') {
          // 协议页：首次启动时点击"下一步" → 推送新手引导；已同意过则跳过引导直达主页
          return PageRouteBuilder(
            pageBuilder: (_, _, _) => UserAgreementPage(
              isFirstLaunch: true,
              onAgreed: () {
                // 用 pushReplacement 替换协议页，next 路由由 isFirstLaunch 决定
                // 避免新协议栈里残留协议页（用户按返回能跳过）
                appNavigatorKey.currentState?.pushReplacementNamed(
                  widget.showOnboarding ? '/onboarding' : '/',
                );
              },
            ),
            transitionsBuilder: (_, animation, _, child) {
              return FadeTransition(opacity: animation, child: child);
            },
            transitionDuration: M3ExpressiveMotion.emphasisDuration,
          );
        }
        if (settings.name == '/') {
          return _UpFadeMainRoute<void>(builder: (_) => const _MainLayout());
        }
        if (settings.name == '/playlist') {
          final playlist = settings.arguments as Playlist;
          return PageRouteBuilder(
            pageBuilder: (_, _, _) => PlaylistPage(playlist: playlist),
            transitionsBuilder: (_, animation, _, child) {
              return FadeTransition(opacity: animation, child: child);
            },
          );
        }
        return null;
      },
    );
  }

  /// 背景图启用时，把主要页面表面（Scaffold/AppBar/导航栏等）改为透明或半透明，
  /// 让底层 [AppBackgroundLayer] 的模糊背景图从间隙透出。关闭时原样返回。
  ///
  /// 卡片（CardTheme）等保持不透明，保证内容可读性；导航栏/抽屉/底部弹层
  /// 保留高透明度背景以维持层级感。
  ///
  /// 「文字阴影」开关开启时，同时给全局 textTheme / AppBar 标题附加阴影
  /// （见 [AppTheme.textShadowsFor]）；因为整个方法在未启用背景图时提前返回，
  /// 阴影天然只在背景图模式下生效。
  ///
  /// 背景是实色的组件（对话框 / 菜单 / SnackBar / Tooltip）反过来要显式钉住
  /// 不带阴影的文字样式：它们默认从 textTheme 兜底取样式，否则会连阴影一起
  /// 继承过去，而壁纸根本透不到它们后面。页面自绘的实色容器用
  /// `NoTextShadow` 包一层。
  ThemeData _applyBackgroundOverrides(
    ThemeData base,
    ThemeProvider themeProvider,
  ) {
    if (!themeProvider.useBackgroundImage) return base;
    final cs = base.colorScheme;
    final withTransparentSurfaces = base.copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
      ),
      // 公开版偏好：背景模式下底部导航栏/侧栏用很低透明度 surface，
      // 让核心的模糊背景图清晰透出（用户要求更透明）；
      // 同时隐藏选中指示器（胶囊/药丸），避免实色胶囊在壁纸上突兀。
      navigationBarTheme: base.navigationBarTheme.copyWith(
        backgroundColor: cs.surface.withValues(alpha: 0.2),
        indicatorColor: Colors.transparent,
      ),
      navigationRailTheme: base.navigationRailTheme.copyWith(
        backgroundColor: cs.surface.withValues(alpha: 0.2),
        indicatorColor: Colors.transparent,
      ),
      drawerTheme: base.drawerTheme.copyWith(
        backgroundColor: cs.surface.withValues(alpha: 0.96),
      ),
      bottomSheetTheme: base.bottomSheetTheme.copyWith(
        backgroundColor: cs.surfaceContainerLow.withValues(alpha: 0.97),
      ),
    );
    if (!themeProvider.useTextShadowEffective) return withTransparentSurfaces;

    final shadows = AppTheme.textShadowsFor(
      base.brightness,
      blurRadius: themeProvider.textShadowBlur,
    );
    return withTransparentSurfaces.copyWith(
      appBarTheme: withTransparentSurfaces.appBarTheme.copyWith(
        titleTextStyle:
            withTransparentSurfaces.appBarTheme.titleTextStyle?.copyWith(
          shadows: shadows,
        ),
      ),
      textTheme: AppTheme.applyTextShadows(base.textTheme, shadows),
      primaryTextTheme: AppTheme.applyTextShadows(base.primaryTextTheme, shadows),
      // 实色表面：把 Flutter 的 M3 默认值（都从 textTheme 兜底取）在这里钉死，
      // 取的是 base 里还没加阴影的那份文字层级。
      dialogTheme: base.dialogTheme.copyWith(
        titleTextStyle:
            base.dialogTheme.titleTextStyle ?? base.textTheme.headlineSmall,
        contentTextStyle:
            base.dialogTheme.contentTextStyle ?? base.textTheme.bodyMedium,
      ),
      popupMenuTheme: base.popupMenuTheme.copyWith(
        textStyle: base.popupMenuTheme.textStyle ?? base.textTheme.labelLarge,
      ),
      snackBarTheme: base.snackBarTheme.copyWith(
        contentTextStyle: base.snackBarTheme.contentTextStyle ??
            base.textTheme.bodyMedium?.copyWith(color: cs.onInverseSurface),
      ),
      tooltipTheme: base.tooltipTheme.copyWith(
        textStyle: base.tooltipTheme.textStyle ??
            base.textTheme.bodySmall?.copyWith(color: cs.onInverseSurface),
      ),
    );
  }
}

/// 根据主题更新系统 UI（状态栏和导航栏颜色）
class _SystemUiUpdater extends StatefulWidget {
  final Widget child;

  const _SystemUiUpdater({required this.child});

  @override
  State<_SystemUiUpdater> createState() => _SystemUiUpdaterState();
}

class _SystemUiUpdaterState extends State<_SystemUiUpdater>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateSystemUi();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 当应用从后台恢复或从其他页面返回时，恢复系统 UI
    if (state == AppLifecycleState.resumed) {
      _updateSystemUi();
    }
  }

  void _updateSystemUi() {
    // 封面流页横屏实际沉浸中：保留 SystemUiMode.immersiveSticky，
    // 不覆盖系统栏模式（否则方向变化等 rebuild 会冲掉沉浸设置）。
    // 用「实际生效」标志：用户请求沉浸但切到其他 tab/竖屏时仍需恢复系统栏样式。
    if (kCoverFlowImmersiveActive.value) return;
    // 播放器 Zen 沉浸生效中：保留 immersiveSticky，不被主界面 edgeToEdge 覆盖
    // （否则亮屏 resumed 会把状态栏重新显示出来）。
    if (kPlayerZenImmersiveActive.value) return;
    // 播放器横屏沉浸（非 Zen）生效中：同 Zen，保留 immersiveSticky 不被覆盖。
    if (kPlayerLandscapeImmersiveActive.value) return;
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;

    // 主界面使用 edgeToEdge：状态栏与底部导航条（小横条）完全透明并悬浮在
    // 内容之上，App 内容延伸到系统栏后面。底部留白由各自组件消费系统 inset：
    // NavigationBar 内部自带 SafeArea(top:false)，MiniPlayer 用
    // SafeArea(bottom:true)（无底栏时生效，Scaffold 有 bottomNavigationBar
    // 时会先移除 body 的 bottom padding，两者不会重复留白）。
    //
    // 不再用 SystemUiMode.manual + systemNavigationBarColor：targetSdk 35 起
    // Android 15+ 强制 edge-to-edge 并忽略该颜色，manual 只会造成新旧系统
    // 表现不一致。
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
        systemNavigationBarIconBrightness: isDark
            ? Brightness.light
            : Brightness.dark,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _MainLayout extends StatefulWidget {
  const _MainLayout();

  @override
  State<_MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<_MainLayout>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  int _selectedIndex = 0;
  final _responsiveShellKey = GlobalKey<ResponsiveShellState>();

  /// 桌面外壳句柄：横屏平板布局下由根 [PopScope] 调用其 [DesktopShellState.maybePop]
  /// 先回退当前 Tab 的中央内容栈（见横屏平板重设计计划 4.4 / 六）。
  final GlobalKey<DesktopShellState> _desktopShellKey =
      GlobalKey<DesktopShellState>();

  /// 上一次同步的沉浸状态，避免重复调用 SystemChrome（幂等去重）。
  bool _immersiveSynced = false;

  /// 当前 tab 是否停在二级页面（及以后），由 [ResponsiveShell] 的
  /// `_scheduleDepthReport` 定级后上报：只看「中央栈有 push 出来的页面路由 ∨
  /// 双栏详情面板独占整宽」两条路由事实，**不看标题对齐**（标题对齐只决定播放条
  /// 形态，见 `kSecondaryPlayerOnPrimaryPages` 的判据说明）。底栏在壳层之外，内层页面
  /// 盖不住它，只能靠这个标志收起；回到一级页面时自动恢复。
  bool _secondaryPageOnTop = false;

  /// 常驻 MiniPlayer 的收起动画（二级路由形态的设置页开在当前 tab 栈顶、
  /// 或封面流横屏沉浸生效时）。
  /// 与底栏收起同时长（kBottomChromeToggleDuration）、同曲线（面板收展缓动），
  /// 且由同一 rebuild 帧驱动（_secondaryPageOnTop 翻转处同步起止），视觉上与
  /// 底栏一起沉底/浮出。reduce-motion 时直接落端点（与底栏口径一致）。
  late final AnimationController _miniPlayerHideController;
  late final CurvedAnimation _miniPlayerHide;

  /// 上一次同步给 [_miniPlayerHideController] 的目标态（true=收起）。
  /// 幂等判据只看它，不看 `status == completed`：动画正 forward 时 status 是
  /// forward 而非 completed，用 status 判等会把「目标翻回显示」误当成已到位、
  /// 不执行 reverse，常驻条沉底不回（成因见 [_syncMiniPlayerHide]）。
  late bool _miniPlayerHideTarget;
  bool _reduceMotion = false;

  /// 底栏**形态交叉过渡**控制器（一级常驻条 ↔ 二级悬浮胶囊）。
  ///
  /// **不能复用 [_miniPlayerHideController]**：它的目标 [_residentMiniPlayerHidden]
  /// 含 `kSecondaryPlayerEnabled.value`，悬浮形态下恒为 true —— 那是"恒定隐藏"，
  /// 不是切换进度（见 `docs/plans/2026-10-11-player-bar-morph-plan.md` §4.5）。
  /// 故单开一条**一次性 260ms** 控制器，时长/曲线与底栏收展同源；值经 listener 写进
  /// [kBottomBarFormProgress]，静止时停在端点、零帧成本（不新增常驻 Ticker/repeat）。
  late final AnimationController _barFormController;
  late final CurvedAnimation _barFormCurve;

  /// 上一次同步给 [_barFormController] 的目标形态（true = 悬浮胶囊）。
  late bool _barFormTargetIsCapsule;

  /// 开启交棒让位窗口（起跑同帧调）：标出源端形态（窗口内两端真身保持挂载，源端
  /// 不 offstage、目的端 offstage，见 [barFormRealBarStandsDown]）。
  void _openBarFormFlight(bool targetIsCapsule) {
    // 目的形态是胶囊 ⇒ 源形态是常驻条（反之亦然）。
    kBarFormResidentIsSource.value = targetIsCapsule;
    kBarFormFlightActive.value = true;
  }

  /// 形态交棒专用的「当前 tab 是否停在 push 出来的页面上」事实（导航时刻立即更新）。
  ///
  /// 与 [_secondaryPageOnTop]（底栏收起 / 常驻条隐藏用）**解耦**：后者等转场收敛
  /// 才上报（底栏收起会当场改变 Tab 栈高度，撞框架 Hero 飞行盒子，见
  /// `responsive_shell.dart` 的 `_scheduleDepthReport`），而形态交棒的飞行窗口
  /// 必须在**导航那一刻**开跑 —— 旧实现用推迟上报驱动形态，转场全程进度贴旧端点，
  /// 转场收敛后胶囊先让位、常驻条凭空长出再变回胶囊（2026-10-11 会诊 D1/D3 实测）。
  ///
  /// 只由 [ResponsiveShell.onPageRouteEvent]（真实 push/pop/remove/replace）与切 tab
  /// 后的栈事实刷新写入：转屏导致的 `_detailExclusive` 翻转、tab 配置装载等
  /// **没有导航事件**的翻转不进入这里（会诊 D3 的幻影翻转 ①②）。
  bool _formSecondaryOnTop = false;

  /// 上一次形态同步时的 tab 下标（切 tab 检测，见 [_syncBarFormTarget]）。
  int _lastSyncedBarFormTabIndex = 0;

  /// 冷启动播种写 notifier 的窗口（见 [_loadSecondaryPlayerEnabled]）：
  /// 期间的目标翻转吸附端点，不播交棒（会诊 D3 的幻影翻转 ②）。
  bool _barFormSeeding = false;

  /// 词幕连接失败弹窗展示中标记，防止连发 connect_failed 时重复弹窗。
  bool _lyriconFailDialogShown = false;

  /// 一起听听众起播确认窗展示中标记：连点/多入口并发时只允许一个确认窗。
  bool _roomGuestPlayDialogOpen = false;

  /// 二次返回退出：首次返回后置位，3 秒内再次返回触发真正退出。
  bool _exitPressed = false;
  Timer? _exitResetTimer;

  /// 退出中标记：置位后整页缩小动画并屏蔽交互，动画结束后回桌面。
  bool _isExiting = false;

  /// 微信风格退出动画：缩放 + 向右下角位移 + 渐隐（400ms）。
  late final AnimationController _exitController;
  late final Animation<double> _exitScale;
  late final Animation<double> _exitOpacity;
  late final Animation<Offset> _exitOffset;

  /// 根据 tab id 构建对应页面 Widget。
  Widget _buildPageForTab(String tabId) {
    // 统一在 tab 页外层包 ContentEntrance：向上淡入滑动（400ms, easeOutCubic），
    // 与本地音乐 SongsPage 的入场动画一致。
    // ContentEntrance 只在首次构建时播放，父组件 rebuild 不会重播。
    // 与外层 AnimatedSwitcher 的左右滑动叠加，形成"内容上浮 → 页面滑入"的层次感。
    Widget page;
    switch (tabId) {
      case 'launchpad':
        page = LaunchPadPage(
          onTabSelected: _switchToTab,
          onTabEnabled: _enableAndSwitchToTab,
          onTabOpened: _openTabAsPage,
        );
        break;
      case 'discover':
        page = const DiscoverPage();
        break;
      case 'coverflow':
        page = const CoverFlowPage();
        break;
      case 'library':
        page = const LibraryPage();
        break;
      case 'favorites':
        page = const FavoritesPage();
        break;
      case 'fm':
        page = const PersonalFmPage();
        break;
      case 'search':
        // Tab 模式：SearchPage 自包悬浮宿主，一级形态自动退化交由 MiniPlayer 承载
        page = const SearchPage();
        break;
      case 'charts':
        page = const ChartsPage();
        break;
      case 'ip':
        page = const IpPage();
        break;
      case 'recognition':
        // Tab 模式：SongRecognitionPage 自包悬浮宿主，一级形态自动退化交由 MiniPlayer 承载
        page = const SongRecognitionPage();
        break;
      case 'audiobook':
        page = const AudiobookPage();
        break;
      case 'scene':
        page = const ScenePage();
        break;
      case 'channel':
        page = const ChannelPage();
        break;
      case 'brush':
        page = const BrushPage();
        break;
      case 'listen_together':
        page = const ListenTogetherPage();
        break;
      case 'settings':
        page = const SettingsPage();
        break;
      case 'user':
        page = const UserCenterPage();
        break;
      default:
        page = const SizedBox.shrink();
    }
    return ContentEntrance(child: page);
  }

  /// 根据 tab id 获取对应的 NavigationDestination 图标。
  /// 不使用 selectedIcon（Flutter 原生内部为硬切，无过渡动画），
  /// 改由 _AnimatedTabIcon 在选中变化时做缩放弹跳，使切换更生动。
  NavigationDestination _buildDestination(TabItem tab, int index) {
    final isSelected = index == _selectedIndex;
    switch (tab.id) {
      case 'launchpad':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.grid_view_outlined,
            filledIcon: Icons.grid_view,
          ),
          label: tab.label,
        );
      case 'discover':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.explore_outlined,
            filledIcon: Icons.explore,
          ),
          label: tab.label,
        );
      case 'coverflow':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.album_outlined,
            filledIcon: Icons.album,
          ),
          label: tab.label,
        );
      case 'library':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.library_music_outlined,
            filledIcon: Icons.library_music,
          ),
          label: tab.label,
        );
      case 'favorites':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.favorite_outline,
            filledIcon: Icons.favorite,
          ),
          label: tab.label,
        );
      case 'fm':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.radio_outlined,
            filledIcon: Icons.radio,
          ),
          label: tab.label,
        );
      case 'search':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.search_outlined,
            filledIcon: Icons.search,
          ),
          label: tab.label,
        );
      case 'charts':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.leaderboard_outlined,
            filledIcon: Icons.leaderboard,
          ),
          label: tab.label,
        );
      case 'ip':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.edit_note_outlined,
            filledIcon: Icons.edit_note,
          ),
          label: tab.label,
        );
      case 'recognition':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.mic_none_outlined,
            filledIcon: Icons.mic,
          ),
          label: tab.label,
        );
      case 'audiobook':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.auto_stories_outlined,
            filledIcon: Icons.auto_stories,
          ),
          label: tab.label,
        );
      case 'scene':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.landscape_outlined,
            filledIcon: Icons.landscape,
          ),
          label: tab.label,
        );
      case 'channel':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.dynamic_feed_outlined,
            filledIcon: Icons.dynamic_feed,
          ),
          label: tab.label,
        );
      case 'brush':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.swipe_outlined,
            filledIcon: Icons.swipe,
          ),
          label: tab.label,
        );
      case 'listen_together':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.groups_outlined,
            filledIcon: Icons.groups,
          ),
          label: tab.label,
        );
      case 'settings':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.settings_outlined,
            filledIcon: Icons.settings,
          ),
          label: tab.label,
        );
      case 'user':
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.person_outlined,
            filledIcon: Icons.person,
          ),
          label: tab.label,
        );
      default:
        return NavigationDestination(
          icon: _AnimatedTabIcon(
            selected: isSelected,
            outlinedIcon: Icons.circle_outlined,
            filledIcon: Icons.circle,
          ),
          label: tab.label,
        );
    }
  }

  NavigationRailDestination _buildRailDestination(TabItem tab) {
    // 横屏侧栏文字跟随设置页「底部导航栏文字」三档：由
    // CompactNavigationRail 按 labelBehavior 决定是否渲染。这里始终传真实标题
    //（与底部 NavigationBar 一致；仅图标模式下文字被隐藏，label 仍用于无障碍朗读）。
    final label = Text(tab.label);
    switch (tab.id) {
      case 'launchpad':
        return NavigationRailDestination(
          icon: const Icon(Icons.grid_view_outlined),
          selectedIcon: const Icon(Icons.grid_view),
          label: label,
        );
      case 'discover':
        return NavigationRailDestination(
          icon: const Icon(Icons.explore_outlined),
          selectedIcon: const Icon(Icons.explore),
          label: label,
        );
      case 'coverflow':
        return NavigationRailDestination(
          icon: const Icon(Icons.album_outlined),
          selectedIcon: const Icon(Icons.album),
          label: label,
        );
      case 'library':
        return NavigationRailDestination(
          icon: const Icon(Icons.library_music_outlined),
          selectedIcon: const Icon(Icons.library_music),
          label: label,
        );
      case 'favorites':
        return NavigationRailDestination(
          icon: const Icon(Icons.favorite_outline),
          selectedIcon: const Icon(Icons.favorite),
          label: label,
        );
      case 'fm':
        return NavigationRailDestination(
          icon: const Icon(Icons.radio_outlined),
          selectedIcon: const Icon(Icons.radio),
          label: label,
        );
      case 'search':
        return NavigationRailDestination(
          icon: const Icon(Icons.search_outlined),
          selectedIcon: const Icon(Icons.search),
          label: label,
        );
      case 'charts':
        return NavigationRailDestination(
          icon: const Icon(Icons.leaderboard_outlined),
          selectedIcon: const Icon(Icons.leaderboard),
          label: label,
        );
      case 'ip':
        return NavigationRailDestination(
          icon: const Icon(Icons.edit_note_outlined),
          selectedIcon: const Icon(Icons.edit_note),
          label: label,
        );
      case 'recognition':
        return NavigationRailDestination(
          icon: const Icon(Icons.mic_none_outlined),
          selectedIcon: const Icon(Icons.mic),
          label: label,
        );
      case 'audiobook':
        return NavigationRailDestination(
          icon: const Icon(Icons.auto_stories_outlined),
          selectedIcon: const Icon(Icons.auto_stories),
          label: label,
        );
      case 'scene':
        return NavigationRailDestination(
          icon: const Icon(Icons.landscape_outlined),
          selectedIcon: const Icon(Icons.landscape),
          label: label,
        );
      case 'channel':
        return NavigationRailDestination(
          icon: const Icon(Icons.dynamic_feed_outlined),
          selectedIcon: const Icon(Icons.dynamic_feed),
          label: label,
        );
      case 'brush':
        return NavigationRailDestination(
          icon: const Icon(Icons.swipe_outlined),
          selectedIcon: const Icon(Icons.swipe),
          label: label,
        );
      case 'listen_together':
        return NavigationRailDestination(
          icon: const Icon(Icons.groups_outlined),
          selectedIcon: const Icon(Icons.groups),
          label: label,
        );
      case 'settings':
        return NavigationRailDestination(
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings),
          label: label,
        );
      case 'user':
        return NavigationRailDestination(
          icon: const Icon(Icons.person_outlined),
          selectedIcon: const Icon(Icons.person),
          label: label,
        );
      default:
        return NavigationRailDestination(
          icon: const Icon(Icons.circle_outlined),
          selectedIcon: const Icon(Icons.circle),
          label: label,
        );
    }
  }

  NavigationDrawerDestination _buildDrawerDestination(TabItem tab) {
    switch (tab.id) {
      case 'launchpad':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.grid_view_outlined),
          selectedIcon: const Icon(Icons.grid_view),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
      case 'discover':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.explore_outlined),
          selectedIcon: const Icon(Icons.explore),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
      case 'coverflow':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.album_outlined),
          selectedIcon: const Icon(Icons.album),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
      case 'library':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.library_music_outlined),
          selectedIcon: const Icon(Icons.library_music),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
      case 'favorites':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.favorite_outline),
          selectedIcon: const Icon(Icons.favorite),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
      case 'fm':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.radio_outlined),
          selectedIcon: const Icon(Icons.radio),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
      case 'search':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.search_outlined),
          selectedIcon: const Icon(Icons.search),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
      case 'charts':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.leaderboard_outlined),
          selectedIcon: const Icon(Icons.leaderboard),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
      case 'ip':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.edit_note_outlined),
          selectedIcon: const Icon(Icons.edit_note),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
      case 'recognition':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.mic_none_outlined),
          selectedIcon: const Icon(Icons.mic),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
      case 'audiobook':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.auto_stories_outlined),
          selectedIcon: const Icon(Icons.auto_stories),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
      case 'scene':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.landscape_outlined),
          selectedIcon: const Icon(Icons.landscape),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
      case 'channel':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.dynamic_feed_outlined),
          selectedIcon: const Icon(Icons.dynamic_feed),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
      case 'brush':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.swipe_outlined),
          selectedIcon: const Icon(Icons.swipe),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
      case 'listen_together':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.groups_outlined),
          selectedIcon: const Icon(Icons.groups),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
      case 'settings':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
      case 'user':
        return NavigationDrawerDestination(
          icon: const Icon(Icons.person_outlined),
          selectedIcon: const Icon(Icons.person),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
      default:
        return NavigationDrawerDestination(
          icon: const Icon(Icons.circle_outlined),
          selectedIcon: const Icon(Icons.circle),
          // 公开版偏好：侧栏（NavigationRail）也不显示文字，仅图标
          label: const Text(''),
        );
    }
  }

  @override
  void initState() {
    super.initState();
    // 微信风格退出动画：缩放 1.0→0.1（图标大小）、位移 0→右下角 70%、渐隐 1.0→0.0
    _exitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _exitScale = Tween<double>(begin: 1.0, end: 0.1).animate(
      CurvedAnimation(parent: _exitController, curve: Curves.easeInOutCubic),
    );
    _exitOpacity = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _exitController, curve: Curves.easeIn),
    );
    _exitOffset = Tween<Offset>(begin: Offset.zero, end: const Offset(0.7, 0.7))
        .animate(
      CurvedAnimation(parent: _exitController, curve: Curves.easeInOutCubic),
    );
    // 常驻 MiniPlayer 收起：时长/曲线与 ResponsiveScaffold._chromeHide 完全一致，
    // 由 [_syncMiniPlayerHide] 在同一帧驱动到目标态。
    // 初值按目标态定端点（与 _chromeHide 按 widget.hideNavigation 定端点同一口径）：
    // 启动即处于收起形态（悬浮播放器开关在 runBootstrap 首帧前播种为 true）时，
    // 不必等 _secondaryPageOnTop 上报后再 forward，省掉整段 260ms 帧提交——
    // 该形态下常驻条子树本就不渲染（见 _buildBody 的 kSecondaryPlayerEnabled 早退）。
    // initState 读 [_residentMiniPlayerHidden] 安全：三个全局 notifier 分别已播种 /
    // 定义即 false（kCoverFlowImmersiveActive 由 _syncImmersiveMode 在首帧 build 才
    // 置位，initState 早于它，初值恒 false → 端点初值不受沉浸项影响），
    // _secondaryPageOnTop 取字段初值 false，不碰 context / MediaQuery。
    final bool initialMiniPlayerHide = _residentMiniPlayerHidden;
    _miniPlayerHideController = AnimationController(
      vsync: this,
      duration: kBottomChromeToggleDuration,
      value: initialMiniPlayerHide ? 1.0 : 0.0,
    );
    _miniPlayerHideTarget = initialMiniPlayerHide;
    _miniPlayerHide = CurvedAnimation(
      parent: _miniPlayerHideController,
      curve: M3ExpressiveMotion.panelCollapseEasing,
      reverseCurve: M3ExpressiveMotion.panelExpandEasing,
    );
    kSecondaryPlayerEnabled.addListener(_syncMiniPlayerHide);
    kSuppressResidentMiniPlayer.addListener(_syncMiniPlayerHide);
    // 形态交叉过渡：目标由纯函数 [resolveBottomBarFormTarget] 给出（三项输入见
    // [_resolveBarFormTargetIsCapsule]）。初值按目标定端点（启动即处于胶囊形态时
    // 不必再播一段 260ms）。
    _barFormTargetIsCapsule = _resolveBarFormTargetIsCapsule();
    kBarFormFlightActive.value = false;
    kBarFormResidentIsSource.value = !_barFormTargetIsCapsule;
    _lastSyncedBarFormTabIndex = _selectedIndex;
    _barFormController = AnimationController(
      vsync: this,
      duration: kBottomChromeToggleDuration,
      value: _barFormTargetIsCapsule ? 1.0 : 0.0,
    );
    _barFormCurve = CurvedAnimation(
      parent: _barFormController,
      curve: M3ExpressiveMotion.panelCollapseEasing,
      reverseCurve: M3ExpressiveMotion.panelExpandEasing,
    );
    _barFormController.addListener(_publishBarFormProgress);
    // 交棒飞行结束/被吸附时解冻常驻条端点快照（见 _startBarFormFlight）。
    _barFormController.addStatusListener(_onBarFormStatusChanged);
    kSecondaryPlayerEnabled.addListener(_onBarFormSettingChanged);
    kSecondaryPlayerOnPrimaryPages.addListener(_onBarFormSettingChanged);
    _publishBarFormProgress();
    // 封面流横屏沉浸：常驻条并入底栏那条 260ms 通道（见 _residentMiniPlayerHidden）。
    // 该 notifier 由本State 的 _syncImmersiveMode 写入，listener 只驱动已存在的
    // _miniPlayerHideController，不新增任何动画对象（净帧增量 0）。
    kCoverFlowImmersiveActive.addListener(_syncMiniPlayerHide);
    // 未登录时尝试播放联网歌曲,弹出登录提示
    context.read<PlayerProvider>().onLoginRequired = _showLoginRequiredDialog;
    // 一起听房主播放守卫：房间歌单外的曲目（本地音乐等）不允许本地起播
    context.read<PlayerProvider>().onRoomOwnerInterceptPlayback =
        _interceptRoomOwnerLocalPlayback;
    // 一起听房主播放态通告：播放器自身的暂停/恢复按钮也同步到房间
    context.read<PlayerProvider>().onPlaybackStateChangedByUser =
        _forwardPlaybackStateToRoom;
    // 一起听进度通告：对房主是上报（player_operation action=2），对成员是复同步
    context.read<PlayerProvider>().onSeekedByUser = _forwardSeekToRoom;
    // 一起听听众：房间内点播其他歌曲前的确认窗。
    // 同步判定（要不要弹）+ 异步确认（弹什么、怎么处理）分两个钩子：
    // 不需要弹的调用不能因此多出一次 await（见 PlayerProvider._roomGuestPlayGate）。
    context.read<PlayerProvider>().shouldConfirmRoomGuestPlay =
        _shouldConfirmRoomGuestPlay;
    context.read<PlayerProvider>().onRoomGuestPlayConfirm =
        _confirmRoomGuestPlay;
    // 一起听：自然播完与上一首/下一首的房间路由（听众暂停等待，房主切歌上报）
    final ltProvider = context.read<ListenTogetherProvider>();
    final playerProvider = context.read<PlayerProvider>();
    playerProvider.onRoomGuestCompletionPause = () {
      final s = ltProvider.session;
      return s != null && !s.isOwner && !s.playbackDetached;
    };
    playerProvider.onRoomOwnerCompletionSwitch = () {
      final s = ltProvider.session;
      if (s == null || !s.isOwner || s.playbackDetached) return false;
      final song = playerProvider.currentSong;
      return song == null ? false : s.ownerHandleSongCompleted(song);
    };
    playerProvider.onRoomOwnerSkip = ({required bool forward}) {
      final s = ltProvider.session;
      if (s == null || !s.isOwner || s.playbackDetached) return false;
      return s.ownerSkip(forward: forward);
    };
    playerProvider.onRoomGuestSkipBlocked = () {
      final s = ltProvider.session;
      if (s == null || s.isOwner || s.playbackDetached) return false;
      showToast('一起听中由房主控制播放');
      return true;
    };
    playerProvider.onRoomSessionActive = () {
      final s = ltProvider.session;
      return s != null && !s.playbackDetached;
    };
    playerProvider.onRoomPlayModeChanged = (mode) {
      ltProvider.session?.ownerSetPlayMode(mode);
    };
    // 冷启动一起听会话恢复：进程被杀后服务端会话仍在进行（其他成员还能看到
    // 自己），按服务端会话重建 RoomSession，让播放器胶囊不进页也立即回到
    // 会话态。首帧后执行（等 Provider 挂载），恢复失败静默跳过。
    // 启动自动播放串在它**之后**：一起听恢复末尾可能自己 resume()/playSong()
    // （见 ListenTogetherProvider 的恢复路径），并发会互相顶掉播放目标。
    // 默认关闭（见 SettingsRepository.getStartupAutoPlayEnabled），关着时
    // 这里对播放零参与。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(() async {
        await ltProvider.restoreCurrentSessionIfAny(
          player: playerProvider,
          account: context.read<KugouProvider>(),
        );
        if (!mounted) return;
        final result = await StartupAutoPlay.maybeAutoPlay(
          kugou: context.read<KugouProvider>(),
          player: playerProvider,
        );
        // 导航决策留在这一层：服务只负责起播，不认识 Navigator。
        // 必须等「真的起播了」再推 —— 联网源解析播放地址要 1~3s，
        // 提前推会先闪一个空播放页。
        if (!mounted || !result.started || !result.openPlayerPage) return;
        openFullPlayer(context);
      }());
    });
    // 监听应用生命周期：detached（进程被系统销毁前的最后窗口）时尝试关停本地 API 服务器
    WidgetsBinding.instance.addObserver(this);
    // 监听 shortcut 入口的 tab 切换请求（来自 main.dart 的 handleShortcut）
    shortcutTabRequest.addListener(_handleShortcutTabRequest);
    // 监听外部音频打开请求（文件管理器「用其他应用打开」）
    externalMediaRequest.addListener(_handleExternalMediaRequest);
    // 冷启动：请求可能先于 _MainLayout 挂载到达（用户协议 / 引导页期间），
    // 首帧完成后补消费一次当前值
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _handleExternalMediaRequest(),
    );
    // 监听封面流沉浸请求（长按切换 / 返回键恢复），变更时重算沉浸状态
    kCoverFlowImmersive.addListener(_onCoverFlowImmersiveChanged);
    // 桌面外壳总开关：启动时载入持久化值 + 监听运行时切换（设置页开关）。
    // 载入前默认 false（常规响应式布局），载入/切换后触发整棵子树重建。
    kDesktopModeEnabled.addListener(_onDesktopModeChanged);
    unawaited(_loadDesktopModeEnabled());
    // 悬浮播放器总开关：启动时载入持久化值（宿主自己订阅，无需本 State 监听）。
    unawaited(_loadSecondaryPlayerEnabled());
    // 悬浮播放器的进度指示与一级页面形态：同上，宿主/本 shell 各自订阅。
    unawaited(_loadSecondaryPlayerProgress());
    unawaited(_loadSecondaryPlayerOnPrimary());
    // 二级页面（及以后）是否收起底部导航栏：本 State 的 hideNavigation 直接读它，
    // 故需监听切换后重建（与 kDesktopModeEnabled 同模式）。
    kHideNavBarOnSecondaryPages.addListener(_onHideNavBarOnSecondaryChanged);
    unawaited(_loadHideNavBarOnSecondaryPages());
    // 封面流歌单源：启动时载入持久化值（封面流页自己订阅通知器）。
    unawaited(_loadCoverFlowSource());
    // 悬浮播放器停靠位：启动时载入持久化值；未设置过则按设备形态取默认。
    unawaited(_loadSecondaryPlayerDock());
    // 播放页进度条波浪起伏开关：启动时载入持久化值（MD3 播放页自己订阅）。
    unawaited(_loadSeekBarWaveEnabled());
    // 封面阴影强度：启动时载入持久化值（两个播放页的封面包装层自己订阅）。
    unawaited(_loadCoverShadowStrength());
    // 宽屏播放页「横屏控制面板独立页」开关：启动时载入持久化值（播放页自己订阅）。
    unawaited(_loadLandscapeDetachedControls());
    // 顶栏「胶囊按钮收缩」开关：启动时载入持久化值（顶栏尾部组件自己订阅）。
    unawaited(_loadTopBarPillCollapse());
    // 页签圆点位置开关（默认关 = 底部页签条）：启动时载入持久化值（播放页自己订阅）。
    unawaited(_loadTopBarTabDots());
    // 监听词幕连接失败（原生侧多次重试后 connect_failed）→ 弹窗提示
    LyriconProviderService.instance.addListener(_onLyriconStateChanged);
    // 冷启动前若已连接失败（如后台唤醒时），进入主页后立即补弹一次
    if (LyriconProviderService.instance.connectFailed) {
      _lyriconFailDialogShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showLyriconConnectFailedDialog();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 与底栏收起同一 reduce-motion 口径：动画直接落端点，不播过渡。
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void dispose() {
    _exitResetTimer?.cancel();
    _exitController.dispose();
    kSecondaryPlayerEnabled.removeListener(_syncMiniPlayerHide);
    kSuppressResidentMiniPlayer.removeListener(_syncMiniPlayerHide);
    kCoverFlowImmersiveActive.removeListener(_syncMiniPlayerHide);
    _miniPlayerHideController.dispose();
    kSecondaryPlayerEnabled.removeListener(_onBarFormSettingChanged);
    kSecondaryPlayerOnPrimaryPages.removeListener(_onBarFormSettingChanged);
    _barFormController.removeStatusListener(_onBarFormStatusChanged);
    _barFormController.removeListener(_publishBarFormProgress);
    _barFormController.dispose();
    LyriconProviderService.instance.removeListener(_onLyriconStateChanged);
    kCoverFlowImmersive.removeListener(_onCoverFlowImmersiveChanged);
    kDesktopModeEnabled.removeListener(_onDesktopModeChanged);
    kHideNavBarOnSecondaryPages.removeListener(
      _onHideNavBarOnSecondaryChanged,
    );
    shortcutTabRequest.removeListener(_handleShortcutTabRequest);
    externalMediaRequest.removeListener(_handleExternalMediaRequest);
    WidgetsBinding.instance.removeObserver(this);
    // 若 App 销毁时仍处于封面流沉浸，恢复系统栏（edgeToEdge，与主界面一致）
    if (_immersiveSynced) {
      _immersiveSynced = false;
      kCoverFlowImmersiveActive.value = false;
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  /// 封面流沉浸请求变化（长按 / 返回键）→ 重算实际沉浸状态。
  void _onCoverFlowImmersiveChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 启动时从持久化载入桌面外壳开关，写入全局 [kDesktopModeEnabled]。
  Future<void> _loadDesktopModeEnabled() async {
    final enabled = await SettingsRepository().getDesktopModeEnabled();
    if (!mounted) return;
    // 仅在与当前值不同时赋值，避免无谓通知；赋值会触发 _onDesktopModeChanged。
    if (kDesktopModeEnabled.value != enabled) {
      kDesktopModeEnabled.value = enabled;
    }
  }

  /// 启动时从持久化载入悬浮播放器开关，写入全局 [kSecondaryPlayerEnabled]。
  ///
  /// 无需监听运行时变更：SecondaryMiniPlayerHost 自己用 ValueListenableBuilder
  /// 订阅，设置页切换后各页宿主即时重建，不依赖本 State。
  ///
  /// TV 构建（kTvBuild）下强制为 false、回落底部常驻播放条：悬浮条本体没有
  /// DpadFocusable 焦点停点，常驻条已有 DpadFocusable + TvPlayerBarFocusBridge。
  /// 只门控写入值，**不回写 prefs**——切回手机版不丢用户设置。
  Future<void> _loadSecondaryPlayerEnabled() async {
    final enabled = await SettingsRepository().getSecondaryPlayerEnabled();
    if (!mounted) return;
    final effective = kTvBuild ? false : enabled;
    if (kSecondaryPlayerEnabled.value != effective) {
      // 冷启动播种：装载写值与用户切换写的是同一个 notifier，但这不是用户动作 ——
      // 形态吸附端点、不播交棒（会诊 D3 的幻影翻转 ②；同 frame 内同步完成）。
      _barFormSeeding = true;
      kSecondaryPlayerEnabled.value = effective;
      _barFormSeeding = false;
    }
  }

  /// 启动时从持久化载入进度指示开关，写入全局 [kSecondaryPlayerProgressEnabled]
  /// （宿主自己订阅，无需本 State 监听）。
  Future<void> _loadSecondaryPlayerProgress() async {
    final enabled = await SettingsRepository().getSecondaryPlayerProgress();
    if (!mounted) return;
    if (kSecondaryPlayerProgressEnabled.value != enabled) {
      kSecondaryPlayerProgressEnabled.value = enabled;
    }
  }

  /// 启动时从持久化载入进度条波浪开关，写入全局 [kSeekBarWaveEnabled]
  /// （MD3 播放页的 ListenableBuilder 自己订阅，无需本 State 监听）。
  Future<void> _loadSeekBarWaveEnabled() async {
    final enabled = await SettingsRepository().getSeekBarWaveEnabled();
    if (!mounted) return;
    if (kSeekBarWaveEnabled.value != enabled) {
      kSeekBarWaveEnabled.value = enabled;
    }
  }

  /// 启动时从持久化载入封面阴影强度，写入全局 [kCoverShadowIntensity]
  /// （两个播放页的封面包装层自己订阅，无需本 State 监听）。
  Future<void> _loadCoverShadowStrength() async {
    final intensity = await SettingsRepository().getCoverShadowStrength();
    if (!mounted) return;
    if (kCoverShadowIntensity.value != intensity) {
      kCoverShadowIntensity.value = intensity;
    }
  }

  /// 启动时从持久化载入宽屏「横屏控制面板独立页」开关，写入全局
  /// [kLandscapeDetachedControlsEnabled]
  /// （两个 full_player 的 _syncTabLayout 监听它，无需本 State 监听）。
  Future<void> _loadLandscapeDetachedControls() async {
    final enabled = await SettingsRepository().getLandscapeDetachedControls();
    if (!mounted) return;
    if (kLandscapeDetachedControlsEnabled.value != enabled) {
      kLandscapeDetachedControlsEnabled.value = enabled;
    }
  }

  /// 启动时从持久化载入顶栏「胶囊按钮收缩」开关，写入全局
  /// [kTopBarPillCollapseEnabled]（顶栏尾部组件订阅它，无需本 State 监听）。
  Future<void> _loadTopBarPillCollapse() async {
    final enabled = await SettingsRepository().getTopBarPillCollapse();
    if (!mounted) return;
    if (kTopBarPillCollapseEnabled.value != enabled) {
      kTopBarPillCollapseEnabled.value = enabled;
    }
  }

  /// 启动时从持久化载入「顶栏页签圆点」开关，写入全局 [kTopBarTabDotsEnabled]
  /// （播放页的顶栏与底部控制列各自订阅它，无需本 State 监听）。
  Future<void> _loadTopBarTabDots() async {
    final enabled = await SettingsRepository().getTopBarTabDots();
    if (!mounted) return;
    if (kTopBarTabDotsEnabled.value != enabled) {
      kTopBarTabDotsEnabled.value = enabled;
    }
  }

  /// 启动时从持久化载入「一级页面是否也用悬浮底栏」，写入全局
  /// [kSecondaryPlayerOnPrimaryPages]。本 State 监听它来切换常驻条的承载位置。
  Future<void> _loadSecondaryPlayerOnPrimary() async {
    final enabled = await SettingsRepository().getSecondaryPlayerOnPrimary();
    if (!mounted) return;
    if (kSecondaryPlayerOnPrimaryPages.value != enabled) {
      // 同 [_loadSecondaryPlayerEnabled]：冷启动播种吸附端点，不播交棒。
      _barFormSeeding = true;
      kSecondaryPlayerOnPrimaryPages.value = enabled;
      _barFormSeeding = false;
    }
  }

  /// 启动时从持久化载入「二级页面是否收起底部导航栏」，写入全局
  /// [kHideNavBarOnSecondaryPages]（默认 true = 隐藏）。
  Future<void> _loadHideNavBarOnSecondaryPages() async {
    final hide = await SettingsRepository().getHideNavBarOnSecondaryPages();
    if (!mounted) return;
    if (kHideNavBarOnSecondaryPages.value != hide) {
      kHideNavBarOnSecondaryPages.value = hide;
    }
  }

  void _onHideNavBarOnSecondaryChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 启动时从持久化载入封面流歌单源，写入全局 [kCoverFlowSource]。
  ///
  /// 无需监听运行时变更：CoverFlowPage 自己 addListener 订听通知器，
  /// 设置页切换后封面流页即时响应，不依赖本 State。
  Future<void> _loadCoverFlowSource() async {
    final raw = await SettingsRepository().getCoverFlowSourceRaw();
    final source = CoverFlowSource.tryParse(raw);
    if (kCoverFlowSource.value != source) {
      kCoverFlowSource.value = source;
    }
  }

  /// 启动时载入悬浮播放器停靠位；未持久化过则按设备形态取默认
  /// （手机 center、Pad right，与产品约定一致）。
  Future<void> _loadSecondaryPlayerDock() async {
    final raw = await SettingsRepository().getSecondaryPlayerDockRaw();
    if (!mounted) return;
    final side = SecondaryPlayerDockSide.tryParse(raw) ??
        (isPadLayout(context)
            ? SecondaryPlayerDockSide.right
            : SecondaryPlayerDockSide.center);
    if (kSecondaryPlayerDock.value != side) {
      kSecondaryPlayerDock.value = side;
    }
  }

  /// 桌面外壳开关变化（启动载入 / 设置页切换）→ 重建整棵子树，
  /// 让 [isDesktopLayout] 分支（外壳选择、双栏导航、探索列数等）随之切换。
  void _onDesktopModeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 处理 shortcut 入口的 tab 切换请求。
  /// 按 tab id 解析实际索引（tab 可排序/隐藏）：
  /// - tab 可见：切主 tab；
  /// - tab 被隐藏：以二级页面路由打开（与 LaunchPad 隐藏 tab 点击行为一致）。
  void _handleShortcutTabRequest() {
    final tabId = shortcutTabRequest.value;
    if (tabId == null || tabId.isEmpty) return;
    shortcutTabRequest.value = null;
    final tabConfig = context.read<TabConfigProvider>();
    if (tabConfig.visibleIndexOf(tabId) >= 0) {
      _switchToTab(tabId);
    } else {
      _openTabAsPage(tabId);
    }
  }

  /// 消费文件管理器「用其他应用打开」的音频请求：
  /// 校验文件 → 等引擎就绪 → 读元数据构建 Song → 播放 → push 播放器页。
  Future<void> _handleExternalMediaRequest() async {
    final request = externalMediaRequest.value;
    if (request == null) return;
    externalMediaRequest.value = null;
    debugPrint('[ExtMedia] 消费请求: ${request.path}');

    final service = ExternalMediaIntentService.instance;
    if (!service.isPathReadable(request.path)) {
      debugPrint('[ExtMedia] 文件不可读: ${request.path}');
      showToast('无法播放：文件不存在或不可访问');
      return;
    }

    final player = context.read<PlayerProvider>();
    // 音频引擎异步初始化（冷启动早期可能未就绪），必须先等待，
    // 否则 playSong 会因 _audioService 为 null 静默跳过实际播放
    debugPrint('[ExtMedia] 等待 audioReady...');
    await player.audioReady;
    if (!mounted) {
      debugPrint('[ExtMedia] audioReady 后已 unmounted');
      return;
    }
    debugPrint('[ExtMedia] audioReady 完成');

    final meta = await service.readMetadata(request.path);
    if (!mounted) {
      debugPrint('[ExtMedia] readMetadata 后已 unmounted');
      return;
    }
    final song = service.buildSong(request, meta);
    debugPrint('[ExtMedia] 播放: ${song.title}');

    // 一起听房主：从文件管理器打开的本机文件无法加入房间歌单，明确拒绝，
    // 避免推起播放器页却处于「本地在响、成员跟不了」的半同步状态
    if (_interceptRoomOwnerLocalPlayback(song)) {
      debugPrint('[ExtMedia] 房主房间内拒绝播放本地文件');
      return;
    }

    // fire-and-forget：冷启动早期 playSong 的 Future 可能长时间不完成，
    // 若 await 会导致后续 push 播放器页被永久阻塞。
    unawaited(player.playSong(song));
    if (!mounted) {
      return;
    }

    // 播放器页已在栈顶（如播放页开着时再次外部打开另一首歌）则只切歌不重复 push
    openFullPlayer(context);
  }

  /// LaunchPad 导航：切换到指定 tab（仅对已可见的 tab 生效）。
  /// 与 onDestinationSelected 相同的守卫：FullPlayer 在栈顶时忽略。
  void _switchToTab(String tabId) {
    if (isFullPlayerOnTop) return;
    final index = context.read<TabConfigProvider>().visibleIndexOf(tabId);
    if (index < 0) return;
    setState(() {
      _selectedIndex = index;
    });
  }

  /// LaunchPad 长按启用：先启用隐藏的 tab，再切换到该 tab。
  /// 与 [toggleTabVisibility] 的差异：这是 LaunchPad 专属入口，
  /// 隐藏 tab 只有在 LaunchPad 中长按才会被启用（点击不启用）。
  void _enableAndSwitchToTab(String tabId) {
    if (isFullPlayerOnTop) return;
    final tabConfig = context.read<TabConfigProvider>();
    if (tabConfig.hiddenTabs.contains(tabId)) {
      // toggleTabVisibility 内部先同步更新 hiddenTabs 再异步持久化，
      // 调用返回后 visibleIndexOf 即可拿到正确索引，无需等待
      // ignore: discarded_futures
      tabConfig.toggleTabVisibility(tabId);
    }
    _switchToTab(tabId);
  }

  /// LaunchPad 点击隐藏 tab：以二级页面路由打开对应功能页（不切换主 tab）。
  /// 推到当前 tab 的中央栈（内层 Navigator），深度观察者上报二级态 → 底栏播放
  /// 收起动画；壳层不在（桌面布局 / 首帧前）时回退根 Navigator 直接覆盖。
  void _openTabAsPage(String tabId) {
    final pushed = _responsiveShellKey.currentState
        ?.pushCurrentTabRoute<void>((_) => _pageForTabAsRoute(tabId));
    if (pushed != null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => _pageForTabAsRoute(tabId)),
    );
  }

  /// tabId → 可作为二级路由打开的页面（复用主 tab 页面，去掉主 tab 专属参数）。
  ///
  /// 二级路由页统一挂悬浮播放器（[SecondaryMiniPlayerHost]）：
  /// - 二级路由（`route.isFirst == false`）→ 宿主渲染悬浮播放栏；
  /// - 页面若自身已包 [SecondaryMiniPlayerHost]（如 DiscoverPage / ChartsPage），
  ///   内层宿主检测到外层作用域后自动退化透传，不会双份；
  /// - 设置页除外：不挂播放栏，保持纯设置界面。
  ///
  /// 一级 tab 形态由 [_MainLayout] 底部常驻 [MiniPlayer] 承载（见 [_buildBody]）；
  /// 悬浮 vs 常驻的判定复用标题对齐同一路由栈判据（见
  /// `page_title_alignment.dart` 的 `isSecondaryRoutePage`）。
  Widget _pageForTabAsRoute(String tabId) {
    final Widget page;
    switch (tabId) {
      case 'discover':
        page = const DiscoverPage();
        break;
      case 'coverflow':
        page = const CoverFlowPage();
        break;
      case 'library':
        page = const LibraryPage();
        break;
      case 'favorites':
        page = const FavoritesPage();
        break;
      case 'fm':
        page = const PersonalFmPage();
        break;
      case 'search':
        page = const SearchPage();
        break;
      case 'charts':
        page = const ChartsPage();
        break;
      case 'ip':
        page = const IpPage();
        break;
      case 'recognition':
        page = const SongRecognitionPage();
        break;
      case 'audiobook':
        page = const AudiobookPage();
        break;
      case 'scene':
        page = const ScenePage();
        break;
      case 'channel':
        page = const ChannelPage();
        break;
      case 'brush':
        page = const BrushPage();
        break;
      case 'listen_together':
        page = const ListenTogetherPage();
        break;
      case 'settings':
        page = const SettingsPage();
        break;
      default:
        page = const SizedBox.shrink();
    }
    // 设置页不挂播放栏，其余二级路由页统一挂悬浮播放器宿主。
    if (tabId == 'settings') {
      // 常驻条形态（悬浮播放器关）下，底部常驻 MiniPlayer 在壳层之外、本路由
      // 盖不住 —— 包装置位后由主布局隐藏，保持「设置页无播放栏」的原有行为。
      return ResidentBarSuppressor(child: page);
    }
    // tabId 照传：push 出来的路由 `isFirst == false`，宿主按标题对齐判据仍归为
    // 二级页面（可收缩），传值只为让两处口径同源、便于日志对照。
    final hosted = SecondaryMiniPlayerHost(tabId: tabId, child: page);
    // LaunchPad「打开为页面」/快捷方式不经 tab 壳层：双栏白名单页自带双栏壳，
    // 详情入口（openDetail）才有作用域可分派进右栏；非白名单页保持整屏页面。
    if (kTwoPaneTabs.contains(tabId)) {
      return TwoPanePage(child: hosted);
    }
    return hosted;
  }

  /// 词幕连接失败（原生侧重试耗尽 → connect_failed）回调：弹窗提示用户。
  /// 只在失败标记置位时触发一次，弹窗期间忽略重复事件。
  void _onLyriconStateChanged() {
    if (!LyriconProviderService.instance.connectFailed) return;
    if (_lyriconFailDialogShown) return;
    _lyriconFailDialogShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showLyriconConnectFailedDialog();
    });
  }

  /// 词幕连接失败提示弹窗（用根 Navigator 的 context，任何页面都能弹出）。
  Future<void> _showLyriconConnectFailedDialog() async {
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) {
      _lyriconFailDialogShown = false;
      return;
    }
    await showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('词幕连接失败'),
        content: const Text('多次尝试连接词幕服务失败，请确认已开启词幕（Lyricon），检查设备上的词幕服务是否正常运行后重试。'),
        actions: [
          TextButton(
            onPressed: () {
              LyriconProviderService.instance.connectFailed = false;
              Navigator.of(dialogCtx).pop();
            },
            child: const Text('知道了'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogCtx).pop();
              // 重新启用触发原生侧重新注册，重试逻辑在原生端（AudioPlaybackService）
              // ignore: discarded_futures
              LyriconProviderService.instance.setEnabled(true);
            },
            child: const Text('重试'),
          ),
        ],
      ),
    );
    _lyriconFailDialogShown = false;
  }

  /// 一起听听众：起播前是否需要弹确认窗（同步判定）。
  ///
  /// 判定口径见 `shouldPromptGuestPlay`：不在房间/房主/房间自己的跟随装载/
  /// 本地文件一律 false。**保持同步**——它运行在播放器起播链路的最前面。
  bool _shouldConfirmRoomGuestPlay(Song song) {
    final session = context.read<ListenTogetherProvider>().session;
    if (session == null) return false;
    return shouldPromptGuestPlay(
      inRoom: !session.closed,
      isOwner: session.isOwner,
      isTakeoverTarget: session.isRoomTakeoverTarget(song),
      canOrder: canOrderSongIntoRoom(song),
    );
  }

  /// 一起听听众：起播确认窗。返回 true 表示允许继续起播。
  ///
  /// - 脱离房间播放 → 置脱离标记（幂等）后放行，由调用方正常起播；
  /// - 申请点歌 → 发起点歌请求，并**放弃本次本地播放**（房间继续播原曲）；
  /// - 取消 → 放弃本次本地播放，房间与播放器现状不变。
  ///
  /// 用全局 [appNavigatorKey] 取 context，任何页面都能弹（与词幕失败弹窗同款）。
  Future<bool> _confirmRoomGuestPlay(Song song) async {
    final session = context.read<ListenTogetherProvider>().session;
    // 同步判定到弹窗之间房间可能已解散/已换会话：这里再兜一次
    if (session == null || session.closed || session.isOwner) return true;
    if (_roomGuestPlayDialogOpen) return true;
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return true;
    _roomGuestPlayDialogOpen = true;
    final GuestPlayChoice choice;
    try {
      choice = await showGuestPlayConfirmDialog(
        context: ctx,
        song: song,
        roomName: session.roomName,
        alreadyDetached: session.playbackDetached,
      );
    } finally {
      _roomGuestPlayDialogOpen = false;
    }
    switch (choice) {
      case GuestPlayChoice.detachAndPlay:
        // 幂等：已脱离时重复置位无副作用
        session.detachIfPlayingOutside(song);
        return true;
      case GuestPlayChoice.orderSong:
        try {
          await session.orderSong(RoomSong.fromSong(song));
        } catch (_) {
          // orderSong 内部已 toast「点歌失败」并 rethrow；此处吞掉避免未捕获异常
        }
        return false;
      case GuestPlayChoice.dismissed:
        return false;
    }
  }

  /// 一起听房主播放守卫：返回 true 表示已拦截，调用方不得起播。
  ///
  /// 房主在房间里是播放权威，每次起播都会上报服务端让成员跟随；房间歌单外
  /// 的曲目（本地文件没有可上报的上游 hash）若照播，只有房主本地在响，
  /// 成员会跟着拿到无法解析的曲目。这里统一拦截并给出可操作的提示。
  ///
  /// 房主在房间歌单里点播同曲时顺带转发为切歌（成员跟随），并同时拦下
  /// 调用方自身的播放，避免房间会话与调用方把同一首播放两遍。
  bool _interceptRoomOwnerLocalPlayback(Song song) {
    final session = context.read<ListenTogetherProvider>().session;
    // 听众在房间外点播其他音乐 → 进入脱离态（不拦截播放，只停止房间接管）
    if (session != null && !session.isOwner) {
      session.detachIfPlayingOutside(song);
      return false;
    }
    if (session == null || !session.isOwner) return false;
    // 房间会话自己的接管起播（ownerSwitchSong→_playRoomSong→playSong）也会
    // 进入守卫：歌单内必命中 handledByRoom，若再路由回 ownerPlaySong→
    // ownerSwitchSong 会无限递归（切歌→守卫→切歌→…）且外层 playSong 永远
    // 被拦下 → 永不起播。接管窗口内直接放行，上报由房间会话自己完成。
    if (session.isRoomTakeoverPlaybackActive) return false;
    switch (session.ownerPlaySong(song)) {
      case OwnerPlayRejection.handledByRoom:
        // 已由房间会话切歌并上报，调用方必须停手
        return true;
      case OwnerPlayRejection.noRoom:
        // 会话已失效：放行普通播放
        return false;
      case OwnerPlayRejection.notInRoom:
        showToast('房间里只能播放房间歌单中的在线歌曲，请先在「歌单」中点歌或切歌', long: true);
        return true;
    }
  }

  /// 一起听：把本地播放态变化转报房间。
  ///
  /// 房主的播放态变化上报服务端让成员跟随；听众的暂停/恢复则置上/清除
  /// 本机暂停豁免标记。房间自身的远端纠偏已被
  /// [PlayerProvider.suppressPlaybackNotify] 挡在门外，
  /// 所以这里收到的都是真实的用户操作。
  void _forwardPlaybackStateToRoom(bool playing) {
    final session = context.read<ListenTogetherProvider>().session;
    if (session == null) return;
    // 听众：播放器任意入口（迷你/全屏播放器、耳机、通知栏）的暂停/恢复都是
    // 「本机暂停意图」——暂停置豁免标记（轮询不再自动拉回播放），恢复清除标记
    // 并立即强制同步追上房间进度。远端纠偏引发的播放态变化已被
    // PlayerProvider.suppressPlaybackNotify 挡住，不会走到这里，无回声风险。
    if (!session.isOwner) {
      if (playing) {
        unawaited(session.guestResume());
      } else {
        session.guestPause();
      }
      return;
    }
    session.ownerSetPlaying(playing);
  }

  /// 一起听：把用户拖动进度转交给房间。
  ///
  /// 房主上报 action=2 让成员跟随；听众拖动 = 显式偏离房间进度 → 进入
  /// 脱离态（本地从拖动位置自由播放，远端不再接管），恢复跟随走房间页
  /// 中央按钮 / 广场横幅的 resumeRoomPlayback。
  void _forwardSeekToRoom(int positionMs) {
    final session = context.read<ListenTogetherProvider>().session;
    debugPrint('[ListenTogether] 用户 seek 通告: ${positionMs}ms '
        'session=${session == null ? "null" : (session.isOwner ? "房主" : (session.playbackDetached ? "已脱离" : "跟随中"))}');
    if (session == null) return;
    if (session.isOwner) {
      session.ownerSeek(positionMs);
    } else {
      session.detachBySeek();
    }
  }

  void _showLoginRequiredDialog() {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('请先登录'),
        content: const Text('播放音乐需要登录账号,是否前往登录?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(
                context,
                rootNavigator: true,
              ).push(MaterialPageRoute(builder: (_) => const LoginPage()));
            },
            child: const Text('去登录'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabConfig = context.watch<TabConfigProvider>();
    final visibleTabs = tabConfig.visibleTabs;

    // 安全守卫：如果当前选中索引超出可见 tab 范围，重置到最后一个
    if (_selectedIndex >= visibleTabs.length) {
      _selectedIndex = visibleTabs.length - 1;
      if (_selectedIndex < 0) _selectedIndex = 0;
    }

    // 动态生成导航目标
    final destinations = <NavigationDestination>[];
    for (var i = 0; i < visibleTabs.length; i++) {
      destinations.add(_buildDestination(visibleTabs[i], i));
    }
    final railDestinations = visibleTabs.map(_buildRailDestination).toList();
    final drawerDestinations = visibleTabs
        .map(_buildDrawerDestination)
        .toList();

    // 封面流页横屏沉浸：由「当前 tab + 方向 + 用户长按请求」统一判定。
    // 横屏默认显示 tab 栏，用户长按封面流页面进入沉浸（隐藏 tab 栏），
    // 沉浸中按返回键恢复。判定与页面生命周期无关，
    // 保证「在封面流页内竖屏→横屏旋转」也能正确进入/退出沉浸。
    final safeIndex = _selectedIndex.clamp(0, visibleTabs.length - 1);
    final currentTab = visibleTabs[safeIndex];
    final immersive =
        currentTab.id == 'coverflow' &&
        MediaQuery.orientationOf(context) == Orientation.landscape &&
        kCoverFlowImmersive.value;
    _syncImmersiveMode(immersive);

    // 底栏形态目标会随「当前 tab / tab 配置 / 两个形态开关」变化，在帧末统一
    // 重算一次（幂等）。**必须排到帧末**：本 State 是浮层所在 Stack 的
    // 后代，同步写全局进度会在同帧标记祖先 dirty（见 [_publishBarFormProgress]）。
    //
    // 帧末重算只兜底两类：切 tab（[tabSwitch]，播 260ms 交棒）与其余顺带重算
    // （[ambient] 吸附端点）。导航与设置切换有各自的显式入口（[_onPageRouteEvent]
    // / [_onBarFormSettingChanged]），不走这里，避免「目标没变却被当导航」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncBarFormTarget();
    });

    // 一级页面返回拦截：
    // 1) PopScope 拦截系统返回手势 / 物理返回键，canPop=false → 触发 onPopInvoked
    // 2) 封面流沉浸中：返回键先恢复 tab 栏（退出沉浸），不弹退出确认
    // 3) 否则双击返回回到手机桌面：首次返回 Toast 提示，3 秒内再按一次
    //    走 moveTaskToBack 挂后台（不杀进程、不停播放器、不停本地 Rust 服务器）
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        // 上滑拖拽展开中：返回键先收起覆盖层，回到 MiniPlayer
        if (playerDragActive.value) {
          playerDragActive.value = false;
          playerExpansion.value = 0.0;
          return;
        }
        // 桌面布局：先回退当前 Tab 的中央内容栈（详情页返回），空栈才继续。
        if (isDesktopLayout(context) &&
            (await _desktopShellKey.currentState?.maybePop() ?? false)) {
          return;
        }
        if (!isDesktopLayout(context) &&
            (await _responsiveShellKey.currentState?.maybePop() ?? false)) {
          return;
        }
        if (!mounted) return;
        if (immersive) {
          kCoverFlowImmersive.value = false;
        } else if (safeIndex != 0) {
          // 主导航页面先返回首页，只有首页继续执行双击返回退出。
          debugPrint('[MainNavigation] back tab=${currentTab.id} -> home');
          setState(() => _selectedIndex = 0);
          _exitResetTimer?.cancel();
          _exitPressed = false;
        } else {
          _onBackPressedForExit();
        }
      },
      child: AbsorbPointer(
        absorbing: _isExiting,
        child: AnimatedBuilder(
          animation: _exitController,
          builder: (context, child) {
            final size = MediaQuery.sizeOf(context);
            final offset = _exitOffset.value;
            // 微信风格：以左上角为锚点缩小到图标大小（0.1），
            // 同时向右下角位移（宽高各 70%）并渐隐；
            // 背景保持透明，缩小后露出系统桌面（FlutterView + windowBackground 透明）
            return Transform.translate(
              offset: Offset(
                size.width * 0.7 * offset.dx,
                size.height * 0.7 * offset.dy,
              ),
              child: Transform.scale(
                scale: _exitScale.value,
                alignment: Alignment.topLeft,
                child: Opacity(
                  opacity: _exitOpacity.value,
                  child: child,
                ),
              ),
            );
          },
          child: isDesktopLayout(context)
              ? DesktopShell(
                  key: _desktopShellKey,
                  visibleTabs: visibleTabs,
                  selectedIndex: _selectedIndex,
                  railDestinations: railDestinations,
                  pageBuilder: _buildPageForTab,
                  header: ValueListenableBuilder<bool>(
                    valueListenable: KugouApiClient.localServerAvailable,
                    builder: (context, available, _) => available
                        ? const SizedBox.shrink()
                        : LocalServerDownBanner(onRetry: KugouApiServer.start),
                  ),
                  onDestinationSelected: (index) {
                    if (isFullPlayerOnTop) return;
                    setState(() {
                      _selectedIndex = index;
                    });
                  },
                )
              : ResponsiveScaffold(
                  destinations: destinations,
                  railDestinations: railDestinations,
                  drawerDestinations: drawerDestinations,
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: (index) {
                    // 守卫：FullPlayer 在栈顶时（展开进度 > 0.5），忽略 tab 切换，
                    // 避免与 FullPlayer 动画叠加导致状态混乱。
                    if (isFullPlayerOnTop) {
                      return;
                    }
                    setState(() {
                      _selectedIndex = index;
                    });
                  },
                  // 沉浸（封面流横屏）恒收起；停在二级页面（及以后）时按设置项决定
                  // （「二级页面隐藏菜单底栏」，默认隐藏）。二级判定由 ResponsiveShell
                  // 根据路由栈及详情面板上报；侧栏同样
                  // 在二级页面收起，只是不受该设置影响（设置只管竖屏底栏）。
                  hideNavigation:
                      immersive ||
                      (_secondaryPageOnTop &&
                          kHideNavBarOnSecondaryPages.value),
                  hideRailNavigation: immersive || _secondaryPageOnTop,
                  body: _buildBody(context, visibleTabs, immersive),
                ),
        ),
      ),
    );
  }

  /// 封面流横屏沉浸：同步「实际生效」标志并设置系统栏沉浸模式。
  /// [immersive] 已由调用方按「tab + 方向 + 用户请求」算好；
  /// 状态变化时调用，非沉浸时恢复默认系统栏。
  /// 置位 [kCoverFlowImmersiveActive] 会顺带触发常驻条的收起 listener
  /// （见 [_syncMiniPlayerHide]），与底栏 `hideNavigation` 用的是同一个 `immersive`。
  void _syncImmersiveMode(bool immersive) {
    if (_immersiveSynced == immersive) return;
    _immersiveSynced = immersive;
    kCoverFlowImmersiveActive.value = immersive;
    // build 阶段不直接调用平台 channel，推迟到帧末执行
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (immersive) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        // 退出沉浸回到主界面的 edgeToEdge（与 _SystemUiUpdater 一致），
        // 先 manual 显式 show 一次：部分设备从 immersiveSticky 直接切
        // edgeToEdge 时系统栏不会自动重新显示。
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    });
  }

  /// 当前选中的 tab id（列表为空返回 null）。
  String? _currentTabId(List<TabItem> visibleTabs) {
    if (visibleTabs.isEmpty) return null;
    return visibleTabs[_selectedIndex.clamp(0, visibleTabs.length - 1)].id;
  }

  /// 常驻播放条的承载位置：总开关关闭时由本壳层最外层承载（所有页面共用一条，
  /// 宿主 `ownsBottomBar` 会抑制各页自补的那条）；总开关开但一级页面退回常驻条时，
  /// 改由每个 tab 根内容底部的 [PrimaryPagePersistentBar] 槽承载 —— 挂在壳层底部
  /// 感知不到 tab 内层 push 出来的二级页面，会与二级页的悬浮条同屏并存。
  ///
  /// [ResponsiveShell.onSecondaryRouteChanged] 上报当前 tab 是否停在二级页面
  /// （及以后）：底栏是本 Scaffold 的 `bottomNavigationBar`，在每 tab 内层 Navigator
  /// 之外，内层页面盖不住它，只能靠 [_secondaryPageOnTop] 收起；回到一级页面时自动恢复。
  void _onSecondaryRouteChanged(bool secondary) {
    if (!mounted || _secondaryPageOnTop == secondary) return;
    setState(() => _secondaryPageOnTop = secondary);
    // 与底栏收起同一帧驱动常驻条动画（设置页开在栈顶时一起沉底）。
    _syncMiniPlayerHide();
  }

  /// 常驻 MiniPlayer 的收起目标，四项输入任一成立即收起：
  /// - [kSecondaryPlayerEnabled]：悬浮播放器形态下它本就不存在；
  /// - [kCoverFlowImmersiveActive]：封面流横屏沉浸生效时（由 [_syncImmersiveMode]
  ///   在同一处 rebuild 写入，底栏的 `hideNavigation` 读的是同一个 `immersive`），
  ///   常驻条同样进入收起目标，与底栏走同一条 260ms 通道；
  /// - [kSuppressResidentMiniPlayer] **且** [_secondaryPageOnTop]：二级路由形态的设置页
  ///   停在当前 tab 栈顶时收起，合取的必要性见该 notifier 的文档。
  bool get _residentMiniPlayerHidden =>
      kSecondaryPlayerEnabled.value ||
      kCoverFlowImmersiveActive.value ||
      (kSuppressResidentMiniPlayer.value && _secondaryPageOnTop);

  /// 把常驻条收起动画驱动到目标态（幂等）。四项输入（悬浮开关、沉浸标志、设置页
  /// 置位 notifier + 二级上报）任一变化都会走到这里（前三项经 listener，末项经
  /// [_onSecondaryRouteChanged]）；与底栏的 `_chromeHide` 共用同一 rebuild 帧起止，
  /// 时长与曲线完全一致，视觉上同步收展。
  ///
  /// 沉浸项的口径说明：进入沉浸的这一次收起**看不见动画** —— [_buildBody] 的
  /// `if (!immersive)` 会把常驻条子树整块摘掉；目标态在此处仍要置位，是为了
  /// 退出沉浸时子树重新挂上后动画从收起端点反向播放（与底栏同一条控制器、
  /// 同一 260ms），并保证 `_miniPlayerHideTarget` 与子树在场时的视觉状态不背离。
  void _syncMiniPlayerHide() {
    if (!mounted) return;
    final hide = _residentMiniPlayerHidden;
    // 幂等判据比较"目标态"而非 `status == completed`：动画正在 forward 时
    // status 是 AnimationStatus.forward（`== completed` 为 false），此时目标若
    // 翻回"显示"(hide=false)，`false == false` 会提前 return、不执行 reverse，
    // 常驻条就此沉底不回。守卫换成目标态后，mid-flight 改目标也一定会重新驱动。
    if (_miniPlayerHideTarget == hide) return;
    _miniPlayerHideTarget = hide;
    if (_reduceMotion) {
      _miniPlayerHideController.value = hide ? 1.0 : 0.0;
    } else if (hide) {
      _miniPlayerHideController.forward();
    } else {
      _miniPlayerHideController.reverse();
    }
  }

  /// 底栏当前该落在哪种形态（true = 悬浮胶囊）。
  ///
  /// 三项输入见 [resolveBottomBarFormTarget] 的说明：
  /// - 悬浮总开关 [kSecondaryPlayerEnabled]；
  /// - 一级页面是否也用悬浮条 [kSecondaryPlayerOnPrimaryPages]；
  /// - 当前页是否「一级导航页」：判据与 `SecondaryMiniPlayerHost._buildHost` 用的是
  ///   同一个 `isPrimaryNavTab`（`tab.pinnedTitle` 且未被 push）。这里的 pushedRoute
  ///   事实取**导航时刻**的 [_formSecondaryOnTop]（不是推迟上报的
  ///   [_secondaryPageOnTop]，理由见该字段注释）。
  bool _resolveBarFormTargetIsCapsule() {
    // tv: TV 版强制关闭悬浮形态（[kSecondaryPlayerEnabled] 在 TV 载入时被钉成
    // false），本机制整段惰性 —— 目标恒 0、进度恒 0、浮层恒不渲染。
    if (kTvBuild) return false;
    final tabs = context.read<TabConfigProvider>().visibleTabs;
    final tab = tabs.isEmpty
        ? null
        : tabs[_selectedIndex.clamp(0, tabs.length - 1)];
    return resolveBottomBarFormTarget(
          floatingEnabled: kSecondaryPlayerEnabled.value,
          onPrimaryPages: kSecondaryPlayerOnPrimaryPages.value,
          pageIsPrimaryNav: isPrimaryNavTab(
            tab,
            pushedRoute: _formSecondaryOnTop,
          ),
        ) >=
        0.5;
  }

  /// 中央栈页面路由事件的**当下**回调（导航时刻，见
  /// [ResponsiveShell.onPageRouteEvent]）：立刻决定形态目标并驱动交棒，
  /// 让 `0<p<1` 的飞行窗口覆盖整个路由转场（会诊 D1/D3 的修复点）。
  ///
  /// **只有真正改变「当前 tab 是否停在 push 出来的页面上」这一事实的事件才算
  /// 导航**（push 进二级 / pop 回一级）。其余路由事件一律走 ambient 语义（吸附
  /// 端点、不播交棒）：新建 tab 的 Navigator 首路由（tab 配置装载/切 tab 时
  /// 懒建的栈）与 pushReplacement 都只是栈内幕，用户看到的形态没有因这次
  /// 路由事件而换（会诊 D3 的幻影翻转 ②）。
  void _onPageRouteEvent(
    bool hasPushedPage,
    Route<dynamic> route,
    Duration transition,
  ) {
    if (!mounted) return;
    final bool factChanged = hasPushedPage != _formSecondaryOnTop;
    _formSecondaryOnTop = hasPushedPage;
    if (!factChanged) {
      _syncBarFormTarget(cause: BarFormFlipCause.ambient);
      return;
    }
    _syncBarFormTarget(
      cause: BarFormFlipCause.navigation,
      transition: transition,
      navRoute: route,
    );
  }

  /// 两个形态开关的用户切换（设置页直接写 notifier）。冷启动播种期间
  /// （[_barFormSeeding]）吸附端点，不播交棒。
  void _onBarFormSettingChanged() {
    _syncBarFormTarget(
      cause: _barFormSeeding
          ? BarFormFlipCause.ambient
          : BarFormFlipCause.settingsToggle,
    );
  }

  /// 重算目标形态并驱动一次性过渡（幂等）。
  ///
  /// [cause] 为空时按当前状态自动分级：切了 tab → [tabSwitch]；其余一切都是
  /// [ambient]（吸附端点）。输入变化来源与分级依据见 [BarFormFlipCause]。
  void _syncBarFormTarget({
    BarFormFlipCause? cause,
    Duration? transition,
    Route<dynamic>? navRoute,
  }) {
    if (!mounted) return;
    // tv: TV 版恒无形态翻转。前提由两处门控保证——形态总开关在装载处被强制 false
    // （`main.dart` 与 [_loadSecondaryPlayerEnabled] 的 `effective = kTvBuild ?
    // false : enabled`），设置页开关在 TV 下 `onChanged: null` 置灰不可点，故 TV
    // 的形态目标恒为常驻条。这里再显式早退一次：本方法的调用面（帧末顺带重算 /
    // 设置切换 / 路由事件）比目标解算 [_resolveBarFormTargetIsCapsule] 更广，显式
    // 门控让「TV 恒不翻转」这一 AGENTS §12 口径**不依赖**该解算内部那处 kTvBuild
    // 早退——它一旦被重构掉，这里会立刻退化成幻影翻转。kTvBuild 为 const，
    // 正常构建此分支被树摇剔除、零开销。
    if (kTvBuild) return;
    final int tabIndex = _selectedIndex;
    final bool tabChanged = tabIndex != _lastSyncedBarFormTabIndex;
    _lastSyncedBarFormTabIndex = tabIndex;
    final resolvedCause =
        cause ??
        (tabChanged ? BarFormFlipCause.tabSwitch : BarFormFlipCause.ambient);
    if (tabChanged) {
      // 切 tab 后形态事实换成新 tab 的中央栈（上一 tab 的 push 态不适用；
      // 此刻壳层里的深度事实是刚更新过的当下值）。
      _formSecondaryOnTop =
          _responsiveShellKey.currentState?.currentTabHasPushedPage() ?? false;
    }
    final target = _resolveBarFormTargetIsCapsule();
    if (target == _barFormTargetIsCapsule) return;
    _barFormTargetIsCapsule = target;
    if (_reduceMotion) {
      _snapBarFormToTarget();
      return;
    }
    switch (resolvedCause) {
      case BarFormFlipCause.navigation:
        // 交棒窗口 = 整段路由转场 + 随后的底栏收起/恢复（两端真身要等底栏
        // 落定才到结算端点，见 resolveMorphFlightDuration）。
        final duration = resolveMorphFlightDuration(
          transition: transition ?? Duration.zero,
          navWillToggle: _barFormNavWillToggle(),
        );
        if (target) {
          // push 方向：目的页的胶囊要等它构建（下一帧）才挂出来 —— 先起跑，
          // 帧末核对；核对不过（设置子页这类不挂播放条的页面）再吸附撤销。
          // 胶囊端点随二级页的底栏状态定：默认收底栏（胶囊贴到屏底净空）。
          _startBarFormFlight(
            duration,
            capsuleNavHiddenAtSettle: kHideNavBarOnSecondaryPages.value,
          );
          _verifyPushedPageHasCapsule(navRoute);
        } else {
          // pop 方向：被弹出的那一页此刻仍在树里，可直接核对它挂不挂播放条。
          if (!BottomBarMorphRegistry.instance.hasCapsuleForRoute(navRoute)) {
            _snapBarFormToTarget();
            return;
          }
          // 胶囊在这一侧是**被弹出的二级页**（当前结算形态），其底栏状态同样
          // 由该设置决定。
          _startBarFormFlight(
            duration,
            capsuleNavHiddenAtSettle: kHideNavBarOnSecondaryPages.value,
          );
        }
      case BarFormFlipCause.settingsToggle:
      case BarFormFlipCause.tabSwitch:
        // 这两条线的胶囊侧都在一级页（标题居中的 tab 根页 / 一级页面也用
        // 悬浮条）：底栏恒在场，胶囊端点要让出底栏槽位。
        _startBarFormFlight(
          kBottomChromeToggleDuration,
          capsuleNavHiddenAtSettle: false,
        );
      case BarFormFlipCause.ambient:
        _snapBarFormToTarget();
    }
  }

  /// 本次形态翻转之后，底栏（竖屏 NavigationBar）还会不会在转场收敛时起
  /// 260ms 收起/恢复动画 —— 交棒窗口据此顺延（竖屏底栏收起是唯一还要在
  /// 转场之后变几何的动作；横屏侧栏是瞬时 Offstage，不需要顺延）。
  bool _barFormNavWillToggle() =>
      (_formSecondaryOnTop && kHideNavBarOnSecondaryPages.value) !=
      (_secondaryPageOnTop && kHideNavBarOnSecondaryPages.value);

  /// 起一次交棒飞行：冻结常驻条端点快照（飞行期间浮层只认它）并驱动一次性
  /// 控制器到目标端点。
  ///
  /// [capsuleNavHiddenAtSettle]：胶囊侧（二级页面）在结算态是否收起了底栏 ——
  /// 决定胶囊端点的底部净空要不要多让一个底栏槽位（见 resolveCapsuleBodyRect）。
  void _startBarFormFlight(
    Duration duration, {
    required bool capsuleNavHiddenAtSettle,
  }) {
    BottomBarMorphRegistry.instance.freezeResidentRectForFlight(
      capsuleNavHiddenAtSettle: capsuleNavHiddenAtSettle,
    );
    _barFormController.duration = duration;
    if (_barFormTargetIsCapsule) {
      _barFormController.forward();
    } else {
      _barFormController.reverse();
    }
    // 同帧开启让位窗口（起跑入口都在事件回调 / 帧末回调，不在 build 期）：目的
    // 真身同帧 offstage，避免在动画首 tick 之前就按结算几何抢闸画出。
    _openBarFormFlight(_barFormTargetIsCapsule);
  }

  /// 直接吸附到目标端点（不走交棒窗口）：reduced-motion、冷启动播种、
  /// 目的页不挂播放条，以及一切没有导航事件的顺带重算。
  void _snapBarFormToTarget() {
    _barFormController.stop();
    BottomBarMorphRegistry.instance.clearFrozenResidentRect();
    void apply() {
      if (!mounted) return;
      // 吸附不走窗口：关窗（两端真身各归各位），再落端点。
      kBarFormFlightActive.value = false;
      _barFormController.value = _barFormTargetIsCapsule ? 1.0 : 0.0;
    }

    // build / layout 阶段写全局进度会 markNeedsBuild 祖先（"setState during
    // build"）：路由事件本都在事件回调里，但 Navigator 装首批路由会在挂载
    // （build）期间回调观察者 —— 那时吸附推迟到帧末，效果同帧可见。
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  /// 交棒飞行收敛（或被吸附）时解冻常驻条端点快照。
  void _onBarFormStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      // 收敛：关窗（两端真身各归各位）并解冻端点快照。
      kBarFormFlightActive.value = false;
      BottomBarMorphRegistry.instance.clearFrozenResidentRect();
    }
  }

  /// push 方向的目的端核对：目的形态是悬浮胶囊，而胶囊要等新页面构建
  /// （转场首帧）才挂出来。给一帧余量后仍找不到该路由的胶囊 → 这一页不挂
  /// 播放条（设置子页、二级路由形态的设置页），交棒没有落点，吸附撤销。
  ///
  /// 撤销发生在新页面刚入场的前两帧、浮层还贴在常驻条端点附近（p≈0），
  /// 与让位前的真身逐像素同值，视觉上无痕。
  void _verifyPushedPageHasCapsule(Route<dynamic>? route) {
    if (route == null) return;
    var attempts = 0;
    void check() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // 目的形态已被改回（又发生了导航）或核对通过：不再跟踪。
        if (!_barFormTargetIsCapsule) return;
        if (BottomBarMorphRegistry.instance.hasCapsuleForRoute(route)) return;
        if (attempts++ == 0) {
          check();
          return;
        }
        _snapBarFormToTarget();
      });
    }

    check();
  }

  /// 把过渡进度写进全局 notifier（浮层与两端真身订阅它）。
  ///
  /// 注意：本 State 是浮层所在 Stack 的**后代**，因此不能在本 State 的 build /
  /// didChangeDependencies 里同步写 —— 那会在同帧标记祖先 dirty（"markNeedsBuild
  /// during build"）。驱动入口都落在帧末 / 事件回调里。
  void _publishBarFormProgress() {
    kBottomBarFormProgress.value = _barFormCurve.value;
  }

  Widget _buildBody(
    BuildContext context,
    List<TabItem> visibleTabs,
    bool immersive,
  ) {
    // 主页（一级页面）与二级页面统一由悬浮播放器承载：整段 body 包进宿主后，
    // 开关开启时底部常驻 MiniPlayer 隐藏（下方 builder），避免两套播放器并存。
    // 沉浸态（封面流全屏浏览）透传 immersive，宿主不渲染悬浮条，保持全屏无遮挡。
    return SecondaryMiniPlayerHost(
      ownsBottomBar: true,
      immersive: immersive,
      // 宿主按「标题左对齐」判据识别一级页面（不回缩），需要当前 tab id。
      tabId: _currentTabId(visibleTabs),
      child: Column(
        children: [
          // 本地 API 服务器启动失败提示：在线内容全部不可用，但页面本身仍能渲染
          // 成空列表/转圈，用户无从判断原因。这里把状态显式摆到所有 tab 顶部。
          ValueListenableBuilder<bool>(
            valueListenable: KugouApiClient.localServerAvailable,
            builder: (context, available, _) => available
                ? const SizedBox.shrink()
                : LocalServerDownBanner(onRetry: KugouApiServer.start),
          ),
          Expanded(
            child: ResponsiveShell(
              key: _responsiveShellKey,
              visibleTabs: visibleTabs,
              selectedIndex: _selectedIndex,
              pageBuilder: _buildPageForTab,
              persistentBarBuilder: (tabId) =>
                  PrimaryPagePersistentBar(tabId: tabId),
              onSecondaryRouteChanged: _onSecondaryRouteChanged,
              // 导航时刻的形态信号（见 _onPageRouteEvent 与
              // ResponsiveShell.onPageRouteEvent 的说明）：底栏收起/常驻条隐藏
              // 继续走上面那条推迟上报，两者解耦。
              onPageRouteEvent: _onPageRouteEvent,
            ),
          ),
          // 封面流页横屏沉浸：隐藏 MiniPlayer，实现全屏浏览。
          // 沉浸下子树直接不挂载（收起动画看不见播放），但目标态仍经
          // [_residentMiniPlayerHidden] 的沉浸项置位，退出沉浸重新挂载时从收起
          // 端点反向播放，与底栏同一条 260ms 通道。
          // 二级路由形态的设置页开在当前 tab 栈顶时，常驻条与底栏同一节奏
          // 收起/展开（见 [_syncMiniPlayerHide]），沉底式收缩（底边贴住底栏
          // 槽位、顶缘被裁），与底栏「槽位收缩 + 下沉」同一视觉语言。
          if (!immersive)
            ListenableBuilder(
              listenable: kSecondaryPlayerEnabled,
              builder: (context, _) {
                // 悬浮播放器形态：常驻条不存在（形态切换保持瞬时，与原行为一致）。
                if (kSecondaryPlayerEnabled.value) {
                  return const SizedBox.shrink();
                }
                return AnimatedBuilder(
                  animation: _miniPlayerHide,
                  builder: (context, child) {
                    final t = _miniPlayerHide.value;
                    if (t <= 0) return child!;
                    if (t >= 1) return const SizedBox.shrink();
                    return ClipRect(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        heightFactor: 1 - t,
                        child: child,
                      ),
                    );
                  },
                  child: const ImeCollapse(child: MiniPlayer()),
                );
              },
            ),
        ],
      ),
    );
  }

  /// 二次返回退出：首次返回显示提示，3 秒内再次返回触发真正退出（不弹窗）。
  void _onBackPressedForExit() {
    if (_isExiting) return;
    if (kTvBuild) {
      unawaited(_confirmTvExit());
      return;
    }
    if (_exitPressed) {
      _exitResetTimer?.cancel();
      _exitPressed = false;
      _doExit();
      return;
    }
    _exitPressed = true;
    _showDoubleBackToast();
    _exitResetTimer?.cancel();
    _exitResetTimer = Timer(
      const Duration(seconds: 3),
      () {
        _exitPressed = false;
        _exitResetTimer = null;
      },
    );
  }

  /// 显示「再按一次返回桌面」提示（系统原生 Toast，非 SnackBar/弹窗）。
  void _showDoubleBackToast() {
    showToast('再按一次返回桌面');
  }

  /// TV：弹出退出确认；确认后走既有 [_doExit]（moveTaskToBack 挂后台，
  /// 后台播放与本地服务器保持运行）。
  Future<void> _confirmTvExit() async {
    final confirmed = await showTvExitConfirmDialog(context);
    if (!mounted) return;
    if (confirmed) {
      await _doExit();
    }
  }

  /// 双击返回后回到手机桌面（仅挂后台）：
  /// 不杀进程、不停播放器、不停本地 Rust 服务器，重新打开瞬时恢复。
  /// 优先走原生 [method 'moveToBack']（等同按 Home），
  /// 异常时兜底 [SystemNavigator.pop]（回桌面但保留后台进程与服务器）。
  Future<void> _doExit() async {
    if (_isExiting) return;
    _isExiting = true;
    try {
      await context.read<PlayerProvider>().flushPersistence();
      await const MethodChannel('com.md3music.md3music/task')
          .invokeMethod<void>('moveToBack');
    } catch (_) {
      await SystemNavigator.pop();
    } finally {
      _isExiting = false;
    }
  }

}

/// 底部 NavigationBar 的 tab 图标（胶囊由别处画，见下）。
///
/// **当前实现**：本类只负责**图标**，胶囊与回弹都在 `responsive_layout.dart` 的
/// `_CapsuleBounce`（两处口径互指，改任一处先看另一处）。
/// - 图标：**静态切换** —— [selected] 直接决定取 filled 还是 outlined
///   （见下方 `build`），不做淡入/位移，也不在弹跳过程中切换；
/// - 胶囊：`ResponsiveScaffold` 把 `icon` 整个包进 `_CapsuleBounce`，由它画
///   secondaryContainer 实心 StadiumBorder（64×32，与 M3 原生胶囊同规格），
///   原生 `NavigationIndicator` 经 `indicatorColor: Colors.transparent` 关掉
///   —— 原生那条是沿 `easeInOutCubicEmphasized` 的单轴 X 缩放 0.4 → 1.0
///   （SDK `navigation_bar.dart` 的 `NavigationIndicator.build`，行号随版本漂移
///   故不写死）；
/// - 回弹：**只作用于胶囊背景层**的 `Transform.scaleX`（图标保持不动）——
///   80ms `Curves.easeOutCubic` 拉伸 1 → 1.2，随后由 m3e_core 官方预设
///   `M3EMotion.standardPopup`（stiffness 1000 / damping 0.6，过冲 ≈9.5%）
///   弹簧弹回 1.2 → 1.0；一次性 Ticker，收敛即停，无常驻帧；
/// - 触发：点击（`_handleDestinationSelected`）或 selected false→true
///   （`_CapsuleBounce.didUpdateWidget`）；背景图模式下胶囊隐藏。
///
/// **文字行为**：由 `NavigationBarThemeData.labelBehavior` 控制，跟随用户在
/// 设置页「底部导航栏文字」的三档选择（始终显示 / 仅当前页 / 始终不显示，
/// 默认不显示）；`NavigationDestination.label` 传真实标题，既用于显示也用于
/// 无障碍朗读。
///
/// 不使用 NavigationDestination.selectedIcon（Flutter 原生内部是硬切）。
class _AnimatedTabIcon extends StatelessWidget {
  /// 类名沿用历史（早期确有动画），现行实现是静态切换，未改名以免牵动全部
  /// `destinations` 构造点。
  final bool selected;
  final IconData outlinedIcon;
  final IconData filledIcon;

  const _AnimatedTabIcon({
    required this.selected,
    required this.outlinedIcon,
    required this.filledIcon,
  });

  @override
  Widget build(BuildContext context) {
    // 公开版偏好：底部导航栏图标不做浮动/胶囊动画，直接静态切换，
    // 简洁、不跳动。
    return Icon(selected ? filledIcon : outlinedIcon);
  }
}
