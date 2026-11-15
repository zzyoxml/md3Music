import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/dy_cover_models.dart';

void main() {
  group('DyCoverInfo.fromResponse', () {
    test('解析正常响应（实测结构）', () {
      final json = {
        'status': 1,
        'error_code': 0,
        'data': [
          {
            'base': {'album_id': 65482908, 'album_name': 'SOS (Explicit)'},
            'dycover': {
              'h264_hash': '64177AE676A7C118D435B889C1CFAFC9',
              'h264_url': 'http://kgv.stream.tencentmusic.com/a.f160030.mp4?dis_k=1',
              'h264_backup_url': [
                'http://kgv.stream.tencentmusic.com/a.f160030.mp4?dis_k=1&isbak=1',
              ],
              'h265_url': 'http://kgv.stream.tencentmusic.com/a.f160130.mp4?dis_k=2',
            },
          },
        ],
      };
      final info = DyCoverInfo.fromResponse(json, albumAudioId: '468087825');
      expect(info, isNotNull);
      expect(info!.hasVideo, isTrue);
      expect(info.albumAudioId, '468087825');
      expect(info.h264Url, contains('f160030.mp4'));
      expect(info.h264Hash, '64177AE676A7C118D435B889C1CFAFC9');
    });

    test('无动态封面条目为 {} → null', () {
      final json = {
        'data': [
          {
            'base': {'album_id': 1},
            'dycover': {
              'h264_hash': 'X',
              'h264_url': 'http://kgv.stream.tencentmusic.com/a.mp4',
            },
          },
          <String, dynamic>{},
        ],
      };
      expect(
        DyCoverInfo.fromResponse(json, index: 1, albumAudioId: '123'),
        isNull,
      );
    });

    test('data 缺失 / 非列表 / dycover 缺 url → null（不抛异常）', () {
      expect(DyCoverInfo.fromResponse({}, albumAudioId: '1'), isNull);
      expect(
        DyCoverInfo.fromResponse({'data': 'oops'}, albumAudioId: '1'),
        isNull,
      );
      expect(
        DyCoverInfo.fromResponse(
          {
            'data': [
              {'dycover': <String, dynamic>{}},
            ],
          },
          albumAudioId: '1',
        ),
        isNull,
      );
    });

    test('h264_url 为空串时回落备份地址', () {
      final json = {
        'data': [
          {
            'dycover': {
              'h264_url': '',
              'h264_backup_url': ['http://kgv.stream.tencentmusic.com/bak.mp4'],
            },
          },
        ],
      };
      final info = DyCoverInfo.fromResponse(json, albumAudioId: '1');
      expect(info?.h264Url, contains('bak.mp4'));
    });
  });
}
