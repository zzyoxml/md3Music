import 'package:dpad/dpad.dart';
import 'package:m3e_core/m3e_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/remote/tv_scroll_region.dart';
import '../../core/utils/app_haptics.dart';
import '../../core/utils/app_text_context_menu.dart';
import '../../core/utils/app_toast.dart';
import '../../data/models/song.dart';
import '../../providers/player_provider.dart';
import '../../providers/song_match_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/smart_artwork_image.dart';

/// 本地歌曲「匹配在线信息」弹层。
///
/// 展示当前匹配（可更换/取消）+ 关键词搜索候选列表，点选候选即记忆为
/// 手动匹配（覆盖自动结果）。匹配生效后：无内嵌封面时用在线封面兜底、
/// 歌词走在线精确检索、评论区按在线歌曲拉取。
Future<void> showSongMatchSheet(BuildContext context, Song song) async {
  await showM3EModalBottomSheet(
    context: context,
    // 与 SongListItem 更多菜单同一口径：实色背景，避免透出封面/壁纸难辨认
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
    builder: (ctx) => _SongMatchSheet(song: song),
  );
}

class _SongMatchSheet extends StatefulWidget {
  final Song song;

  const _SongMatchSheet({required this.song});

  @override
  State<_SongMatchSheet> createState() => _SongMatchSheetState();
}

