import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('启动时立即使用已保存的关闭背景图设置', () async {
    SharedPreferences.setMockInitialValues({'use_background_image': false});

    final provider = ThemeProvider(initialUseBackgroundImage: false);

    expect(provider.useBackgroundImage, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(provider.useBackgroundImage, isFalse);
  });

  test('未保存背景图设置时仍保留首次安装默认值', () {
    SharedPreferences.setMockInitialValues({});

    final provider = ThemeProvider(initialUseBackgroundImage: true);

    expect(provider.useBackgroundImage, isTrue);
  });

  test('自定义背景图片默认模糊为 20、透明度为 20%', () async {
    SharedPreferences.setMockInitialValues({});

    final provider = ThemeProvider();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(provider.backgroundBlur, 20.0);
    expect(provider.backgroundOpacity, 0.2);
  });
}
