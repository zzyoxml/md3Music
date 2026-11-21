import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/update/release_version.dart';

void main() {
  group('parseReleaseVersion', () {
    test('去掉 v 前缀并解析三段', () {
      expect(parseReleaseVersion('v5.6.5'), [5, 6, 5]);
      expect(parseReleaseVersion('5.6.0'), [5, 6, 0]);
      expect(parseReleaseVersion('  v10.0.1  '), [10, 0, 1]);
    });

    test('忽略构建号与预发布后缀', () {
      expect(parseReleaseVersion('5.6.0+40'), [5, 6, 0]);
      expect(parseReleaseVersion('v5.6.0-beta.2'), [5, 6, 0]);
    });

    test('段数不足时按已解析段返回', () {
      expect(parseReleaseVersion('5'), [5]);
      expect(parseReleaseVersion('5.6'), [5, 6]);
    });

    test('非法输入返回 null', () {
      expect(parseReleaseVersion(''), isNull);
      expect(parseReleaseVersion('v'), isNull);
      expect(parseReleaseVersion('latest'), isNull);
      expect(parseReleaseVersion('v5.x.0'), isNull);
      expect(parseReleaseVersion('v-1.0.0'), isNull);
    });
  });

  group('compareReleaseVersions', () {
    test('逐段比较，缺失段按 0 补齐', () {
      expect(compareReleaseVersions([5, 6, 5], [5, 6, 0]), 1);
      expect(compareReleaseVersions([5, 6, 0], [5, 6, 5]), -1);
      expect(compareReleaseVersions([5, 6], [5, 6, 0]), 0);
      expect(compareReleaseVersions([6, 0, 0], [5, 99, 99]), 1);
      expect(compareReleaseVersions([10, 0, 0], [9, 99, 99]), 1);
    });
  });

  group('isNewerRelease', () {
    test('远端更高返回 true', () {
      expect(isNewerRelease('5.6.5', '5.6.0'), isTrue);
      expect(isNewerRelease('v5.6.5', 'v5.6.0'), isTrue);
    });

    test('相同或本地更高返回 false', () {
      expect(isNewerRelease('5.6.0', '5.6.0'), isFalse);
      expect(isNewerRelease('5.5.0', '5.6.0'), isFalse);
    });

    test('任一无法解析时返回 false（宁可不提醒，也不误报）', () {
      expect(isNewerRelease('latest', '5.6.0'), isFalse);
      expect(isNewerRelease('5.6.5', ''), isFalse);
    });
  });
}
