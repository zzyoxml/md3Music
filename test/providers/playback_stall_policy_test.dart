import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/playback_stall_policy.dart';

void main() {
  const minimumHeadroom = Duration(seconds: 10);

  CdnStallWindowDecision classify({
    required Duration advanced,
    required Duration elapsed,
    required Duration bufferedHeadroom,
  }) => classifyCdnStallWindow(
    advanced: advanced,
    elapsed: elapsed,
    bufferedHeadroom: bufferedHeadroom,
    minimumBufferedHeadroom: minimumHeadroom,
    minimumPlaybackRate: 0.5,
  );

  test('慢速窗口但剩余缓冲充足时等待，不重建音源', () {
    expect(
      classify(
        advanced: const Duration(milliseconds: 200),
        elapsed: const Duration(seconds: 2),
        bufferedHeadroom: const Duration(seconds: 56),
      ),
      CdnStallWindowDecision.waitForBufferedAudio,
    );
  });

  test('缓冲余量低于刷新准备时间时换源', () {
    expect(
      classify(
        advanced: const Duration(milliseconds: 200),
        elapsed: const Duration(seconds: 2),
        bufferedHeadroom: const Duration(seconds: 8),
      ),
      CdnStallWindowDecision.refreshSource,
    );
  });

  test('播放位置停住且没有剩余缓冲时换源', () {
    expect(
      classify(
        advanced: Duration.zero,
        elapsed: const Duration(seconds: 2),
        bufferedHeadroom: Duration.zero,
      ),
      CdnStallWindowDecision.refreshSource,
    );
  });

  test('速率与缓冲阈值边界保持既定策略', () {
    expect(
      classify(
        advanced: const Duration(seconds: 1),
        elapsed: const Duration(seconds: 2),
        bufferedHeadroom: Duration.zero,
      ),
      CdnStallWindowDecision.sufficientProgress,
    );
    expect(
      classify(
        advanced: const Duration(milliseconds: 999),
        elapsed: const Duration(seconds: 2),
        bufferedHeadroom: const Duration(seconds: 10, microseconds: 1),
      ),
      CdnStallWindowDecision.waitForBufferedAudio,
    );
    expect(
      classify(
        advanced: const Duration(milliseconds: 999),
        elapsed: const Duration(seconds: 2),
        bufferedHeadroom: minimumHeadroom,
      ),
      CdnStallWindowDecision.refreshSource,
    );
  });

  test('正常推进、向后seek和无效时间窗口都不触发换源', () {
    expect(
      classify(
        advanced: const Duration(seconds: 1),
        elapsed: const Duration(seconds: 2),
        bufferedHeadroom: Duration.zero,
      ),
      CdnStallWindowDecision.sufficientProgress,
    );
    expect(
      classify(
        advanced: const Duration(seconds: -1),
        elapsed: const Duration(seconds: 2),
        bufferedHeadroom: Duration.zero,
      ),
      CdnStallWindowDecision.sufficientProgress,
    );
    expect(
      classify(
        advanced: Duration.zero,
        elapsed: Duration.zero,
        bufferedHeadroom: Duration.zero,
      ),
      CdnStallWindowDecision.sufficientProgress,
    );
  });
}
