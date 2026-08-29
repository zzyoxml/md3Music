class Artist {
  final String id;
  final String name;
  final String? artworkUri;
  final int songCount;
  final int albumCount;

  const Artist({
    required this.id,
    required this.name,
    this.artworkUri,
    required this.songCount,
    required this.albumCount,
  });

  factory Artist.fromJson(Map<String, dynamic> json) {
    return Artist(
      id: json['id'] as String,
      name: json['name'] as String,
      artworkUri: json['artworkUri'] as String?,
      songCount: (json['songCount'] as num).toInt(),
      albumCount: (json['albumCount'] as num).toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'artworkUri': artworkUri,
      'songCount': songCount,
      'albumCount': albumCount,
    };
  }

  Artist copyWith({
    String? id,
    String? name,
    String? artworkUri,
    int? songCount,
    int? albumCount,
  }) {
    return Artist(
      id: id ?? this.id,
      name: name ?? this.name,
      artworkUri: artworkUri ?? this.artworkUri,
      songCount: songCount ?? this.songCount,
      albumCount: albumCount ?? this.albumCount,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Artist && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
