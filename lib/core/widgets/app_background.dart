import 'dart:io';
import 'dart:ui';

import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../build_flags.dart';
import '../../providers/theme_provider.dart';

/// 内置保底壁纸：用户未选择自定义背景图（或清除后）时作为默认背景。
const String kDefaultWallpaperAsset = 'assets/images/default_wallpaper.jpg';

/// 当前背景图的 ImageProvider，供页面底层壁纸使用。
/// 路径无效（未选/已删除）时回落内置默认壁纸。
ImageProvider backgroundImageProvider(
  ThemeProvider tp, {
  required int cacheWidth,
}) {
  final path = tp.backgroundImagePath;
  final file = (path != null && path.isNotEmpty) ? File(path) : null;
  if (file != null && file.existsSync()) {
    return ResizeImage(FileImage(file), width: cacheWidth);
  }
  return ResizeImage(
    const AssetImage(kDefaultWallpaperAsset),
    width: cacheWidth,
  );
}

/// 页面背景组件：模糊背景图 + 透明度调节（主题背景色打底）。
///
/// 静止时由 MaterialApp.builder 绘制一份全局背景，透过透明的 Scaffold 显示；
/// 路由过渡期间临时在页面内绘制同源背景以遮住旧页面，转场结束即停止绘制，
/// 避免嵌套 Navigator 的多层壁纸叠加造成分区透明度不一致。
///
/// 开关关闭时返回空（保持页面原样）；开关开启时优先用用户选择的图片，
/// 无有效用户图片时回落到内置默认壁纸（始终有背景，避免"无背景"状态导致
/// 浅色模式配色异常）。
class AppBackground extends StatelessWidget {
  const AppBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final tp = context.watch<ThemeProvider>();
    // 判定用**用户开关**本身，不加"图片文件必须存在"的条件。
    //
    // 原因：`backgroundImageProvider` 在路径为空/失效时会**回落到内置默认壁纸**，
    // 即"开关开着但用户还没选图"是一个完全正常的状态，此时就该显示默认壁纸。
    //
    // ⚠️ 2026-10-11 曾在这里改用 `isBackgroundImageEffective`（额外要求文件存在），
    // 想解决"壁纸未生效时页签栏色带不一致"。**方向错了**：它把兜底壁纸在数据层
    // 整个废掉 —— 开关开 + 无图 ⇒ 桌面与Android 两侧都不再渲染任何壁纸层，
    // 页面回到不透明纯色。色带问题应在**渲染层**解决（各页顶部区域与主体
    // 用同一 provider / 同一 opacity），不该拿"不渲染"当解法。
    if (!tp.useBackgroundImage) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    // 解码宽度按屏幕物理宽度限制：模糊背景无需超高分辨率，避免高分辨率
    // 照片全尺寸解码造成的内存峰值（低内存设备会闪退）。
    final screenWidth = MediaQuery.sizeOf(context).width *
        MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = screenWidth.round().clamp(540, 1440);
    // 图片源统一由 backgroundImageProvider 选择。
    final image = Image(
      image: backgroundImageProvider(tp, cacheWidth: cacheWidth),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
    );
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
                sigmaX: tvBlurSigma(tp.backgroundBlur),
                sigmaY: tvBlurSigma(tp.backgroundBlur),
              ),
              child: image,
            ),
          ),
        ],
      ),
    );
  }
}
