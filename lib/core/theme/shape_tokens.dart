import 'package:flutter/material.dart';

/// M3 Expressive Shape 系统
///
/// 参考：https://m3.material.io/styles/shapes/shape-scale-tokens
/// M3 Expressive 在原 M3 的 5 级 shape 基础上扩展到 35+ 种形状变体。
/// 本文件定义项目实际使用的 7 个核心 token，按圆角半径递增。
///
/// 使用方式：直接传给组件的 `shape` 属性，例如：
/// ```dart
/// Card(shape: M3ExpressiveShapes.expressive, ...)
/// FloatingActionButton(shape: M3ExpressiveShapes.full, ...)
/// ```
class M3ExpressiveShapes {
  M3ExpressiveShapes._();

  /// 4dp — 小型组件：Chip、Badge、Tooltip
  static const OutlinedBorder extraSmall = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(4)),
  );

  /// 8dp — 小型卡片、文本字段装饰、SongListItem 封面
  static const OutlinedBorder small = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(8)),
  );

  /// 12dp — 中型卡片、列表项图标容器
  static const OutlinedBorder medium = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(12)),
  );

  /// 16dp — 标准卡片（保留兼容旧组件，与原 cardTheme 一致）
  static const OutlinedBorder large = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(16)),
  );

  /// 20dp — 大型卡片、弹窗顶部
  static const OutlinedBorder largeEnd = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(20)),
  );

  /// 28dp — 底部弹窗顶部、抽屉（与原 bottomSheetTheme 一致）
  static const OutlinedBorder extraLarge = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(28)),
  );

  /// 32dp — M3 Expressive 大卡片专用：AlbumCard / PlaylistCard
  static const OutlinedBorder expressive = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(32)),
  );

  /// Full — 圆形，用于 FAB / 圆形按钮 / NavigationBar pill indicator
  static const OutlinedBorder full = CircleBorder();
}
