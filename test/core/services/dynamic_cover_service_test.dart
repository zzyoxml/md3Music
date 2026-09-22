import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/dynamic_cover_service.dart';

void main() {
  group('shouldLoadDynamicCover', () {
    test('主开关关闭 → 任何网络都不加载', () {
      expect(
        shouldLoadDynamicCover(
          enabled: false,
          allowOnMobile: true,
          isWifi: true,
        ),
        isFalse,
      );
      expect(
        shouldLoadDynamicCover(
          enabled: false,
          allowOnMobile: true,
          isWifi: false,
        ),
        isFalse,
      );
    });

    test('Wi-Fi 且主开关开启 → 加载（与子开关无关）', () {
      expect(
        shouldLoadDynamicCover(
          enabled: true,
          allowOnMobile: false,
          isWifi: true,
        ),
        isTrue,
      );
    });

    test('移动网络：子开关决定', () {
      expect(
        shouldLoadDynamicCover(
          enabled: true,
          allowOnMobile: false,
          isWifi: false,
        ),
        isFalse,
      );
      expect(
        shouldLoadDynamicCover(
          enabled: true,
          allowOnMobile: true,
          isWifi: false,
        ),
        isTrue,
      );
    });
  });

  group('streamUrlFor', () {
    test('必须是回环代理地址且带 album_audio_id', () {
      final url = DynamicCoverService.instance.streamUrlFor('468087825');
      expect(url, endsWith('/album/dycover/media?album_audio_id=468087825'));
    });
  });

  group('mapDyCoverProbe', () {
    // 这三条钉住一个不变量：只有「确定无封面」才允许写负缓存。
    // 回归背景：把请求失败也当成「无封面」会让一次瞬时失败（回环服务器未就绪 /
    // 上游抖动 / 非 200）演变成该专辑整个会话都不再显示动态封面，且静默无日志。
    test('请求失败（null）→ unknown，不得写负缓存', () {
      expect(mapDyCoverProbe(null, '468087825'), DyCoverProbe.unknown);
    });

    test('响应里条目为 {} → absent（确定无动态封面）', () {
      expect(
        mapDyCoverProbe({
          'status': 1,
          'data': [<String, dynamic>{}],
        }, '468087825'),
        DyCoverProbe.absent,
      );
    });

    test('h264_url 为空 → absent', () {
      expect(
        mapDyCoverProbe({
          'data': [
            {
              'dycover': {'h264_url': '', 'h264_hash': 'X'},
            },
          ],
        }, '468087825'),
        DyCoverProbe.absent,
      );
    });

    test('有可播放地址 → present', () {
      expect(
        mapDyCoverProbe({
          'data': [
            {
              'dycover': {
                'h264_url': 'http://kgv.stream.tencentmusic.com/a.f160030.mp4',
              },
            },
          ],
        }, '468087825'),
        DyCoverProbe.present,
      );
    });
  });

  group('dyCoverStatusText（界面设置菜单展示）', () {
    test('本地歌曲 / 缺 albumAudioId → 不适用', () {
      expect(
        dyCoverStatusText(
          isOnline: false,
          albumAudioId: '',
          known: null,
        ),
        '不适用',
      );
      expect(
        dyCoverStatusText(
          isOnline: true,
          albumAudioId: '',
          known: null,
        ),
        '不适用',
      );
    });

    test('确定有 / 确定没有 → 有 / 无', () {
      expect(
        dyCoverStatusText(
          isOnline: true,
          albumAudioId: '1',
          known: true,
        ),
        '有',
      );
      expect(
        dyCoverStatusText(
          isOnline: true,
          albumAudioId: '1',
          known: false,
        ),
        '无',
      );
    });

    test('探测中 → 检测中…；请求结束仍未确定 → 未获取到（不得说成「无」）', () {
      expect(
        dyCoverStatusText(
          isOnline: true,
          albumAudioId: '1',
          known: null,
          probing: true,
        ),
        '检测中…',
      );
      expect(
        dyCoverStatusText(
          isOnline: true,
          albumAudioId: '1',
          known: null,
        ),
        '未获取到',
      );
    });
  });
}
