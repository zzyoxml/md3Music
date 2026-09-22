import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/artwork_loader.dart';

void main() {
  group('ArtworkLoader LRU 缓存', () {
    test('put 超过上限后逐出最久未用项', () {
      final loader = ArtworkLoader();
      loader.debugCacheLimit = 4; // 见 Task 4 Step 2：暴露测试用上限
      for (var i = 0; i < 6; i++) {
        loader.put('k$i', Uint8List.fromList([0]));
      }
      // 先写 0..5：超限后应逐出最先写入的 k0, k1
      expect(loader.debugCacheLength(), 4);
      expect(loader.debugHasKey('k0'), isFalse);
      expect(loader.debugHasKey('k5'), isTrue);
    });
  });
}