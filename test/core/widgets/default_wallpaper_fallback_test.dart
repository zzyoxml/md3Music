import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/core/widgets/app_background.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「默认壁纸（内置兜底图）」相关行为的回归。
///
/// **Bug 报告（2026-10-12）**：设置 → 界面背景，开启「启用自定义背景图片」
/// 但未选图时，预览区不显示内置默认壁纸；随后 Android 侧也报"自定义默认壁纸
/// 失效"。两者同一根因。
///
/// 根因与两条铁律：
/// 1. `backgroundImageProvider` 在路径为空/失效时**回落到内置默认壁纸**，
///    所以「开关开着但没选图」是**正常状态**，此时必须照常渲染壁纸层。
/// 2. 因此判据必须是 [ThemeProvider.useBackgroundImage]（用户开关本身）。
///    2026-10-11 曾改用 `isBackgroundImageEffective`（额外要求文件存在）替换
///    14 处渲染分支 ⇒ 两端在"开关开 + 无图"时完全不渲染壁纸层。
///    `isBackgroundImageEffective` 只**不**用于"要不要渲染"，只用于
///    "需不需要真实图片才能算"（如背景莫奈取色）。
void main() {
  const defaultAsset = 'assets/images/default_wallpaper.jpg';

  Future<ThemeProvider> pump() async {
    SharedPreferences.setMockInitialValues({});
    final tp = ThemeProvider();
    // 构造时会触发 _loadBackgroundImage()，等它落定
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return tp;
  }

  group('默认壁纸兜底（backgroundImageProvider）', () {
    test('无用户路径时回落到内置默认壁纸', () async {
      final tp = await pump();
      final provider = backgroundImageProvider(tp, cacheWidth: 800);
      expect(
        provider,
        isNot(isA<FileImage>()),
        reason: '没有用户图片时应走 asset 兜底，而非 FileImage',
      );
    });

    test('路径为空串同样回落', () async {
      final tp = await pump();
      await tp.setBackgroundImagePath('');
      expect(
        backgroundImageProvider(tp, cacheWidth: 800),
        isNot(isA<FileImage>()),
      );
    });

    test('指向不存在的文件也回落（不留空背景）', () async {
      final tp = await pump();
      await tp.setBackgroundImagePath(r'C:\definitely\not\exist.jpg');
      expect(
        backgroundImageProvider(tp, cacheWidth: 800),
        isNot(isA<FileImage>()),
        reason: '文件失效时必须回落默认壁纸，否则页面无背景',
      );
    });

    test('路径有效时用用户图片', () async {
      final tmp = File('tmp/default_wallpaper_test.jpg');
      tmp.parent.createSync(recursive: true);
      tmp.writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE0]); // 最小 JPEG 头
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync();
      });

      final tp = await pump();
      await tp.setBackgroundImagePath(tmp.path);
      final provider = backgroundImageProvider(tp, cacheWidth: 800);
      expect(provider, isA<ResizeImage>());
      final inner = (provider as ResizeImage).imageProvider;
      expect(inner, isA<FileImage>());
    });

    test('默认壁纸资源文件真实存在', () {
      expect(
        File(defaultAsset).existsSync(),
        isTrue,
        reason: '默认壁纸缺失会导致"无图时页面空白"，且明暗配色可能异常',
      );
    });
  });

  group('开关语义：useBackgroundImage ≠ isBackgroundImageEffective', () {
    test('开关关：两者都为 false', () async {
      SharedPreferences.setMockInitialValues({});
      final tp = ThemeProvider();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(tp.useBackgroundImage, isFalse);
      expect(tp.isBackgroundImageEffective, isFalse);
    });

    test('开关开但未选图：开关为 true，生效判定为 false', () async {
      SharedPreferences.setMockInitialValues({
        'flutter.use_background_image': true,
      });
      final tp = ThemeProvider();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        tp.useBackgroundImage,
        isTrue,
        reason: '用户开关本身是"开"，设置页开关与壁纸层都必须按"壁纸模式"处理',
      );
      expect(
        tp.isBackgroundImageEffective,
        isFalse,
        reason: '没选图 ⇒ 没用到用户图片。这个值**只**用于取色等'
            '需要真实图片的场合，不能用来判断是否渲染壁纸',
      );
    });
  });

  group('回归防线：渲染判据不得用 isBackgroundImageEffective', () {
    // 2026-10-11 把 14 处渲染分支改成了 isBackgroundImageEffective，
    // 导致 Android + Windows 双端壁纸同时消失。
    // 这里做**源码级**断言：这些文件里不应再出现该getter 参与渲染判定。
    // 允许的例外仅限设置页「主题色」两处（背景莫奈取色确需真实图片）。
    const banned = {
      'lib/app.dart': '全局页面表面透明化判定',
      'lib/core/widgets/app_background.dart': '壁纸主体层',
      'lib/core/layout/responsive_layout.dart': '响应式背景',
      'lib/widgets/scroll_aware_app_bar.dart': 'AppBar 沉浸层',
      'lib/modules/search/search_page.dart': '搜索页头/页签栏',
      'lib/modules/playlist/playlist_page.dart': '歌单页头',
      'lib/modules/album/album_detail_page.dart': '专辑页头',
      'lib/modules/audiobook/audiobook_album_detail_page.dart': '有声书页头',
      'lib/modules/onboarding/user_agreement_page.dart': '用户协议页',
      'lib/modules/player/mini_player.dart': '迷你播放器',
      'lib/modules/player/secondary_mini_player.dart': '悬浮播放器',
      'lib/modules/player/player_panel_frame.dart': '播放面板底',
      'lib/modules/player/bottom_bar_morph_overlay.dart': '底栏底色',
    };

    test('渲染分支不再使用 isBackgroundImageEffective', () {
      final offenders = <String>[];
      banned.forEach((path, usage) {
        final file = File(path);
        if (!file.existsSync()) {
          offenders.add('$path（文件不存在，需同步本测试）');
          return;
        }
        // 剔除注释行，只看生效代码
        final code = file
            .readAsLinesSync()
            .where((l) {
          final t = l.trimLeft();
          return !t.startsWith('//') && !t.startsWith('*');
        })
            .join('\n');
        if (code.contains('isBackgroundImageEffective')) {
          offenders.add('$path（$usage）');
        }
      });
      expect(
        offenders,
        isEmpty,
        reason: '这些位置必须用 useBackgroundImage。'
            '"开关开 + 无用户图"要回落内置默认壁纸，'
            '不能用 isBackgroundImageEffective 把整个壁纸层关掉',
      );
    });

    test('设置页仅「主题色」两处可用（取色确需真实图片）', () {
      final file = File('lib/modules/settings/settings_page.dart');
      final code = file
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      final count = 'isBackgroundImageEffective'.allMatches(code).length;
      expect(
        count,
        2,
        reason: '仅「主题色」提示语与禁用态两处允许使用；'
            '开关显示（_useBackgroundImage）必须读 useBackgroundImage',
      );
      // 赋值来源允许两种等价写法：直接在 build 内 `context.read<ThemeProvider>()`，
      // 或上游重构后由方法参数 `themeProvider` 传入（2026-10-24 合并上游后）。
      // 关键约束不变：必须读**用户开关** useBackgroundImage。
      expect(
        RegExp(
          r'final\s+useBackgroundImage\s*=\s*'
          r'(?:context\.read<ThemeProvider>\(\)|themeProvider)\.useBackgroundImage;',
        ).hasMatch(code),
        isTrue,
        reason: '设置页开关赋值必须读 useBackgroundImage（2026-10-12 回归）',
      );
    });
  });

  group('持久化往返', () {
    test('模糊 / 透明度能读回存储值', () async {
      SharedPreferences.setMockInitialValues({
        'flutter.use_background_image': true,
        'flutter.background_blur': 0.66,
        'flutter.background_opacity': 0.5,
      });
      final tp = ThemeProvider();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(
        tp.backgroundBlur,
        closeTo(0.66, 0.001),
        reason: '设置页应读到存储值而非默认 20；'
            '若读到 20 说明构造期异步加载与设置页读取存在竞态',
      );
      expect(tp.backgroundOpacity, closeTo(0.5, 0.01));
    });
  });
}