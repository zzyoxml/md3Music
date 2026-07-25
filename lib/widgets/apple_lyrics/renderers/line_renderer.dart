/// 整行降级渲染器（用于 LRC 与纯文本，无逐字时间戳；亦用于非当前行的 KRC 行）
///
/// 参照 spec.md "Requirement: 逐字 mask alpha 渲染" 中"非当前行渲染"场景与
/// tasks.md Task 10 实现。启用整行模式的场景：
/// - hasWordTiming=false 的行（LRC/纯文本）：始终用本类
/// - hasWordTiming=true 的非当前行（KRC）：用本类降级渲染（性能优化）
///
/// 渲染规则：
/// - 当前行（isActive）：整行 alpha = dynamicBrightAlpha（随 scale 0.2~1.0）
/// - 非当前行：整行 alpha = dynamicDarkAlpha（随 scale 0.2~0.4，SOLID 模式）
/// - 行内无 mask 渐变，整行使用同一 alpha
/// - 行切换通过指数衰减实现淡入淡出过渡（变亮 ATTACK_SPEED=50，变暗 RELEASE_SPEED=7）
///
/// 与 [WordRenderer] 的关系：
/// - [WordRenderer] 处理当前行 + hasWordTiming=true 的逐字模式（有 mask 渐变 + 上浮）
/// - 本类处理 hasWordTiming=false 的行 + 非当前行的 KRC 行（无 mask 渐变）
/// - 上层 AppleLyricsView 根据 isActive 与 hasWordTiming 调度使用哪个 renderer
/// - 非当前行不需要逐字渐变，用本类每帧只 1 次 layout，大幅降低 CPU
///
/// 本类不是 Widget，是核心绘制逻辑类，由外部 CustomPainter 调用 [paintLine]。
/// 动画驱动由外部 AnimationController + Ticker 调用 [tick] 实现。
library;

import 'dart:math';

import 'package:flutter/widgets.dart';

import '../layout/lyric_layout.dart';
import '../models/lyric_line.dart';

/// 整行降级渲染器。
///
/// 持有当前 isActive 状态与单一 [_currentAlpha] 值（整行共用一个 alpha），
/// 通过 [tick] 推进指数衰减动画，通过 [paintLine] 用当前 alpha 绘制白色文本。
class LineRenderer {
  LineRenderer();

  // ============== 内部状态 ==============

  /// 当前是否为当前行（高亮）。默认 false（SOLID 暗态）。
  bool _isActive = false;

  /// 当前整行 alpha 值。初始 [LyricLayout.currentDarkAlpha]=0.2（SOLID 非当前行暗态）。
  double _currentAlpha = LyricLayout.currentDarkAlpha;

  /// 目标 alpha 值。isActive=true 时 1.0，false 时 0.2。
  double _targetAlpha = LyricLayout.currentDarkAlpha;

  /// 复用的 TextPainter 实例（避免每帧创建对象）。
  ///
  /// **性能优化**：之前每帧 paintLine 都创建新 TextPainter + GC，
  /// 现在复用实例，只重新 set text + layout（alpha 变了需要重新 layout）。
  final TextPainter _painter = TextPainter(textDirection: TextDirection.ltr);

  // ============== 状态查询 ==============

  /// 当前 alpha（用于测试与外部协调）。
  double get currentAlpha => _currentAlpha;

  /// 当前是否为当前行。
  bool get isActive => _isActive;

  /// 目标 alpha（用于测试断言）。
  @visibleForTesting
  double get targetAlpha => _targetAlpha;

  // ============== 状态设置 ==============

  /// 设置当前行状态。
  ///
  /// [isActive] 为 true 时整行高亮（alpha 目标 dynamicBrightAlpha），
  /// 为 false 时整行 SOLID 暗态（alpha 目标 dynamicDarkAlpha）。
  /// [scale] 是行缩放，0.97（inactive）~1.0（active）。
  /// [blurFade] 控制非当前行透明度：1.0=透明（模糊图片覆盖），0.0=正常显示。
  /// [blurActive] 是否启用高斯模糊：false 时不降低非当前行透明度。
  void setLineState({required bool isActive, required double scale, double blurFade = 1.0, bool blurActive = true}) {
    _isActive = isActive;
    final double factor = ((scale - LyricLayout.inactiveScale) /
            (LyricLayout.activeScale - LyricLayout.inactiveScale))
        .clamp(0.0, 1.0)
        .toDouble();
    final double dynamicDark = factor * 0.2 + 0.2;
    final double dynamicBright = factor * 0.8 + 0.2;
    // 非当前行 alpha = dynamicDark * (1 - blurFade)，blurActive=false 时不降低
    final double effectiveFade = blurActive ? blurFade : 0.0;
    _targetAlpha = isActive ? dynamicBright : dynamicDark * (1.0 - effectiveFade);
  }

  // ============== 动画推进 ==============

  /// 推进动画。
  ///
  /// [dt] 距上一帧的时间间隔（秒）。
  /// 用指数衰减公式 `_currentAlpha += (_targetAlpha - _currentAlpha) * (1 - exp(-speed * dt))`
  /// 平滑过渡：变亮用 [LyricLayout.attackSpeed]（50.0），变暗用 [LyricLayout.releaseSpeed]（7.0）。
  /// 差值小于 [LyricLayout.alphaEpsilon]（0.001）时吸附到目标。
  void tick(double dt) {
    if (dt <= 0) return;
    // 变亮用 ATTACK（快），变暗用 RELEASE（慢）
    final double speed = _targetAlpha >= _currentAlpha
        ? LyricLayout.attackSpeed
        : LyricLayout.releaseSpeed;
    final double decay = 1.0 - exp(-speed * dt);
    double next = _currentAlpha + (_targetAlpha - _currentAlpha) * decay;
    // 阈值收敛：差值小于 alphaEpsilon 直接吸附到目标
    if ((next - _targetAlpha).abs() < LyricLayout.alphaEpsilon) {
      next = _targetAlpha;
    }
    _currentAlpha = next;
  }

  // ============== 绘制 ==============

  /// 绘制整行歌词。
  ///
  /// [offset] 是行起始绘制原点。文字颜色固定白色 #FFFFFFFF，
  /// alpha 由 [_currentAlpha] 控制（整行同一 alpha，无 mask 渐变）。
  /// 使用复用的 [_painter] 实例测量整行宽度并绘制。
  ///
  /// [maxWidth] 为可用最大文字宽度，超出时 TextPainter 自动换行（默认不换行）。
  ///
  /// **性能优化**：复用 [_painter] 实例，避免每帧创建 TextPainter 对象 + GC。
  /// layout 仍需每帧执行（alpha 变化需重新 set TextSpan）。
  void paintLine(
      Canvas canvas, Offset offset, LyricLine line, double fontSize,
      {double maxWidth = double.infinity}) {
    if (line.text.isEmpty) return;
    _painter.text = TextSpan(
      text: line.text,
      style: TextStyle(
        // 文字颜色固定白色，alpha 整行统一（无 mask 渐变）
        color: Color.fromRGBO(255, 255, 255, _currentAlpha),
        fontSize: fontSize,
        height: LyricLayout.lineHeight,
      ),
    );
    _painter.layout(
        maxWidth: maxWidth == double.infinity ? double.infinity : maxWidth);
    _painter.paint(canvas, offset);
  }

  /// 重置状态：alpha 回到初始值（0.2），isActive=false。
  void reset() {
    _isActive = false;
    _currentAlpha = LyricLayout.currentDarkAlpha;
    _targetAlpha = LyricLayout.currentDarkAlpha;
  }
}
