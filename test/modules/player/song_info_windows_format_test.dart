import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/player/song_info_page.dart';
import 'package:md3music/providers/player_provider.dart';
import 'package:md3music/providers/song_match_provider.dart';

class _Audio {
  _Audio(this.player);
  final _Native player;
}

class _Native {
  Future<Map<String, dynamic>?> Function() read = () async => null;
  Future<Map<String, dynamic>?> getSourceFormat() => read();
  Future<Map<String, dynamic>?> getTransferStats() async => null;
}

class _Player extends ChangeNotifier implements PlayerProvider {
  _Player(this.currentSong, _Native native) : audioService = _Audio(native);
  @override
  Song? currentSong;
  @override
  final dynamic audioService;
  void change(Song song) {
    currentSong = song;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Match extends ChangeNotifier implements SongMatchProvider {
  @override
  Song? matchedSongFor(Song song) => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Song _song(String id, {String? path}) => Song(
  id: id,
  title: id,
  artist: '歌手',
  album: '专辑',
  duration: const Duration(seconds: 1),
  localPath: path,
);

const _format = <String, dynamic>{
  'hasData': true,
  'sampleRate': 96000,
  'bitsPerSample': 24,
  'channelCount': 2,
};

void main() {
  Future<void> mount(WidgetTester tester, _Player player) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ChangeNotifierProvider<SongMatchProvider>(create: (_) => _Match()),
        ],
        child: const MaterialApp(home: SongInfoPage()),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'Windows 显示原生源格式，不把 24-bit 猜成 16-bit',
    (tester) async {
      final native = _Native()..read = () async => _format;
      await mount(tester, _Player(_song('first'), native));
      expect(find.text('96 kHz'), findsWidgets);
      expect(find.text('24-bit'), findsWidgets);
      expect(find.text('立体声'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    skip: !Platform.isWindows,
  );

  testWidgets(
    'Windows 未知位深保持未知，不伪造为 16-bit',
    (tester) async {
      final native = _Native()
        ..read = () async => {..._format, 'bitsPerSample': 0};
      await mount(tester, _Player(_song('lossy'), native));
      expect(find.text('96 kHz'), findsWidgets);
      expect(find.text('16-bit'), findsNothing);
      expect(find.text('—'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    skip: !Platform.isWindows,
  );

  testWidgets(
    'Windows 媒体稍后就绪时自动补取，不永久显示空值',
    (tester) async {
      var calls = 0;
      final native = _Native()
        ..read = () async => ++calls == 1 ? {'hasData': false} : _format;
      await mount(tester, _Player(_song('loading'), native));
      expect(find.text('96 kHz'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('96 kHz'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    skip: !Platform.isWindows,
  );

  testWidgets(
    'Windows 切歌清除旧值，忽略旧歌曲迟到的格式请求',
    (tester) async {
      final old = Completer<Map<String, dynamic>?>();
      var calls = 0;
      final native = _Native()
        ..read = () => ++calls == 1
            ? old.future
            : Future.value({..._format, 'sampleRate': 48000});
      final player = _Player(_song('old'), native);
      await mount(tester, player);
      player.change(_song('new'));
      await tester.pump();
      await tester.pump();
      expect(find.text('48 kHz'), findsWidgets);
      old.complete(_format);
      await tester.pump();
      expect(find.text('48 kHz'), findsWidgets);
      expect(find.text('96 kHz'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    skip: !Platform.isWindows,
  );

  testWidgets(
    'Windows 盘符路径能显示文件大小',
    (tester) async {
      await tester.runAsync(() async {
        final dir = Directory.systemTemp.createTempSync('md3-format-');
        try {
          final file = File('${dir.path}\\中文[测试].bin');
          file.writeAsBytesSync(List.filled(1024 * 1024, 0));
          final native = _Native()..read = () async => _format;
          await mount(tester, _Player(_song('size', path: file.path), native));
          // 在真实异步域内完成文件 I/O，避免 FakeAsync 挂住打开的文件句柄。
          await Future<void>.delayed(const Duration(milliseconds: 1200));
          await tester.pump();
          expect(find.text('1.0 MB'), findsWidgets);
          await tester.pumpWidget(const SizedBox());
        } finally {
          await tester.pumpWidget(const SizedBox());
          await Future<void>.delayed(const Duration(milliseconds: 100));
          dir.deleteSync(recursive: true);
        }
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    skip: !Platform.isWindows,
  );
}
