import 'song.dart';

class Playlist {
  final String id;
  final String name;
  final String? description;
  final String? artworkUri;
  final int songCount;
  final String? creator;
  final List<Song> songs;
  final bool isLocal;
  final String? listCreateUserid;
  final String? listCreateListid;
  final String? listCreateGid;
  /// 用户订阅/收藏后的版本 listid（用于拉取歌曲列表）。
  /// 收藏别人歌单时，listCreateListid 是原作者的 listid（无权拉取），
  /// 而本字段是用户自己订阅后分配的 listid（可正常拉取歌曲）。
  final String? subscribedListId;
  /// 歌单总版本号（`/user/playlist` 的 `total_ver`）：写接口的乐观锁，缺省 0。
  final int totalVer;
  /// 是否隐私歌单（`/user/playlist` 的 `is_pri`）。
  /// 编辑保存时随 v4 modify_list 回传，避免擅自把隐私歌单改成公开。
  final bool isPri;
  /// 歌单在「我的歌单」列表里的排序位（`/user/playlist` 的 `sort`）。
  /// 编辑保存时原样回传，避免 sort=0 把歌单挪到列表顶部。
  final int sort;

  const Playlist({
    required this.id,
    required this.name,
    this.description,
    this.artworkUri,
    required this.songCount,
    this.creator,
    required this.songs,
    this.isLocal = false,
    this.listCreateUserid,
    this.listCreateListid,
    this.listCreateGid,
    this.subscribedListId,
    this.totalVer = 0,
    this.isPri = false,
    this.sort = 0,
  });

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      artworkUri: json['artworkUri'] as String?,
      songCount: (json['songCount'] as num).toInt(),
      creator: json['creator'] as String?,
      songs: (json['songs'] as List<dynamic>)
          .map((e) => Song.fromJson(e as Map<String, dynamic>))
          .toList(),
      isLocal: (json['isLocal'] as bool?) ?? false,
      listCreateGid: json['listCreateGid'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'artworkUri': artworkUri,
      'songCount': songCount,
      'creator': creator,
      'songs': songs.map((e) => e.toJson()).toList(),
      'isLocal': isLocal,
      'listCreateGid': listCreateGid,
      'subscribedListId': subscribedListId,
      'totalVer': totalVer,
      'isPri': isPri,
      'sort': sort,
    };
  }

  Playlist copyWith({
    String? id,
    String? name,
    String? description,
    String? artworkUri,
    int? songCount,
    String? creator,
    List<Song>? songs,
    bool? isLocal,
    String? listCreateUserid,
    String? listCreateListid,
    String? listCreateGid,
    String? subscribedListId,
    int? totalVer,
    bool? isPri,
    int? sort,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      artworkUri: artworkUri ?? this.artworkUri,
      songCount: songCount ?? this.songCount,
      creator: creator ?? this.creator,
      songs: songs ?? this.songs,
      isLocal: isLocal ?? this.isLocal,
      listCreateUserid: listCreateUserid ?? this.listCreateUserid,
      listCreateListid: listCreateListid ?? this.listCreateListid,
      listCreateGid: listCreateGid ?? this.listCreateGid,
      subscribedListId: subscribedListId ?? this.subscribedListId,
      totalVer: totalVer ?? this.totalVer,
      isPri: isPri ?? this.isPri,
      sort: sort ?? this.sort,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Playlist && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
