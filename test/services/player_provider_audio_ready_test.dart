import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../lib/providers/player_provider.dart';

/// audioReady 就绪信号测试。
///
/// 背景：外部调用（文件管理器打开歌曲）在冷启动早期触发播放时，
/// _initAudioService 可能尚未完成；playSong 在 _audioService 为 null 时
/// 静默跳过实际播放。调用方必须先 await audioReady。
///
/// 说明：
/// 1. 必须用普通 test 而非 testWidgets——testWidgets 的 FakeAsync 环境不派发
///    平台通道响应，未 mock 的通道调用会永久挂起，导致就绪信号永不完成。
/// 2. 不能直接 new PlayerProvider() 触发真实音频初始化：Windows 宿主机上
///    构造 just_audio AudioPlayer 会加载平台实现并可能挂起（而非立即抛错）。
///    因此注入一个 init 立即返回、其余方法 via noSuchMethod 抛错的 fake，
///    使 _initAudioService 快速走完 try/catch 并执行方法末尾的 complete，
///    从而验证「初始化失败也必然完成、不挂起调用方」这一核心契约。
class _FakeAudioService {
  Future<void> init() async {}

  // ignore: annotate_overrides
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
        '_FakeAudioService: 未实现的方法 ${invocation.memberName}',
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('audioReady 音频引擎初始化失败也必然完成（不挂起调用方）', () async {
    SharedPreferences.setMockInitialValues({});
    // 注入 fake 加载器，避免触发真实 just_audio 平台初始化
    AudioServiceLoader.setTestOverride(() async => _FakeAudioService());
    final player = PlayerProvider();
    try {
      // fake 使初始化流程快速走完（即使失败），audioReady 应在超时前完成
      await player.audioReady.timeout(const Duration(seconds: 10));
    } finally {
      AudioServiceLoader.setTestOverride(null);
      player.dispose();
      // 让初始化期间派生的后台异步任务（均为 try/catch 包裹）跑完
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  });
}