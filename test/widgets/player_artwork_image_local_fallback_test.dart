import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/widgets/player_artwork_image.dart';

/// [PlayerArtworkImage] 的本地封面回退回归。
///
/// 用户症状：Android 上播放本地音乐时，播放页（FullPlayer）不显示封面，列表
/// 正常；开关「匹配在线封面」也没有变化。根因是 Android MediaStore 扫描出的
/// 本地歌 `artworkUri` 为 `content://.../albumart/<id>`，该分支只能靠
/// `fallbackFilePath`（= 播放解析后回写的 `file://` localPath）读内嵌封面，
/// 而路径既带 `file://` 前缀又带 percent 编码，`File()` 读不到 → 占位符；
/// 同时该分支也没有查匹配偏好，所以开关无效。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Uint8List pngBytes;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('md3_artwork_widget');
    pngBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8'
      'BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 造一个带内嵌封面（ID3v2.3 APIC）的临时 MP3，返回其裸路径。
  String writeAudioWithCover(String name) {
    final path = '${tempDir.path}${Platform.pathSeparator}$name';
    File(path).writeAsBytesSync(_buildMp3WithApic(pngBytes), flush: true);
    return path;
  }

  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: SizedBox(width: 80, height: 80, child: child))),
  );

  testWidgets('content:// 封面 + file:// 回退路径：必须显示内嵌封面而不是占位符', (tester) async {
    final barePath = writeAudioWithCover('晴天 a.mp3');
    // 播放解析回写的真实形态（`Uri.file` 会给中文/空格做 percent 编码）
    final fallback = Uri.file(barePath).toString();
    expect(fallback.contains('%'), isTrue);

    await tester.pumpWidget(
      host(
        PlayerArtworkImage(
          artworkUri: 'content://media/external/audio/albumart/1',
          fallbackFilePath: fallback,
        ),
      ),
    );
    // 内嵌封面走 LocalArtworkCache → compute(isolate)，必须放行真实异步
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();

    expect(
      find.byType(Image),
      findsOneWidget,
      reason: '回归点：此前路径未归一 → LocalArtworkCache 返回 null → 只剩音符占位符',
    );
    expect(find.byIcon(Icons.music_note), findsNothing);

    final provider = tester.widget<Image>(find.byType(Image)).image;
    final memory = provider is ResizeImage ? provider.imageProvider : provider;
    expect(memory, isA<MemoryImage>());
  });

  testWidgets('content:// 封面 + local:// 回退：同样显示内嵌封面', (tester) async {
    final barePath = writeAudioWithCover('local-style.mp3');
    await tester.pumpWidget(
      host(
        PlayerArtworkImage(
          artworkUri: 'content://media/external/audio/albumart/2',
          fallbackFilePath: 'local://$barePath',
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.music_note), findsNothing);
  });

  testWidgets('回退路径不可用（文件不存在）：保持占位符，不伪造封面', (tester) async {
    await tester.pumpWidget(
      host(
        PlayerArtworkImage(
          artworkUri: 'content://media/external/audio/albumart/3',
          fallbackFilePath: 'file:///md3music_test_missing/not-there.mp3',
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.music_note), findsOneWidget);
  });

  testWidgets('content:// 且无回退路径：保持占位符（不新增原生解码通道）', (tester) async {
    await tester.pumpWidget(
      host(
        PlayerArtworkImage(
          artworkUri: 'content://media/external/audio/albumart/4',
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.music_note), findsOneWidget);
  });
}

// ── 最小 MP3 构造（沿用 local_lyric_loader_test 的写法）──

List<int> _synchsafe(int value) => [
  (value >> 21) & 0x7F,
  (value >> 14) & 0x7F,
  (value >> 7) & 0x7F,
  value & 0x7F,
];

Uint8List _buildMp3WithApic(Uint8List image) {
  final payload = <int>[
    0, // 文本编码 latin1
    ...'image/png'.codeUnits,
    0, // MIME 结束符
    3, // picture type: Front cover
    0, // 描述结束符
    ...image,
  ];
  final frames = <int>[
    ...'APIC'.codeUnits,
    ..._synchsafe(payload.length),
    0,
    0,
    ...payload,
  ];
  return Uint8List.fromList(<int>[
    ...'ID3'.codeUnits,
    3,
    0,
    0,
    ..._synchsafe(frames.length),
    ...frames,
  ]);
}
