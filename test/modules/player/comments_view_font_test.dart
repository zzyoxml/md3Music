import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:md3music/modules/player/comments_view.dart';
import 'package:md3music/providers/comment_display_provider.dart';
import 'package:md3music/providers/kugou_provider.dart';
import 'package:md3music/services/kugou_api/kugou_models.dart';

/// 返回固定评论的假 Provider：评论正文走歌手评论栏直接渲染，
/// 不依赖「最热」接口（childrenId 留空即跳过），测试不触网。
class _FakeKugouProvider extends KugouProvider {
  _FakeKugouProvider() : super(registerDeviceOnStart: false);

  @override
  Future<KugouCommentList?> getComments(
    String hash, {
    String? albumAudioId,
    int page = 1,
  }) async {
    return const KugouCommentList(
      hotComments: [
        KugouComment(
          id: 'c1',
          username: '测试用户',
          content: '全局字体测试正文',
          isStar: true,
        ),
      ],
    );
  }
}

void main() {
  testWidgets('播放页顶层评论正文跟随全局字体', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final fake = _FakeKugouProvider();
    addTearDown(fake.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'GlobalFontA'),
        home: Scaffold(
          body: MultiProvider(
            providers: [
              ChangeNotifierProvider<KugouProvider>.value(value: fake),
              ChangeNotifierProvider(create: (_) => CommentDisplayProvider()),
            ],
            child: const CommentsView(
              songHash: 'test_hash',
              showComposer: false,
            ),
          ),
        ),
      ),
    );
    // 首帧 post-frame 回调发起 getComments（假实现立即完成），再一帧渲染评论
    await tester.pump();
    await tester.pump();

    final rich = tester.widget<RichText>(
      find.text('全局字体测试正文', findRichText: true),
    );
    final contentSpan = (rich.text as TextSpan).children!.first as TextSpan;
    // 裸 TextStyle 不带 fontFamily 时这里会拿到 null（引擎默认字体），
    // 即用户反馈的「改全局字体评论不变」。
    expect(contentSpan.style?.fontFamily, 'GlobalFontA');
  });
}
