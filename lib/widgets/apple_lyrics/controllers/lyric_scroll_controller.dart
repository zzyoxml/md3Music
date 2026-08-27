import 'package:flutter/widgets.dart';
import 'package:md3music/widgets/apple_lyrics/animation/spring.dart';
import 'package:md3music/widgets/apple_lyrics/layout/lyric_layout.dart';

/// 歌词滚动控制器
///
/// 参照 spec.md "Requirement: 弹簧物理动画引擎" 与 tasks.md Task 11 实现。
/// 用 [Spring] 驱动 `posY`（垂直滚动偏移），使当前行的中心始终位于
/// 视口高度 [LyricLayout.alignPosition]=0.35 处（不是 0.5）。
///
/// 设计要点：
/// - `tick(dt)` 由外部驱动（外部 Widget 用 `AnimationController` + `addListener`
///   调用 `tick`），因此构造函数不需要 `vsync` 参数。
/// - 普通播放模式下，弹簧参数由相邻行间隔动态决定（间隔越短，弹簧越灵敏）。
/// - seeking/间奏模式下使用固定参数（stiffness=90, damping=15），更稳定。
/// - 用户手动滚动后 5000ms 自动回弹到当前行。
class LyricScrollController {
  LyricScrollController() {
    _posYSpring = Spring(
      mass: 1,
      stiffness: LyricLayout.posYSeekingStiffness,
      damping: LyricLayout.posYSeekingDamping,
      initialPosition: 0,
    );
  }

  /// posY 弹簧
  late final Spring _posYSpring;

  /// 视口高度（像素）
  double _viewportHeight = 0;

  /// 当前行索引，-1 表示未设置
  int _currentLineIndex = -1;

  /// 当前行高度（用于自动回弹时计算 targetY）
  double _currentLineHeight = 0;

  /// 当前行顶部 y（累加偏移，支持非均匀行高）
  ///
  /// 之前 `targetYForLine` 用 `lineTop = lineIndex * lineHeight` 线性假设，
  /// 启用自动换行后每行高度不同，需传入实际累加 lineTop。
  double _currentLineTop = 0;

  /// 用户是否正在拖动
  bool _isUserScrolling = false;

  /// 自动回弹剩余倒计时（毫秒），<=0 且 _autoReturned=false 时表示等待回弹
  double _autoReturnRemainingMs = 0;

  /// 是否已自动回弹（避免在倒计时结束后重复 setTarget）
  bool _autoReturned = true;

  /// 自动回弹触发回调：5s 倒计时结束、弹簧开始回弹时调用。
  ///
  /// 外部（AppleLyricsView）可监听此回调来恢复歌词模糊效果。
  VoidCallback? onAutoReturn;

  /// 是否已完成"首次定位瞬移"。
  ///
  /// 新建控制器（重新进入歌词页 / 切歌）时弹簧位置从 0（歌词顶部）出发，
  /// 若直接 setTarget 会看到"从顶部一路滚动到当前行"的长动画。
  /// 首次 setCurrentLine 且视口已就绪时用 setPosition 瞬移到位，避免该动画。
  bool _initialJumpDone = false;

  /// 当前弹簧 stiffness（用于测试与外部诊断）
  double _currentStiffness = LyricLayout.posYSeekingStiffness;

  /// 当前弹簧 damping（用于测试与外部诊断）
  double _currentDamping = LyricLayout.posYSeekingDamping;

  // P1-D：弹簧参数计算缓存。
  // _applySpringParams 由 _onTick 每帧调用，而普通模式的 stiffness 计算
  // 依赖 math.pow（posYNormalStiffness），intervalMs 只在当前行切换时变化。
  // 三个输入未变时直接早退，跳过 pow 与 setParams，每帧省一次 pow + 若干比较。
  bool _cachedIsSeeking = false;
  int _cachedIntervalMs = -1;
  bool _cachedIsInterludeActive = false;

