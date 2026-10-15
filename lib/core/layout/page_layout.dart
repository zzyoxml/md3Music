import 'package:material_ui/material_ui.dart';

import '../theme/app_dimens.dart';
import 'responsive_layout.dart';

/// 局部坐标下的双栏/单栏几何。竖直铰链两侧够宽时分栏，否则用较宽一侧。
({
  double masterLeft,
  double masterWidth,
  double detailLeft,
  double detailWidth,
  bool twoPane,
})
resolvePaneGeometry({
  required double width,
  required double masterFraction,
  List<Rect> verticalObstructions = const [],
}) {
  for (final bounds in verticalObstructions) {
    if (bounds.left <= 0 || bounds.right >= width) continue;
    final rightWidth = width - bounds.right;
    if (usesTwoPane(width) &&
        bounds.left >= AppLayout.twoPaneMasterWidth &&
        rightWidth >= 480) {
      return (
        masterLeft: 0,
        masterWidth: bounds.left,
        detailLeft: bounds.right,
        detailWidth: rightWidth,
        twoPane: true,
      );
    }
    final left = bounds.left >= rightWidth ? 0.0 : bounds.right;
    final available = bounds.left >= rightWidth ? bounds.left : rightWidth;
    return (
      masterLeft: left,
      masterWidth: available,
      detailLeft: left,
      detailWidth: available,
      twoPane: false,
    );
  }
  final twoPane = usesTwoPane(width);
  final master = twoPane
      ? (masterFraction * width).clamp(
          AppLayout.twoPaneMasterWidth,
          width - 496,
        )
      : width;
  final detailLeft = twoPane ? master + 16 : 0.0;
  return (
    masterLeft: 0,
    masterWidth: master,
    detailLeft: detailLeft,
    detailWidth: width - detailLeft,
    twoPane: twoPane,
  );
}

/// 壳层的页面形态表。设置页保留独立的页内状态双列，沉浸页不参与分栏。
const Set<String> kTwoPaneTabs = {
  'library',
  'favorites',
  'search',
  'charts',
  'scene',
  'channel',
  'discover',
  'ip',
  'user',
  'audiobook',
};

const Set<String> kConstrainedTabs = {'user', 'audiobook'};

/// 保持手机尺寸，只在内容过宽时居中限宽；使用局部约束，不改 MediaQuery。
class ContentWidth extends StatelessWidget {
  const ContentWidth({
    super.key,
    required this.child,
    this.maxWidth = AppLayout.maxContentWidth,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: SizedBox(width: double.infinity, child: child),
    ),
  );
}
