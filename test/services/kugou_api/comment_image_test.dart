import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/services/kugou_api/kugou_models.dart';

/// 评论图片：解析上游 images 数组（url/width/height），过滤无效项。
void main() {
  test('解析单图：url/width/height 就位，宽高比可算', () {
    final c = KugouComment.fromJson({
      'id': '1666906178',
      'user_name': 'FYAO-',
      'content': '新婚快乐。',
      'images': [
        {
          'url': 'https://cmtimgbssdl.cloud.kugou.com/abc.jpg',
          'width': 2040,
          'height': 1530,
          'mark': 1,
          'label': '[此评论图片请到手机查看]',
        },
      ],
    });

    expect(c.images, hasLength(1));
    expect(c.images.first.url, 'https://cmtimgbssdl.cloud.kugou.com/abc.jpg');
    expect(c.images.first.width, 2040);
    expect(c.images.first.height, 1530);
    expect(c.images.first.aspectRatio, closeTo(2040 / 1530, 0.0001));
  });

  test('解析多图并保持顺序', () {
    final c = KugouComment.fromJson({
      'id': '1',
      'user_name': 'x',
      'content': 'y',
      'images': [
        {'url': 'https://a/1.jpg', 'width': 900, 'height': 900},
        {'url': 'https://a/2.jpg', 'width': 482, 'height': 1024},
      ],
    });

    expect(c.images.map((e) => e.url).toList(), ['https://a/1.jpg', 'https://a/2.jpg']);
  });

  test('http 图片地址保持原样，不做 https 改写', () {
    // webimg.bssdl.kugou.com 无有效 https 证书，改写会导致加载失败
    final c = KugouComment.fromJson({
      'id': '1',
      'content': 'y',
      'images': [
        {'url': 'http://webimg.bssdl.kugou.com/x.jpg', 'width': 900, 'height': 900},
      ],
    });

    expect(c.images.first.url, 'http://webimg.bssdl.kugou.com/x.jpg');
  });

  test('无图/空数组/字段缺失 → 空列表', () {
    expect(KugouComment.fromJson({'id': '1', 'content': 'y'}).images, isEmpty);
    expect(
      KugouComment.fromJson({'id': '1', 'content': 'y', 'images': []}).images,
      isEmpty,
    );
    expect(
      KugouComment.fromJson({'id': '1', 'content': 'y', 'images': null}).images,
      isEmpty,
    );
  });

  test('跳过无 url 的脏数据，尺寸缺失时宽高比回退 1.0', () {
    final c = KugouComment.fromJson({
      'id': '1',
      'content': 'y',
      'images': [
        {'url': '', 'width': 100, 'height': 100},
        {'width': 100, 'height': 100},
        {'url': 'https://a/ok.jpg'},
      ],
    });

    expect(c.images, hasLength(1));
    expect(c.images.first.url, 'https://a/ok.jpg');
    expect(c.images.first.aspectRatio, 1.0);
  });

  test('images 非数组时安全降级为空列表', () {
    final c = KugouComment.fromJson({'id': '1', 'content': 'y', 'images': 'oops'});
    expect(c.images, isEmpty);
  });
}
