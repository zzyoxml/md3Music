import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/repositories/settings_repository.dart';
import 'package:md3music/modules/update/release_info.dart';
import 'package:md3music/modules/update/update_check_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSource implements ReleaseSource {
  _FakeSource(this.release);

  final ReleaseInfo? release;
  int calls = 0;

  @override
  Future<ReleaseInfo?> fetchLatest() async {
    calls++;
    return release;
  }
}

ReleaseInfo _release(String tag) => ReleaseInfo.fromTag(
  tagName: tag,
  htmlUrl: 'https://github.com/zzyoxml/md3Music/releases/tag/$tag',
);

/// 构造被测服务：注入假数据源、假当前版本、捕获提醒文案。
({UpdateCheckService service, _FakeSource source, List<String> messages}) _build({
  required ReleaseInfo? remote,
  required String currentVersion,
}) {
  final source = _FakeSource(remote);
  final messages = <String>[];
  final service = UpdateCheckService(
    source: source,
    readCurrentVersion: () async => currentVersion,
    notifier: messages.add,
  );
  return (service: service, source: source, messages: messages);
}

Future<int> _hoursAgo(int hours) async => DateTime.now().millisecondsSinceEpoch -
    Duration(hours: hours).inMilliseconds;

void main() {
  test('提醒开关关闭时不发起查询', () async {
    SharedPreferences.setMockInitialValues({
      'settings_update_reminder_enabled': false,
    });
    final ctx = _build(remote: _release('v9.9.9'), currentVersion: '5.6.0');

    expect(
      await ctx.service.checkAndNotify(),
      UpdateCheckOutcome.skipped,
    );
    expect(ctx.source.calls, 0);
    expect(ctx.messages, isEmpty);
  });

  test('距上次检查不足 12 小时时跳过且不查询', () async {
    SharedPreferences.setMockInitialValues({
      'update_last_check_ms': DateTime.now().millisecondsSinceEpoch,
    });
    final ctx = _build(remote: _release('v9.9.9'), currentVersion: '5.6.0');

    expect(
      await ctx.service.checkAndNotify(),
      UpdateCheckOutcome.skipped,
    );
    expect(ctx.source.calls, 0);
  });

  test('超过 12 小时后正常查询', () async {
    SharedPreferences.setMockInitialValues({
      'update_last_check_ms': DateTime.now().millisecondsSinceEpoch -
          const Duration(hours: 13).inMilliseconds,
    });
    final ctx = _build(remote: _release('v9.9.9'), currentVersion: '5.6.0');

    expect(await ctx.service.checkAndNotify(), UpdateCheckOutcome.notified);
    expect(ctx.source.calls, 1);
  });

  test('发现新版本时提醒一次并记录版本与检查时间', () async {
    SharedPreferences.setMockInitialValues({});
    final ctx = _build(remote: _release('v5.6.5'), currentVersion: '5.6.0');

    expect(await ctx.service.checkAndNotify(), UpdateCheckOutcome.notified);
    expect(ctx.messages, ['发现新版本 v5.6.5（当前 5.6.0），可在「设置 → 关于」中更新']);

    final repo = SettingsRepository();
    expect(await repo.getUpdateLastNotifiedVersion(), '5.6.5');
    expect(await repo.getUpdateLastCheckMs(), greaterThan(0));
  });

  test('同一版本不重复提醒', () async {
    SharedPreferences.setMockInitialValues({
      'update_last_check_ms': await _hoursAgo(13),
      'update_last_notified_version': '5.6.5',
    });
    final ctx = _build(remote: _release('v5.6.5'), currentVersion: '5.6.0');

    expect(
      await ctx.service.checkAndNotify(),
      UpdateCheckOutcome.skipped,
    );
    expect(ctx.messages, isEmpty);
  });

  test('远端不高于本地时视为已是最新', () async {
    SharedPreferences.setMockInitialValues({});
    final ctx = _build(remote: _release('v5.6.0'), currentVersion: '5.6.0');

    expect(
      await ctx.service.checkAndNotify(),
      UpdateCheckOutcome.upToDate,
    );
    expect(ctx.messages, isEmpty);
  });

  test('查询失败返回 failed 且不写入已提醒版本', () async {
    SharedPreferences.setMockInitialValues({});
    final ctx = _build(remote: null, currentVersion: '5.6.0');

    expect(
      await ctx.service.checkAndNotify(),
      UpdateCheckOutcome.failed,
    );
    expect(ctx.messages, isEmpty);
    expect(await SettingsRepository().getUpdateLastNotifiedVersion(), '');
    // 失败也记录检查时间：避免每次启动反复重试
    expect(await SettingsRepository().getUpdateLastCheckMs(), greaterThan(0));
  });

  test('版本号无法解析时不误报', () async {
    SharedPreferences.setMockInitialValues({});
    final ctx = _build(remote: _release('latest'), currentVersion: '5.6.0');

    expect(
      await ctx.service.checkAndNotify(),
      UpdateCheckOutcome.upToDate,
    );
    expect(ctx.messages, isEmpty);
  });
}
