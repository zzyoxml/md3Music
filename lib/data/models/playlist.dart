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

  const Playlist({
    required this.id,
    required this.name,
    this.description,
    this.artworkUri,
    required this.songCount,
    this.creator,
    required this.songs,
    this.isLocal = false,
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
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Playlist && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
