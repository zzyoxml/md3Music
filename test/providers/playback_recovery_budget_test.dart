import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as just_audio;
import 'package:md3music/providers/playback_recovery_budget.dart';

void main() {
  group('PlaybackRecoveryBudget', () {
    test('对单首歌最多发起三次自动恢复，并逐步退避', () {
      final budget = PlaybackRecoveryBudget();

      expect(budget.nextDelay, const Duration(seconds: 30));
      expect(budget.tryConsume('song-a'), isTrue);
      expect(budget.nextDelay, const Duration(seconds: 60));
      expect(budget.tryConsume('song-a'), isTrue);
      expect(budget.nextDelay, const Duration(seconds: 120));
      expect(budget.tryConsume('song-a'), isTrue);
      expect(budget.nextDelay, isNull);
      expect(budget.tryConsume('song-a'), isFalse);
    });

    test('换歌或显式重置会开启新的恢复预算', () {
      final budget = PlaybackRecoveryBudget();
      expect(budget.tryConsume('song-a'), isTrue);
      expect(budget.tryConsume('song-b'), isTrue);
      expect(budget.attempts, 1);
      budget.reset('song-b');
      expect(budget.attempts, 0);
      expect(budget.nextDelay, const Duration(seconds: 30));
    });
  });

  group('classifyPlaybackRecoveryFailure', () {
    PlaybackRecoveryFailureKind classify({
      bool hasFailure = true,
      bool userCanceled = false,
      bool authenticationRequired = false,
      bool paidContent = false,
      bool networkAvailable = true,
    }) => classifyPlaybackRecoveryFailure(
      hasFailure: hasFailure,
      userCanceled: userCanceled,
      authenticationRequired: authenticationRequired,
      paidContent: paidContent,
      networkAvailable: networkAvailable,
    );

    test('无失败、用户取消、鉴权、付费和断网均不作为瞬时错误重试', () {
      expect(
        classify(hasFailure: false),
        PlaybackRecoveryFailureKind.noFailure,
      );
      expect(
        classify(userCanceled: true),
        PlaybackRecoveryFailureKind.userCanceled,
      );
      expect(
        classify(authenticationRequired: true),
        PlaybackRecoveryFailureKind.authenticationRequired,
      );
      expect(
        classify(paidContent: true),
        PlaybackRecoveryFailureKind.paidContent,
      );
      expect(
        classify(networkAvailable: false),
        PlaybackRecoveryFailureKind.networkUnavailable,
      );
    });

    test('在线且可播放的普通解析失败归为瞬时错误', () {
      expect(classify(), PlaybackRecoveryFailureKind.transientResolution);
    });
  });

  group('shouldAutomaticallyRetryPlatformPlaybackError', () {
    test(
      'blocks only known deterministic Android format incompatibilities',
      () {
        for (final code in [3003, 4004, 4005]) {
          expect(
            shouldAutomaticallyRetryPlatformPlaybackError(
              isAndroid: true,
              errorCode: code,
            ),
            isFalse,
            reason:
                'Media3 error code $code cannot be fixed by re-resolving URL',
          );
        }
      },
    );

    test('keeps network, output-route, and unknown failures recoverable', () {
      for (final code in [2001, 2002, 2005, 4001, 4003, 5001, 5002, 9999]) {
        expect(
          shouldAutomaticallyRetryPlatformPlaybackError(
            isAndroid: true,
            errorCode: code,
          ),
          isTrue,
          reason: 'Media3 error code $code may recover after state changes',
        );
      }
    });

    test(
      'preserves existing behavior on other platforms and without a code',
      () {
        expect(
          shouldAutomaticallyRetryPlatformPlaybackError(
            isAndroid: false,
            errorCode: 4004,
          ),
          isTrue,
        );
        expect(
          shouldAutomaticallyRetryPlatformPlaybackError(
            isAndroid: true,
            errorCode: null,
          ),
          isTrue,
        );
      },
    );

    test('HTTP拒绝和限流可刷新链接，确定性缺失和客户端错误停止自动重试', () {
      for (final status in [401, 403, 408, 425, 429, 500, 503]) {
        expect(
          shouldAutomaticallyRetryPlatformPlaybackError(
            isAndroid: true,
            errorCode: 2004,
            httpStatusCode: status,
          ),
          isTrue,
          reason: 'HTTP $status can recover after bounded URL refresh',
        );
      }
      for (final status in [400, 404, 410, 422]) {
        expect(
          shouldAutomaticallyRetryPlatformPlaybackError(
            isAndroid: true,
            errorCode: 2004,
            httpStatusCode: status,
          ),
          isFalse,
          reason: 'HTTP $status should keep the manual retry path only',
        );
      }
    });
  });

  group('classifyPlaybackSourceHttpFailure', () {
    test('区分签名拒绝、资源缺失、瞬时和永久HTTP失败', () {
      expect(
        classifyPlaybackSourceHttpFailure(403),
        PlaybackSourceHttpFailureKind.signedUrlRejected,
      );
      expect(
        classifyPlaybackSourceHttpFailure(404),
        PlaybackSourceHttpFailureKind.resourceMissing,
      );
      expect(
        classifyPlaybackSourceHttpFailure(503),
        PlaybackSourceHttpFailureKind.transientHttpFailure,
      );
      expect(
        classifyPlaybackSourceHttpFailure(422),
        PlaybackSourceHttpFailureKind.permanentHttpFailure,
      );
      expect(
        classifyPlaybackSourceHttpFailure(null),
        PlaybackSourceHttpFailureKind.noHttpStatus,
      );
      expect(
        just_audio.PlayerException(
          2004,
          'bad status [http_status=404]',
          0,
        ).httpStatusCode,
        404,
        reason: 'runtime playback events carry status in a safe marker',
      );
    });
  });
}