  /// 视口高度
  double get viewportHeight => _viewportHeight;

  /// 当前行索引
  int get currentLineIndex => _currentLineIndex;

  /// 用户是否正在手动拖动歌词
  bool get isUserScrolling => _isUserScrolling;

  /// 是否在等待自动回弹（用户松手后、倒计时结束前）
  bool get isWaitingForAutoReturn =>
      !_isUserScrolling && !_autoReturned && _autoReturnRemainingMs > 0;

  /// v3 优化：scroll controller 是否已收敛
  /// （无用户滚动、无等待回弹、posY 弹簧已稳定）。
  /// 用于 AppleLyricsView 判断是否可以停止 Ticker。
  bool get isConverged =>
      !isUserScrolling && !isWaitingForAutoReturn && _posYSpring.isSettled;

  /// posY 弹簧是否已静止。
  ///
  /// 供省电模式区分"松手后仍在惯性滑行"（弹簧未静止，需保持 120Hz 顺滑）
  /// 与"惯性已停、仅等待自动回弹倒计时"（弹簧静止，画面不动，可锁 60fps）。
  bool get isPosYSpringSettled => _posYSpring.isSettled;

  /// 当前 posY（用于绘制时偏移）
  double get posY => _posYSpring.position;

  /// 当前弹簧目标（用于测试与外部诊断）
  double get currentTarget => _posYSpring.target;

  /// 当前弹簧 stiffness（用于测试）
  double get currentStiffness => _currentStiffness;

  /// 当前弹簧 damping（用于测试）
  double get currentDamping => _currentDamping;

  /// 设置视口尺寸
  void setViewportSize(Size size) {
    _viewportHeight = size.height;
  }

  /// 设置当前行
  ///
  /// [isSeeking] 为 true 时使用固定弹簧参数（stiffness=90, damping=15）；
  /// 为 false 时使用动态参数（基于 [intervalMs]）。
  ///
  /// [isInterludeActive] 为 true 时使用更柔和的弹簧参数（stiffness=40, damping=10），
  /// 让间奏结束时歌词跟随占位收起更柔软（约 500ms 到位而非瞬移）。
  /// 优先级：isSeeking > isInterludeActive > 普通模式。
  ///
  /// [intervalMs] 为下一行 startTime - 当前行 endTime，仅 [isSeeking]=false
  /// 时用于计算动态 stiffness。会被 clamp 到 [100, 800]。
  ///
  /// [lineHeight] 为当前行的总高度（含 padding 与自动换行高度），
  /// 用于计算 targetY。
  ///
  /// [lineTop] 为当前行顶部 y（前面所有行高度的累加），用于自动换行场景。
  /// 默认 -1 表示用线性假设 `lineTop = lineIndex * lineHeight`。
  ///
  /// **重要**：用户正在拖动歌词时（[onUserScroll] 后到 5000ms 回弹前），
  /// 不调用 `setTarget`，避免覆盖用户手动滚动位置导致瞬间回弹。
  /// 仅更新 `_currentLineIndex` 和 `_currentLineHeight`，等用户松手 5s 后
  /// 由 [_returnToCurrentLine] 自动对齐到最新行。
  void setCurrentLine(
    int index, {
    required bool isSeeking,
    required double lineHeight,
    int intervalMs = 0,
    double lineTop = -1,
    bool isInterludeActive = false,
  }) {
    _currentLineIndex = index;
    _currentLineHeight = lineHeight;
    _currentLineTop = lineTop >= 0 ? lineTop : index * lineHeight;
    _applySpringParams(isSeeking, intervalMs, isInterludeActive);
    // 用户滚动期间不强制 setTarget，等 5s 倒计时结束后自动回弹到最新行
    if (!_isUserScrolling && _autoReturned) {
      final double targetY = targetYForLine(index, lineHeight, lineTop: lineTop);
      if (!_initialJumpDone && _viewportHeight > 0) {
        // 首次定位：直接瞬移到当前行（setPosition 会把 target 同步为当前位置），
        // 避免弹簧从顶部 0 一路滚动到当前行的动画
        _initialJumpDone = true;
        _posYSpring.setPosition(targetY, 0);
      } else {
        _posYSpring.setTarget(targetY);
      }
    }
  }

