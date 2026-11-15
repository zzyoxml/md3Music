import 'package:material_ui/material_ui.dart';

import '../../../data/models/song.dart';

/// 听众在房间内点播「其他歌曲」时的选择结果。
enum GuestPlayChoice {
  /// 脱离房间，本机单独播放这首歌。
  detachAndPlay,

  /// 不本地播放，改为向房主发起点歌请求。
  orderSong,

  /// 取消：房间与播放器现状都不变。
  dismissed,
}

/// 「脱离房间播放 / 申请点歌」确认窗。
///
/// 触发时机：听众在房间里从列表/单曲入口点播了**非房间正在播放**的歌曲
/// （判定见 `shouldPromptGuestPlay`）。返回用户选择；遮罩点击 / 返回键
/// （`showDialog` 返回 null）归一为 [GuestPlayChoice.dismissed]。
///
/// 文案刻意不说「这首歌不在房间歌单里」——歌曲可能确实在歌单里、只是当前
/// 不在播放，那种说法会与事实矛盾。统一表述为「不是房间正在播放的歌」。
///
/// [alreadyDetached] 为 true 时主按钮文案改为「直接播放」：用户已脱离房间，
/// 再写「脱离房间播放」会让人以为还要再操作一次。
Future<GuestPlayChoice> showGuestPlayConfirmDialog({
  required BuildContext context,
  required Song song,
  required String roomName,
  required bool alreadyDetached,
}) async {
  final songLabel = song.displayName.isEmpty ? '这首歌' : '「${song.displayName}」';
  final room = roomName.trim().isEmpty ? '一起听房间' : '「${roomName.trim()}」';
  final choice = await showDialog<GuestPlayChoice>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: const Text('一起听中'),
      content: Text(
        alreadyDetached
            ? '你正在 $room 里。$songLabel 不是房间正在播放的歌：'
                '可以在本机直接播放，也可以向房主申请点歌。'
            : '你正在 $room 里跟随房主播放。$songLabel 不是房间正在播放的歌：'
                '脱离后本机单独播放、不再跟随房主进度；也可以向房主申请点歌。',
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(dialogCtx).pop(GuestPlayChoice.dismissed),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogCtx).pop(GuestPlayChoice.orderSong),
          child: const Text('申请点歌'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(dialogCtx).pop(GuestPlayChoice.detachAndPlay),
          child: Text(alreadyDetached ? '直接播放' : '脱离房间播放'),
        ),
      ],
    ),
  );
  return choice ?? GuestPlayChoice.dismissed;
}
