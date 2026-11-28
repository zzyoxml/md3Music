import 'dart:typed_data';
import 'dart:ui' as ui;

/// 歌单自定义封面的客户端预处理，及上游错误文案的汉化映射。
///
/// ## 上游图床的硬约束（2026-10-15 对 imgphp.kugou.com 实测定格）
///
/// `POST http://imgphp.kugou.com/imageupload/stream.php`（`/playlist/pic/upload`
/// 的上游）对 `type=custom` 的图片逐层校验：
/// - 宽、高**各自独立**校验，任一低于约 400px 即拒：
///   `{"IsSuccess":false,"Message":"Bad width"}` / `"Bad height"`；
/// - 仅接受 JPEG / PNG（WebP 等拒：`Bad image format`）；
/// - 体积上限约 3MB（3.4MB 即拒：`Too big`）。
///
/// ## 为什么必须客户端预处理
///
/// image_picker（Android 端 `ImageResizer`）的行为与上游约束不匹配：
/// - `maxWidth/maxHeight` 只做「fit within 1024」下采样，**不放大小图**，
///   小图原样上传必然触发 Bad width / Bad height；
/// - 位图带 alpha 时存成 **PNG** 并忽略 imageQuality；GIF 只保留首帧；
/// - 解码失败时原样返回（可能是 WebP 等上游不认的格式）。
///
/// 因此统一加工成 [kCoverOutputSide] 边长正方形 PNG 再上传：
/// 解码走引擎 Skia（与 image_picker 同一套解码器，JPEG/PNG/GIF/WebP 全兼容），
/// 中心裁正方形 → 缩放 → PNG 编码（PNG 已被上游实测接受，含 alpha 与
/// `extendName=.png` 组合）。
///
/// 参考实现（MakcRe/KuGouMusicApi `playlist_pic_upload.js`）与本项目 Rust
/// 转发层均不含任何尺寸/格式处理，这些约束只能由客户端归一化。

/// 封面输出边长（正方形）。
///
/// 上游要求宽高各自 ≥ 约 400px，取 640 兼顾清晰度与体积：
/// 640×640 PNG 最坏约 1.2MB（全噪声图），低于上游约 3MB 的体积上限。
const int kCoverOutputSide = 640;

/// 把相册选图加工成上游接受的正方形 PNG 字节。
///
/// 源图无法解码（或光栅化失败）时返回 null，调用方应提示用户换图。
Future<Uint8List?> prepareCoverImage(Uint8List source) async {
  final ui.Codec codec;
  try {
    codec = await ui.instantiateImageCodec(source);
  } catch (_) {
    return null;
  }
  final ui.FrameInfo frame;
  try {
    frame = await codec.getNextFrame();
  } catch (_) {
    return null;
  }
  final image = frame.image;
  try {
    // 中心裁正方形：短边为边长，长边居中
    final side = image.width < image.height ? image.width : image.height;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH(
        (image.width - side) / 2,
        (image.height - side) / 2,
        side.toDouble(),
        side.toDouble(),
      ),
      ui.Rect.fromLTWH(0, 0, kCoverOutputSide.toDouble(), kCoverOutputSide.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final ui.Image rendered;
    try {
      rendered = await recorder.endRecording().toImage(
        kCoverOutputSide,
        kCoverOutputSide,
      );
    } catch (_) {
      return null;
    }
    try {
      final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      return Uint8List.view(data.buffer, data.offsetInBytes, data.lengthInBytes);
    } finally {
      rendered.dispose();
    }
  } finally {
    image.dispose();
  }
}

/// 上游英文 `Message` → 中文可操作文案。
///
/// 词汇表为 2026-10-15 实测所得（大小写不敏感匹配）。未知消息回退通用文案，
/// 原始消息由 Rust 侧 `handle_pic_upload` 的日志留存，不影响排查。
String localizeCoverUploadError(String? rawMessage) {
  switch (rawMessage?.trim().toLowerCase()) {
    case 'bad width':
      return '封面宽度过小，请选择尺寸更大的图片';
    case 'bad height':
      return '封面高度过小，请选择尺寸更大的图片';
    case 'bad image format':
      return '封面格式不受支持，请使用 JPG 或 PNG 图片';
    case 'too big':
      return '封面文件过大，请更换一张图片';
    case 'empty file':
      return '图片数据为空，请重新选择';
    case 'empty type':
    case 'bad md5':
      return '上传校验失败，请稍后重试';
    default:
      return '封面上传失败，请稍后重试';
  }
}
