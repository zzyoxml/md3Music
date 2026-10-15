import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/automix/automix_analysis.dart';
import 'package:md3music/core/services/automix/automix_analysis_store.dart';

AutomixAnalysis _a(String key, int at) => AutomixAnalysis(
      key: key, bpm: 120, confidence: 0.7, firstBeatSec: 0.1,
      rhythmDensity: 0.4, loudnessDbfs: -12, windowMs: 25000, analyzedAtMs: at,
    );

void main() {
  late Directory dir;
  late AutomixAnalysisStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('automix_store_test');
    store = AutomixAnalysisStore(directory: dir);
  });
  tearDown(() => dir.delete(recursive: true));

  test('未命中返回 null，写入后可读回', () async {
    expect(await store.read('nope'), isNull);
    await store.write(_a('k1', 100));
    final got = await store.read('k1');
    expect(got, isNotNull);
    expect(got!.bpm, closeTo(120, 1e-9));
  });

  test('进程内不落盘也能读（写入后立即可读，不依赖 flush 时机）', () async {
    await store.write(_a('k2', 100));
    expect((await store.read('k2'))!.key, 'k2');
  });

  test('重启（新实例读同一目录）能取回', () async {
    await store.write(_a('k3', 100));
    final other = AutomixAnalysisStore(directory: dir);
    expect((await other.read('k3'))!.key, 'k3');
  });

  test('超过上限时淘汰最旧的，保留最新的', () async {
    for (var i = 0; i < AutomixAnalysisStore.maxEntries + 20; i++) {
      await store.write(_a('k$i', i));
    }
    expect(await store.read('k0'), isNull);
    expect(await store.read('k${AutomixAnalysisStore.maxEntries + 19}'), isNotNull);
    expect(await store.count(), AutomixAnalysisStore.maxEntries);
  });

  test('JSON 文件损坏时降级为空缓存而不是崩', () async {
    await File('${dir.path}${Platform.pathSeparator}automix_analysis.json')
        .writeAsString('{ not json');
    final other = AutomixAnalysisStore(directory: dir);
    expect(await other.read('anything'), isNull);
    await other.write(_a('k9', 1));
    expect(await other.read('k9'), isNotNull);
  });

  test('单条记录字段缺失不会让整个缓存失效', () async {
    final f = File('${dir.path}${Platform.pathSeparator}automix_analysis.json');
    await f.writeAsString(jsonEncode({
      'version': 1,
      'items': [
        _a('good', 1).toJson(),
        {'key': 'bad'},
      ],
    }));
    final other = AutomixAnalysisStore(directory: dir);
    expect(await other.read('good'), isNotNull);
    expect(await other.read('bad'), isNull);
  });
}
