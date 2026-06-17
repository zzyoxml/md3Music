import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/repositories/settings_repository.dart';
import '../../providers/kugou_provider.dart';
import '../../providers/theme_provider.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final SettingsRepository _settingsRepository = SettingsRepository();
  final TextEditingController _apiServerController = TextEditingController(
    text: 'http://musicplayer.ccwu.cc',
  );
  ThemeMode _themeMode = ThemeMode.system;
  String _defaultQuality = 'hq';
  bool _autoPlay = true;
  bool _showLyrics = true;
  bool _isTestingConnection = false;
  String? _connectionResult;
  bool _autoReceiveVip = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _apiServerController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final themeMode = await _settingsRepository.getThemeMode();
    final quality = await _settingsRepository.getDefaultQuality();
    final autoPlay = await _settingsRepository.getAutoPlay();
    final showLyrics = await _settingsRepository.getShowLyrics();
    final autoReceiveVip = await _settingsRepository.getAutoReceiveVip();
    final apiServerUrl = await _settingsRepository.getApiServerUrl();

    setState(() {
      _themeMode = themeMode;
      _defaultQuality = quality;
      _autoPlay = autoPlay;
      _showLyrics = showLyrics;
      _autoReceiveVip = autoReceiveVip;
      _apiServerController.text = apiServerUrl;
    });

    final kugouProvider = context.read<KugouProvider>();
    kugouProvider.setBaseUrl(apiServerUrl);
  }

  Future<void> _testConnection() async {
    setState(() {
      _isTestingConnection = true;
      _connectionResult = null;
    });

    final url = _apiServerController.text.trim();
    final kugouProvider = context.read<KugouProvider>();
    kugouProvider.setBaseUrl(url);

    try {
      await kugouProvider.getHotSearch();
      final success = kugouProvider.error == null;
      setState(() {
        _connectionResult = success ? '连接成功' : '连接失败: ${kugouProvider.error}';
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
          _buildSectionHeader('播放'),
          _buildPlaybackSection(colorScheme),
          const Divider(),
          _buildSectionHeader('在线音乐'),
          _buildOnlineMusicSection(colorScheme),
          const Divider(),
          _buildSectionHeader('歌词'),
          _buildLyricsSection(colorScheme),
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

  Widget _buildAppearanceSection(ColorScheme colorScheme) {
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
        const SizedBox(height: 8),
      ],
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
          title: const Text('自动播放'),
          subtitle: const Text('打开应用时自动继续播放'),
          value: _autoPlay,
          onChanged: (value) {
            setState(() {
              _autoPlay = value;
            });
            _settingsRepository.setAutoPlay(value);
          },
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
              labelText: 'API 服务器地址',
              hintText: 'http://musicplayer.ccwu.cc',
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
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Card(
            color: Colors.amber,
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '⚠️ Android设备配置说明',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Android设备上的"localhost"指向设备本身，不是电脑！\n\n'
                    '解决方案：\n'
                    '1. 确保API服务器在电脑上运行\n'
                    '2. 获取电脑的局域网IP（如 192.168.1.100）\n'
                    '   Windows: 运行 ipconfig 查找IPv4地址\n'
                    '3. 在下方输入: http://192.168.1.100:3000\n'
                    '4. 确保Android和电脑在同一WiFi下',
                    style: TextStyle(fontSize: 13, color: Colors.black87),
                  ),
                ],
              ),
            ),
          ),
        ),
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
      ],
    );
  }

  Widget _buildLyricsSection(ColorScheme colorScheme) {
    return SwitchListTile(
      title: const Text('显示歌词'),
      subtitle: const Text('播放时显示歌词'),
      value: _showLyrics,
      onChanged: (value) {
        setState(() {
          _showLyrics = value;
        });
        _settingsRepository.setShowLyrics(value);
      },
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
      ],
    );
  }

  Widget _buildAboutSection(ColorScheme colorScheme) {
    return Column(
      children: [
        ListTile(
          title: const Text('应用版本'),
          subtitle: const Text('1.0.0'),
          leading: const Icon(Icons.info_outline),
        ),
        ListTile(
          title: const Text('开源许可'),
          leading: const Icon(Icons.description_outlined),
          onTap: () {
            showLicensePage(
              context: context,
              applicationName: 'MD3Music',
              applicationVersion: '1.0.0',
            );
          },
        ),
      ],
    );
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
              onPressed: () {
                _settingsRepository.setCacheSize(0);
                Navigator.pop(context);
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }
}
