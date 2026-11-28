import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_aux_scope.dart';

void main() {
  group('auxScopeFromName', () {
    test('已知取值按名解析', () {
      expect(auxScopeFromName('currentLine'), LyricAuxScope.currentLine);
      expect(auxScopeFromName('allLines'), LyricAuxScope.allLines);
      expect(auxScopeFromName('hidePlayed'), LyricAuxScope.hidePlayed);
    });

    test('null / 未知取值回退默认（仅当前行）', () {
      expect(auxScopeFromName(null), LyricAuxScope.currentLine);
      expect(auxScopeFromName(''), LyricAuxScope.currentLine);
      expect(auxScopeFromName('bogus'), LyricAuxScope.currentLine);
      // 大小写敏感：持久化只写 name，不做宽松匹配
      expect(auxScopeFromName('AllLines'), LyricAuxScope.currentLine);
    });
  });

  group('resolveAuxTarget', () {
    double resolve(
      LyricAuxScope scope, {
      required int index,
      required int current,
      bool enabled = true,
      bool hasAux = true,
    }) {
      return resolveAuxTarget(
        scope: scope,
        enabled: enabled,
        hasAuxText: hasAux,
        lineIndex: index,
        currentLineIndex: current,
      );
    }

    test('开关关闭时三种范围都收起', () {
      for (final scope in LyricAuxScope.values) {
        expect(
          resolve(scope, index: 3, current: 3, enabled: false),
          0,
          reason: 'scope=$scope',
        );
      }
    });

    test('无副行文本的行恒收起', () {
      for (final scope in LyricAuxScope.values) {
        expect(
          resolve(scope, index: 3, current: 3, hasAux: false),
          0,
          reason: 'scope=$scope',
        );
      }
    });

    test('currentLine 只有当前行展开', () {
      expect(resolve(LyricAuxScope.currentLine, index: 2, current: 2), 1);
      expect(resolve(LyricAuxScope.currentLine, index: 1, current: 2), 0);
      expect(resolve(LyricAuxScope.currentLine, index: 3, current: 2), 0);
      // 无当前行：没有任何一行可见
      expect(resolve(LyricAuxScope.currentLine, index: 2, current: -1), 0);
    });

    test('allLines 所有行展开（含无当前行）', () {
      for (final current in <int>[-1, 0, 2, 9]) {
        expect(resolve(LyricAuxScope.allLines, index: 2, current: current), 1);
        expect(resolve(LyricAuxScope.allLines, index: 0, current: current), 1);
      }
    });

    test('hidePlayed 已播行收起、当前行与未播行展开', () {
      const scope = LyricAuxScope.hidePlayed;
      expect(resolve(scope, index: 1, current: 2), 0);
      expect(resolve(scope, index: 2, current: 2), 1);
      expect(resolve(scope, index: 3, current: 2), 1);
      // 无当前行 = 没有任何已播行 → 全部显示
      expect(resolve(scope, index: 0, current: -1), 1);
      expect(resolve(scope, index: 5, current: -1), 1);
    });

    test('hidePlayed 与 currentLine 在首行上的差异符合定义', () {
      // 首行为当前行时两者一致（只有当前行有副行）
      expect(
        resolve(LyricAuxScope.hidePlayed, index: 0, current: 0),
        resolve(LyricAuxScope.currentLine, index: 0, current: 0),
      );
      // 第二行起分叉：hidePlayed 仍然显示未播行
      expect(resolve(LyricAuxScope.hidePlayed, index: 1, current: 0), 1);
      expect(resolve(LyricAuxScope.currentLine, index: 1, current: 0), 0);
    });
  });

  test('label 覆盖全部枚举且非空', () {
    for (final scope in LyricAuxScope.values) {
      expect(auxScopeLabel(scope).isNotEmpty, isTrue, reason: 'scope=$scope');
    }
    // 下拉条目名（设置页 M3EDropdownMenu 直接消费）
    expect(auxScopeLabel(LyricAuxScope.currentLine), '仅当前行');
    expect(auxScopeLabel(LyricAuxScope.allLines), '所有行');
    expect(auxScopeLabel(LyricAuxScope.hidePlayed), '已播行除外');
  });
}
