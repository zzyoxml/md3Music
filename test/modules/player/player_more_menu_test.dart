/// 「播放与输出」收口 + 播放速度归位的源码级防回归测试。
///
/// 背景：投屏 / 音量 / 音质曾散在三处（⋯ 菜单的投屏格、菜单里的常驻音量条、
/// 顶栏音质弹窗），现统一收进顶栏音质格打开的 `PlaybackCenterSheet`；
/// 播放速度则从 ListTile 收进「定时关闭」同一行宫格。
///
/// 这类"整块 UI 增删"在编译期不报错，只能靠 UI 截图或读代码发现，故用源码扫描
/// 钉住结构（与 `song_info_entry_test.dart` / `platform_capabilities_test.dart`
/// 同风格）：只剔除整行 `//` 注释，行尾注释里的关键字不影响断言方向。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 去掉整行 `//` 注释后的源码（用于判断某段 UI 是否真的生效）。
  String activeSource(String path) => File(path)
      .readAsLinesSync()
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  for (final path in const [
    'lib/modules/player/full_player.dart',
    'lib/modules/player/full_player_am.dart',
  ]) {
    group('$path 播放与输出收口', () {
      late String source;
      setUp(() => source = activeSource(path));

      test('顶栏音质格仍是音符图标 + 音质文案（顶栏样式未改）', () {
        expect(
          RegExp(
            r'TopBarTrailingSegment _qualityTopBarSegment[\s\S]*?icon: Icons\.music_note',
          ).hasMatch(source),
          isTrue,
          reason: '顶栏要还原成原来的音符图标',
        );
        expect(
          RegExp(r'label: playerProvider\.currentQualityLabel').hasMatch(source),
          isTrue,
          reason: '顶栏要继续显示当前音质',
        );
      });

      test('顶栏音质格点开的是播放与输出面板', () {
        expect(
          RegExp(
            r'TopBarTrailingSegment _qualityTopBarSegment[\s\S]*?showPlaybackCenterSheet\(context\)',
          ).hasMatch(source),
          isTrue,
          reason: '音质格是投屏/音量/音质三合一面板的唯一入口',
        );
      });

      test('更多菜单里没有常驻音量条（音量已收进面板）', () {
        expect(
          source.contains('PlayerVolumeBar('),
          isFalse,
          reason: '音量条不应再留在 ⋯ 菜单里（横屏控制页那份不受影响）',
        );
      });

      test('播放速度是宫格格，不再是 ListTile', () {
        expect(
          source.contains("label: '播放速度'"),
          isTrue,
          reason: '播放速度应收进「定时关闭」同一行宫格',
        );
        expect(
          source.contains("title: const Text('播放速度')"),
          isFalse,
          reason: 'ListTile 形态的播放速度应已移除',
        );
      });

      test('投屏只在车机窄面板保留（其它形态走面板）', () {
        expect(
          RegExp(
            r'if \(widget\.dockMode\)\s*\n\s*MenuActionCell\(\s*\n\s*icon: Icons\.cast',
          ).hasMatch(source),
          isTrue,
          reason: '投屏格必须由 dockMode 门控，否则触屏形态会出现第二个入口',
        );
        // 非门控的那份（旧的常驻投屏格）不应存在：全文件只允许出现一次 Icons.cast
        expect(
          RegExp(r'Icons\.cast').allMatches(source).length,
          1,
          reason: 'Icons.cast 只应出现在 dockMode 门控的那一格',
        );
      });

      test('引入了播放与输出面板', () {
        expect(
          source.contains("import 'playback_center_sheet.dart';"),
          isTrue,
          reason: '两份播放页都要能打开同一个面板',
        );
      });
    });
  }
}
