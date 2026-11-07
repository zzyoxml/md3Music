import 'package:flutter_test/flutter_test.dart';

import 'package:md3music/data/models/song.dart';

/// 「歌手未知」占位值判定。
///
/// 回归背景：项目里两条路径产生不同字面量——在线侧是「未知歌手」、
/// 本地侧是「未知艺术家」。歌词检索词守卫曾只比较后者，导致一起听跟随端
/// （值是「未知歌手」）漏判，检索词退化成「未知歌曲 未知歌手」。
void main() {
  group('isUnknownArtist', () {
    test('两个占位值都判为未知（这是本次修复的核心）', () {
      expect(isUnknownArtist(kUnknownArtistPlaceholder), isTrue);
      expect(isUnknownArtist(kUnknownArtistPlaceholderLocal), isTrue);
    });

    test('null 与空串判为未知', () {
      expect(isUnknownArtist(null), isTrue);
      expect(isUnknownArtist(''), isTrue);
      expect(isUnknownArtist('   '), isTrue);
    });

    test('真实歌手名判为已知', () {
      expect(isUnknownArtist('G.E.M.邓紫棋'), isFalse);
      expect(isUnknownArtist('周杰伦'), isFalse);
      expect(isUnknownArtist('hanser'), isFalse);
    });

    test('含「未知」但不是占位值的真名不被误判', () {
      // 防止用 contains('未知') 之类过宽判定
      expect(isUnknownArtist('未知森林'), isFalse);
      expect(isUnknownArtist('未知艺术家乐队'), isFalse);
    });

    test('两侧占位值互不相等（所以旧守卫必然漏判）', () {
      expect(
        kUnknownArtistPlaceholder,
        isNot(kUnknownArtistPlaceholderLocal),
        reason: '这正是旧代码 song.artist != 未知艺术家 会漏掉一起听跟随端的原因',
      );
    });

    test('常量值与原字面量保持一致（防止改动破坏既有数据）', () {
      expect(kUnknownSongTitle, '未知歌曲');
      expect(kUnknownArtistPlaceholder, '未知歌手');
      expect(kUnknownArtistPlaceholderLocal, '未知艺术家');
    });
  });
}