class _SongMatchSheetState extends State<_SongMatchSheet> {
  late final TextEditingController _keywordCtrl;
  List<KugouSongDetail> _results = [];
  bool _searching = false;
  bool _searched = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _keywordCtrl =
        TextEditingController(text: SongMatchProvider.buildSearchKeyword(widget.song));
    // 输入时刷新清空按钮的显隐
    _keywordCtrl.addListener(() {
      if (mounted) setState(() {});
    });
    _search();
  }

  @override
  void dispose() {
    _keywordCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final keyword = _keywordCtrl.text.trim();
    if (keyword.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final candidates =
          await context.read<SongMatchProvider>().searchCandidates(keyword);
      if (!mounted) return;
      setState(() {
        _results = _rank(candidates);
        _searching = false;
        _searched = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searched = true;
        _error = '搜索失败，请检查网络后重试';
      });
    }
  }

  /// 候选排序：标题相似度为主，歌手匹配与时长接近度加权。
  List<KugouSongDetail> _rank(List<KugouSongDetail> candidates) {
    final normTitle =
        SongMatchProvider.normalizeForMatch(widget.song.displayName);
    final artistUnknown = isUnknownArtist(widget.song.artist);
    final normArtist =
        artistUnknown ? '' : SongMatchProvider.normalizeForMatch(widget.song.artist);
    final localDurMs = widget.song.duration.inMilliseconds;
    double score(KugouSongDetail c) {
      final titleSim = SongMatchProvider.bigramSimilarity(
        normTitle,
        SongMatchProvider.normalizeForMatch(c.songName),
      );
      final cArtist = SongMatchProvider.normalizeForMatch(c.artistName ?? '');
      final artistSim = artistUnknown
          ? 0.5
          : (cArtist.isEmpty
              ? 0.4
              : (cArtist == normArtist ||
                      cArtist.contains(normArtist) ||
                      normArtist.contains(cArtist))
                  ? 1.0
                  : 0.0);
      final cDurMs = c.duration > 0 ? c.duration * 1000 : 0;
      final durSim = (cDurMs == 0 || localDurMs == 0)
          ? 0.0
          : 1 - ((cDurMs - localDurMs).abs() / 5000.0).clamp(0.0, 1.0);
      return titleSim * 0.6 + artistSim * 0.25 + durSim * 0.15;
    }

    final sorted = [...candidates]..sort((a, b) => score(b).compareTo(score(a)));
    return sorted;
  }

  Future<void> _confirmMatch(BuildContext ctx, KugouSongDetail candidate) async {
    AppHaptics.lightImpact(HapticCategory.control);
    await ctx.read<SongMatchProvider>().setManualMatch(widget.song, candidate);
    if (!ctx.mounted) return;
    Navigator.of(ctx).pop();
    showToast('已匹配：${candidate.songName}');
  }

  void _preview(BuildContext ctx, KugouSongDetail candidate) {
    AppHaptics.lightImpact(HapticCategory.control);
    ctx.read<PlayerProvider>().playOnlinePlaylist([candidate.toSong()], 0);
  }

  Future<void> _dismissMatch(BuildContext ctx) async {
    AppHaptics.lightImpact(HapticCategory.control);
    await ctx.read<SongMatchProvider>().dismissMatch(widget.song);
    showToast('已取消匹配');
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        // 键盘弹出时抬升内容，避免输入框被遮挡
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题行：本地歌曲名 + 关闭
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '匹配在线信息',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${widget.song.displayName} · ${widget.song.artist}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: colorScheme.outlineVariant),
              _buildCurrentMatch(context),
              _buildSearchBar(context),
              Divider(height: 1, color: colorScheme.outlineVariant),
              Flexible(child: _buildResults(context)),
            ],
          ),
        ),
      ),
    );
  }

  /// 当前匹配状态卡：已匹配时显示在线封面/歌名/歌手 + 取消入口 +
  /// 两个**单曲**偏好开关（使用在线歌词/封面，只影响这首歌）。
  Widget _buildCurrentMatch(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Consumer<SongMatchProvider>(
      builder: (ctx, match, _) {
        final info = match.matchedInfo(widget.song.id);
        if (info == null || !info.isMatched) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    SmartArtworkImage(
                      artworkUri: info.artworkUri,
                      size: 44,
                      borderRadius: 8,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            info.title ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(ctx).textTheme.bodyMedium,
                          ),
                          Text(
                            '已匹配 · ${info.artist ?? ''}',
                            style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () => _dismissMatch(ctx),
                      child: const Text('取消匹配'),
                    ),
                  ],
                ),
              ),
              // 单曲偏好：写进这首歌自己的匹配记录，不全局生效
              SwitchListTile(
                dense: true,
                title: const Text('使用在线歌词（覆盖内嵌）'),
                value: info.preferOnlineLyrics,
                onChanged: (value) {
                  AppHaptics.lightImpact(HapticCategory.control);
                  match.setUseOnlineLyrics(widget.song, value);
                },
              ),
              SwitchListTile(
                dense: true,
                title: const Text('使用在线封面（覆盖内嵌）'),
                value: info.preferOnlineCover,
                onChanged: (value) {
                  AppHaptics.lightImpact(HapticCategory.control);
                  match.setUseOnlineCover(widget.song, value);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// 搜索行：关键词输入框保持裸置（TV 上箭头移光标、边缘移出）。
  Widget _buildSearchBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _keywordCtrl,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              // 守卫测试要求所有 TextField 接统一长按菜单（空框常显「粘贴」）
              contextMenuBuilder: buildAppTextContextMenu,
              decoration: InputDecoration(
                hintText: '搜索在线歌曲（歌名 歌手）',
                isDense: true,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _keywordCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: '清空',
                        onPressed: () {
                          _keywordCtrl.clear();
                          setState(() {});
                        },
                      ),
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.arrow_forward, color: colorScheme.primary),
            tooltip: '搜索',
            onPressed: _searching ? null : _search,
          ),
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    Widget body;
    if (_searching) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (_error != null) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            TextButton(onPressed: _search, child: const Text('重试')),
          ],
        ),
      );
    } else if (_results.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
        child: Text(
          _searched ? '未找到候选，试试只搜歌名' : '输入关键词搜索在线歌曲',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
      );
    } else {
      // tv: 候选列表为新增纵向滚动区，包 TvScrollRegion（memoryKey + 纵 wrap）
      body = TvScrollRegion(
        memoryKey: 'song-match-candidates',
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _results.length,
          itemBuilder: (ctx, index) =>
              _buildCandidateRow(ctx, _results[index]),
        ),
      );
    }
    return body;
  }

  Widget _buildCandidateRow(BuildContext ctx, KugouSongDetail candidate) {
    final colorScheme = Theme.of(ctx).colorScheme;
    final subtitle = [
      if ((candidate.artistName ?? '').isNotEmpty) candidate.artistName!,
      if ((candidate.albumName ?? '').isNotEmpty) candidate.albumName!,
    ].join(' · ');
    Widget row = ListTile(
      leading: SmartArtworkImage(
        artworkUri: candidate.artworkUri,
        size: 48,
        borderRadius: 8,
      ),
      title: Text(
        candidate.songName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (candidate.duration > 0)
            Text(
              _formatDuration(candidate.duration),
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          IconButton(
            icon: const Icon(Icons.play_circle_outline),
            tooltip: '试听',
            onPressed: () => _preview(ctx, candidate),
          ),
        ],
      ),
      onTap: () => _confirmMatch(ctx, candidate),
    );
    // tv: 单停点接遥控焦点线（OK=确认匹配，长按=试听）
    if (kTvBuild) {
      row = DpadFocusable(
        onSelect: () => _confirmMatch(ctx, candidate),
        onLongSelect: () => _preview(ctx, candidate),
        child: row,
      );
    }
    return row;
  }

  String _formatDuration(int seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$secs';
  }
}
