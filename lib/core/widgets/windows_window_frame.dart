import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:md3music/core/layout/bottom_chrome_sink.dart';
import 'package:md3music/core/widgets/windows_caption_buttons.dart';

/// 仅 Windows：20% 主题底色叠在全局背景上，正文不透明度不变。
class WindowsWindowFrame extends StatefulWidget {
  const WindowsWindowFrame({super.key, required this.child});

  final Widget child;

  @override
  State<WindowsWindowFrame> createState() => _WindowsWindowFrameState();
}

class _WindowsWindowFrameState extends State<WindowsWindowFrame> {
  static const _channel = MethodChannel('md3music/window_tray');

  Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Widget 测试没有原生 runner；实际运行须使用同一构建中的 Dart 与 runner。
    } on PlatformException catch (error) {
      debugPrint('Windows window control $method failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return widget.child;
    final colors = Theme.of(context).colorScheme;
    // 本组件位于 MaterialApp.builder，Navigator 的 Overlay 是后代而非祖先。
    // 三键的 Tooltip 悬停需要独立宿主，否则 release 会被错误占位替换成白块。
    return Overlay.wrap(
      child: ValueListenableBuilder<double>(
        valueListenable: PlayerPanelSignal.expansion,
        builder: (context, expansion, child) => Column(
          children: [
            // 完整播放页（含展开/收起过程）占满客户区，不留下标题栏空白。
            //
            // 全屏（F11 / Zen）时**保留**这条 32dp 标题栏：它是鼠标用户退出全屏的
            // 唯一入口（原生侧已去掉窗口边框，此时最大化键的语义是「退出全屏」）。
            // Zen 进播放页时这条会由上面的 `expansion` 判据收起，不影响沉浸观感。
            Visibility(
              visible: expansion <= 0,
              child: SizedBox(
                height: 32,
                child: ColoredBox(
                  key: const ValueKey('windows_title_bar'),
                  color: colors.surface.withValues(alpha: 0.2),
                  child: Material(
                    type: MaterialType.transparency,
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            key: const ValueKey('windows_title_drag'),
                            behavior: HitTestBehavior.opaque,
                            onPanStart: (_) => _invoke('startDrag'),
                            onDoubleTap: () => _invoke('toggleMaximize'),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Row(
                                children: [
                                  // 应用图标（与 exe / 托盘同一吉祥物），替代原先的
                                  // 通用 Material 音符字形。cacheWidth 限制解码尺寸
                                  // （16dp × 最高 4x DPI），避免整张 1254px 原图解码。
                                  Image.asset(
                                    'assets/images/app_icon.png',
                                    width: 16,
                                    height: 16,
                                    cacheWidth: 64,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'md3Music',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colors.onSurface,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        // 三键与播放页顶栏共用同一组件（视觉、命中区、全屏语义一致）。
                        const WindowsCaptionButtonRow(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 注意：这里插入的 32dp 标题栏是**正文之上**的一段布局偏移，正文子树的
            // 局部坐标因此整体下移 32dp。设计像素锚点（DisplayScaleReference，探针与
            // 顶层浮层共用）量的是整个窗口客户区，所以挂在 `child` 内部的顶层浮层会
            // 低一条标题栏。App 级悬浮层（封面飞行 / 跳水球 / 形变层…）必须留在本组件
            // **之外**，见 `app.dart` 的「顶层悬浮层组」。
            Expanded(child: child!),
          ],
        ),
        child: widget.child,
      ),
    );
  }
}
