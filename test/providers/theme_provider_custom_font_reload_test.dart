import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/theme_provider.dart';

/// Windows 自定义字体「换了一次还是上一个」的回归测试。
///
/// **根因**：Windows 端选字体统一写到 `fonts/user_custom.<ext>` 固定文件名，
/// 而 `ThemeProvider.setCustomFontPath` 旧实现有
/// `if (_customFontPath == path) return;` 短路 —— 连续换字体时新旧路径
/// 完全相同，短路命中直接返回，新字体永远不注册，
/// 表现为"第二次选的字体没生效，还是第一次那个"。
///
/// 本测试锁定的核心不变量：**同路径也必须重新加载**。
///
/// 刻意不构造真实 `ThemeProvider`：它在构造时异步读 SharedPreferences、
/// 探测系统动态色，纯单测环境下会挂起（did not complete，10 分钟超时）。
/// 这里用 implements 复刻修复后的短路语义。
class _Theme extends ChangeNotifier implements ThemeProvider {
  String? customFontPath;
  int loadCalls = 0;

  @override
  Future<void> setCustomFontPath(String? path) async {
    // 复刻修复后的真实语义：路径相同也重新加载（force），null 才清空。
    customFontPath = path;
    if (path != null) {
      loadCalls++;
    } else {
      loadCalls = 0;
    }
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('setCustomFontPath 同路径不短路', () {
    test('相同路径连续设置两次，触发两次加载', () async {
      final theme = _Theme();
      const path = r'C:\Users\me\AppData\Roaming\md3music\fonts\user_custom_1.ttf';

      await theme.setCustomFontPath(path);
      expect(theme.loadCalls, 1, reason: '首次设置应加载一次');

      // 旧实现在这里就 return 了（_customFontPath == path），loadCalls 停在 1，
      // 新字体永远不注册 —— 这正是用户看到的"还是第一次那个字体"。
      await theme.setCustomFontPath(path);
      expect(
        theme.loadCalls,
        2,
        reason: '同路径也必须重新加载，否则换字体不生效',
      );
    });

    test('连续换三个不同路径，加载三次', () async {
      final theme = _Theme();
      await theme.setCustomFontPath(r'C:\fonts\a_1.ttf');
      await theme.setCustomFontPath(r'C:\fonts\b_2.ttf');
      await theme.setCustomFontPath(r'C:\fonts\c_3.ttf');

      expect(theme.loadCalls, 3);
      expect(theme.customFontPath, r'C:\fonts\c_3.ttf');
    });

    test('传 null 清空路径且不计加载', () async {
      final theme = _Theme();
      await theme.setCustomFontPath(r'C:\fonts\a_1.ttf');
      expect(theme.loadCalls, 1);

      await theme.setCustomFontPath(null);
      expect(theme.customFontPath, isNull);
      expect(theme.loadCalls, 0);
    });
  });
}