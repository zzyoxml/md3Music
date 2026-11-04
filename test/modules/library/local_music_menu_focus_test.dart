import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/library/library_page.dart';
import 'package:md3music/providers/library_provider.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/local_favorites_provider.dart';
import 'package:md3music/providers/tab_config_provider.dart';

// 展示有搜索框但暂无可匹配歌曲的页面，避免启动原生播放或扫描服务。
class _SearchLibrary extends LibraryProvider {
  int scans = 0;
  @override
  bool get hasMusic => true;
  @override
  Future<void> loadLocalMusic() async {
    scans++;
  }
}

class _IdlePlayer extends ChangeNotifier implements PlayerProvider {
  @override
  Song? get currentSong => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final action in [
    '返回菜单',
    '点击外部退出',
    '扫描音乐',
    '添加扫描文件夹',
    '关闭排除管理',
    '添加排除文件夹',
    '过滤开关',
    '切换分类',
  ]) {
    testWidgets('$action 不恢复输入焦点，主动搜索仍可输入', (tester) async {
      final library = _SearchLibrary();
      final player = _IdlePlayer();
      addTearDown(library.dispose);
      addTearDown(player.dispose);
      const picker = MethodChannel('com.md3music.md3music/folder_picker');
      var pickerCalls = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(picker, (
        _,
      ) async {
        pickerCalls++;
        return null; // 系统选择器取消。
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          picker,
          null,
        ),
      );
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<LibraryProvider>.value(value: library),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
            // LibraryPage 的 build 会读取页面标题对齐配置，缺失即整页构建失败。
            ChangeNotifierProvider(create: (_) => TabConfigProvider()),
          ],
          child: const MaterialApp(home: LibraryPage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      final focus = tester.widget<TextField>(find.byType(TextField)).focusNode!;
      expect(focus.hasFocus, isTrue);

      if (action == '切换分类') {
        await tester.tap(find.text('文件夹'));
      } else {
        await tester.tap(find.byIcon(Icons.add));
        await tester.pumpAndSettle();
        expect(focus.hasFocus, isFalse);
        if (action == '点击外部退出') {
          await tester.tapAt(const Offset(5, 5));
        } else if (action == '返回菜单') {
          await tester.binding.handlePopRoute();
        } else if (action == '关闭排除管理' || action == '添加排除文件夹') {
          await tester.tap(find.text('排除文件夹'));
          await tester.pumpAndSettle();
          if (action == '添加排除文件夹') {
            await tester.tap(find.text('添加排除文件夹'));
            await tester.pumpAndSettle();
            expect(pickerCalls, 1);
          }
          await tester.tap(find.text('关闭'));
        } else if (action == '过滤开关') {
          await tester.tap(find.text('过滤不超过 60 秒的音频'));
          await tester.pumpAndSettle();
          expect(library.filterShortAudio, isTrue);
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.text(action));
        }
      }
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      if (action == '扫描音乐') expect(library.scans, 1);
      if (action == '添加扫描文件夹') expect(pickerCalls, 1);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('横屏进入本地音乐不自动请求输入焦点，点搜索框才弹键盘', (
    tester,
  ) async {
    final library = _SearchLibrary();
    final player = _IdlePlayer();
    addTearDown(library.dispose);
    addTearDown(player.dispose);
    tester.view.physicalSize = const Size(900, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryProvider>.value(value: library),
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ChangeNotifierProvider(create: (_) => LocalFavoritesProvider()),
          ChangeNotifierProvider(create: (_) => TabConfigProvider()),
        ],
        child: const MaterialApp(home: LibraryPage()),
      ),
    );
    await tester.pumpAndSettle();
    final focus = tester.widget<TextField>(find.byType(TextField)).focusNode!;
    expect(focus.canRequestFocus, isFalse);
    expect(focus.hasFocus, isFalse);
    expect(tester.testTextInput.hasAnyClients, isFalse);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tapAt(const Offset(850, 400));
    await tester.pumpAndSettle();
    expect(focus.canRequestFocus, isFalse);
    expect(focus.hasFocus, isFalse);
    expect(tester.testTextInput.hasAnyClients, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
