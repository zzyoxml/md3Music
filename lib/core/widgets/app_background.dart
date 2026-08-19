import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';

/// 页面背景组件：模糊背景图 + 透明度调节（主题背景色打底）。
///
/// 作为页面内容的底层（页面 Scaffold 背景透明时透出），并**随页面一起位移/
/// 过渡**——路由入场动画时背景图跟着画面滑动，避免"背景固定、页面跳变"的
/// 分离感。主页与所有二级页面统一使用（移除全局固定背景层）。
///
/// 未启用背景图或图片不可用时返回空（保持页面原样）。
class AppBackground extends StatelessWidget {
  const AppBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final tp = context.watch<ThemeProvider>();
    if (!tp.useBackgroundImage) return const SizedBox.shrink();
    final path = tp.backgroundImagePath;
    if (path == null || path.isEmpty) return const SizedBox.shrink();
    final file = File(path);
    if (!file.existsSync()) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    // 解码宽度按屏幕物理宽度限制：模糊背景无需超高分辨率，避免高分辨率
    // 照片全尺寸解码造成的内存峰值（低内存设备会闪退）。
    final screenWidth = MediaQuery.sizeOf(context).width *
        MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = screenWidth.round().clamp(540, 1440);
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 主题背景色打底：透明度调低时露出的是主题莫奈取色的背景色
          ColoredBox(color: colorScheme.surface),
          // 外层显式 Opacity 控制图片透明度（实时生效）
          Opacity(
            opacity: tp.backgroundOpacity,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: tp.backgroundBlur,
                sigmaY: tp.backgroundBlur,
              ),
              child: Image.file(
                file,
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                cacheWidth: cacheWidth,
                // provider 变化时保持旧帧直到新图解码完成，避免空白闪烁
                gaplessPlayback: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
