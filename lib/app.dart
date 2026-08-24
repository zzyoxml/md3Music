import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:quick_actions/quick_actions.dart';

import 'core/layout/responsive_layout.dart';
import 'core/layout/ui_density.dart';
import 'core/services/lyricon_provider_service.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/motion_constants.dart';
import 'core/utils/artwork_color_extractor.dart';
import 'core/utils/app_toast.dart';
import 'core/widgets/app_background.dart';
import 'data/models/playlist.dart';
import 'services/kugou_api/kugou_api_client.dart';
import 'main.dart'
    show
        appNavigatorKey,
        handleShortcut,
        pendingShortcutType,
        shortcutTabRequest;
import 'modules/discover/discover_page.dart';
import 'modules/coverflow/coverflow_page.dart';
import 'modules/charts/charts_page.dart';
import 'modules/ip/ip_page.dart';
import 'modules/user/user_center_page.dart';
import 'modules/user/favorites_page.dart';
import 'modules/brush/brush_page.dart';

import 'modules/player/full_player.dart';
import 'modules/player/full_player_route.dart';
import 'modules/player/mini_player.dart';
import 'modules/player/player_drag_overlay.dart';
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
import 'providers/kugou_provider.dart';
import 'providers/library_provider.dart';
// ignore: unused_import  // 类型用于 ChangeNotifierProvider(create: ...) 的 T 推断
import 'providers/local_favorites_provider.dart';
import 'providers/player_provider.dart';
import 'providers/playlist_collection_notifier.dart';
import 'providers/device_provider.dart';
import 'providers/grid_columns_provider.dart';
import 'providers/shortcut_config_provider.dart';
import 'providers/tab_config_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/comment_display_provider.dart';
import 'services/kugou_server.dart';
import 'widgets/dlna_casting_overlay.dart';

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

  /// 可选扩展：额外注册的 Provider 列表（默认无，由私有构建注入，
  /// 用于注册私有功能 Provider）。
  final List<SingleChildWidget>? extraProviders;

  const MyApp({
    super.key,
    this.showOnboarding = false,
    this.showUserAgreement = false,
    this.extraProviders,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => DeviceProvider()),
        ChangeNotifierProvider(create: (_) => GridColumnsProvider()),
        ChangeNotifierProvider(create: (_) => PlayerProvider()),
        ChangeNotifierProvider(create: (_) => LibraryProvider()),
        ChangeNotifierProvider(create: (_) => KugouProvider()),
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
    });
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

  @override
  void dispose() {
    _shortcutConfig?.removeListener(_applyDesktopShortcuts);
    _playerProvider?.removeListener(_onPlayerChanged);
    _backgroundThemeProvider?.removeListener(_onBackgroundChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    // 当前生效的 fontFamily：system 模式为 null（让 Flutter 走系统字体链），
    // bundled/custom 模式为对应字体名。加载失败时降级为 null。
    final fontFamily = themeProvider.effectiveFontFamily;

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
          labelBehavior: themeProvider.navLabelBehavior,
        ),
        themeProvider,
      ),
      darkTheme: _applyBackgroundOverrides(
        AppTheme.darkThemeFromSeed(
          themeProvider.effectiveSeedColor,
          useOledBlack: themeProvider.useOledBlack,
          fontFamily: fontFamily,
          labelBehavior: themeProvider.navLabelBehavior,
        ),
        themeProvider,
      ),
      themeMode: themeProvider.themeMode,
      // 根据主题设置系统导航栏颜色
      builder: (context, child) {
        // 全局「显示大小」：整个 App 唯一的缩放点，页面侧一律直接写 dp。
        // 包在最外层，所以背景层、Navigator（全部路由）、Overlay（对话框 /
        // 底部弹层 / 菜单）、DLNA 与拖拽覆盖层都在作用域内。
        return DisplayScaleScope(
          scale: context.watch<ThemeProvider>().displayScale,
          child: _SystemUiUpdater(
            child: Stack(
              children: [
                // 全局背景层（主页/底层背景）：复用 AppBackground 组件。
                // 二级页面由路由过渡内嵌 AppBackground，随页面位移入场。
                Positioned.fill(child: AppBackground()),
                child!,
                const DlnaCastingOverlay(),
                // 上滑拖拽跟手覆盖层（在 Navigator 之上，拖拽期间显示预览）
                const PlayerDragOverlay(),
              ],
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
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  int _selectedIndex = 0;
  int _previousSelectedIndex = 0;

  /// 上一次同步的沉浸状态，避免重复调用 SystemChrome（幂等去重）。
  bool _immersiveSynced = false;

  /// 词幕连接失败弹窗展示中标记，防止连发 connect_failed 时重复弹窗。
  bool _lyriconFailDialogShown = false;

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
        // Tab 模式：隐藏页面自带 MiniPlayer，由 _MainLayout 统一提供全局 MiniPlayer
        page = const SearchPage(showMiniPlayer: false);
        break;
      case 'charts':
        page = const ChartsPage();
        break;
      case 'ip':
        page = const IpPage();
        break;
      case 'recognition':
        // Tab 模式：由 _MainLayout 统一提供全局 MiniPlayer，页面不自带
        page = const SongRecognitionPage(showMiniPlayer: false);
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
    // 未登录时尝试播放联网歌曲,弹出登录提示
    context.read<PlayerProvider>().onLoginRequired = _showLoginRequiredDialog;
    // 监听应用生命周期：detached（进程被系统销毁前的最后窗口）时尝试关停本地 API 服务器
    WidgetsBinding.instance.addObserver(this);
    // 监听 shortcut 入口的 tab 切换请求（来自 main.dart 的 handleShortcut）
    shortcutTabRequest.addListener(_handleShortcutTabRequest);
    // 监听封面流沉浸请求（长按切换 / 返回键恢复），变更时重算沉浸状态
    kCoverFlowImmersive.addListener(_onCoverFlowImmersiveChanged);
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
  void dispose() {
    _exitResetTimer?.cancel();
    _exitController.dispose();
    LyriconProviderService.instance.removeListener(_onLyriconStateChanged);
    kCoverFlowImmersive.removeListener(_onCoverFlowImmersiveChanged);
    shortcutTabRequest.removeListener(_handleShortcutTabRequest);
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

  /// LaunchPad 导航：切换到指定 tab（仅对已可见的 tab 生效）。
  /// 与 onDestinationSelected 相同的守卫：FullPlayer 在栈顶时忽略。
  void _switchToTab(String tabId) {
    if (isFullPlayerOnTop) return;
    final index = context.read<TabConfigProvider>().visibleIndexOf(tabId);
    if (index < 0) return;
    setState(() {
      _previousSelectedIndex = _selectedIndex;
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
  void _openTabAsPage(String tabId) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _pageForTabAsRoute(tabId)),
    );
  }

  /// tabId → 可作为二级路由打开的页面（复用主 tab 页面，去掉主 tab 专属参数）。
  ///
  /// 二级路由页统一在底部挂全局 MiniPlayer（与主 tab 模式一致）：
  /// - 页面自带 MiniPlayer 的（如 SearchPage）通过 showMiniPlayer: false 关闭，
  ///   避免与这里提供的重复；
  /// - 其余页面在 tab 模式下依赖 _MainLayout 的全局 MiniPlayer，作为二级路由
  ///   打开时没有该全局条，这里统一补上；
  /// - 设置页除外：不挂 MiniPlayer，保持纯设置界面。
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
        // 路由模式的 MiniPlayer 由本方法统一提供，关闭页面自带的以免重复
        page = const SearchPage(showMiniPlayer: false);
        break;
      case 'charts':
        page = const ChartsPage();
        break;
      case 'ip':
        page = const IpPage();
        break;
      case 'recognition':
        // 路由模式的 MiniPlayer 由本方法统一提供，关闭页面自带的以免重复
        page = const SongRecognitionPage(showMiniPlayer: false);
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
      case 'settings':
        page = const SettingsPage();
        break;
      default:
        page = const SizedBox.shrink();
    }
    // 设置页不挂 MiniPlayer，其余二级路由页统一挂载
    if (tabId == 'settings') return page;
    // removeBottom：底部小横条的 inset 已由下方 MiniPlayer 的 SafeArea 消费，
    // 若不去掉，page 内的滚动视图会按原 inset 再留一份，MiniPlayer 上方多出空白
    return Column(
      children: [
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeBottom: true,
            child: page,
          ),
        ),
        const MiniPlayer(),
      ],
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 当系统即将销毁应用进程时（包含后台划掉 / 系统回收），Flutter 会先收到 detached。
    // 此时同步触发 API 服务器关停：若进程随之被 kill 也无副作用；若进程仍存活则释放端口。
    if (state == AppLifecycleState.detached) {
      // 同步触发即可，Dart 端很快；不 await，避免阻塞 framework 销毁流程
      // ignore: discarded_futures
      KugouApiServer.stop();
    }
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

    // 一级页面返回拦截：
    // 1) PopScope 拦截系统返回手势 / 物理返回键，canPop=false → 触发 onPopInvoked
    // 2) 封面流沉浸中：返回键先恢复 tab 栏（退出沉浸），不弹退出确认
    // 3) 否则双击返回回到手机桌面：首次返回 Toast 提示，3 秒内再按一次
    //    走 moveTaskToBack 挂后台（不杀进程、不停播放器、不停本地 Rust 服务器）
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // 上滑拖拽展开中：返回键先收起覆盖层，回到 MiniPlayer
        if (playerDragActive.value) {
          playerDragActive.value = false;
          playerExpansion.value = 0.0;
          return;
        }
        if (immersive) {
          kCoverFlowImmersive.value = false;
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
          child: ResponsiveScaffold(
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
                  _previousSelectedIndex = _selectedIndex;
                  _selectedIndex = index;
                });
              },
              hideNavigation: immersive,
              body: _buildBody(context, visibleTabs, immersive),
              compactBody: _buildBody(context, visibleTabs, immersive),
              mediumBody: _buildBody(context, visibleTabs, immersive),
              expandedBody: _buildBody(context, visibleTabs, immersive),
            ),
          ),
        ),
    );
  }

  /// 封面流横屏沉浸：同步「实际生效」标志并设置系统栏沉浸模式。
  /// [immersive] 已由调用方按「tab + 方向 + 用户请求」算好；
  /// 状态变化时调用，非沉浸时恢复默认系统栏。
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

  Widget _buildBody(
    BuildContext context,
    List<TabItem> visibleTabs,
    bool immersive,
  ) {
    // 切换方向：横屏（侧边导航栏）用上下淡入，竖屏（底部导航栏）用左右滑动
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final useVerticalTransition = isLandscape;
    final goingRight = _selectedIndex > _previousSelectedIndex;

    // 安全守卫
    final safeIndex = _selectedIndex.clamp(0, visibleTabs.length - 1);
    final currentTab = visibleTabs[safeIndex];

    return Column(
      children: [
        // 本地 API 服务器启动失败提示：在线内容全部不可用，但页面本身仍能渲染
        // 成空列表/转圈，用户无从判断原因。这里把状态显式摆到所有 tab 顶部。
        ValueListenableBuilder<bool>(
          valueListenable: KugouApiClient.localServerAvailable,
          builder: (context, available, _) =>
              available ? const SizedBox.shrink() : const _LocalServerDownBanner(),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: M3ExpressiveMotion.defaultDuration,
            switchInCurve: const Interval(
              0.5,
              1.0,
              curve: M3ExpressiveMotion.expressiveEasing,
            ),
            // 退出曲线必须与进入曲线错开：旧页（outgoing）的 controller 是
            // reverse（1→0），Interval(0.5,1.0) 对反向值映射后旧页恰好在前半段
            // 淡出、新页在后半段淡入，避免新旧页同时过渡造成内容重叠/闪烁。
            switchOutCurve: const Interval(
              0.5,
              1.0,
              curve: M3ExpressiveMotion.expressiveEasing,
            ),
            transitionBuilder: (child, animation) {
              final isEntering = child.key == ValueKey(currentTab.id);

              if (useVerticalTransition) {
                // 侧边导航栏：基于 tab 顺序上下滑动
                final slideY = isEntering
                    ? (goingRight ? 0.1 : -0.1)
                    : (goingRight ? -0.1 : 0.1);
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: Offset(0.0, slideY),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              } else {
                // 底部导航栏：左右滑动淡入淡出
                final slideX = isEntering
                    ? (goingRight ? 0.12 : -0.12)
                    : (goingRight ? -0.12 : 0.12);
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: Offset(slideX, 0.0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              }
            },
            child: KeyedSubtree(
              key: ValueKey(currentTab.id),
              child: _buildPageForTab(currentTab.id),
            ),
          ),
        ),
        // 封面流页横屏沉浸：隐藏 MiniPlayer，实现全屏浏览
        if (!immersive) const MiniPlayer(),
      ],
    );
  }

  /// 二次返回退出：首次返回显示提示，3 秒内再次返回触发真正退出（不弹窗）。
  void _onBackPressedForExit() {
    if (_isExiting) return;
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

  /// 双击返回后回到手机桌面（仅挂后台）：
  /// 不杀进程、不停播放器、不停本地 Rust 服务器，重新打开瞬时恢复。
  /// 优先走原生 [method 'moveToBack']（等同按 Home），
  /// 异常时兜底 [SystemNavigator.pop]（回桌面但保留后台进程与服务器）。
  Future<void> _doExit() async {
    if (_isExiting) return;
    try {
      const MethodChannel('com.md3music.md3music/task')
          .invokeMethod('moveToBack');
    } catch (_) {
      SystemNavigator.pop();
    }
  }

}

