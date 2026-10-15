import 'package:flutter_test/flutter_test.dart';
// 铁律 24：测试导入 lib 必须用 package: 前缀（相对导入会让同一库出现两个 URI，
// 编译期报 LyricLine/*1*/ 与 /*2*/ 类型不匹配而 loading 失败）
import 'package:md3music/providers/player_provider.dart';

void main() {
  test('非循环模式下停在最后一首 → 需要提示', () {
    expect(
      shouldHintQueueEnd(loopMode: 'off', currentIndex: 4, playlistLength: 5),
      isTrue,
    );
  });

  test('非循环模式下不在最后一首 → 不提示', () {
    expect(
      shouldHintQueueEnd(loopMode: 'off', currentIndex: 3, playlistLength: 5),
      isFalse,
    );
  });

  test('列表循环（all）→ 不提示（会绕回队首）', () {
    expect(
      shouldHintQueueEnd(loopMode: 'all', currentIndex: 4, playlistLength: 5),
      isFalse,
    );
  });

  test('单曲循环（one）→ 不提示（会重播当前曲）', () {
    expect(
      shouldHintQueueEnd(loopMode: 'one', currentIndex: 0, playlistLength: 1),
      isFalse,
    );
  });

  test('单曲队列 + 非循环 → 提示（已是最后一首）', () {
    expect(
      shouldHintQueueEnd(loopMode: 'off', currentIndex: 0, playlistLength: 1),
      isTrue,
    );
  });

  test('空队列 → 不提示（另有空队列语义）', () {
    expect(
      shouldHintQueueEnd(loopMode: 'off', currentIndex: -1, playlistLength: 0),
      isFalse,
    );
  });
}
