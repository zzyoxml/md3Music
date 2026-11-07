/// 整页重建的判定单位 = 顶栏淡入档位 × 标题淡入档位 × banner 是否可见。
/// 页面只有这三个消费点（见 artist_detail_page.dart 的 appBar / title / header.active），
/// 所以只要三者量化后不变，setState 产出的帧在视觉上完全等价。
typedef ArtistScrollVisual = ({int fadeStep, int titleStep, bool bannerVisible});

class ArtistScrollGate {
  ArtistScrollGate({
    this.toolbarHeight = 56.0,
    this.fadeWindow = 60.0,
    this.fadeStepPx = 2.0,
    this.titleStepPx = 12.0,
  });

  final double toolbarHeight;

  /// 淡入窗口宽度，与页面的 `(...).clamp(0.0, 60.0) / 60` 一致。
  final double fadeWindow;

  /// 量化步长：2px 一档的底色渐变在屏幕上没有可辨差异。
  final double fadeStepPx;
  final double titleStepPx;

  ArtistScrollVisual? _last;
  double? _lastBannerHeight;

  /// 视觉量是否发生变化 → 需要重建。`bannerHeight` 变化时强制放行一次。
  bool shouldRebuild(double offset, {required double bannerHeight}) {
    if (_lastBannerHeight != bannerHeight) {
      _lastBannerHeight = bannerHeight;
      _last = null;
    }
    final fadeTop = bannerHeight - toolbarHeight - fadeWindow;
    final titleTop = bannerHeight - toolbarHeight;
    final visual = (
      fadeStep: ((offset - fadeTop).clamp(0.0, fadeWindow) / fadeStepPx).round(),
      titleStep: ((offset - titleTop).clamp(0.0, fadeWindow) / titleStepPx).round(),
      bannerVisible: offset < bannerHeight,
    );
    if (visual == _last) return false;
    _last = visual;
    return true;
  }

  void reset() {
    _last = null;
    _lastBannerHeight = null;
  }
}
