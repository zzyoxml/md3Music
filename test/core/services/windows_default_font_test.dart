import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/windows_default_font.dart';
import 'package:md3music/providers/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows 内置 OTF 可注册为默认全局字体', () async {
    if (!Platform.isWindows) return;
    final source = File('windows/runner/fonts/SOURCEHANSANSCN-MEDIUM.OTF');
    expect(source.existsSync(), isTrue);
    await WindowsDefaultFont.load(fontFilePath: source.absolute.path);
    expect(WindowsDefaultFont.loadedFamily, WindowsDefaultFont.family);
    expect(ThemeProvider().effectiveFontFamily, WindowsDefaultFont.family);
  });
}
