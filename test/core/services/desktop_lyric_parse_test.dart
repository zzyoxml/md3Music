import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/desktop_lyric_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('小文本直接解析', () async {
    final lines = await parseLyricOffMainThread('[00:01.00]你好');
    expect(lines, isNotEmpty);
    expect(lines.first.text, '你好');
  });

  test('超过 32KB 的大文本经 isolate 解析结果一致', () async {
    final big = StringBuffer();
    // 2000 行 × 约 30 字节 ≈ 60KB，稳定超过阈值
    for (int i = 0; i < 2000; i++) {
      big.writeln(
        '[00:${(i % 60).toString().padLeft(2, '0')}.${(i % 100).toString().padLeft(2, '0')}]第$i行歌词内容测试文本',
      );
    }
    final lines = await parseLyricOffMainThread(big.toString());
    expect(lines.length, 2000);
  });

  test('锁屏整包推送重置轻量进度的500ms节流基线', () {
    final gate = LockScreenProgressPushGate();
    gate.markFullPush(nowMs: 1000, isPlaying: true);

    expect(gate.shouldPush(nowMs: 1499, isPlaying: true), isFalse);
    expect(gate.shouldPush(nowMs: 1500, isPlaying: true), isTrue);
    expect(gate.shouldPush(nowMs: 1600, isPlaying: false), isTrue);
    expect(gate.shouldPush(nowMs: 2099, isPlaying: false), isFalse);
    expect(gate.shouldPush(nowMs: 2100, isPlaying: false), isTrue);
    gate.reset();
    expect(gate.shouldPush(nowMs: 2200, isPlaying: false), isTrue);
  });
}
