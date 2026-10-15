import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/widgets/smart_artwork_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Uint8List firstArtwork;
  late Uint8List secondArtwork;

  setUp(() {
    firstArtwork = File('assets/images/app_icon.png').readAsBytesSync();
    secondArtwork = File('assets/images/app_icon_3.jpg').readAsBytesSync();
    SmartArtworkImage.localArtworkReader = null;
  });

  tearDown(() {
    SmartArtworkImage.localArtworkReader = null;
  });

  testWidgets('歌曲切换后旧封面读取迟到不能覆盖新歌曲封面', (tester) async {
    final firstLoad = Completer<Uint8List?>();
    final secondLoad = Completer<Uint8List?>();
    SmartArtworkImage.localArtworkReader = (songId) {
      return songId == 'first' ? firstLoad.future : secondLoad.future;
    };

    Widget build(String songId) => MaterialApp(
      home: Scaffold(
        body: SmartArtworkImage(
          key: const ValueKey('reused-cover'),
          artworkUri: null,
          songId: songId,
          size: 96,
        ),
      ),
    );

    await tester.pumpWidget(build('first'));
    await tester.pumpWidget(build('second'));

    secondLoad.complete(secondArtwork);
    await tester.pumpAndSettle();
    expect(_displayedArtworkBytes(tester), same(secondArtwork));

    firstLoad.complete(firstArtwork);
    await tester.pumpAndSettle();
    expect(
      _displayedArtworkBytes(tester),
      same(secondArtwork),
      reason: '旧歌曲的异步结果不能覆盖当前歌曲封面',
    );
  });
}

Uint8List _displayedArtworkBytes(WidgetTester tester) {
  ImageProvider provider = tester.widget<Image>(find.byType(Image)).image;
  if (provider is ResizeImage) provider = provider.imageProvider;
  return (provider as MemoryImage).bytes;
}
