import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/player_cover_morph.dart';

void main() {
  test('coverSuppressed=true 时封面不画，文字判据不受影响', () {
    final bus = PlayerCoverMorphBus.instance;
    bus.coverSuppressed = false;
    bus.eligible = true;
    bus.miniRect = const Rect.fromLTWH(0, 0, 44, 44);
    bus.settledRect = const Rect.fromLTWH(40, 60, 300, 300);
    bus.miniTextRect = const Rect.fromLTWH(60, 10, 200, 30);
    bus.settledTextRect = const Rect.fromLTWH(40, 380, 300, 60);
    bus.textEligible = true;
    addTearDown(() {
      bus.coverSuppressed = false;
      bus.eligible = false;
      bus.textEligible = false;
      bus.miniRect = null;
      bus.settledRect = null;
      bus.miniTextRect = null;
      bus.settledTextRect = null;
    });

    expect(bus.layerWillDraw, isTrue);
    expect(bus.coverLayerWillDraw, isTrue);
    expect(bus.textWillDraw, isTrue);

    bus.coverSuppressed = true;
    expect(bus.coverLayerWillDraw, isFalse);
    // 文字形变保留（用户明确要求）
    expect(bus.textWillDraw, isTrue);
  });
}
