import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/modules/playlist/cover_prepare.dart';

/// 封面预处理的单测。
///
/// 上游约束（2026-10-15 对 imgphp.kugou.com 实测）：宽高**各自** ≥ 约 400px、
/// 仅 JPEG/PNG、体积 ≤ 约 3MB。image_picker 不放大小图，因此客户端必须把任意
/// 选图（含极小图、非正方形图、GIF 转出的 PNG）统一加工成 640×640 正方形 PNG，
/// 否则真机上传必然得到 `Bad width` / `Bad height`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 4×2 非正方形 PNG（PIL 生成的确定性夹具）。
  final png4x2 = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAIAAADwyuo0AAAAFklEQVR4nGNkYIiyYWCAIBaGCgY4AAAbAgGMZrKcTAAAAABJRU5ErkJggg==',
  );

  /// 8×8 JPEG 夹具（覆盖 JPEG 解码路径）。
  final jpeg8x8 = base64Decode(
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAA0JCgsKCA0LCgsODg0PEyAVExISEyccHhcgLikxMC4pLSwzOko+MzZGNywtQFdBRkxOUlNSMj5aYVpQYEpRUk//2wBDAQ4ODhMREyYVFSZPNS01T09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0//wAARCAAIABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDJtvD/AE+T9K1rbw/0+T9KKKiviqvc5crxtbTU/9k=',
  );

  /// 1×1 PNG 夹具：上游下限约 400px，极小图必须被放大而非原样上传。
  final png1x1 = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGM4IScHAAK2AQU0pnWqAAAAAElFTkSuQmCC',
  );

  Future<void> expectSquarePng(List<int> out) async {
    // PNG magic：确认编码格式是上游接受的 PNG（不是 JPEG/WebP）
    expect(out.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(out));
    final frame = await codec.getNextFrame();
    expect(frame.image.width, kCoverOutputSide);
    expect(frame.image.height, kCoverOutputSide);
    frame.image.dispose();
  }

  test('非正方形 PNG 被中心裁成 640×640 正方形 PNG', () async {
    final out = await prepareCoverImage(png4x2);
    expect(out, isNotNull);
    await expectSquarePng(out!);
  });

  test('JPEG 源图同样被加工成 640×640 正方形 PNG', () async {
    final out = await prepareCoverImage(jpeg8x8);
    expect(out, isNotNull);
    await expectSquarePng(out!);
  });

  test('1×1 极小图被放大到 640×640（不放大小图是上游 Bad width 的根因）', () async {
    final out = await prepareCoverImage(png1x1);
    expect(out, isNotNull);
    await expectSquarePng(out!);
  });

  test('无法解码的字节返回 null（调用方提示换图）', () async {
    final out = await prepareCoverImage(
      Uint8List.fromList(const [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]),
    );
    expect(out, isNull);
  });

  group('localizeCoverUploadError 上游词汇表映射', () {
    test('实测词汇表逐一映射为中文可操作文案', () {
      expect(localizeCoverUploadError('Bad width'), '封面宽度过小，请选择尺寸更大的图片');
      expect(localizeCoverUploadError('Bad height'), '封面高度过小，请选择尺寸更大的图片');
      expect(
        localizeCoverUploadError('Bad image format'),
        '封面格式不受支持，请使用 JPG 或 PNG 图片',
      );
      expect(localizeCoverUploadError('Too big'), '封面文件过大，请更换一张图片');
      expect(localizeCoverUploadError('Empty file'), '图片数据为空，请重新选择');
      expect(localizeCoverUploadError('Empty type'), '上传校验失败，请稍后重试');
      expect(localizeCoverUploadError('Bad md5'), '上传校验失败，请稍后重试');
    });

    test('大小写与首尾空白不敏感', () {
      expect(localizeCoverUploadError('bad width'), '封面宽度过小，请选择尺寸更大的图片');
      expect(localizeCoverUploadError('  BAD HEIGHT  '), '封面高度过小，请选择尺寸更大的图片');
    });

    test('未知消息与 null 回退通用文案', () {
      expect(localizeCoverUploadError('something new'), '封面上传失败，请稍后重试');
      expect(localizeCoverUploadError(null), '封面上传失败，请稍后重试');
      expect(localizeCoverUploadError(''), '封面上传失败，请稍后重试');
    });
  });
}
