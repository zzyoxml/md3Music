import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「歌曲信息」入口与 USB 独占内容可见性的防回归测试。
///
/// **背景**：`0b6c7dd8` 曾把播放页「⋯」菜单里的「歌曲信息」入口整块注释
///（标准版 + AM 版各一处），并把歌曲信息页的 USB 独占区块一并删掉，页面因此
/// 成了没有调用点的死代码（`flutter analyze` 报两处 `unused_import`）。
/// 这类"整块注释"在编译期不报错，只能靠 UI 截图或读代码发现，故这里用源码
/// 扫描钉住两件事（与 `platform_capabilities_test.dart` 的门控存在性测试同风格）：
///
/// 1. 两份播放页的更多菜单里确实有**未注释**的「歌曲信息」导航；
/// 2. 歌曲信息页的 USB 独占区块与 USB 遥测行都挂在 `supportsUsbExclusive` 上
///    —— 该能力已排除桌面端与 TV 构建（TV 不注册原生插件），删掉门控就会在
///    TV/桌面端露出死 UI。
///
/// 说明：只剔除**整行注释**，足以发现"把整块 UI 注释掉"这种回归；行尾注释里
/// 出现关键字不影响断言方向。
void main() {
  /// 去掉整行 `//` 注释后的源码（用于判断某段 UI 是否真的生效）。
  String activeSource(String path) => File(path)
      .readAsLinesSync()
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  group('播放页更多菜单：歌曲信息入口', () {
    for (final path in const [
      'lib/modules/player/full_player.dart',
      'lib/modules/player/full_player_am.dart',
    ]) {
      test('$path 含生效的「歌曲信息」入口', () {
        final source = activeSource(path);
        expect(
          source.contains("title: const Text('歌曲信息')"),
          isTrue,
          reason: '更多菜单缺少「歌曲信息」标题（是不是又被整块注释了？）',
        );
        expect(
          source.contains('const SongInfoPage()'),
          isTrue,
          reason: '入口没有导航到 SongInfoPage',
        );
        expect(
          source.contains("import 'song_info_page.dart';"),
          isTrue,
          reason: '入口恢复后必须保留（或恢复）对应 import',
        );
      });
    }
  });

  group('歌曲信息页：USB 独占内容按平台能力门控', () {
    final path = 'lib/modules/player/song_info_page.dart';

    test('USB 独立区块只在 supportsUsbExclusive 为真时渲染', () {
      final source = activeSource(path);
      expect(
        RegExp(r'if \(supportsUsbExclusive\) \.\.\.\[').hasMatch(source),
        isTrue,
        reason: 'USB 独占区块必须按能力门控，否则桌面端/TV 会出现死 UI',
      );
      expect(
        source.contains('UsbExclusiveSection('),
        isTrue,
        reason: '应与设置页共用同一 USB 独占组件',
      );
      expect(
        source.contains("import '../../widgets/usb_exclusive_section.dart';"),
        isTrue,
        reason: '恢复区块后必须恢复对应 import',
      );
    });

    test('USB 遥测行（解码输出 / USB 输出）同样按能力隐藏', () {
      final source = activeSource(path);
      expect(
        RegExp(r'supportsUsbExclusive\s*&&\s*!exclusiveEnabled')
            .hasMatch(source),
        isTrue,
        reason: '「解码输出」来自 USB 原生通道，桌面端/TV 无数据，必须隐藏',
      );
      expect(
        RegExp(r'supportsUsbExclusive\s*&&\s*dacBits > 0')
            .hasMatch(source),
        isTrue,
        reason: '「USB 输出」只在独占链路存在时有意义，必须按能力隐藏',
      );
    });

    test('USB 状态订阅按能力门控（不在桌面端/TV 打无 handler 的通道）', () {
      final source = activeSource(path);
      expect(
        RegExp(
          r'if \(supportsUsbExclusive\) \{\s*\n\s*_status = UsbAudioService',
        ).hasMatch(source),
        isTrue,
        reason: 'initState 的 USB 状态订阅/refresh 应整体门控',
      );
    });
  });
}
