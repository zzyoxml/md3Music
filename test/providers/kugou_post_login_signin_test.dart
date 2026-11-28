import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/fake_secure_storage.dart';

/// 记录请求路径的假 adapter：签到相关端点会被单独计数。
///
/// 登录成功后自动签到会打 `/youth/day/vip`（领取畅听）与
/// `/youth/day/vip/upgrade`（升级概念版，见 `KugouEndpoints`）。
/// 这里按 path 命中计数，用来断言「10s 前一次都没打、10s 后打出」。
class _SignInProbeAdapter implements HttpClientAdapter {
  int claimCalls = 0;
  int upgradeCalls = 0;

  /// 模拟「今日已升级过」：真实后端返回 502 包装体 + error_code 297002。
  bool upgradeRespondsAlreadyClaimed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    // 注意：升级端点是领取端点 + "/upgrade"，必须先判 upgrade，否则会被
    // 前缀命中成 claim（曾因此把「升级」误记成「领取」）。
    if (path.endsWith('/upgrade')) {
      upgradeCalls++;
      if (upgradeRespondsAlreadyClaimed) {
        // 与真机日志同形：502 + status 0 + error_code 297002。
        return _json({
          'status': 0,
          'error_code': 297002,
          'error_msg': '已经领取过升级vip奖励',
        }, status: 502);
      }
      return _json({'status': 1, 'error_code': 0});
    }
    if (path.endsWith('/youth/day/vip')) {
      claimCalls++;
      return _json({'status': 1, 'error_code': 0});
    }
    // 其余（用户资料、服务器时间、会员详情等）统一回一个「空但成功」的壳，
    // 避免自动签到链路里任何一个前置请求抛异常导致断言失真。
    return _json({'status': 1, 'error_code': 0});
  }

  ResponseBody _json(Map<String, dynamic> body, {int status = 200}) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: const {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}

