import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/services/kugou_api/kugou_api_client.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

void main() {
  group('蝰蛇母带音质降级链', () {
    test('viper_tape 从母带逐级退到标准', () {
      expect(
        KugouApiClient.downgradeChain(KugouQuality.viperTape),
        [
          KugouQuality.viperTape,
          KugouQuality.hires,
          KugouQuality.lossless,
          KugouQuality.high,
          KugouQuality.standard,
        ],
      );
    });

    test('既有档位降级链不回退', () {
      expect(
        KugouApiClient.downgradeChain(KugouQuality.hires),
        [KugouQuality.hires, KugouQuality.lossless, KugouQuality.high, KugouQuality.standard],
      );
      expect(
        KugouApiClient.downgradeChain(KugouQuality.lossless),
        [KugouQuality.lossless, KugouQuality.high, KugouQuality.standard],
      );
      expect(
        KugouApiClient.downgradeChain(KugouQuality.high),
        [KugouQuality.high, KugouQuality.standard],
      );
      expect(KugouApiClient.downgradeChain(KugouQuality.standard), [KugouQuality.standard]);
    });

    test('音质排序：母带 > Hi-Res > 无损 > 320 > 128', () {
      expect(KugouApiClient.qualityRank(KugouQuality.viperTape), 4);
      expect(KugouApiClient.qualityRank(KugouQuality.hires), 3);
      expect(KugouApiClient.qualityRank(KugouQuality.lossless), 2);
      expect(KugouApiClient.qualityRank(KugouQuality.high), 1);
      expect(KugouApiClient.qualityRank(KugouQuality.standard), 0);
    });
  });

  group('蝰蛇母带标签', () {
    test('labelOf 返回中文标签', () {
      expect(KugouQuality.labelOf(KugouQuality.viperTape), '蝰蛇母带');
    });
  });
}
