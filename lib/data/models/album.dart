class Album {
  final String id;
  final String name;
  final String artist;
  final String? artworkUri;
  final int songCount;
  final int? year;

  const Album({
    required this.id,
    required this.name,
    required this.artist,
    this.artworkUri,
    required this.songCount,
    this.year,
  });

  factory Album.fromJson(Map<String, dynamic> json) {
    return Album(
      id: json['id'] as String,
      name: json['name'] as String,
      artist: json['artist'] as String,
      artworkUri: json['artworkUri'] as String?,
      songCount: (json['songCount'] as num).toInt(),
      year: json['year'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'artist': artist,
      'artworkUri': artworkUri,
      'songCount': songCount,
      'year': year,
    };
  }

  Album copyWith({
    String? id,
    String? name,
    String? artist,
    String? artworkUri,
    int? songCount,
    int? year,
  }) {
    return Album(
      id: id ?? this.id,
      name: name ?? this.name,
      artist: artist ?? this.artist,
      artworkUri: artworkUri ?? this.artworkUri,
      songCount: songCount ?? this.songCount,
      year: year ?? this.year,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Album && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
