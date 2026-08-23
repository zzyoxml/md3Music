import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/theme_provider.dart';

/// 内置保底壁纸：用户未选择自定义背景图（或清除后）时作为默认背景。
const String kDefaultWallpaperAsset = 'assets/images/default_wallpaper.jpg';

/// 页面背景组件：模糊背景图 + 透明度调节（主题背景色打底）。
///
/// 作为页面内容的底层（页面 Scaffold 背景透明时透出），并**随页面一起位移/
/// 过渡**——路由入场动画时背景图跟着画面滑动，避免"背景固定、页面跳变"的
/// 分离感。主页与所有二级页面统一使用（移除全局固定背景层）。
///
/// 开关关闭时返回空（保持页面原样）；开关开启时优先用用户选择的图片，
/// 无有效用户图片时回落到内置默认壁纸（始终有背景，避免"无背景"状态导致
/// 浅色模式配色异常）。
class AppBackground extends StatelessWidget {
  const AppBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final tp = context.watch<ThemeProvider>();
    if (!tp.useBackgroundImage) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    // 解码宽度按屏幕物理宽度限制：模糊背景无需超高分辨率，避免高分辨率
    // 照片全尺寸解码造成的内存峰值（低内存设备会闪退）。
    final screenWidth = MediaQuery.sizeOf(context).width *
        MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = screenWidth.round().clamp(540, 1440);
    // 图片源：优先用户选择的文件，无效（未选/已删除）时回落到内置默认壁纸。
    Widget image;
    final path = tp.backgroundImagePath;
    final file = (path != null && path.isNotEmpty) ? File(path) : null;
    if (file != null && file.existsSync()) {
      image = Image.file(
        file,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: cacheWidth,
        // provider 变化时保持旧帧直到新图解码完成，避免空白闪烁
        gaplessPlayback: true,
      );
    } else {
      image = Image.asset(
        kDefaultWallpaperAsset,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: cacheWidth,
        gaplessPlayback: true,
      );
    }
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
              child: image,
            ),
          ),
        ],
      ),
    );
  }
}