  /// 切歌（lines 变化）后复位"首次定位"状态，让新歌的首次定位直接瞬移。
  void resetInitialJump() {
    _initialJumpDone = false;
  }

  /// 应用弹簧参数
  ///
  /// 优先级：seeking > 间奏 > 普通。
  /// - seeking 模式：固定 stiffness=90, damping=15
  /// - 间奏模式：固定 stiffness=40, damping=10（更柔和，跟随占位收起）
  /// - 普通模式：stiffness = LyricLayout.posYNormalStiffness(intervalMs)，
  ///   damping = LyricLayout.posYNormalDamping(stiffness)
  void _applySpringParams(bool isSeeking, int intervalMs,
      [bool isInterludeActive = false]) {
    // P1-D: 输入未变时直接早退（_onTick 每帧调用，intervalMs 只在行切换时变）。
    // 跳过 math.pow（posYNormalStiffness）与 setParams；参数未变时 setParams
    // 本就无效果（运动中才重新初始化求解器），早退不改变弹簧行为。
    if (isSeeking == _cachedIsSeeking &&
        intervalMs == _cachedIntervalMs &&
        isInterludeActive == _cachedIsInterludeActive) {
      return;
    }
    _cachedIsSeeking = isSeeking;
    _cachedIntervalMs = intervalMs;
    _cachedIsInterludeActive = isInterludeActive;

    if (isSeeking) {
      _currentStiffness = LyricLayout.posYSeekingStiffness;
      _currentDamping = LyricLayout.posYSeekingDamping;
    } else if (isInterludeActive) {
      _currentStiffness = 40;
      _currentDamping = 10;
    } else {
      _currentStiffness = LyricLayout.posYNormalStiffness(intervalMs);
      _currentDamping = LyricLayout.posYNormalDamping(_currentStiffness);
    }
    _posYSpring.setParams(
      mass: 1,
      stiffness: _currentStiffness,
      damping: _currentDamping,
    );
  }

  /// 计算某行的目标 posY
  ///
  /// 公式：`targetY = -(lineTop + lineHeight/2 - viewportHeight * alignPosition)`
  ///
  /// 负号因为滚动是反向偏移（posY 越负，内容越往上）。
  ///
  /// [lineTop] 默认 -1 表示用线性假设 `lineTop = lineIndex * lineHeight`；
  /// 自动换行场景下需传入实际累加 lineTop（前面所有行高度之和）。
  ///
  /// 例：viewport=600, lineHeight=40, lineIndex=0, alignPosition=0.35
  ///   → targetY = -(0 + 20 - 210) = 190
  double targetYForLine(int lineIndex, double lineHeight, {double lineTop = -1}) {
    final double top = lineTop >= 0 ? lineTop : lineIndex * lineHeight;
    return -(top + lineHeight / 2 - _viewportHeight * LyricLayout.alignPosition);
  }

  /// 用户手动滚动（拖动）
  ///
  /// 直接修改 spring 的 position（不通过 setTarget），并重置 5000ms 倒计时。
  /// 在倒计时结束前若用户停止滚动，将自动回弹到当前行的 targetY。
  void onUserScroll(double delta) {
    // setPosition 会把 target 同步设为当前 position，弹簧暂时不会回弹；
    // 等 5000ms 倒计时结束后再 setTarget 触发回弹。
    _posYSpring.setPosition(_posYSpring.position + delta, 0);
    _isUserScrolling = true;
    _autoReturnRemainingMs = LyricLayout.autoReturnMs.toDouble();
    _autoReturned = false;
  }

