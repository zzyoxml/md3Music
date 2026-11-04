import 'package:flutter/widgets.dart';

import '../../data/models/album.dart';
import '../../data/models/song.dart';
import '../../modules/album/album_detail_page.dart';
import '../../modules/artist/artist_detail_page.dart';
import '../layout/adaptive_navigator.dart';
import 'app_toast.dart';

/// 从歌曲对象进入专辑详情。
///
/// 刷歌推荐行、封面流信息条这类只有歌曲、拿不到专辑对象的入口共用。`albumId`
/// 缺失时给明确提示而不是静默 return——"点了没反应"最难排查。导航统一走
/// [AdaptiveNav.openDetail]，与发现页新碟入口同口径，手机单栏 / 宽屏双栏 / TV
/// 表现一致。
void openSongAlbum(BuildContext context, Song song) {
  final albumId = song.albumId;
  if (albumId == null || albumId.isEmpty) {
    showToast('暂无专辑信息', long: true);
    return;
  }
  AdaptiveNav.openDetail(
    context,
    (_) => AlbumDetailPage(
      album: Album(
        id: albumId,
        name: song.album,
        artist: song.artist,
        artworkUri: song.artworkUri,
        // 详情页会拉接口拿到真实曲目数；这里只影响加载前的兜底展示。
        songCount: 0,
      ),
    ),
  );
}

/// 从歌曲对象进入歌手详情。
///
/// `artistId` 缺失时提示后返回（不做按名字搜索兜底：搜索是异步且可能同名误配，
/// 这里保持一次点击的确定性反馈）。
void openSongArtist(BuildContext context, Song song) {
  final artistId = song.artistId;
  if (artistId == null || artistId.isEmpty) {
    showToast('暂无歌手信息', long: true);
    return;
  }
  AdaptiveNav.openDetail(
    context,
    (_) => ArtistDetailPage(
      artistId: artistId,
      artistName: song.artist,
    ),
  );
}
