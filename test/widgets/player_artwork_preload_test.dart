import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/widgets/player_artwork_image.dart';

void main() {
  test('预热封面时接收并吞掉图片流加载错误', () async {
    final previousHandler = FlutterError.onError;
    final reportedErrors = <FlutterErrorDetails>[];
    FlutterError.onError = reportedErrors.add;

    try {
      preloadArtworkImage(_FailingImageProvider());
      await Future<void>.delayed(Duration.zero);

      expect(reportedErrors, isEmpty);
    } finally {
      FlutterError.onError = previousHandler;
    }
  });
}

class _FailingImageProvider extends ImageProvider<Object> {
  @override
  Future<Object> obtainKey(ImageConfiguration configuration) async =>
      Object();

  @override
  ImageStreamCompleter loadImage(
    Object key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    Future<ImageInfo>.error(StateError('simulated artwork load failure')),
  );
}