/// 本地 API 服务器未启动提示条（所有 tab 顶部）。
///
/// 触发条件：[KugouApiClient.localServerAvailable] 为 false，即本地 Rust
/// 服务器连端口都没拿到。此时所有在线接口都会被拦截器立即拒绝，
/// 页面只会显示空状态，必须告知用户真正的原因。
class _LocalServerDownBanner extends StatelessWidget {
  const _LocalServerDownBanner();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // Windows 上最常见的成因是打包时漏了 kugou_server.dll，直接给出可操作提示。
    final hint = Platform.isWindows
        ? '本地数据接口未启动，在线内容不可用（可能缺少 kugou_server.dll）'
        : '本地数据接口未启动，在线内容不可用';

    return Material(
      color: colorScheme.errorContainer.withValues(alpha: 0.85),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.dns_outlined,
              size: 18,
              color: colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hint,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onErrorContainer,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部 NavigationBar 的 tab 图标 + 自定义 M3E Expressive 胶囊 indicator。
///
/// **设计思路**（对齐 MD3E MotionScheme.expressive()）：
/// - 关掉 Flutter 原生 NavigationIndicator 的硬切横向拉伸
///   （见 navigation_bar.dart 第 845-849 行，用 easeInOutCubicEmphasized 单轴缩放）
/// - 自己在图标背后画一个 secondaryContainer 色的圆角胶囊
/// - 胶囊出现/消失用 **带过冲的曲线**（easeOutBack，过冲约 10%），
///   对应 MD3E `defaultSpatialSpec` 的"轻微过冲"原则
/// - 胶囊做 **单轴 X 拉伸**（0.4 → 1.0），对齐 Flutter 原生 NavigationIndicator 的形变方式
/// - 图标在胶囊弹起过程中完成 outlined → filled 切换，被弹跳掩盖
///
/// **文字行为**：由 `NavigationBarThemeData.labelBehavior` 控制，跟随用户在
/// 设置页「底部导航栏文字」的三档选择（始终显示 / 仅当前页 / 始终不显示，
/// 默认不显示）；`NavigationDestination.label` 传真实标题，既用于显示也用于
/// 无障碍朗读。
///
/// 不使用 NavigationDestination.selectedIcon（Flutter 原生内部是硬切）。
class _AnimatedTabIcon extends StatelessWidget {
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