  /// 用户滚动结束
  ///
  /// 从此时起开始 5000ms 倒计时，到时自动回弹到当前行。
  ///
  /// **惯性滚动（AMLL 标准）**：松手时根据 [velocity] 计算惯性距离，
  /// 让歌词继续滑动一段再停下，营造自然物理感。
  /// - velocity 单位：px/s（来自 DragEndDetails.velocity.pixelsPerSecond.dy）
  /// - 惯性距离 = velocity * 0.3s，clamp 到 [-300, 300] px
  /// - 用 spring 的 velocity 注入 + target 偏移实现衰减
  void onUserScrollEnd({double velocity = 0}) {
    _isUserScrolling = false;

    // 注入惯性：松手时根据速度让歌词继续滑动一段距离
    // 距离 = velocity * 0.3s，clamp 到 ±300px（AMLL 标准 200-400px）
    final double inertiaDistance =
        (velocity * 0.3).clamp(-300.0, 300.0);
    if (inertiaDistance.abs() > 5) {
      // 用当前位置 + 惯性距离作为新 target，并注入速度
      // setPosition 会把 target 设为 position，所以先 setPosition 注入速度，
      // 再 setTarget 偏移 target（setTarget 会保留当前 velocity）
      final double currentPos = _posYSpring.position;
      _posYSpring.setPosition(currentPos, velocity);
      _posYSpring.setTarget(currentPos + inertiaDistance);
    }

    // 仅在尚未回弹时重置倒计时
    if (!_autoReturned) {
      _autoReturnRemainingMs = LyricLayout.autoReturnMs.toDouble();
    }
  }

  /// 推进动画，返回是否需要重绘
  ///
  /// 返回 true 表示 spring 仍在运动或即将开始运动，需要重绘；false 表示已稳定。
  /// 同时负责推进自动回弹倒计时（用户停止滚动后 5000ms）。
  bool tick(double dt) {
    // 推进自动回弹倒计时（仅在用户停止滚动且尚未回弹时）
    if (!_isUserScrolling && !_autoReturned && _autoReturnRemainingMs > 0) {
      _autoReturnRemainingMs -= dt * 1000;
      if (_autoReturnRemainingMs <= 0) {
        _autoReturnRemainingMs = 0;
        _returnToCurrentLine();
      }
    }

    _posYSpring.tick(dt);
    return !_posYSpring.isSettled;
  }

  /// 自动回弹到当前行的 targetY
  void _returnToCurrentLine() {
    _autoReturned = true;
    onAutoReturn?.call();
    if (_currentLineIndex < 0 || _currentLineHeight <= 0) return;
    final double targetY = targetYForLine(
      _currentLineIndex,
      _currentLineHeight,
      lineTop: _currentLineTop,
    );
    _posYSpring.setTarget(targetY);
  }

  /// 判断手势是否为点击
  ///
  /// 移动总距离 < [LyricLayout.clickThresholdPx]=10px 视为点击。
  bool isClickGesture(double totalDelta) {
    return totalDelta.abs() < LyricLayout.clickThresholdPx;
  }

  /// 设置普通/seeking 模式
  ///
  /// 切换模式时会立即应用对应的弹簧参数。
  /// [isSeeking]=true 使用固定参数（90, 15）；
  /// false 使用普通模式默认参数（intervalMs=0 → clamp 到 100，stiffness=220）。
  void setSeekingMode(bool isSeeking) {
    _applySpringParams(isSeeking, 0, false);
  }

  /// 释放资源
  ///
  /// Spring 是纯 Dart 对象，无需显式释放，但保留 dispose 以便未来扩展
  /// （如内部添加 Ticker/AnimationController 时在此释放）。
  void dispose() {
    _currentLineIndex = -1;
    _viewportHeight = 0;
    _currentLineHeight = 0;
    _currentLineTop = 0;
    _autoReturned = true;
    _autoReturnRemainingMs = 0;
    _initialJumpDone = false;
  }
}
