import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/automix/automix_analysis.dart';
import 'package:md3music/core/services/automix/automix_analysis_store.dart';
import 'package:md3music/core/services/automix/automix_analyzer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('缓存命中时不再调用原生解码', () async {
    final calls = <MethodCall>[];
    final analyzer = AutomixAnalyzer.forTest(
      store: AutomixAnalysisStore(directory: await Directory.systemTemp.createTemp('a')),
      handler: (call) async {
        calls.add(call);
        return null;
      },
    );
    await analyzer.store.write(AutomixAnalysis(
      key: 'song1|h', bpm: 120, confidence: 0.8, firstBeatSec: 0.1,
      rhythmDensity: 0.4, loudnessDbfs: -12, windowMs: 25000, analyzedAtMs: 1,
    ));
    final a = await analyzer.analyze(key: 'song1|h', url: 'http://x/y.mp3');
    expect(a!.bpm, closeTo(120, 1e-9));
    expect(calls, isEmpty);
  });

  test('120BPM PCM 走完整链路测出 ≈120 并写入缓存', () async {
    const sr = 48000;
    final pcm = Int16List(sr * 20);
    final period = (sr * 60.0 / 120).round();
    for (var t = 0; t + 200 < pcm.length; t += period) {
      for (var k = 0; k < 200; k++) {
        pcm[t + k] = (30000 * (1 - k / 200) * (k % 2 == 0 ? 1 : -1)).round();
      }
    }
    final bytes = Uint8List.view(pcm.buffer, 0, pcm.length * 2);
    final analyzer = AutomixAnalyzer.forTest(
      store: AutomixAnalysisStore(directory: await Directory.systemTemp.createTemp('b')),
      handler: (call) async => <String, dynamic>{
        'sampleRate': sr,
        'pcm': bytes,
        'decodedMs': 20000,
      },
    );
    final a = await analyzer.analyze(key: 'song2|h', url: 'http://x/y.mp3');
    expect(a, isNotNull);
    expect(a!.bpm, closeTo(120, 4));
    expect(a.usable, isTrue);
    expect((await analyzer.store.read('song2|h')), isNotNull);
  });

  test('原生解码失败返回 null，且被记入失败抑制（不会每首重试）', () async {
    var attempts = 0;
    final analyzer = AutomixAnalyzer.forTest(
      store: AutomixAnalysisStore(directory: await Directory.systemTemp.createTemp('c')),
      handler: (call) async {
        attempts++;
        throw PlatformException(code: 'DECODE_FAILED');
      },
    );
    expect(await analyzer.analyze(key: 's3|h', url: 'u'), isNull);
    expect(await analyzer.analyze(key: 's3|h', url: 'u'), isNull);
    expect(attempts, 1);
  });

  test('同一 key 并发只解一次', () async {
    var attempts = 0;
    final analyzer = AutomixAnalyzer.forTest(
      store: AutomixAnalysisStore(directory: await Directory.systemTemp.createTemp('d')),
      handler: (call) async {
        attempts++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        throw PlatformException(code: 'DECODE_FAILED');
      },
    );
    final rs = await Future.wait([
      analyzer.analyze(key: 's4|h', url: 'u'),
      analyzer.analyze(key: 's4|h', url: 'u'),
    ]);
    expect(rs, [null, null]);
    expect(attempts, 1);
  });

  test('url 为空时直接跳过：不发起解码，也不记入失败抑制', () async {
    // 回归：队列里「下一首」的播放地址是懒解析的，起播时为空。
    // 早期实现会把它当真实失败 → 每首歌都白跑一次解码并报 BAD_ARGS。
    var attempts = 0;
    final analyzer = AutomixAnalyzer.forTest(
      store: AutomixAnalysisStore(directory: await Directory.systemTemp.createTemp('e')),
      handler: (call) async {
        attempts++;
        throw PlatformException(code: 'DECODE_FAILED');
      },
    );
    expect(await analyzer.analyze(key: 's5', url: ''), isNull);
    expect(attempts, 0, reason: '空地址不应发起解码');
    // 地址就绪后必须还能正常分析（说明没被 _failedKeys 永久拦掉）
    expect(await analyzer.analyze(key: 's5', url: 'u'), isNull);
    expect(attempts, 1);
  });

  test('cached 只读缓存，不触发解码', () async {
    var attempts = 0;
    final analyzer = AutomixAnalyzer.forTest(
      store: AutomixAnalysisStore(directory: await Directory.systemTemp.createTemp('f')),
      handler: (call) async {
        attempts++;
        return null;
      },
    );
    expect(await analyzer.cached('missing'), isNull);
    expect(attempts, 0);
    await analyzer.store.write(AutomixAnalysis(
      key: 'hit', bpm: 128, confidence: 0.9, firstBeatSec: 0,
      rhythmDensity: 0.6, loudnessDbfs: -10, windowMs: 25000, analyzedAtMs: 2,
    ));
    expect((await analyzer.cached('hit'))!.bpm, closeTo(128, 1e-9));
    expect(attempts, 0);
  });

  test('缓存键只依赖 songId：CDN 签名轮换不会导致未命中', () {
    // 回归：早期把带时效签名的播放地址纳入键 → 每次解析 url 都不同 → 永不命中。
    expect(buildAutomixKey(songId: 'abc'), 'abc');
    expect(buildAutomixKey(songId: 'abc'), buildAutomixKey(songId: 'abc'));
  });
}
