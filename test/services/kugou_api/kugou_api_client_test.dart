import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// KugouApiClient.getLyric 双请求（LRC + KRC）合并逻辑测试。
///
/// 说明：项目未引入 mocktail / http_mock_adapter，且 `_get` 为私有方法，
/// 因此本测试聚焦于抽出的静态合并方法 `mergeLyricResponses`，
/// 它是 getLyric 双请求路径的核心逻辑（Future.wait 后调用）。
/// 覆盖 spec.md "Requirement: KRC 双请求与降级" 的 5 种场景。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KugouApiClient.mergeLyricResponses', () {
    // 模拟 LRC 响应 data 节点：decodeContent 为 LRC 明文
    const lrcText = '[00:01.00]Hello LRC\n[00:03.00]World';
    final lrcJson = <String, dynamic>{
      'content': 'BASE64_LRC_RAW',
      'decodeContent': lrcText,
      'translated_content': '[00:01.00]你好',
    };

    // 模拟 KRC 响应 data 节点：Node 侧把解码后的 KRC 明文放在 decodeContent 字段
    // （这是双请求场景下 KRC 响应的典型形态）
    const krcText = '[1000,2000]<0,1000,0>Hello';
    final krcJson = <String, dynamic>{
      'content': 'BASE64_KRC_RAW',
      'decodeContent': krcText,
    };

    test('场景1: 双请求成功 — decodedContent 与 decodedKrcContent 都有值', () {
      final lyric = KugouApiClient.mergeLyricResponses(lrcJson, krcJson);

      expect(lyric, isNotNull);
      // LRC 明文来自 LRC 响应的 decodeContent
      expect(lyric!.decodedContent, lrcText);
      // KRC 明文来自 KRC 响应的 decodeContent（在合并逻辑中映射到 decodedKrcContent）
      expect(lyric.decodedKrcContent, krcText);
      // translatedContent 来自 LRC 响应
      expect(lyric.translatedContent, '[00:01.00]你好');
      // content 优先用 LRC 的原始字段
      expect(lyric.content, 'BASE64_LRC_RAW');
      // displayLyric 优先返回 KRC
      expect(lyric.displayLyric, krcText);
      expect(lyric.displayKrcLyric, krcText);
      expect(lyric.displayLrcLyric, lrcText);
    });

    test('场景1变体: KRC 响应显式带 decodeKrcContent 字段时优先用专用字段', () {
      // 上游若显式返回 decodeKrcContent 字段，应优先于 decodeContent
      final krcJsonWithExplicitField = <String, dynamic>{
        'content': 'BASE64_KRC_RAW',
        'decodeContent': 'SHOULD_NOT_BE_USED',
        'decodeKrcContent': krcText,
      };
      final lyric = KugouApiClient.mergeLyricResponses(
        lrcJson,
        krcJsonWithExplicitField,
      );
      expect(lyric, isNotNull);
      expect(lyric!.decodedKrcContent, krcText);
      expect(lyric.decodedContent, lrcText);
    });

    test('场景2: 仅 LRC 成功（KRC 失败）— decodedKrcContent 为 null', () {
      // KRC 请求失败 → krcJson 为 null
      final lyric = KugouApiClient.mergeLyricResponses(lrcJson, null);

      expect(lyric, isNotNull);
      expect(lyric!.decodedContent, lrcText);
      expect(lyric.decodedKrcContent, isNull);
      expect(lyric.translatedContent, '[00:01.00]你好');
      // 无 KRC 时 displayLyric 降级到 LRC
      expect(lyric.displayLyric, lrcText);
    });

    test('场景3: 仅 KRC 成功（LRC 失败）— decodedContent 为 null', () {
      // LRC 请求失败 → lrcJson 为 null
      final lyric = KugouApiClient.mergeLyricResponses(null, krcJson);

      expect(lyric, isNotNull);
      expect(lyric!.decodedContent, isNull);
      expect(lyric.decodedKrcContent, krcText);
      // 无 LRC 时 displayLyric 降级到 KRC
      expect(lyric.displayLyric, krcText);
      expect(lyric.displayKrcLyric, krcText);
      expect(lyric.displayLrcLyric, isNull);
    });

    test('场景4: 两者都失败 — 返回 null', () {
      final lyric = KugouApiClient.mergeLyricResponses(null, null);
      expect(lyric, isNull);
    });

    test('场景5: 显式 fmt=krc 单请求路径 — 仅 KRC 响应被解析为 KugouLyric', () {
      // 此场景对应 getLyric(fmt: 'krc') 的单请求路径：
      // 直接 KugouLyric.fromJson(krcJson)，不走合并逻辑。
      // 单请求路径下 fromJson 把 decodeContent 映射到 decodedContent
      // （因为 fromJson 不知道响应是 LRC 还是 KRC）。
      // 这是单请求路径的已知行为；双请求路径通过 mergeLyricResponses
      // 才能正确把 KRC 响应的 decodeContent 映射到 decodedKrcContent。
      final krcJsonStandalone = <String, dynamic>{
        'content': 'BASE64_KRC_RAW',
        'decodeContent': krcText,
      };
      final lyric = KugouLyric.fromJson(krcJsonStandalone);

      // 单请求路径下 decodeContent 落入 decodedContent
      expect(lyric.decodedContent, krcText);
      expect(lyric.decodedKrcContent, isNull);
      expect(lyric.displayLyric, krcText);
    });

    test('合并时 translatedContent 优先取 LRC，LRC 缺失则取 KRC', () {
      // LRC 没有 translated_content，KRC 有
      final lrcNoTrans = <String, dynamic>{
        'content': 'LRC_RAW',
        'decodeContent': lrcText,
      };
      final krcWithTrans = <String, dynamic>{
        'content': 'KRC_RAW',
        'decodeContent': krcText,
        'translated_content': '[00:01.00]KRC翻译',
      };
      final lyric = KugouApiClient.mergeLyricResponses(lrcNoTrans, krcWithTrans);
      expect(lyric, isNotNull);
      expect(lyric!.translatedContent, '[00:01.00]KRC翻译');
    });

    test('空 JSON 输入不崩溃，返回非 null 但字段为空/null', () {
      final lyric = KugouApiClient.mergeLyricResponses(
        <String, dynamic>{},
        <String, dynamic>{},
      );
      expect(lyric, isNotNull);
      expect(lyric!.content, '');
      expect(lyric.decodedContent, isNull);
      expect(lyric.decodedKrcContent, isNull);
    });

    test('韩语歌 KRC 含翻译+汉字拟声词+拉丁罗马音 3 条目时正确分离', () {
      // 模拟韩语歌 KRC 明文：含 [language:<base64>] 元数据
      // base64 解码后 content 数组有 3 个 entry：
      // - 单元素翻译（含汉字）
      // - 多元素汉字拟声词（含 CJK，旧逻辑会误判为翻译并抢占 translation）
      // - 多元素拉丁罗马音（纯 ASCII，每元素一个词如 xeng）
      final langJson = jsonEncode({
        'content': [
          {
            'language': 0,
            'lyricContent': [
              ['翻译行1'],
              ['翻译行2'],
            ],
          },
          {
            'language': 1,
            'lyricContent': [
              ['啊', '哦'],
              ['嗯', '啊'],
            ],
          },
          {
            'language': 1,
            'lyricContent': [
              ['xeng', 'xeng'],
              ['xeng', 'xeng'],
            ],
          },
        ],
      });
      final b64 = base64Encode(utf8.encode(langJson));
      // KRC 明文：歌词行带时间戳（韩文原文）+ [language:] 元数据
      final krcText = '[1000,2000]<0,1000,0>행1\n'
          '[3000,2000]<0,1000,0>행2\n'
          '[language:$b64]';
      final krcJson = <String, dynamic>{
        'content': 'BASE64_KRC_RAW',
        'decodeContent': krcText,
      };

      final lyric = KugouApiClient.mergeLyricResponses(null, krcJson);

      expect(lyric, isNotNull);
      // 翻译应是单元素条目（"翻译行1"/"翻译行2"），而非汉字拟声词
      expect(lyric!.translatedContent, contains('翻译行1'));
      expect(lyric.translatedContent, contains('翻译行2'));
      expect(lyric.translatedContent, isNot(contains('啊')));
      // roma 应是第一个多元素条目（汉字拟声词），按 ??= 语义保留首个
      expect(lyric.romaContent, contains('啊'));
      expect(lyric.romaContent, contains('哦'));
    });
  });

  group('KugouApiClient 多账号存储', () {
    late KugouApiClient client;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      KugouApiClient.markServerReady();
      client = KugouApiClient();
      // 清除之前测试组残留的单例内存状态
      await client.clearCookies();
    });

    test('setLoginCookies 后保存账号列表，setLoginCookies(B) 时不丢失 A', () async {
      await client.setLoginCookies('token_a', 'user_a', vipToken: 'vip_a');
      expect(client.savedAccounts.length, 1);
      expect(client.savedAccounts.first.userid, 'user_a');
      expect(client.isLoggedIn, true);

      // 保存第二个账号
      await client.setLoginCookies('token_b', 'user_b', vipToken: 'vip_b');
      expect(client.savedAccounts.length, 2);
      // 仍然可以读取 user_a 的凭证（通过 switchToUser）
      final switched = await client.switchToUser('user_a');
      expect(switched, true);
      expect(client.token, 'token_a');
      expect(client.userid, 'user_a');
    });

    test('switchToUser 切换凭证', () async {
      await client.setLoginCookies('token_a', 'user_a');
      await client.setLoginCookies('token_b', 'user_b');
      expect(client.userid, 'user_b');

      // 切回 A
      expect(await client.switchToUser('user_a'), true);
      expect(client.token, 'token_a');
      expect(client.userid, 'user_a');

      // 不存在的用户
      expect(await client.switchToUser('nonexistent'), false);
    });

    test('removeAccount 删除账号及凭证', () async {
      await client.setLoginCookies('token_a', 'user_a');
      await client.setLoginCookies('token_b', 'user_b');

      // 删除非当前账号
      await client.removeAccount('user_a');
      expect(client.savedAccounts.length, 1);
      // user_a 凭证仍在存储中，但已从列表移除
      expect(await client.switchToUser('user_a'), false);

      // 删除当前账号
      await client.removeAccount('user_b');
      expect(client.savedAccounts.length, 0);
      expect(client.isLoggedIn, false);
      expect(client.userid, null);
    });

    test('updateAccountProfile 更新昵称/头像', () async {
      await client.setLoginCookies('token', 'user1');
      await client.updateAccountProfile('user1', nickname: '测试用户', avatar: 'http://example.com/avatar.png');
      final saved = client.savedAccounts.first;
      expect(saved.nickname, '测试用户');
      expect(saved.avatar, 'http://example.com/avatar.png');

      // 昵称/头像已持久化到 prefs 的账号列表
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('kugou_accounts');
      expect(raw, isNotNull);
      expect(raw, contains('测试用户'));
    });
  });
}
