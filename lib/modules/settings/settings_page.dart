import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/lyricon_provider_service.dart';
import '../../core/theme/app_theme.dart';
import '../../data/repositories/settings_repository.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/theme_provider.dart';
import '../../widgets/apple_lyrics/layout/lyric_preferences_panel.dart';
import '../../widgets/apple_lyrics/preview/lyrics_preview_page.dart';
import '../../widgets/seed_color_picker.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final SettingsRepository _settingsRepository = SettingsRepository();
  final TextEditingController _apiServerController = TextEditingController(
    text: 'http://127.0.0.1:8080',
  );
  ThemeMode _themeMode = ThemeMode.system;
  String _defaultQuality = 'hq';
  bool _isTestingConnection = false;
  String? _connectionResult;
  bool _autoReceiveVip = true;
  bool _useDynamicColor = false;
  // Apple Music 风格播放页开关（默认关闭，开启后用 AM 风格 FullPlayer）
  bool _useAmStylePlayer = false;
  String _appVersion = '';
  // Lyricon 词幕推送相关状态
  bool _lyriconEnabled = false;
  bool _lyriconDisplayTranslation = true;
  bool _lyriconDisplayRoma = false;
  // 下载目录（默认系统 Downloads 下的 MD3Music 子目录）
  String _downloadDir = SettingsRepository.defaultDownloadDir;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadVersion();
    _loadLyriconSettings();
    LyriconProviderService.instance.addListener(_onLyriconStateChanged);
  }

  @override
  void dispose() {
    LyriconProviderService.instance.removeListener(_onLyriconStateChanged);
    _apiServerController.dispose();
    super.dispose();
  }

  /// Lyricon 服务状态变化回调：触发 UI 刷新
  void _onLyriconStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 从 SettingsRepository 加载 Lyricon 三个偏好
  Future<void> _loadLyriconSettings() async {
    final enabled = await _settingsRepository.getLyriconEnabled();
    final displayTranslation =
        await _settingsRepository.getLyriconDisplayTranslation();
    final displayRoma = await _settingsRepository.getLyriconDisplayRoma();
    if (mounted) {
      setState(() {
        _lyriconEnabled = enabled;
        _lyriconDisplayTranslation = displayTranslation;
        _lyriconDisplayRoma = displayRoma;
      });
    }
  }

  /// Lyricon 连接状态 → 中文文案
  String _getLyriconStateText() {
    switch (LyriconProviderService.instance.state) {
      case LyriconConnectionState.disabled:
        return '未启用';
      case LyriconConnectionState.connecting:
        return '连接中...';
      case LyriconConnectionState.connected:
        return '已连接';
      case LyriconConnectionState.disconnected:
        return '已断开';
      case LyriconConnectionState.timeout:
        return '连接超时，请检查 Lyricon / LSPosed 配置';
    }
  }

  Future<void> _loadSettings() async {
    final themeMode = await _settingsRepository.getThemeMode();
    final quality = await _settingsRepository.getDefaultQuality();
    final autoReceiveVip = await _settingsRepository.getAutoReceiveVip();
    final apiServerUrl = await _settingsRepository.getApiServerUrl();
    final downloadDir = await _settingsRepository.getDownloadDir();
    // 从 ThemeProvider 同步「使用系统主题色」开关状态
    final useDynamicColor = context.read<ThemeProvider>().useDynamicColor;
    // 从 ThemeProvider 同步「Apple Music 风格播放页」开关状态
    final useAmStylePlayer = context.read<ThemeProvider>().useAmStylePlayer;

    setState(() {
      _themeMode = themeMode;
      _defaultQuality = quality;
      _autoReceiveVip = autoReceiveVip;
      _apiServerController.text = apiServerUrl;
      _useDynamicColor = useDynamicColor;
      _useAmStylePlayer = useAmStylePlayer;
      _downloadDir = downloadDir;
    });
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _appVersion = info.version;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _appVersion = '3.2.0';
        });
      }
    }
  }

  Future<void> _testConnection() async {
    setState(() {
      _isTestingConnection = true;
      _connectionResult = null;
    });

    final url = _apiServerController.text.trim();

    try {
      final response = await http
          .get(Uri.parse('$url/server/now'))
          .timeout(const Duration(seconds: 5));
      final success = response.statusCode == 200;
      setState(() {
        _connectionResult = success
            ? '连接成功'
            : '连接失败: HTTP ${response.statusCode}';
      });
      if (success) {
        await _settingsRepository.setApiServerUrl(url);
      }
    } catch (e) {
      setState(() {
        _connectionResult = '连接失败: $e';
      });
    }

    setState(() {
      _isTestingConnection = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          _buildSectionHeader('外观'),
          _buildAppearanceSection(colorScheme),
          const Divider(),
          _buildSectionHeader('歌词'),
          _buildLyricSection(colorScheme),
          const Divider(),
          _buildSectionHeader('播放'),
          _buildPlaybackSection(colorScheme),
          const Divider(),
          _buildSectionHeader('在线音乐'),
          _buildOnlineMusicSection(colorScheme),
          const Divider(),
          _buildSectionHeader('下载'),
          _buildDownloadSection(colorScheme),
          const Divider(),
          _buildSectionHeader('缓存'),
          _buildCacheSection(colorScheme),
          const Divider(),
          _buildSectionHeader('关于'),
          _buildAboutSection(colorScheme),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  /// 歌词设置 section：点击进入字号/行间距调节面板。
  Widget _buildLyricSection(ColorScheme colorScheme) {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.lyrics),
          title: const Text('歌词显示'),
          subtitle: const Text('字号、行间距'),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () {
            showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (context) => SafeArea(
                child: const LyricPreferencesPanel(),
              ),
            );
          },
        ),
        // Lyricon 词幕推送主开关
        SwitchListTile(
          title: const Text('Lyricon 词幕推送'),
          subtitle: const Text('向 Lyricon 提供方实时推送歌词'),
          value: _lyriconEnabled,
          onChanged: (value) {
            setState(() {
              _lyriconEnabled = value;
            });
            LyriconProviderService.instance.setEnabled(value);
            _settingsRepository.setLyriconEnabled(value);
          },
        ),
        // 主开关下方显示当前连接状态
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _getLyriconStateText(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        // 次级开关：翻译歌词（主开关关闭时禁用）
        SwitchListTile(
          title: const Text('翻译歌词'),
          value: _lyriconDisplayTranslation,
          onChanged: _lyriconEnabled
              ? (value) {
                  setState(() {
                    _lyriconDisplayTranslation = value;
                  });
                  LyriconProviderService.instance.setDisplayTranslation(value);
                  _settingsRepository.setLyriconDisplayTranslation(value);
                }
              : null,
        ),
        // 次级开关：罗马音（主开关关闭时禁用）
        SwitchListTile(
          title: const Text('罗马音'),
          value: _lyriconDisplayRoma,
          onChanged: _lyriconEnabled
              ? (value) {
                  setState(() {
                    _lyriconDisplayRoma = value;
                  });
                  LyriconProviderService.instance.setDisplayRoma(value);
                  _settingsRepository.setLyriconDisplayRoma(value);
                }
              : null,
        ),
      ],
    );
  }

  Widget _buildAppearanceSection(ColorScheme colorScheme) {
    final themeProvider = context.read<ThemeProvider>();
    // 仅 ThemeMode.light 时禁用 OLED 开关；dark 与 system 均可勾选。
    // system 模式下勾选后，等系统切到深色时 darkTheme 自动应用纯黑（MaterialApp 机制）。
    final canToggleOled = _themeMode != ThemeMode.light;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '主题模式',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                value: ThemeMode.light,
                label: Text('浅色'),
                icon: Icon(Icons.light_mode),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                label: Text('深色'),
                icon: Icon(Icons.dark_mode),
              ),
              ButtonSegment(
                value: ThemeMode.system,
                label: Text('跟随系统'),
                icon: Icon(Icons.brightness_auto),
              ),
            ],
            selected: {_themeMode},
            onSelectionChanged: (modes) {
              final mode = modes.first;
              setState(() {
                _themeMode = mode;
              });
              context.read<ThemeProvider>().setThemeMode(mode);
              _settingsRepository.setThemeMode(mode);
            },
          ),
        ),
        // 主题色入口：点击弹出 8 色预设面板。
        // 系统色开启时用 IgnorePointer 禁用点击（不灰显，色块仍显示当前 effectiveSeedColor）。
        IgnorePointer(
          ignoring: themeProvider.useDynamicColor,
          child: ListTile(
            leading: const Icon(Icons.palette),
            title: const Text('主题色'),
            subtitle: Text(
              themeProvider.useDynamicColor
                  ? '跟随系统壁纸取色'
                  : '手动选择种子色',
            ),
            trailing: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: themeProvider.effectiveSeedColor,
                shape: BoxShape.circle,
                border: Border.all(color: colorScheme.outline, width: 1.5),
              ),
            ),
            onTap: () => _showSeedColorPicker(themeProvider),
          ),
        ),
        SwitchListTile(
          title: const Text('使用系统主题色'),
          subtitle: const Text('跟随系统壁纸取色（Android 12+ 莫奈色，HCT 多点量化）'),
          value: _useDynamicColor,
          onChanged: (v) {
            setState(() => _useDynamicColor = v);
            context.read<ThemeProvider>().setUseDynamicColor(v);
          },
        ),
        // OLED 纯黑开关：light 模式禁用；dark 与 system 可勾选。
        // system 模式下勾选后，系统切深色时自动生效，切浅色时不影响 lightTheme。
        SwitchListTile(
          title: const Text('OLED 纯黑深色'),
          subtitle: const Text('将深色背景改为纯黑（仅深色模式生效，节省 OLED 电量）'),
          value: themeProvider.useOledBlack,
          onChanged: canToggleOled
              ? (v) => themeProvider.setUseOledBlack(v)
              : null,
        ),
        SwitchListTile(
          title: const Text('Apple Music 风格播放页'),
          subtitle: const Text('使用模糊封面背景 + 弹簧动画 + 逐字歌词（关闭则用原版 MD3 风格）'),
          value: _useAmStylePlayer,
          onChanged: (v) {
            setState(() => _useAmStylePlayer = v);
            context.read<ThemeProvider>().setUseAmStylePlayer(v);
          },
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  /// 弹出 8 色预设种子色选择面板。
  /// 选择后调用 ThemeProvider.setManualSeedColor 持久化并立即生效。
  void _showSeedColorPicker(ThemeProvider themeProvider) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SeedColorPicker(
        currentColor:
            themeProvider.manualSeedColor ?? AppTheme.defaultSeedColor,
        onSelected: (color) {
          themeProvider.setManualSeedColor(color);
          Navigator.pop(ctx);
        },
      ),
    );
  }

  Widget _buildPlaybackSection(ColorScheme colorScheme) {
    return Column(
      children: [
        ListTile(
          title: const Text('默认音质'),
          subtitle: Text(_getQualityLabel(_defaultQuality)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showQualityDialog(),
        ),
        SwitchListTile(
          title: const Text('自动领取VIP'),
          subtitle: const Text('每次启动自动领取每日VIP（需要登录）'),
          value: _autoReceiveVip,
          onChanged: (value) {
            setState(() {
              _autoReceiveVip = value;
            });
            _settingsRepository.setAutoReceiveVip(value);
          },
        ),
      ],
    );
  }

  Widget _buildOnlineMusicSection(ColorScheme colorScheme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _apiServerController,
            decoration: InputDecoration(
              labelText: '在线登录接口地址',
              hintText: 'http://115.29.236.96:5621',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: _isTestingConnection
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.primary,
                        ),
                      )
                    : const Icon(Icons.wifi_find),
                onPressed: _isTestingConnection ? null : _testConnection,
              ),
            ),
            onSubmitted: (_) => _testConnection(),
          ),
        ),
        if (_connectionResult != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              _connectionResult!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: _connectionResult == '连接成功'
                    ? Colors.green
                    : colorScheme.error,
              ),
            ),
          )
        else
          const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.wifi_tethering),
              label: const Text('测试连接'),
              onPressed: _isTestingConnection ? null : _testConnection,
            ),
          ),
        ),
        const SizedBox(height: 8),
        ListTile(
          leading: Icon(Icons.dns, color: colorScheme.primary),
          title: const Text('本地数据接口'),
          subtitle: const Text('http://127.0.0.1:8080'),
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              '运行中',
              style: TextStyle(color: Colors.green, fontSize: 12),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '本地 Node.js 服务器运行中，推荐/排行/搜索/播放等数据接口均通过本地处理',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
      ],
    );
  }

  Widget _buildDownloadSection(ColorScheme colorScheme) {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.download),
          title: const Text('下载目录'),
          subtitle: Text(
            _downloadDir,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: _showDownloadDirDialog,
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '下载歌曲会保存到此目录并嵌入标题/艺术家/专辑/封面/歌词。\n'
            '首次下载需要授予「所有文件访问权限」。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
      ],
    );
  }

  void _showDownloadDirDialog() {
    final controller = TextEditingController(text: _downloadDir);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载目录'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: '目录绝对路径',
            hintText: '/storage/emulated/0/Download/MD3Music',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final path = controller.text.trim();
              if (path.isEmpty) return;
              await _settingsRepository.setDownloadDir(path);
              setState(() {
                _downloadDir = path;
              });
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _buildCacheSection(ColorScheme colorScheme) {
    return Column(
      children: [
        ListTile(
          title: const Text('清除缓存'),
          leading: Icon(Icons.delete_outline, color: colorScheme.error),
          onTap: () => _showClearCacheDialog(),
        ),
        ListTile(
          title: const Text('数据迁移（修复数据混乱）'),
          subtitle: const Text('如果看到其他用户的信息，执行此操作'),
          leading: Icon(Icons.bug_report, color: colorScheme.tertiary),
          onTap: () => _showDataMigrationDialog(),
        ),
      ],
    );
  }

  Future<void> _showDataMigrationDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('🔧 数据迁移'),
        content: const Text(
          '此操作将清除旧版本的登录数据，修复可能的数据混乱问题。\n\n'
          '执行后需要重新登录。\n\n'
          '是否继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('执行'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final prefs = await SharedPreferences.getInstance();

        // 清除旧版本的全局键
        await prefs.remove('kugou_token');
        await prefs.remove('kugou_userid');
        await prefs.remove('kugou_vip_token');
        await prefs.remove('kugou_dfid');
        await prefs.remove('kugou_current_userid');

        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ 数据迁移完成，请重新登录'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ),
        );

        // 退出登录
        context.read<KugouProvider>().logout();

        // 返回上一页
        Navigator.of(context).pop();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ 数据迁移失败: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Widget _buildAboutSection(ColorScheme colorScheme) {
    return Column(
      children: [
        ListTile(
          title: const Text('应用版本'),
          subtitle: Text(_appVersion.isEmpty ? '3.2.0' : _appVersion),
          leading: const Icon(Icons.info_outline),
        ),
        ListTile(
          title: const Text('更新最新版本'),
          subtitle: const Text('https://github.com/zzyoxml/md3Music/releases'),
          leading: const Icon(Icons.system_update_outlined),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => _openReleasesUrl(),
        ),
        ListTile(
          title: const Text('开源许可'),
          leading: const Icon(Icons.description_outlined),
          onTap: () {
            showLicensePage(
              context: context,
              applicationName: 'MD3Music',
              applicationVersion: _appVersion.isEmpty ? '3.2.0' : _appVersion,
            );
          },
        ),
        // 开发者入口：跳转 Apple Music 风格歌词渲染预览页（Task 22.5）
        ListTile(
          title: const Text('歌词预览（开发）'),
          subtitle: const Text('Apple Music 风格歌词渲染调试'),
          leading: const Icon(Icons.lyrics_outlined),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const LyricsPreviewPage(),
              ),
            );
          },
        ),
      ],
    );
  }

  Future<void> _openReleasesUrl() async {
    const url = 'https://github.com/zzyoxml/md3Music/releases';
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  String _getQualityLabel(String quality) {
    switch (quality) {
      case 'standard':
      case '128':
        return '标准 128k';
      case 'hq':
      case '320':
        return '高品质 320k';
      case 'sq':
      case 'flac':
        return '无损 FLAC';
      case 'hires':
        return 'Hi-Res';
      default:
        return '高品质 320k';
    }
  }

  void _showQualityDialog() {
    final qualities = [
      ('128', '标准 128k'),
      ('320', '高品质 320k'),
      ('flac', '无损 FLAC'),
    ];

    showDialog(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: const Text('默认音质'),
          children: qualities.map((q) {
            return SimpleDialogOption(
              onPressed: () {
                setState(() {
                  _defaultQuality = q.$1;
                });
                _settingsRepository.setDefaultQuality(q.$1);
                Navigator.pop(context);
              },
              child: Text(
                q.$2,
                style: TextStyle(
                  color: _defaultQuality == q.$1
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  void _showClearCacheDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('清除缓存'),
          content: const Text('确定要清除所有缓存数据吗？此操作不可撤销。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                await _doClearCache();
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _doClearCache() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // 1. 清图片缓存
      await DefaultCacheManager().emptyCache();
      // 2. 清 app 临时目录（Android 系统设置里的"清除缓存"也指这个）
      try {
        final dir = await getTemporaryDirectory();
        if (dir.existsSync()) {
          for (final entity in dir.listSync()) {
            try {
              if (entity is Directory) {
                entity.deleteSync(recursive: true);
              } else {
                entity.deleteSync();
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
      // 3. 清 KugouProvider 内存
      if (mounted) {
        context.read<KugouProvider>().clearMemoryCache();
      }
      // 4. 重置发现页日期标志
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('discover_last_date');
      _settingsRepository.setCacheSize(0);
    } catch (e) {
      debugPrint('Clear cache error: $e');
    }
    if (mounted) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('已清除缓存'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}
