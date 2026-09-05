import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/kugou_provider.dart';
import '../../services/kugou_api/kugou_models.dart';
import '../../widgets/smart_artwork_image.dart';
import 'audiobook_album_detail_page.dart';

/// 听书搜索页：顶部搜索框 + 听书专辑结果列表。
class AudiobookSearchPage extends StatefulWidget {
  const AudiobookSearchPage({super.key});

  @override
  State<AudiobookSearchPage> createState() => _AudiobookSearchPageState();
}

class _AudiobookSearchPageState extends State<AudiobookSearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  List<KugouLongAudioAlbum> _results = const [];
  bool _loading = false;
  bool _searched = false;
  String _lastKeyword = '';

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _searched = true;
      _lastKeyword = kw;
    });
    final kugou = context.read<KugouProvider>();
    final result = await kugou.searchLongAudio(kw);
    if (!mounted) return;
    setState(() {
      _results = result;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (!_searched) {
      body = _EmptyHint(
        icon: Icons.search,
        hint: '搜索演播者、书名或作者',
      );
    } else if (_results.isEmpty) {
      body = _EmptyHint(
        icon: Icons.now_wallpaper_outlined,
        hint: '未找到“$_lastKeyword”相关的听书',
      );
    } else {
      body = ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _results.length,
        itemBuilder: (context, i) {
          final album = _results[i];
          return _AlbumResultTile(
            album: album,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AudiobookAlbumDetailPage(album: album),
                ),
              );
            },
          );
        },
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
          decoration: InputDecoration(
            hintText: '搜索听书',
            hintStyle: tt.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
            border: InputBorder.none,
            isDense: true,
          ),
          style: tt.bodyLarge?.copyWith(color: cs.onSurface),
        ),
        actions: [
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder: (context, value, _) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return IconButton(
                tooltip: '清空',
                icon: const Icon(Icons.close),
                onPressed: () {
                  _controller.clear();
                  setState(() {
                    _results = const [];
                    _searched = false;
                  });
                },
              );
            },
          ),
        ],
      ),
      body: SafeArea(child: body),
    );
  }
}

/// 听书专辑结果条目：横向封面 + 名称 / 演播者 / 集数。
class _AlbumResultTile extends StatelessWidget {
  final KugouLongAudioAlbum album;
  final VoidCallback onTap;

  const _AlbumResultTile({required this.album, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      onTap: onTap,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 64,
          height: 64,
          child: SmartArtworkImage(
            artworkUri: album.coverUrl,
            size: double.infinity,
          ),
        ),
      ),
      title: Text(
        album.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: tt.bodyMedium?.copyWith(
          color: cs.onSurface,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          album.audioCount > 0 ? '${album.author ?? ''} · 共 ${album.audioCount} 集' : (album.author ?? ''),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final IconData icon;
  final String hint;

  const _EmptyHint({required this.icon, required this.hint});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}