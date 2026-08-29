import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// KugouProvider 歌词 getter 行为测试（Task 16）。
///
/// 覆盖 spec.md "Requirement: Provider 暴露 KRC / LRC 双 getter" 的可测部分。
///
/// **测试边界说明**：
/// 项目未引入 mocktail / http_mock_adapter，且 `KugouApiClient` 是私有单例字段
/// （`final KugouApiClient _apiClient = KugouApiClient();`），无法注入 mock。
/// 因此 `getLyric` 成功 / 失败的 HTTP 路径不在此处直接覆盖，而是由以下两层
/// 单元测试间接保证：
///  1. `test/services/kugou_api/kugou_api_client_test.dart` 覆盖
///     `mergeLyricResponses` 静态方法的 5 种合并场景（Task 15 双请求核心逻辑）；
///  2. `test/services/kugou_api/kugou_models_test.dart` 覆盖
///     `KugouLyric.displayLyric` / `displayKrcLyric` / `displayLrcLyric`
///     的降级行为（Task 14 模型层契约）。
///
/// 本文件聚焦 Provider 层：getter 是否存在、是否共享 `_lyric` 存储、
/// 是否不破坏现有调用方。`getLyric` 的方法签名兼容性由 Dart 编译器保证
/// （`full_player.dart:91` 调用 `kugouProvider.getLyric(songId, songName: song.title)`，
/// 任何签名变更都会导致编译失败）。
void main() {
  group('KugouProvider 歌词 getter (Task 16)', () {
    late KugouProvider provider;

    setUp(() {
      provider = KugouProvider();
    });

    tearDown(() {
      provider.dispose();
    });

    test('SubTask 16.2: 暴露 krcLyric 与 lrcLyric 两个 getter，返回 KugouLyric?',
        () {
      // 初始状态：两个新 getter 都应返回 null
      // 返回类型 KugouLyric? 由 getter 声明静态保证，无需运行时校验
      expect(provider.krcLyric, isNull);
      expect(provider.lrcLyric, isNull);
    });

    test(
        'SubTask 16.3: 保留现有 lyric getter 兼容旧代码（返回 krcLyric ?? lrcLyric）',
        () {
      // 初始时三个 getter 均为 null，关系 lyric == krcLyric ?? lrcLyric 成立
      expect(provider.lyric, isNull);
      expect(provider.lyric, equals(provider.krcLyric ?? provider.lrcLyric));

      // Task 15 返回单个合并后的 KugouLyric，krcLyric 与 lrcLyric 引用同一对象，
      // 因此二者应始终 identical（同一 _lyric 实例），由模型层
      // displayKrcLyric/displayLrcLyric 区分 KRC / LRC 部分。
      // 初始 null 时 identical 成立；非 null 时也成立。
      expect(identical(provider.krcLyric, provider.lrcLyric), isTrue);
    });

    test('lyric / krcLyric / lrcLyric 三者在初始状态下一致为 null', () {
      expect(provider.lyric, isNull);
      expect(provider.krcLyric, isNull);
      expect(provider.lrcLyric, isNull);
      // 一致性不变式：lyric 永远等于 krcLyric ?? lrcLyric
      expect(provider.lyric, equals(provider.krcLyric ?? provider.lrcLyric));
    });

    test('其他现有 getter 行为不受影响（isLoading / error / songUrl 等）', () {
      // 这些 getter 与歌词无关，Task 16 不应破坏它们
      expect(provider.isLoading, isFalse);
      expect(provider.error, isNull);
      expect(provider.songUrl, isNull);
      expect(provider.comments, isNull);
      expect(provider.searchResults, isNull);
      expect(provider.hotSearchKeywords, isEmpty);
      expect(provider.recommendSongs, isEmpty);
      expect(provider.personalFmSongs, isEmpty);
      expect(provider.rankSongs, isEmpty);
      expect(provider.currentPlaylistSongs, isEmpty);
    });

    test('KugouLyric 模型契约：displayLyric 优先返回 KRC，降级 LRC', () {
      // 直接构造 KugouLyric 验证 Provider 依赖的模型契约
      // （此契约由 Task 14 实现，由 kugou_models_test.dart 完整覆盖，
      // 这里再验证一次确保 Provider 通过 lyric?.displayLyric 拿到的是 KRC 优先）
      const lrcText = '[00:01.00]Hello LRC';
      const krcText = '[1000,2000]<0,1000,0>Hello';

      // 同时有 KRC + LRC：displayLyric 返回 KRC
      final bothLyric = KugouLyric(
        content: 'raw',
        decodedContent: lrcText,
        decodedKrcContent: krcText,
      );
      expect(bothLyric.displayLyric, krcText);
      expect(bothLyric.displayKrcLyric, krcText);
      expect(bothLyric.displayLrcLyric, lrcText);

      // 仅 LRC：displayLyric 降级返回 LRC
      final lrcOnlyLyric = KugouLyric(
        content: 'raw',
        decodedContent: lrcText,
      );
      expect(lrcOnlyLyric.displayLyric, lrcText);
      expect(lrcOnlyLyric.displayKrcLyric, isNull);
      expect(lrcOnlyLyric.displayLrcLyric, lrcText);

      // 仅 KRC：displayLyric 返回 KRC，displayLrcLyric 为 null
      final krcOnlyLyric = KugouLyric(
        content: 'raw',
        decodedKrcContent: krcText,
      );
      expect(krcOnlyLyric.displayLyric, krcText);
      expect(krcOnlyLyric.displayKrcLyric, krcText);
      expect(krcOnlyLyric.displayLrcLyric, isNull);
    });
  });

  group('KugouProvider 多账号管理', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    late KugouProvider provider;

    setUp(() async {
      // 重置本地存储 + 标记本地服务器就绪（避免测试内等待 8s / 真实网络）
      SharedPreferences.setMockInitialValues({});
      KugouApiClient.markServerReady();

      // mock path_provider：logout/switch 会触发 DefaultCacheManager 清头像缓存，
      // 其内部用 path_provider 拿临时目录，测试环境无插件实现会抛未处理异常
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => switch (call.method) {
          'getTemporaryDirectory' ||
          'getApplicationSupportDirectory' ||
          'getApplicationDocumentsDirectory' ||
          'getDownloadsDirectory' =>
            Directory.systemTemp.path,
          _ => null,
        },
      );

      provider = KugouProvider();
      // 清除之前测试残留的单例内存账号列表（_accounts 跨测试共享）
      await provider.apiClient.clearCookies();
    });

    tearDown(() {
      provider.dispose();
    });

    test('savedAccounts 暴露已保存的账号列表', () async {
      await provider.apiClient.setLoginCookies('token_a', 'user_a');
      await provider.apiClient.setLoginCookies('token_b', 'user_b');
      expect(provider.savedAccounts.length, 2);
      expect(provider.savedAccounts.any((a) => a.userid == 'user_a'), isTrue);
      expect(provider.savedAccounts.any((a) => a.userid == 'user_b'), isTrue);
    });

    test('logout 只有一个账号时回到未登录态', () async {
      await provider.apiClient.setLoginCookies('token_a', 'user_a');
      expect(provider.apiClient.isLoggedIn, isTrue);
      await provider.logout();
      expect(provider.isLoggedIn, isFalse);
      expect(provider.savedAccounts, isEmpty);
      expect(provider.apiClient.userid, isNull);
    });

    test('logout 有多个账号时自动切换到剩余账号', () async {
      await provider.apiClient.setLoginCookies('token_a', 'user_a');
      await provider.apiClient.setLoginCookies('token_b', 'user_b');
      // 当前为 user_b，logout 应删除 user_b 并自动切换到 user_a
      await provider.logout();
      expect(provider.apiClient.userid, 'user_a');
      expect(provider.apiClient.token, 'token_a');
      expect(provider.isLoggedIn, isTrue);
      expect(provider.savedAccounts.any((a) => a.userid == 'user_a'), isTrue);
      expect(provider.savedAccounts.any((a) => a.userid == 'user_b'), isFalse);
    });

    test('switchAccount 切换到指定账号并更新当前账号', () async {
      await provider.apiClient.setLoginCookies('token_a', 'user_a');
      await provider.apiClient.setLoginCookies('token_b', 'user_b');
      final ok = await provider.switchAccount('user_a');
      expect(ok, isTrue);
      expect(provider.apiClient.userid, 'user_a');
      expect(provider.isLoggedIn, isTrue);
    });
  });
}
