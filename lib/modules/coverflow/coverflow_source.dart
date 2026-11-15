// lib/modules/coverflow/coverflow_source.dart
import 'package:flutter/foundation.dart';

/// 封面流歌单源。
///
/// FM 四档（红心/探索/小众/电台）**摊平成独立枚举值**，与 [StartupAutoPlaySource]
/// 的 `fmHeart/fmExplore/fmNiche/fmRadio` 同一口径——不另设「FM 电台」二级选项。
///
/// [rawValue] 是持久化契约（SettingsRepository 存的就是它），改值即弃档；
/// `fmHeart` 沿用历史值 `personalFm`，老用户已持久化的私人FM 档不失效。
/// [label] 同时用于设置页下拉文本与各处展示；
/// [emptyHint] 是封面流页对应源的空态文案。
enum CoverFlowSource {
  daily('daily', '每日推荐', '暂无每日推荐'),
  fmHeart('personalFm', '私人FM · 红心', '暂无私人FM歌曲'),
  fmExplore('fmExplore', '私人FM · 探索', '暂无私人FM歌曲'),
  fmNiche('fmNiche', '私人FM · 小众', '暂无私人FM歌曲'),
  fmRadio('fmRadio', '私人FM · 电台', '暂无私人FM歌曲'),
  homeDiscover('homeDiscover', '刷歌推荐', '暂无刷歌推荐');

  final String rawValue;
  final String label;
  final String emptyHint;

  const CoverFlowSource(this.rawValue, this.label, this.emptyHint);

  /// 解析持久化值；非法 / 空 / null 一律回退每日推荐（默认源）。
  static CoverFlowSource tryParse(String? raw) {
    for (final value in values) {
      if (value.rawValue == raw) return value;
    }
    return CoverFlowSource.daily;
  }

  /// 对应 kFmStations（personal_fm_core）的下标；非 FM 源返回 null。
  /// kFmStations 顺序：0=红心(normal/0) 1=探索(normal/2) 2=小众(small/1)
  /// 3=电台(radio/0)——档位表只允许**末尾追加**，插入会让已持久化的下标整体错位。
  /// 本文件保持 foundation-only，不反向依赖该模块，数字对齐靠测试钉住。
  int? get fmStationIndex => switch (this) {
        CoverFlowSource.fmHeart => 0,
        CoverFlowSource.fmExplore => 1,
        CoverFlowSource.fmNiche => 2,
        CoverFlowSource.fmRadio => 3,
        _ => null,
      };
}

/// 封面流当前歌单源（全局通知器，模式同 kDesktopModeEnabled）：
/// - app.dart 启动时从 SettingsRepository 载入写入；
/// - 设置页切换时写入；
/// - CoverFlowPage 订听，变更即复位位置并按新源拉取。
final ValueNotifier<CoverFlowSource> kCoverFlowSource =
    ValueNotifier<CoverFlowSource>(CoverFlowSource.daily);
