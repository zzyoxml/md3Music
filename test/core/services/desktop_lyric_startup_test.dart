import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:md3music/main.dart';
import 'package:md3music/core/services/desktop_lyric_service.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/providers/theme_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';
import 'package:md3music/services/kugou_api/lyric_lookup_result.dart';

class _Player extends ChangeNotifier implements PlayerProvider {
  @override
  Song? currentSong;
  @override
  Duration get position => const Duration(seconds: 2);
  @override
  Duration? get duration => const Duration(minutes: 3);
  @override
  bool get isPlaying => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Kugou extends ChangeNotifier implements KugouProvider {
  final requests = <String, Completer<LyricLookupResult>>{};
  final progress = <String, void Function(KugouLyric)?>{};
  @override
  Future<LyricLookupResult> getLyricResult(
    String hash, {
    String? songName,
    String fmt = 'lrc',
    String? localIdentity,
    bool forceRefresh = false,
    void Function(KugouLyric)? onProgress,
  }) {
    progress[hash] = onProgress;
    return (requests[hash] = Completer<LyricLookupResult>()).future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Theme extends ChangeNotifier implements ThemeProvider {
  @override
  double get displayScale => 1;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Song _song(String id) => Song(
  id: id,
  title: id,
  artist: '歌手',
  album: '',
  duration: const Duration(minutes: 3),
  isOnline: true,
);
const _lyric = KugouLyric(content: '[00:00.00]第一句\n[00:20.00]第二句');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in ['reopen', 'switchPending', 'progress']) {
    testWidgets('桌面歌词启动回归 $scenario', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final calls = <MethodCall>[];
      const channel = MethodChannel('com.md3music.md3music/floating_lyric');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'hasOverlayPermission' ||
            call.method == 'startFloatingLyric') {
          return true;
        }
        return null;
      });
      final player = _Player()..currentSong = _song(scenario);
      final kugou = _Kugou();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<KugouProvider>.value(value: kugou),
            ChangeNotifierProvider<ThemeProvider>.value(value: _Theme()),
          ],
          child: MaterialApp(
            navigatorKey: appNavigatorKey,
            home: const SizedBox(),
          ),
        ),
      );
      final service = DesktopLyricService.instance;
      addTearDown(() async {
        await service.disable();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });
      try {
        await service.enable();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(service.enabled, isTrue);
        expect(kugou.requests.containsKey(scenario), isTrue);
        if (scenario == 'switchPending') {
          await service.disable();
          player.currentSong = _song('next');
          await service.enable();
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
          expect(
            kugou.requests.containsKey('next'),
            isTrue,
            reason: '旧请求未结束也必须请求新曲，不能锁死 awaiting',
          );
          calls.clear();
          kugou.progress[scenario]?.call(const KugouLyric(content: '[00:00.00]旧曲'));
          kugou.requests[scenario]!.complete(
            const LyricLookupResult.canceled(),
          );
          kugou.requests['next']?.complete(
            const LyricLookupResult.found(_lyric),
          );
          await tester.pump();
          await tester.pump();
          expect(calls.where((c) => c.method == 'updateLyric' &&
              c.arguments['lyric'] == '旧曲'), isEmpty);
        } else if (scenario == 'progress') {
          calls.clear();
          kugou.progress[scenario]?.call(_lyric);
          await tester.pump();
          await tester.pump();
          expect(
            calls.where(
              (c) => c.method == 'updateLyric' && c.arguments['lyric'] == '第一句',
            ),
            isNotEmpty,
            reason: '首份 LRC 不等补充 KRC 请求结束即可显示',
          );
          kugou.requests[scenario]!.complete(
            const LyricLookupResult.transientFailure(),
          );
          await tester.pump();
          await tester.pump();
          expect(
            calls.where(
              (c) =>
                  c.method == 'updateLyric' && c.arguments['lyric'] == '歌词加载失败',
            ),
            isEmpty,
          );
        } else {
          kugou.requests[scenario]!.complete(
            const LyricLookupResult.found(_lyric),
          );
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          await service.disable();
          calls.clear();
          await service.enable();
          await tester.pump();
          expect(
            calls
                .firstWhere((c) => c.method == 'startFloatingLyric')
                .arguments['lyric'],
            '第一句',
            reason: '创建窗口时不能先传空歌词',
          );
          expect(
            calls.where(
              (c) => c.method == 'updateLyric' && c.arguments['lyric'] == '第一句',
            ),
            isNotEmpty,
            reason: '同一行重新打开也必须立即完整推送',
          );
        }
        await tester.pump();
      } finally {
        await service.disable();
        await tester.pump();
      }
    });
  }
}
