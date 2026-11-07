import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/automix/automix_analysis.dart';

void main() {
  test('usable：BPM 有效且置信度达标才算可用', () {
    final ok = AutomixAnalysis(
      key: 'k', bpm: 124, confidence: 0.6, firstBeatSec: 0.12,
      rhythmDensity: 0.5, loudnessDbfs: -12, windowMs: 25000,
      analyzedAtMs: 1,
    );
    expect(ok.usable, isTrue);
    expect(ok.copyWith(bpm: 0).usable, isFalse);
    expect(ok.copyWith(confidence: 0.2).usable, isFalse);
  });

  test('JSON 往返一致', () {
    final a = AutomixAnalysis(
      key: 'k', bpm: 124.5, confidence: 0.61, firstBeatSec: 0.12,
      rhythmDensity: 0.5, loudnessDbfs: -12.25, windowMs: 25000,
      analyzedAtMs: 1700000000000,
    );
    final b = AutomixAnalysis.fromJson(a.toJson())!;
    expect(b.bpm, closeTo(124.5, 1e-9));
    expect(b.loudnessDbfs, closeTo(-12.25, 1e-9));
    expect(b.key, 'k');
  });

  test('字段缺失/类型错误时 fromJson 返回 null 而不是抛异常', () {
    expect(AutomixAnalysis.fromJson({'bpm': 120}), isNull);
    expect(AutomixAnalysis.fromJson(<String, dynamic>{}), isNull);
  });
}
