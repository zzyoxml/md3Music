import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 桌面外壳在壁纸模式下的**透明度契约**。
///
/// **Bug（2026-10-12）**：桌面布局开启「自定义壁纸」后完全看不到壁纸。
///
/// 根因：`app.dart` 把壁纸层挂在全局 `Stack` 的
/// `Positioned.fill(child: AppBackground())`（最底层），而 `DesktopShell`
/// 在其上又套了一层 **`Material(color: cs.surface)`（不透明）**，
/// 整窗把壁纸层盖死。
///
/// 背景模式下 `ThemeData` 已把 `scaffoldBackgroundColor` /
/// `appBarTheme` / `navigationRailTheme` 调成透明或半透明
/// （见 `app.dart::_applyBackgroundOverrides`），但**桌面壳自建的这层
/// Material 不受那些 ThemeData 影响** —— 必须单独处理。
///
/// 这里做**源码级**断言：这类"壳层不透明盖住背景"很难靠行为测试稳定覆盖，
/// 而它一旦回归就是整窗无背景，破坏性极强。
void main() {
  const shellPath = 'lib/core/layout/desktop_shell.dart';

  String readEffective(String path) {
    return File(path)
        .readAsLinesSync()
        .where((l) {
          final t = l.trimLeft();
          return !t.startsWith('//') && !t.startsWith('*');
        })
        .join('\n');
  }

  test('桌面外壳有壁纸模式透明分支', () {
    final code = readEffective(shellPath);
    expect(
      code.contains('wallpaperOn'),
      isTrue,
      reason: 'DesktopShell 必须按壁纸模式决定外层 Material 是否透明，'
          '否则不透明底色会盖住 app.dart 的 Positioned.fill 壁纸层',
    );
  });

  test('外壳 Material：壁纸模式走透明', () {
    final code = readEffective(shellPath);
    expect(
      code.contains('wallpaperOn ? Colors.transparent : cs.surface'),
      isTrue,
      reason: '外壳最外层 Material 在壁纸模式下必须 Colors.transparent',
    );
  });

  test('侧栏 Material：壁纸模式走半透明', () {
    final code = readEffective(shellPath);
    expect(
      code.contains('surfaceContainerLow.withValues(alpha: 0.2)'),
      isTrue,
      reason: '侧栏在壁纸模式下应半透明让壁纸透出，'
          '与 app.dart 里 navigationRailTheme 的 0.2 口径保持一致',
    );
  });

  test('壁纸判据用 useBackgroundImage，不得用 isBackgroundImageEffective', () {
    final code = readEffective(shellPath);
    expect(
      code.contains('isBackgroundImageEffective'),
      isFalse,
      reason: '"开关开 + 未选图"会回落到内置默认壁纸，仍属壁纸模式。'
          '用 isBackgroundImageEffective 会让这种情况下壁纸再次消失'
          '（2026-10-11 双端回归的同一根因）',
    );
    expect(
      code.contains('useBackgroundImage'),
      isTrue,
      reason: '壁纸判据必须是用户开关本身',
    );
  });

  test('未引入第三个壁纸判据（避免语义漂移）', () {
    final code = readEffective(shellPath);
    // 允许出现的判定 getter 仅 useBackgroundImage（是否壁纸模式 / 渲染）。
    // 若将来新增第三个判据，必须先想清楚它落在哪个语义位上。
    final re = RegExp(r'\.(useBackgroundImage|isBackgroundImageEffective)');
    final verdicts = <String>{};
    for (final m in re.allMatches(code)) {
      verdicts.add(m.group(0)!);
    }
    expect(
      verdicts.length,
      1,
      reason: '只允许 .useBackgroundImage。实际出现：$verdicts',
    );
    expect(verdicts.contains('.useBackgroundImage'), isTrue);
  });
}