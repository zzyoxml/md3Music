import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/providers/listen_together_provider.dart';
import 'package:md3music/services/kugou_api/listen_together_models.dart';

/// 房主头像回填的时序回归。
///
/// 两种时序都要能拿到头像：
///   A. 详情先到 → ensureSelfInMembers 注入时直接带上头像；
///   B. 成员先到 → 房主条目已按 avatar: '' 建好，详情返回后必须**就地回填**，
///      否则长度不变会被 `merged.length != members.length` 的旧判断漏掉，
///      头像永久留空（用户表现为「房主头像无法加载」）。
void main() {
  RoomMember m(String userId, {String avatar = '', String nickname = ''}) =>
      RoomMember(
        userId: userId,
        nickname: nickname.isEmpty ? '用户$userId' : nickname,
        avatar: avatar,
        studyStatus: 0,
      );

  const ownerPic = 'http://imge.kugou.com/kugouicon/165/20260918/x.jpg';

  group('backfillOwnerAvatar（成员先于详情返回时的就地回填）', () {
    test('房主头像为空时回填', () {
      final members = [m('OWNER', nickname: '房主'), m('u1')];
      final out = backfillOwnerAvatar(
        members,
        ownerUserId: 'OWNER',
        ownerAvatar: ownerPic,
      );
      expect(out.first.avatar, ownerPic);
      expect(out.first.nickname, '房主', reason: '昵称应保持不变');
      expect(out.map((e) => e.userId).toList(), ['OWNER', 'u1'],
          reason: '位置与顺序不得改变');
    });

    test('无变化时返回原实例（调用方靠 identical 判断是否需要 notify）', () {
      final members = [m('OWNER', avatar: ownerPic), m('u1')];
      final out = backfillOwnerAvatar(
        members,
        ownerUserId: 'OWNER',
        ownerAvatar: ownerPic,
      );
      expect(identical(out, members), isTrue);
    });

    test('头像未变但昵称不同也不误判（只比头像）', () {
      final members = [m('OWNER', avatar: ownerPic, nickname: '房主')];
      final out = backfillOwnerAvatar(
        members,
        ownerUserId: 'OWNER',
        ownerAvatar: ownerPic,
      );
      expect(identical(out, members), isTrue);
    });

    test('列表中没有房主条目时原样返回', () {
      final members = [m('u1'), m('u2')];
      final out = backfillOwnerAvatar(
        members,
        ownerUserId: 'OWNER',
        ownerAvatar: ownerPic,
      );
      expect(identical(out, members), isTrue);
    });

    test('ownerAvatar 为空时不做任何事（避免把已有头像清成空）', () {
      final members = [m('OWNER', avatar: ownerPic)];
      final out = backfillOwnerAvatar(
        members,
        ownerUserId: 'OWNER',
        ownerAvatar: '',
      );
      expect(identical(out, members), isTrue);
      expect(out.first.avatar, ownerPic);
    });

    test('ownerUserId 为空时不做任何事', () {
      final members = [m('OWNER')];
      final out = backfillOwnerAvatar(
        members,
        ownerUserId: '',
        ownerAvatar: ownerPic,
      );
      expect(identical(out, members), isTrue);
    });

    test('不会误改其他成员的头像', () {
      final members = [
        m('OWNER'),
        m('u1', avatar: 'http://x/u1.jpg'),
        m('u2'),
      ];
      final out = backfillOwnerAvatar(
        members,
        ownerUserId: 'OWNER',
        ownerAvatar: ownerPic,
      );
      expect(out[0].avatar, ownerPic);
      expect(out[1].avatar, 'http://x/u1.jpg');
      expect(out[2].avatar, isEmpty);
    });

    test('不可变源列表：输入不被改动（返回新列表）', () {
      final members = [m('OWNER'), m('u1')];
      final out = backfillOwnerAvatar(
        members,
        ownerUserId: 'OWNER',
        ownerAvatar: ownerPic,
      );
      expect(identical(out, members), isFalse);
      expect(members.first.avatar, isEmpty, reason: '原列表元素须保持不变');
    });
  });

  group('房主头像端到端时序（listener 接口不含房主）', () {
    // 注意：ensureSelfInMembers 内部是「先注入房主、再注入自己」，
    // 所以自己（SELF）总在 index 0，房主紧随其后（index 1）。
    test('时序A：详情先到 → 注入即带头像', () {
      final out = ensureSelfInMembers(
        [m('u1')],
        'SELF',
        ownerUserId: 'OWNER',
        ownerName: '尾鳍',
        ownerAvatar: ownerPic,
      );
      expect(out.map((e) => e.userId).toList(), ['SELF', 'OWNER', 'u1']);
      expect(out[1].avatar, ownerPic);
      expect(out[1].nickname, '尾鳍');
    });

    test('时序B：成员先到 → 靠 backfillOwnerAvatar 补齐', () {
      // 第一步：详情未返回，ensureSelfInMembers 注入房主但无头像
      final stage1 = ensureSelfInMembers(
        [m('u1')],
        'SELF',
        ownerUserId: 'OWNER',
        ownerName: '尾鳍',
      );
      expect(stage1[1].avatar, isEmpty);

      // 第二步：详情返回，就地回填
      final stage2 = backfillOwnerAvatar(
        stage1,
        ownerUserId: 'OWNER',
        ownerAvatar: ownerPic,
      );
      expect(stage2[1].avatar, ownerPic);
      expect(stage2.map((e) => e.userId).toList(), ['SELF', 'OWNER', 'u1'],
          reason: '回填不得改变成员集合与顺序');
    });
  });
}
