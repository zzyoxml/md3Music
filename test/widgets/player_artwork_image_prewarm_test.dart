import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/modules/player/mini_player.dart';
import 'package:md3music/widgets/player_artwork_image.dart';

/// 飞行封面**纹理预热**（真机定案的笔 A）的回归测试。
///
/// 这条线的成败只取决于一件事：**预热用的 provider 必须与飞行层同一个缓存键**。
/// 键一旦不同，预热就只是「多解一张没人用的大图」，而转场里该付的上传照付——
/// 数字上表现为日志打了 `prewarm ok` 但 `worst` 的 GPU 位原地不动（上一轮阴影预热
/// 就是这么被否证的）。所以这里不测「有没有画」，测「键对不对、该不该画」。
void main() {
  const url = 'https://cdn.example.com/cover.jpg';

  ImageProvider<Object>? providerFor(double width, double dpr) =>
      coverPrewarmProviderFor(
        artworkUri: url,
        settledLogicalWidth: width,
        devicePixelRatio: dpr,
      );

  group('缓存键必须与飞行层逐位相同', () {
    test('在线封面：336 逻辑宽 × dpr 3 → 档位 1024，与 resizeIfNeeded 同键', () {
      // 飞行层是 `CachedNetworkImage(memCacheWidth: tier)`，octo_image 内部落成
      // `ResizeImage.resizeIfNeeded(memCacheWidth, memCacheHeight, provider)`；
      // 期望值必须用**同一个工厂**构造，否则测的是我的抄写而不是行为。
      final expected =
          ResizeImage.resizeIfNeeded(1024, null, CachedNetworkImageProvider(url));
      expect(providerFor(336, 3), expected);
    });

    test('同档不同宽度共用一份解码结果', () {
      // 相邻尺寸归进同一档是本组件的既有约定（[_decodeTiers]），
      // 预热也必须按档走，否则每首歌都可能多解一份不同宽度的图。
      expect(providerFor(340, 3), providerFor(336, 3));
    });

    test('跨档必须换键（说明档位真的进了缓存键，不是常量）', () {
      expect(providerFor(250, 3), isNot(providerFor(336, 3))); // 768 vs 1024
    });

    test('dpr 异常时按 1.0 解，绝不按 0 解出空图', () {
      // ResizeImage 的目标为 0 会解出空图，飞行层会拿到一张看不见的封面。
      expect(providerFor(336, 0), ResizeImage.resizeIfNeeded(384, null, CachedNetworkImageProvider(url)));
      expect(providerFor(336, double.nan), providerFor(336, 1));
      expect(providerFor(double.nan, 3), providerFor(200, 3));
    });

    testWidgets('端到端：与 PlayerArtworkImage 真正渲染出来的那个 provider 同键', (
      tester,
    ) async {
      // 上面几条用的是「我也调 resizeIfNeeded」的期望值，本质是自证。
      // 这一条把真组件摆上去，读它实际交给 Image 的 provider 来对照：
      // 缓存键由 octo_image 把 memCacheWidth 转成 ResizeImage 这条链路
      // 只要哪天上游改了（policy / allowUpscaling / 参数顺序），这里就会先红。
      const width = 336.0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(devicePixelRatio: 3.0),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: width,
                child: PlayerArtworkImage(
                  artworkUri: url,
                  fallbackFilePath: null,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
        ),
      );
      final rendered = tester.widget<Image>(find.byType(Image)).image;
      expect(
        coverPrewarmProviderFor(
          artworkUri: url,
          settledLogicalWidth: width,
          devicePixelRatio: 3.0,
        ),
        rendered,
        reason: '预热键与渲染键不同 = 白解一份大图，转场里那笔上传照付',
      );
    });

    test('不该预热的源一律返回 null，而不是解一份不同键的图', () {
      expect(coverPrewarmProviderFor(
          artworkUri: null, settledLogicalWidth: 336, devicePixelRatio: 3), isNull);
      expect(coverPrewarmProviderFor(
          artworkUri: '', settledLogicalWidth: 336, devicePixelRatio: 3), isNull);
      // 内嵌封面的字节在 PlayerArtworkImage 的 State 里异步提取，外部拿不到同一份
      // bytes → 凑不出同一个 MemoryImage 键，明确不预热。
      expect(coverPrewarmProviderFor(
          artworkUri: 'local:///sdcard/Music/a.mp3',
          settledLogicalWidth: 336,
          devicePixelRatio: 3), isNull);
      expect(coverPrewarmProviderFor(
          artworkUri: 'content://media/external/audio/albumart/1',
          settledLogicalWidth: 336,
          devicePixelRatio: 3), isNull);
      expect(coverPrewarmProviderFor(
          artworkUri: 'file:///does/not/exist.jpg',
          settledLogicalWidth: 336,
          devicePixelRatio: 3), isNull);
    });
  });

  group('prewarm 必须自带成败与原因', () {
    // 上一轮的阴影预热静默执行，判「无效」时连它到底跑没跑都没证据。
    // 这里只测**不走网络**的分支：skip 的三种原因必须能互相区分。
    test('无 uri / 内嵌源 / 文件不存在，三种 skip 各说各话', () async {
      expect(
        await prewarmPlayerArtworkTexture(
            artworkUri: null, settledLogicalWidth: 336, devicePixelRatio: 3),
        'skip:no-uri',
      );
      expect(
        await prewarmPlayerArtworkTexture(
            artworkUri: 'content://media/external/audio/albumart/1',
            settledLogicalWidth: 336,
            devicePixelRatio: 3),
        'skip:embedded-source',
      );
      expect(
        await prewarmPlayerArtworkTexture(
            artworkUri: 'file:///does/not/exist.jpg',
            settledLogicalWidth: 336,
            devicePixelRatio: 3),
        'skip:file-missing',
      );
    });
  });

  group('触发闸门：不展开过播放页就不预付', () {
    const settled = Rect.fromLTWH(180, 400, 336, 336);

    test('本会话还没展开过播放页（settledRect 为 null）→ 不预热', () {
      expect(
        shouldPrewarmCoverTexture(
            artworkUri: url, alreadyPrewarmedUri: null, settledRect: null),
        isFalse,
        reason: 'settled 档解码一张封面约 4MB 驻留，从不进播放页的用户不该背；'
            '而且没有 settledRect 就算不出飞行层那一档的精确宽度，白解一份不同键的图',
      );
    });

    test('展开过、且是本会话里这首歌的第一次 → 预热', () {
      expect(
        shouldPrewarmCoverTexture(
            artworkUri: url, alreadyPrewarmedUri: null, settledRect: settled),
        isTrue,
      );
    });

    test('同一首歌反复 build 不重复调度', () {
      expect(
        shouldPrewarmCoverTexture(
            artworkUri: url,
            alreadyPrewarmedUri: url,
            settledRect: settled),
        isFalse,
      );
    });

    test('没有封面 uri 时什么都不做（占位符不占缓存）', () {
      expect(
        shouldPrewarmCoverTexture(
            artworkUri: null,
            alreadyPrewarmedUri: null,
            settledRect: settled),
        isFalse,
      );
      expect(
        shouldPrewarmCoverTexture(
            artworkUri: '',
            alreadyPrewarmedUri: null,
            settledRect: settled),
        isFalse,
      );
    });

    test('终点矩形宽度为 0（页面还没真正布局）也不预热', () {
      expect(
        shouldPrewarmCoverTexture(
            artworkUri: url,
            alreadyPrewarmedUri: null,
            settledRect: Rect.zero),
        isFalse,
      );
    });
  });
}
