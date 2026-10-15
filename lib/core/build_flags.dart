/// 编译期构建旗标（--dart-define）。全部为 const，false 分支会被 AOT 树摇剔除，
/// 因此"正常版不编入 TV 代码 / TV 版不编入手机专属功能"由这些旗标保证。
///
/// - MD3_TV：TV 版包体（--flavor tv）。TV 版启用 dpad 遥控导航，
///   排除 3D 封面 / USB 独占输出 / 实时歌词推送。正常版不定义此旗标（默认 false）。
/// 与既有的 ENABLE_DEPTH_3D（lib/core/services/depth_cover_feature.dart）同一模式。
const bool kTvBuild = bool.fromEnvironment('MD3_TV');

/// tv: TV overscan 安全边距上限（dp）。
///
/// 仅作为**比例自适应时的封顶值**保留：`app.dart` 原先对内容子树套了固定
/// 48dp 的 `Padding`（Android TV 建议的安全区下限，约 1080p 宽度的 2.5%），
/// 但实测在无过扫描的设备（平板/手机、多数现代零间隙屏电视）上会显示为
/// 四条纯黑边且与铺满整屏的背景层不同色，已于 2026-10-04 移除该 Padding。
/// 若日后确需恢复边距，按屏宽比例取值并以本常量封顶，不要直接写死 48。
/// 正常构建不引用。
const double kTvOverscanInset = 48;

/// tv: TV 构建下正文的缩放下限（10-foot 可读性）。
///
/// 经 MediaQuery.textScaler.clamp 应用：只抬下限不压上限——系统字体缩放
/// 大于该值时保持用户设置。取值依据（保守）：主路径实测列表标题
/// titleSmall=14sp、副标题 labelSmall=11sp、设置标题 bodyLarge=16sp；
/// 1.15 → 16.1/12.65/18.4sp，设置标题达 18sp 硬线，列表标题 14→16sp。
/// 刻意不再上探（拉到 18sp 需 ×1.29）：密集列表行与固定高度布局会溢出，
/// 违背"温和提升、宁保守"的约束。正常构建不引用。
const double kTvMinTextScale = 1.15;

/// TV 弱 GPU 设备的模糊上限（sigma）。全屏高斯模糊在低端 Mali 上是主要
/// 掉帧源，TV 构建把各处 [ImageFilter.blur] 的 sigma 钳制到该值以内；
/// 非 TV 构建 [tvBlurSigma] 恒等返回原值（kTvBuild 为 const，分支折叠零开销）。
const double kTvMaxBlurSigma = 12.0;

double tvBlurSigma(double sigma) {
  if (!kTvBuild) return sigma;
  return sigma > kTvMaxBlurSigma ? kTvMaxBlurSigma : sigma;
}