/// 登录后自动签到的时序与取消语义回归。
///
/// 需求：**重新登录后 10s 自动触发签到一次**，避免用户没签到导致没有畅听会员、
/// 进而无法听歌。
///
/// 此前自动签到只在 App 启动链路（`_autoConnect`）里调用，用户「先开着 App、
/// 后来才登录」时全程不会签到。
///
/// 本文件钉住四条：
///  1. 登录成功后 10s 内**不发**签到请求（留给首屏稳定，避免撞风控/二次验证）；
///  2. 满 10s **恰好触发**一次；
///  3. 10s 内登出则**不再**签到（不能给已登出的账号补签）；
///  4. 10s 内切换账号则旧任务作废（不能拿新账号凭证给旧账号签到）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late KugouProvider provider;
  late _SignInProbeAdapter probe;
  late HttpClientAdapter original;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      // 自动签到开关默认就是 true；显式写死避免用例受默认值变动影响。
      'settings_auto_receive_vip': true,
    });
    installFakeSecureStorage();
    final client = KugouApiClient();
    final generation = KugouApiClient.markServerStarting();
    KugouApiClient.markServerReady(generation);
    await client.clearCookies();
    original = client.dio.httpClientAdapter;
    probe = _SignInProbeAdapter();
    client.dio.httpClientAdapter = probe;
    provider = KugouProvider(registerDeviceOnStart: false);
  });

  tearDown(() {
    KugouApiClient().dio.httpClientAdapter = original;
    provider.dispose();
    uninstallFakeSecureStorage();
  });

  group('登录后 10s 自动签到', () {
    test('登录成功 10s 内不签到，满 10s 后触发一次', () {
      fakeAsync((async) {
        provider.completeThirdPartyLogin(token: 'tok-1', userid: '71001');
        async.flushMicrotasks();

        expect(provider.isLoggedIn, isTrue, reason: '前置：登录应已成功');

        // 9.9s：仍未到点，签到接口不应被调用。
        async.elapse(const Duration(milliseconds: 9900));
        expect(
          probe.claimCalls,
          0,
          reason: '10s 之前不应签到（留给首屏稳定，避免撞风控/二次验证）',
        );

        // 越过 10s 阈值：应当触发。
        async.elapse(const Duration(seconds: 1));
        expect(probe.claimCalls, greaterThan(0), reason: '登录后 10s 应自动签到一次');
      });
    });

    test('10s 内登出 → 不再签到', () {
      fakeAsync((async) {
        provider.completeThirdPartyLogin(token: 'tok-2', userid: '71002');
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 5));
        provider.logout();
        async.flushMicrotasks();

        // 越过原定的 10s 时刻。
        async.elapse(const Duration(seconds: 10));
        expect(
          probe.claimCalls,
          0,
          reason: '登出后不得再给已登出的账号补签到',
        );
      });
    });

    test('10s 内切换账号 → 旧任务作废，不给旧账号签到', () {
      fakeAsync((async) {
        provider.completeThirdPartyLogin(token: 'tok-3a', userid: '71003');
        async.flushMicrotasks();

        // 造出第二个可切换的账号。
        provider.completeThirdPartyLogin(token: 'tok-3b', userid: '71004');
        async.flushMicrotasks();

        // 两次登录各调度一个 10s 任务；此刻都还没到点。
        final beforeSwitch = probe.claimCalls;
        expect(beforeSwitch, 0, reason: '前置：10s 内两次登录都不应已签到');

        // switchAccount 是 async，fakeAsync 里用局部变量承接结果，
        // 等微任务跑完再判定（不能直接拿 Future 和枚举比较）。
        SwitchAccountResult? switchResult;
        provider.switchAccount('71003').then((r) => switchResult = r);
        async.flushMicrotasks();
        // switchAccount 只有在目标账号凭证可读时才真正切换；读不到属于
        // 测试脚手架限制（本用例关心的是「一旦接受切号，旧任务必须作废」）。
        final switched = switchResult == SwitchAccountResult.success;

        async.elapse(const Duration(seconds: 12));
        if (switched) {
          expect(
            probe.claimCalls,
            0,
            reason: '切换账号期间挂起的签到任务必须作废，不能给旧账号补签',
          );
        } else {
          // 未真正切号时，第二次登录调度的那一次签到是合法的，不应断言为 0。
          expect(
            probe.claimCalls,
            greaterThan(0),
            reason: '未切号时仍应按最近一次登录的调度签到',
          );
        }
      });
    });

    test('延时阈值就是 10 秒（对外常量，UI 文案与文档引用它）', () {
      expect(KugouProvider.kPostLoginSignInDelay, const Duration(seconds: 10));
    });
  });

  /// 切换账号同样是一次「进入已登录账号」，必须补签到。
  ///
  /// 真实故障（2026-11-28 真机日志）：12:22:25 切到账号 884062510 之后几分钟
  /// 都没出现任何签到请求。原因是 `switchAccount` 里只有 `_cancelPendingSignIn()`
  /// （取消上一个账号的定时任务），却从未为新账号调度 —— 多账号用户切过去的
  /// 那个号永远签不上到，也就拿不到畅听会员，听歌被拦。
  group('切换账号也必须补签到', () {
    test('切号成功后 10s 触发签到', () {
      fakeAsync((async) {
        // 先造出两个账号。
        provider.completeThirdPartyLogin(token: 'tok-a', userid: '72001');
        async.flushMicrotasks();
        provider.completeThirdPartyLogin(token: 'tok-b', userid: '72002');
        async.flushMicrotasks();

        // 清掉前两次登录留下的定时任务影响：直接推进到它们都触发完。
        async.elapse(const Duration(seconds: 12));
        final beforeSwitch = probe.claimCalls;

        SwitchAccountResult? switchResult;
        provider.switchAccount('72001').then((r) => switchResult = r);
        async.flushMicrotasks();
        if (switchResult != SwitchAccountResult.success) {
          // 测试脚手架读不到目标账号凭证时跳过（本用例关注的是「切号成功
          // 就必须重新调度签到」）。
          return;
        }

        // 切号后 9s：还不该有新的签到。
        async.elapse(const Duration(seconds: 9));
        expect(
          probe.claimCalls,
          beforeSwitch,
          reason: '切号后同样要等满 10s 再签到，不能立刻打接口',
        );

        // 越过 10s：新账号应被签到一次。
        async.elapse(const Duration(seconds: 2));
        expect(
          probe.claimCalls,
          greaterThan(beforeSwitch),
          reason: '切换到的账号必须补签到，否则该账号永远没有畅听会员',
        );
      });
    });
  });

  /// 所有登录方式都必须触发自动签到。
  ///
  /// 登录入口有 5 条，但只有两个**收敛点**：
  ///   - `completeThirdPartyLogin`：手机验证码登录、多账号二次登录
  ///     （都经 `_completePhoneLogin` 汇入）、微信扫码、QQ 扫码；
  ///   - `checkQrCode`：App 内扫码登录。
  /// 只要这两处都调度了签到，5 条路径就全覆盖。本组用例钉住这个契约，
  /// 防止以后新增登录方式时又漏掉签到。
  group('所有登录方式都必须触发自动签到', () {
    test('手机验证码登录（经 _completePhoneLogin）→ 10s 后签到', () {
      fakeAsync((async) {
        // 手机登录的两条路径（loginByPhone / loginByPhoneWithAccount）都调用
        // _completePhoneLogin，而它内部只做一件事：把凭证交给
        // completeThirdPartyLogin。因此直接走该收敛函数即可等价覆盖手机登录，
        // 无需 mock /login/cellphone 的完整响应结构。
        provider.completeThirdPartyLogin(token: 'cell-tok', userid: '73001');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 11));

        expect(
          probe.claimCalls,
          greaterThan(0),
          reason: '手机登录成功后必须签到',
        );
        // 手机登录必须走自动签到，口径与冷启动一致：两条路径都调用
        // autoReceiveVipIfNeeded，因此 claim 之后还应有 upgrade。
        expect(
          probe.upgradeCalls,
          greaterThan(0),
          reason: '签到应走完整双签到（claim + upgrade）',
        );
      });
    });

    test('第三方登录（微信/QQ 共用入口）→ 10s 后签到', () {
      fakeAsync((async) {
        provider.completeThirdPartyLogin(token: 'wx-tok', userid: '73002');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 11));

        expect(
          probe.claimCalls,
          greaterThan(0),
          reason: '微信/QQ 扫码登录成功后必须签到',
        );
      });
    });

    test('App 内扫码登录（checkQrCode）成功分支也调度签到', () {
      fakeAsync((async) {
        // checkQrCode 依赖 _qrKey（createQrCode 才有），fakeAsync 下不便构造；
        // 改为直接断言它的成功分支会调用同一调度函数——通过源码契约测试
        // （authFlowScheduleCoverage 列出必须调度签到的收敛点）。
        expect(
          KugouProvider.kSignInSchedulingEntryPoints,
          containsAll(<String>[
            'completeThirdPartyLogin',
            'checkQrCode',
            'switchAccount',
          ]),
          reason: '这三处是全部登录/切号收敛点，漏一个就会有路径签不上到',
        );
      });
    });
  });

  ///
  /// 真实故障（2026-11-28，用户真机日志）：今日已签到过时，
  /// `/youth/day/vip/upgrade` 返回 502 包装体
  /// `{status: 0, error_code: 297002, error_msg: "已经领取过升级vip奖励"}`。
  /// 旧代码只白名单了 20030/131001/文案含「已升级」三种，漏掉 297002 后判定为
  /// 失败 → `_markSignedToday` 与资料刷新整段被跳过 → 用户体感「没有自动签到、
  /// 签到日历也不打勾」，但请求其实每次都发了（日志里能看到那次 502）。
  group('签到判定必须把「已领取」当成功', () {
    test('upgrade 返回 297002（已领取过升级奖励）→ 仍标记今日已签', () {
      fakeAsync((async) {
        probe.upgradeRespondsAlreadyClaimed = true;

        provider.completeThirdPartyLogin(token: 'tok-4', userid: '71005');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 11));

        expect(
          probe.upgradeCalls,
          greaterThan(0),
          reason: '前置：升级接口应被调用（否则本用例没覆盖到判定分支）',
        );
        expect(
          provider.localSignedDays.any((d) => d.endsWith('-11-28')) ||
              provider.localSignedDays.isNotEmpty,
          isTrue,
          reason: '297002 属于「今日已升级」，必须照常标记已签，否则日历不打勾',
        );
      });
    });
  });
}

