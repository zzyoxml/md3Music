import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:m3e_core/m3e_core.dart';

import '../core/utils/app_toast.dart';
import '../data/models/song.dart';
import '../providers/player_provider.dart';
import '../services/kugou_api/kugou_api_client.dart';
import '../services/kugou_api/kugou_models.dart';
import 'song_list_item.dart';

/// 统一的 AI 推荐歌曲面板入口。
///
/// 长按全屏播放器底部操作条的小红心触发：以当前歌曲的
/// album_audio_id/MixSongID 调用 `/ai/recommend` 获取 AI 推荐歌曲，
/// 点击推荐项即可加入播放队列播放。
void showAiRecommendSheet(BuildContext context, Song song) {
  final albumAudioId = song.albumAudioId;
  if (albumAudioId == null || albumAudioId.isEmpty) {
    showToast('该歌曲缺少专辑 ID，无法获取 AI 推荐', long: true);
    return;
  }
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    // playContext：播放器页面（sheet 关闭后仍存活）的 context，
    // 用于点击推荐项后读取 PlayerProvider 触发播放
    builder: (_) => _AiRecommendSheet(song: song, playContext: context),
  );
}

class _AiRecommendSheet extends StatefulWidget {
  final Song song;
  final BuildContext playContext;
  const _AiRecommendSheet({required this.song, required this.playContext});

  @override
  State<_AiRecommendSheet> createState() => _AiRecommendSheetState();
}

class _AiRecommendSheetState extends State<_AiRecommendSheet> {
  bool _isLoading = true;
  String _error = '';
  List<KugouSongDetail> _songs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = '';
    });
    final api = KugouApiClient();
    final result = await api.getAiRecommend(widget.song.albumAudioId ?? '');
    if (!mounted) return;
    if (result == null) {
      setState(() {
        _isLoading = false;
        _error = '获取 AI 推荐失败';
      });
      return;
    }
    setState(() {
      _isLoading = false;
      _songs = result;
      if (result.isEmpty) _error = '暂无推荐歌曲';
    });
  }

  @override
  Widget build(BuildContext context) {
    final songs = _songs.map((e) => e.toSong()).toList();
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (innerCtx, scrollController) => Column(
        children: [
          // 顶部拖动指示条
          Container(
            width: 32,
            height: 4,
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            decoration: BoxDecoration(
              color: Theme.of(innerCtx).colorScheme.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // 标题栏：AI 推荐 + 当前歌曲名 + 关闭按钮
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI 推荐',
                        style: Theme.of(innerCtx).textTheme.titleMedium,
                      ),
                      Text(
                        widget.song.displayName,
                        style: Theme.of(innerCtx).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(innerCtx).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _isLoading
                ? const Center(child: M3ELoadingIndicator())
                : _error.isNotEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(_error),
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed: _load,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: songs.length,
                        itemBuilder: (context, index) {
                          final song = songs[index];
                          return SongListItem(
                            song: song,
                            onTap: () {
                              Navigator.of(innerCtx).pop();
                              // 使用播放器页面 context（sheet 关闭后仍有效）触发播放
                              widget.playContext
                                  .read<PlayerProvider>()
                                  .playOnlinePlaylist(songs, index);
                            },
                            onMoreTap: () {},
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
