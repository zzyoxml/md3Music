import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/playback_status_feedback_state.dart';

void main() {
  test('没有加载和错误时隐藏提示条', () {
    final state = PlaybackStatusFeedbackState.resolve(
      loading: false,
      errorMessage: null,
    );

    expect(state.phase, PlaybackFeedbackPhase.hidden);
    expect(state.visible, isFalse);
    expect(state.actionLabel, isNull);
  });

  test('加载状态显示准备文案与取消动作', () {
    final state = PlaybackStatusFeedbackState.resolve(
      loading: true,
      errorMessage: null,
    );

    expect(state.phase, PlaybackFeedbackPhase.preparing);
    expect(state.message, '正在准备播放');
    expect(state.actionLabel, '取消');
  });

  test('播放命令已发出但音频未推进时显示等待与暂停动作', () {
    final state = PlaybackStatusFeedbackState.resolve(
      loading: false,
      awaitingProgress: true,
      errorMessage: null,
    );

    expect(state.phase, PlaybackFeedbackPhase.awaitingProgress);
    expect(state.message, '播放命令已发出，等待音频进度');
    expect(state.actionLabel, '暂停');
  });

  test('准备或失败状态优先于等待音频进度', () {
    final preparing = PlaybackStatusFeedbackState.resolve(
      loading: true,
      awaitingProgress: true,
      errorMessage: null,
    );
    final failed = PlaybackStatusFeedbackState.resolve(
      loading: false,
      awaitingProgress: true,
      errorMessage: '播放失败，请重试',
    );

    expect(preparing.phase, PlaybackFeedbackPhase.preparing);
    expect(failed.phase, PlaybackFeedbackPhase.failed);
  });

  test('失败状态显示安全错误文案与重试动作', () {
    final state = PlaybackStatusFeedbackState.resolve(
      loading: false,
      errorMessage: '无法获取播放链接，请重试',
    );

    expect(state.phase, PlaybackFeedbackPhase.failed);
    expect(state.message, '无法获取播放链接，请重试');
    expect(state.actionLabel, '重试');
  });

  test('失败优先于尚未清理的加载标志', () {
    final state = PlaybackStatusFeedbackState.resolve(
      loading: true,
      errorMessage: '播放失败，请检查网络后重试',
    );

    expect(state.phase, PlaybackFeedbackPhase.failed);
    expect(state.message, '播放失败，请检查网络后重试');
    expect(state.actionLabel, '重试');
  });

  test('空白错误不覆盖准备中状态', () {
    final state = PlaybackStatusFeedbackState.resolve(
      loading: true,
      errorMessage: '  ',
    );

    expect(state.phase, PlaybackFeedbackPhase.preparing);
    expect(state.actionLabel, '取消');
  });
}
