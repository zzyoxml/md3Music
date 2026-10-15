import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/modules/player/player_tab_layout.dart';

/// 顺序固定为 [播放列表, 封面?, 控制?, 歌词, 评论?]：
///   * 封面 tab 只在窄屏存在、控制 tab 只在宽屏存在，两者同为下标 1 但不冲突；
///   * 歌词、评论恒在控制 tab 之后。
void main() {
  group('宽分栏页签判定', () {
    test('嵌入播放器的宽面板仍按宽屏处理', () {
      expect(
        isWidePlayerTabLayout(
          dockMode: true,
          deviceIsPad: false,
          width: 800,
        ),
        isTrue,
      );
      final layout = resolvePlayerTabLayout(
        isWideLayout: isWidePlayerTabLayout(
          dockMode: true,
          deviceIsPad: false,
          width: 800,
        ),
        isLocalSong: false,
        closeLocalMusicComments: true,
        showControlsPage: false,
      );
      expect(layout.hasCover, isFalse);
      expect(layout.tabKinds, const [
        PlayerTabKind.playlist,
        PlayerTabKind.lyrics,
        PlayerTabKind.comments,
      ]);
    });

    test('设备标记为平板但车机面板窄时仍保留封面页签', () {
      expect(
        isWidePlayerTabLayout(
          dockMode: true,
          deviceIsPad: true,
          width: 500,
        ),
        isFalse,
      );
    });

    test('普通播放器仍尊重平板设备类型', () {
      expect(
        isWidePlayerTabLayout(
          dockMode: false,
          deviceIsPad: true,
          width: 500,
        ),
        isTrue,
      );
    });
  });

  group('resolvePlayerTabLayout 结构推导', () {
    test('窄屏在线歌曲：含封面与评论 tab，共 4 个，歌词下标 2', () {
      final layout = resolvePlayerTabLayout(
        isWideLayout: false,
        isLocalSong: false,
        closeLocalMusicComments: true,
        showControlsPage: false,
      );
      expect(layout.hasCover, isTrue);
      expect(layout.hasComments, isTrue);
      expect(layout.length, 4);
      expect(layout.lyricsIndex, 2);
    });

    test('窄屏本地歌曲且开启「关闭本地音乐评论区」：无评论 tab，共 3 个', () {
      final layout = resolvePlayerTabLayout(
        isWideLayout: false,
        isLocalSong: true,
        closeLocalMusicComments: true,
        showControlsPage: false,
      );
      expect(layout.hasCover, isTrue);
      expect(layout.hasComments, isFalse);
      expect(layout.length, 3);
      expect(layout.lyricsIndex, 2);
    });

    test('commentsIndex 指向评论 tab；无评论 tab 时为 -1（不能用 length-1 反推）', () {
      final narrow = resolvePlayerTabLayout(
        isWideLayout: false,
        isLocalSong: false,
        closeLocalMusicComments: true,
        showControlsPage: false,
      );
      expect(narrow.commentsIndex, 3);
      expect(narrow.commentsIndex, narrow.length - 1);

      final wide = resolvePlayerTabLayout(
        isWideLayout: true,
        isLocalSong: false,
        closeLocalMusicComments: true,
        showControlsPage: false,
      );
      expect(wide.commentsIndex, 2);

      final noComments = resolvePlayerTabLayout(
        isWideLayout: false,
        isLocalSong: true,
        closeLocalMusicComments: true,
        showControlsPage: false,
      );
      expect(noComments.commentsIndex, -1);
      expect(noComments.length - 1, 2, reason: '此时 length-1 会指到歌词 tab');
    });

    test('窄屏本地歌曲但关闭该开关：恢复评论 tab，共 4 个', () {
      final layout = resolvePlayerTabLayout(
        isWideLayout: false,
        isLocalSong: true,
        closeLocalMusicComments: false,
        showControlsPage: false,
      );
      expect(layout.hasComments, isTrue);
      expect(layout.length, 4);
    });

    test('宽屏在线歌曲：无封面 tab，共 3 个，歌词下标 1', () {
      final layout = resolvePlayerTabLayout(
        isWideLayout: true,
        isLocalSong: false,
        closeLocalMusicComments: true,
        showControlsPage: false,
      );
      expect(layout.hasCover, isFalse);
      expect(layout.hasComments, isTrue);
      expect(layout.length, 3);
      expect(layout.lyricsIndex, 1);
    });

    test('宽屏本地歌曲且开启该开关：无封面无评论，共 2 个', () {
      final layout = resolvePlayerTabLayout(
        isWideLayout: true,
        isLocalSong: true,
        closeLocalMusicComments: true,
        showControlsPage: false,
      );
      expect(layout.hasCover, isFalse);
      expect(layout.hasComments, isFalse);
      expect(layout.length, 2);
      expect(layout.lyricsIndex, 1);
    });

    test('该开关只作用于本地歌：在线歌曲开启开关时仍有评论 tab', () {
      final layout = resolvePlayerTabLayout(
        isWideLayout: false,
        isLocalSong: false,
        closeLocalMusicComments: true,
        showControlsPage: false,
      );
      expect(layout.hasComments, isTrue);
    });

    test('coverIndex 恒为 1；无封面 tab（宽屏）时为 -1', () {
      // 封面形变的资格判定依赖它：窄屏切到非封面 tab 时封面不可见，
      // 必须屏蔽形变（否则下拉收起会凭空飞出一个封面和歌名）；
      // 宽屏封面常驻左栏、与 tab 无关，`-1` 表示"永远可见"。
      for (final hasComments in [true, false]) {
        final narrow = resolvePlayerTabLayout(
          isWideLayout: false,
          isLocalSong: !hasComments,
          closeLocalMusicComments: true,
          showControlsPage: false,
        );
        expect(narrow.hasCover, isTrue);
        expect(narrow.coverIndex, 1, reason: '窄屏封面 tab 恒为 1');

        final wide = resolvePlayerTabLayout(
          isWideLayout: true,
          isLocalSong: !hasComments,
          closeLocalMusicComments: true,
          showControlsPage: false,
        );
        expect(wide.hasCover, isFalse);
        expect(wide.coverIndex, -1, reason: '宽屏无封面 tab');
      }
    });

    test('coverIndex 不与歌词下标混同（窄屏 1 vs 2）', () {
      final layout = resolvePlayerTabLayout(
        isWideLayout: false,
        isLocalSong: false,
        closeLocalMusicComments: true,
        showControlsPage: false,
      );
      expect(layout.coverIndex, isNot(layout.lyricsIndex));
    });
  });

  group('控制页 tab（宽屏 + 横屏控制面板独立页）', () {
    test('宽屏 + 开关开启：控制页紧跟播放列表，歌词/评论顺位后移', () {
      for (final entry in [
        (isLocalSong: false, hasComments: true), // 在线歌：播放列表/控制/歌词/评论，4 个
        (isLocalSong: true, hasComments: false), // 本地歌 + 关评论区：播放列表/控制/歌词，3 个
      ]) {
        final layout = resolvePlayerTabLayout(
          isWideLayout: true,
          isLocalSong: entry.isLocalSong,
          closeLocalMusicComments: true,
          showControlsPage: true,
        );
        expect(layout.hasControls, isTrue);
        expect(layout.hasComments, entry.hasComments);
        expect(layout.length, 3 + (entry.hasComments ? 1 : 0));
        expect(layout.controlsIndex, 1, reason: '控制页紧跟播放列表');
        expect(layout.lyricsIndex, 2, reason: '控制页把歌词往后顶一位');
        if (entry.hasComments) {
          expect(layout.commentsIndex, 3);
          expect(layout.commentsIndex, layout.length - 1);
        } else {
          expect(layout.commentsIndex, -1);
          expect(layout.length - 1, 2, reason: 'length-1 此时是歌词 tab');
        }
      }
    });

    test('tabKinds 与下标 getter 同源', () {
      final layout = resolvePlayerTabLayout(
        isWideLayout: true,
        isLocalSong: false,
        closeLocalMusicComments: true,
        showControlsPage: true,
      );
      expect(layout.tabKinds, const [
        PlayerTabKind.playlist,
        PlayerTabKind.controls,
        PlayerTabKind.lyrics,
        PlayerTabKind.comments,
      ]);
      expect(layout.length, layout.tabKinds.length);
      for (final kind in PlayerTabKind.values) {
        expect(
          layout.indexOfKind(kind),
          layout.tabKinds.indexOf(kind),
          reason: '$kind 的下标必须由 tabKinds 单一真值给出',
        );
      }
    });

    test('窄屏即使开关开启也没有控制页（控制页只在宽屏存在）', () {
      final layout = resolvePlayerTabLayout(
        isWideLayout: false,
        isLocalSong: false,
        closeLocalMusicComments: true,
        showControlsPage: true,
      );
      expect(layout.hasControls, isFalse);
      expect(layout.controlsIndex, -1);
      expect(layout.length, 4, reason: '结构与未开控制页时一致');
      expect(layout.tabKinds, const [
        PlayerTabKind.playlist,
        PlayerTabKind.cover,
        PlayerTabKind.lyrics,
        PlayerTabKind.comments,
      ]);
    });

    test('showControlsPage=false（含 dockMode 短路）结构与今天逐字段一致', () {
      // dockMode（车机面板）在调用方把 isWideLayout 短路成 false，
      // 这里两个输入都关，覆盖「双保险」路径。
      final wide = resolvePlayerTabLayout(
        isWideLayout: true,
        isLocalSong: false,
        closeLocalMusicComments: true,
        showControlsPage: false,
      );
      expect(wide, (hasCover: false, hasComments: true, hasControls: false));
      expect(wide.length, 3);
      expect(wide.controlsIndex, -1);

      final narrow = resolvePlayerTabLayout(
        isWideLayout: false,
        isLocalSong: true,
        closeLocalMusicComments: true,
        showControlsPage: false,
      );
      expect(narrow, (hasCover: true, hasComments: false, hasControls: false));
    });

    test('封面 tab 与控制 tab 互斥，同为下标 1 也不撞车', () {
      const narrow = (hasCover: true, hasComments: true, hasControls: false);
      const wide = (hasCover: false, hasComments: true, hasControls: true);
      expect(narrow.coverIndex, 1);
      expect(wide.controlsIndex, 1);
      // resolve 不会产出「两者同在」的结构；即使手构造，封面恒在前、控制在后，
      // 两个 getter 也各指各的页。
      const synthetic = (hasCover: true, hasComments: true, hasControls: true);
      expect(synthetic.coverIndex, 1);
      expect(synthetic.controlsIndex, 2);
      expect(synthetic.lyricsIndex, 3);
      expect(synthetic.commentsIndex, 4);
      expect(synthetic.length, 5);
    });
  });

  group('indexAfterChangeFrom 结构变化后记住上一页的内容', () {
    const narrowFull = (hasCover: true, hasComments: true, hasControls: false);
    const narrowNoComments = (
      hasCover: true,
      hasComments: false,
      hasControls: false
    );
    const wideControls = (
      hasCover: false,
      hasComments: true,
      hasControls: true
    );
    const wideNoControls = (
      hasCover: false,
      hasComments: true,
      hasControls: false
    );

    test('窄屏 → 宽屏：播放列表留在播放列表，歌词留在歌词', () {
      // 这是「记住上一页」的核心：裸下标会变（窄屏 1 = 封面、宽屏 1 = 控制），
      // 但同一页的内容必须还在这页上。
      expect(wideControls.indexAfterChangeFrom(0, narrowFull), 0);
      expect(wideControls.indexAfterChangeFrom(2, narrowFull), 2);
      expect(wideControls.indexAfterChangeFrom(3, narrowFull), 3);
    });

    test('窄屏 → 宽屏：专辑页落到控制页（两者互为跨形态替身）', () {
      // 竖屏停在专辑页 → 旋到横屏对应控制页；宽屏若没有控制页（开关关），
      // 替身不存在，退回歌词（封面已常驻左栏）。
      expect(wideControls.indexAfterChangeFrom(1, narrowFull), 1);
      expect(wideNoControls.indexAfterChangeFrom(1, narrowFull), 1);
    });

    test('宽屏 → 窄屏：控制页落到专辑页', () {
      expect(narrowFull.indexAfterChangeFrom(1, wideControls), 1);
      expect(narrowNoComments.indexAfterChangeFrom(1, wideControls), 1);
    });

    test('运行中关掉控制页开关：停在控制页时落歌词，停在其它页时跟着顺位前移', () {
      // wideControls = 播放列表0 / 控制1 / 歌词2 / 评论3
      // wideNoControls = 播放列表0 / 歌词1 / 评论2
      expect(
        wideNoControls.indexAfterChangeFrom(1, wideControls),
        1,
        reason: '控制页消失 → 歌词（此时歌词下标就是 1）',
      );
      expect(wideNoControls.indexAfterChangeFrom(0, wideControls), 0);
      expect(wideNoControls.indexAfterChangeFrom(2, wideControls), 1);
      expect(wideNoControls.indexAfterChangeFrom(3, wideControls), 2);
    });

    test('运行中打开控制页开关：原来在歌词仍在歌词，不被拽到控制页', () {
      expect(wideControls.indexAfterChangeFrom(1, wideNoControls), 2);
      expect(wideControls.indexAfterChangeFrom(0, wideNoControls), 0);
      expect(wideControls.indexAfterChangeFrom(2, wideNoControls), 3);
    });

    test('评论 tab 消失：从评论页出发落到歌词（与旧的钳制行为一致）', () {
      expect(narrowNoComments.indexAfterChangeFrom(3, narrowFull), 2);
    });

    test('宽屏关掉控制页开关：从评论页出发评论仍在，只是顺位前移', () {
      // 宽屏有控制页：播放列表0 / 控制1 / 歌词2 / 评论3；关掉后评论仍是最后一项。
      expect(wideNoControls.indexAfterChangeFrom(3, wideControls), 2);
    });

    test('下标越界（旧 controller 比新结构长）时落到歌词', () {
      expect(wideNoControls.indexAfterChangeFrom(9, narrowFull), 1);
      expect(wideControls.indexAfterChangeFrom(-1, narrowFull), 2);
    });

    test('结构不变时保持原下标', () {
      expect(narrowFull.indexAfterChangeFrom(0, narrowFull), 0);
      expect(narrowFull.indexAfterChangeFrom(3, narrowFull), 3);
      expect(wideControls.indexAfterChangeFrom(1, wideControls), 1);
    });

    test('常驻控制带档（开关关闭）：宽屏恒无 controls 页，替身不生效', () {
      // dock 档「控制」不再是页 —— 右栏底部常驻控制带承载它。
      // tab 结构里少一个页，pager children / TabController.length / 页签 items
      // 三处必须由这同一份结构派生（计划 R4）。
      for (final isLocal in <bool>[false, true]) {
        final layout = resolvePlayerTabLayout(
          isWideLayout: true,
          isLocalSong: isLocal,
          closeLocalMusicComments: false,
          showControlsPage: false,
        );
        expect(layout.hasControls, isFalse);
        expect(layout.controlsIndex, -1);
        expect(layout.tabKinds, isNot(contains(PlayerTabKind.controls)));
      }
      // 竖屏专辑页的跨形态替身（控制页）在本档不存在 → 落回歌词，
      // 而不是被丢到一个并不存在的页上。
      expect(wideNoControls.indexAfterChangeFrom(1, narrowFull), wideNoControls.lyricsIndex);
    });
  });
}
