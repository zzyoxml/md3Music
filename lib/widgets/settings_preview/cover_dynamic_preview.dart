import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/services/player_frame_driver.dart';
import '../../../modules/player/player_cover_shadow.dart';
import 'settings_preview_frame.dart';

/// 「封面与动态」三级子页的演示卡。
///
/// 左右两半：
/// - 左：封面投影浓度（读 [shadowStrength]，直接复用播放页的
///   [PlayerCoverShadow.decoration] 纯函数，口径一致）；
/// - 右：3D 视差（读 [depthEnabled] / [depthStrength]），用**自动来回的模拟
///   倾角**驱动——设置页里用户不会一直晃手机，用真陀螺仪演示等于大部分时间
///   看不到效果。
///
/// 底部一行提示当前「歌词双击跳转」的状态：关=单击即跳转，开=需双击。
class CoverDynamicPreview extends StatefulWidget {
  final double shadowStrength;
  final bool depthEnabled;
  final double depthStrength;
  final bool neuralInpaint;
  final bool lyricDoubleTapToJump;

  const CoverDynamicPreview({
    super.key,
    required this.shadowStrength,
    required this.depthEnabled,
    required this.depthStrength,
    required this.neuralInpaint,
    required this.lyricDoubleTapToJump,
  });

  @override
  State<CoverDynamicPreview> createState() => _CoverDynamicPreviewState();
}

class _CoverDynamicPreviewState extends State<CoverDynamicPreview> {
  /// 演示用封面边长（dp）。投影与视差都按它取比例，与播放页同一套 clamp。
  static const double _coverSide = 76.0;

  /// 模拟倾角的一个来回周期（秒）。
  static const double _tiltPeriodSeconds = 2.5;

  double _tilt = 0.0;
  double _time = 0.0;
  bool _driverBound = false;

  @override
  void initState() {
    super.initState();
    _syncDriver();
  }

  @override
  void didUpdateWidget(covariant CoverDynamicPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.depthEnabled != widget.depthEnabled) _syncDriver();
  }

  @override
  void dispose() {
    _unbindDriver();
    super.dispose();
  }

  void _syncDriver() {
    if (widget.depthEnabled) {
      if (!_driverBound) {
        PlayerFrameDriver.instance.addListener(_onTick);
        _driverBound = true;
      }
    } else if (_driverBound) {
      _unbindDriver();
    }
  }

  void _unbindDriver() {
    if (_driverBound) {
      PlayerFrameDriver.instance.removeListener(_onTick);
      _driverBound = false;
    }
  }

  void _onTick() {
    if (!mounted) return;
    // 用真实帧间隔推进，不写死 1/60：挂起恢复后不会跳变
    _time += 1.0 / 60.0;
    setState(() {
      _tilt = math.sin(_time * 2 * math.pi / _tiltPeriodSeconds);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 视差位移：演示卡尺寸比播放页小，按比例缩放（播放页 0~40 像素）
    final shift = widget.depthStrength * 0.5 * _tilt;

    return SettingsPreviewFrame(
      title: '封面与动态预览',
      subtitle: '阴影 ${(widget.shadowStrength * 100).round()}% · '
          '${widget.depthEnabled ? '3D 视差 ${widget.depthStrength.round()}' : '3D 关闭'}',
      footnote: widget.lyricDoubleTapToJump
          ? '歌词需双击才跳转（单击无效）'
          : '歌词单击即跳转位置',
      height: 190,
      background: colorScheme.surfaceContainerHighest,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── 左：封面投影 ──
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '封面投影',
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                // 投影画在布局盒外会被祖先裁掉，宿主必须 Clip.none。
                // OverflowBox 给足溢出空间，让投影完整可见。
                Expanded(
                  child: OverflowBox(
                    alignment: Alignment.center,
                    minWidth: 0,
                    maxWidth: double.infinity,
                    minHeight: 0,
                    maxHeight: double.infinity,
                    child: Center(
                      child: Container(
                        width: _coverSide,
                        height: _coverSide,
                        decoration: PlayerCoverShadow.decoration(
                          shadowColor: colorScheme.shadow,
                          side: _coverSide,
                          intensity: widget.shadowStrength,
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.music_note,
                            size: 32,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // ── 右：3D 视差 ──
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '3D 视差',
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: OverflowBox(
                    alignment: Alignment.center,
                    minWidth: 0,
                    maxWidth: double.infinity,
                    minHeight: 0,
                    maxHeight: double.infinity,
                    child: Center(
                      child: widget.depthEnabled
                          // 两层反向平移 = 视差：背景层与主体错开移动
                          ? SizedBox(
                              width: _coverSide,
                              height: _coverSide,
                              child: Stack(
                                alignment: Alignment.center,
                                clipBehavior: Clip.none,
                                children: [
                                  Transform.translate(
                                    offset: Offset(-shift, 0),
                                    child: _LayerBox(
                                      side: _coverSide,
                                      color: colorScheme.secondaryContainer,
                                      onColor: colorScheme.onSecondaryContainer,
                                      label: '背景层',
                                    ),
                                  ),
                                  Transform.translate(
                                    offset: Offset(shift, 0),
                                    child: _LayerBox(
                                      side: _coverSide * 0.68,
                                      color: colorScheme.primaryContainer,
                                      onColor: colorScheme.onPrimaryContainer,
                                      label: null,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : Opacity(
                              opacity: 0.35,
                              child: _LayerBox(
                                side: _coverSide,
                                color: colorScheme.primaryContainer,
                                onColor: colorScheme.onPrimaryContainer,
                                label: '已关闭',
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LayerBox extends StatelessWidget {
  final double side;
  final Color color;
  final Color onColor;
  final String? label;

  const _LayerBox({
    required this.side,
    required this.color,
    required this.onColor,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: label == null
          ? null
          : Center(
              child: Text(
                label!,
                style: TextStyle(fontSize: 10, color: onColor),
              ),
            ),
    );
  }
}
