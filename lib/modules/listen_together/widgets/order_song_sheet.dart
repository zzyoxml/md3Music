import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/app_toast.dart';
import '../../../providers/listen_together_provider.dart';
import '../../../providers/player_provider.dart';
import '../../../services/kugou_api/listen_together_models.dart';
import '../../../widgets/playing_spectrum_indicator.dart';
import 'room_cover_image.dart';
import 'song_picker_sheet.dart';

/// 托盘最大高度占屏比例（与 [DraggableScrollableSheet.maxChildSize] 同源，
/// 点歌请求区的高度上限据此推算，避免两处各写一个数字而失配）。
const double _kSheetMaxChildSize = 0.95;

/// 房间歌单与点歌托盘。
///
/// 房主：可切歌、处理成员点歌请求（通过 / 忽略）。
/// 成员：可对歌单中的歌曲发起点歌。当前播放中的歌曲带「播放中」标识。
class OrderSongSheet extends StatelessWidget {
  const OrderSongSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final session = context.watch<ListenTogetherProvider>().session;
    final songs = session?.playlist ?? const [];
    final orders = session?.songOrders ?? const [];
    final isOwner = session?.isOwner ?? false;
    final loadingRoom = session?.loadingRoom ?? false;
    final player = context.watch<PlayerProvider>();
    // 正在播放的歌曲身份：优先房间远端快照（hash/歌曲 id/mixsongid 任一键
    // 命中即算），回退本地播放器当前歌。用于歌单行的当前歌曲标识。
    final remote = session?.remoteState;
    final currentSong = session?.player.currentSong;
    bool isPlayingSong(RoomSong song) {
      if (currentSong != null && song.sameAs(RoomSong.fromSong(currentSong))) {
        return true;
      }
      return remote != null && remote.hash.isNotEmpty && song.matchesRemote(remote);
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      maxChildSize: _kSheetMaxChildSize,
      minChildSize: 0.4,
      builder: (context, scrollController) => Center(
        // 横屏/平板下限宽居中，避免弹层被拉满整个屏幕宽度
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: cs.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: Text('房间歌单（${songs.length}）',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                TextButton.icon(
                  onPressed: () => showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => const SongPickerSheet(),
                  ),
                  icon: const Icon(Icons.add),
                  label: Text(isOwner ? '添加歌曲' : '点歌'),
                ),
                IconButton(
                  tooltip: '刷新歌单',
                  onPressed: () async {
                    try {
                      await session?.refreshSongs();
                    } catch (_) {
                      showToast('刷新失败，请稍后重试');
                    }
                  },
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          // 房主视角：待处理的点歌请求。
          //
          // 高度**按内容自适应、不参与 flex 分配**：此前用 `Flexible(flex: 1)`，
          // 与下方歌单的 `Expanded(flex: 1)` 各分剩余空间的一半——请求区实际只占
          // 内容高（1 行 ~72dp），歌单却被压成半个托盘、底部留出空洞，末行裁在
          // 视口边缘（用户截图现象）。改成非 flex 子项（非弹性子项的主轴约束无界，
          // shrinkWrap 列表按内容取高）+ 上限兜底，歌单的 Expanded 才能拿到全部剩余。
          if (isOwner && orders.isNotEmpty)
            ConstrainedBox(
              // 上限 = 托盘最大高度的 1/3（与 maxChildSize 同源），超出则本区内部滚动
              constraints: BoxConstraints(
                maxHeight:
                    MediaQuery.sizeOf(context).height * _kSheetMaxChildSize / 3,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: orders.length,
                itemBuilder: (context, index) {
                  final order = orders[index];
                  return ListTile(
                    dense: true,
                    // 封面统一走 RoomCoverImage：磁盘缓存 + 圆角与音符占位由组件承担
                    // （尺寸/圆角对齐 EchoMusic 点播列表 Cover 46×46 / r10）。
                    // song_info 不带封面，由房间会话的富化链路补（见
                    // RoomSession._patchSongOrdersMetadata）。
                    leading: SizedBox(
                      width: 46,
                      height: 46,
                      child: RoomCoverImage(
                        url: order.song.coverUrl,
                        iconSize: 20,
                        customRadius: BorderRadius.circular(10),
                      ),
                    ),
                    title: Text(
                      order.song.displayName.isEmpty
                          ? '未知歌曲'
                          : order.song.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    // 请求人 + 歌手（对齐 EchoMusic「{requestor} 的点歌 · {artist}」）
                    subtitle: Text(
                      order.song.singer.isEmpty
                          ? '${order.orderNickname} 发起点歌'
                          : '${order.orderNickname} 发起点歌 · ${order.song.singer}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () async {
                            try {
                              await session?.ownerAddSongs(
                                [order.song],
                                orderUserId: order.orderUserId,
                              );
                            } catch (_) {
                              showToast('加入歌单失败，请稍后重试');
                            }
                          },
                          child: const Text('通过'),
                        ),
                        TextButton(
                          onPressed: () async {
                            try {
                              await session?.ownerRemoveOrder(order);
                            } catch (_) {
                              showToast('忽略失败，请稍后重试');
                            }
                          },
                          child: const Text('忽略'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          if (isOwner && orders.isNotEmpty)
            Divider(height: 1, color: cs.outlineVariant),
          Expanded(
            child: songs.isEmpty
                ? Center(
                    // 增量加载期间歌单可能尚未返回：入房加载中显示获取中文案
                    child: Text(loadingRoom ? '正在获取房间歌单…' : '歌单为空'))
                : ListView.builder(
                    controller: scrollController,
                    // 底部安全区：托盘最大高度贴屏幕底，缺 inset 时最后一行会落在
                    // 系统导航条下方，滚到底也看不全（本文件此前是一起听里唯一
                    // 没做 inset 的托盘，其余 create/join/chat/preview 都是 SafeArea）
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.paddingOf(context).bottom,
                    ),
                    itemCount: songs.length,
                    itemBuilder: (context, index) {
                      final song = songs[index];
                      // 当前歌曲：标题加粗 + 行尾三柱波形（与播放器播放列表同款）
                      final playing = isPlayingSong(song);
                      return ListTile(
                        // 封面统一走 RoomCoverImage：磁盘缓存 + 圆角与音符占位由组件承担
                        leading: SizedBox(
                          width: 48,
                          height: 48,
                          child: RoomCoverImage(
                            url: song.coverUrl,
                            iconSize: 20,
                          ),
                        ),
                        title: Text(
                          song.displayName.isEmpty ? '未知歌曲' : song.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: playing ? FontWeight.bold : null,
                          ),
                        ),
                        subtitle: Text(
                          song.singer,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        // 行尾：当前歌曲给三柱波形，其余给切歌/点歌入口。
                        // 波形套与 TextButton 完全同尺寸（64×40）的盒子居中，
                        // 柱子落在与按钮文字相同的位置，横竖两个方向都对齐
                        trailing: playing
                            ? SizedBox(
                                width: 64,
                                height: 40,
                                child: Center(
                                  child: PlayingSpectrumIndicator(
                                    color: cs.primary,
                                    size: 18,
                                    isPlaying: player.isPlaying,
                                  ),
                                ),
                              )
                            : isOwner
                                ? TextButton(
                                    onPressed: () {
                                      session?.ownerSwitchSong(song);
                                      Navigator.pop(context);
                                    },
                                    child: const Text('切歌'),
                                  )
                                : TextButton(
                                    onPressed: () async {
                                      try {
                                        await session?.orderSong(song);
                                      } catch (_) {
                                        showToast('点歌失败，请稍后重试');
                                      }
                                    },
                                    child: const Text('点歌'),
                                  ),
                      );
                    },
                  ),
          ),
        ],
          ),
        ),
      ),
    );
  }
}
