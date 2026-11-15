import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/playback_error_event_gate.dart';

void main() {
  group('shouldHandlePlaybackErrorEvent', () {
    test('只接收当前请求已完成装载后的播放中错误', () {
      expect(
        shouldHandlePlaybackErrorEvent(
          errorCode: 0,
          isCurrentRequest: true,
          loadCompleted: true,
        ),
        isTrue,
      );
    });

    test('忽略过期请求或装载阶段错误，由对应请求Future处理', () {
      expect(
        shouldHandlePlaybackErrorEvent(
          errorCode: 0,
          isCurrentRequest: false,
          loadCompleted: true,
        ),
        isFalse,
      );
      expect(
        shouldHandlePlaybackErrorEvent(
          errorCode: 0,
          isCurrentRequest: true,
          loadCompleted: false,
        ),
        isFalse,
      );
    });

    test('快速切歌产生的just_audio加载中断不标记为播放失败', () {
      expect(
        shouldHandlePlaybackErrorEvent(
          errorCode: interruptedPlayerLoadErrorCode,
          isCurrentRequest: true,
          loadCompleted: true,
        ),
        isFalse,
      );
    });
  });
}
