import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/modules/listen_together/widgets/guest_play_confirm_dialog.dart';

const _song = Song(
  id: 'HASH1',
  title: '测试歌曲',
  artist: '歌手',
  album: '',
  duration: Duration(seconds: 60),
  isOnline: true,
);

/// 挂一个宿主页并打开弹窗；结果写进 [out]。
Future<void> _open(
  WidgetTester tester, {
  required ValueNotifier<GuestPlayChoice?> out,
  bool alreadyDetached = false,
  String roomName = '房间A',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              out.value = await showGuestPlayConfirmDialog(
                context: context,
                song: _song,
                roomName: roomName,
                alreadyDetached: alreadyDetached,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('点「脱离房间播放」返回 detachAndPlay', (tester) async {
    final out = ValueNotifier<GuestPlayChoice?>(null);
    await _open(tester, out: out);

    expect(find.text('脱离房间播放'), findsOneWidget);
    await tester.tap(find.text('脱离房间播放'));
    await tester.pumpAndSettle();

    expect(out.value, GuestPlayChoice.detachAndPlay);
  });

  testWidgets('点「申请点歌」返回 orderSong', (tester) async {
    final out = ValueNotifier<GuestPlayChoice?>(null);
    await _open(tester, out: out);

    await tester.tap(find.text('申请点歌'));
    await tester.pumpAndSettle();

    expect(out.value, GuestPlayChoice.orderSong);
  });

  testWidgets('点「取消」返回 dismissed', (tester) async {
    final out = ValueNotifier<GuestPlayChoice?>(null);
    await _open(tester, out: out);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(out.value, GuestPlayChoice.dismissed);
  });

  testWidgets('点遮罩（NULL 返回）归一为 dismissed', (tester) async {
    final out = ValueNotifier<GuestPlayChoice?>(null);
    await _open(tester, out: out);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(out.value, GuestPlayChoice.dismissed);
  });

  testWidgets('已脱离态主按钮文案改为「直接播放」', (tester) async {
    final out = ValueNotifier<GuestPlayChoice?>(null);
    await _open(tester, out: out, alreadyDetached: true);

    expect(find.text('直接播放'), findsOneWidget);
    expect(find.text('脱离房间播放'), findsNothing);
  });

  testWidgets('跟随态主按钮文案为「脱离房间播放」且只有两个可点动作', (tester) async {
    final out = ValueNotifier<GuestPlayChoice?>(null);
    await _open(tester, out: out);

    expect(find.text('脱离房间播放'), findsOneWidget);
    expect(find.text('申请点歌'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
  });

  testWidgets('房间名为空时不出现空引号', (tester) async {
    final out = ValueNotifier<GuestPlayChoice?>(null);
    await _open(tester, out: out, roomName: '');

    // 「」为空房名时的兜底文案，不得出现连续空引号
    expect(find.textContaining('「」'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });
}
