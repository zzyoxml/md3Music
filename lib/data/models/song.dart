class Song {
  final String id;
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final String? url;
  final String? localPath;
  final String? artworkUri;
  final bool isOnline;
  final String? albumId;
  final String? artistId;
  final String? quality;
  final String? albumAudioId;
  final int? fileId;

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    this.url,
    this.localPath,
    this.artworkUri,
    this.isOnline = false,
    this.albumId,
    this.artistId,
    this.quality,
    this.albumAudioId,
    this.fileId,
  });

  String get displayDuration {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      id: json['id'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String,
      album: json['album'] as String,
      duration: Duration(milliseconds: (json['duration'] as num).toInt()),
      url: json['url'] as String?,
      localPath: json['localPath'] as String?,
      artworkUri: json['artworkUri'] as String?,
      isOnline: (json['isOnline'] as bool?) ?? false,
      albumId: json['albumId'] as String?,
      artistId: json['artistId'] as String?,
      quality: json['quality'] as String?,
      albumAudioId: json['albumAudioId'] as String?,
      fileId: json['fileId'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'duration': duration.inMilliseconds,
      'url': url,
      'localPath': localPath,
      'artworkUri': artworkUri,
      'isOnline': isOnline,
      'albumId': albumId,
      'artistId': artistId,
      'quality': quality,
      'albumAudioId': albumAudioId,
      'fileId': fileId,
    };
  }

  Song copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    String? url,
    String? localPath,
    String? artworkUri,
    bool? isOnline,
    String? albumId,
    String? artistId,
    String? quality,
    String? albumAudioId,
    int? fileId,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      url: url ?? this.url,
      localPath: localPath ?? this.localPath,
      artworkUri: artworkUri ?? this.artworkUri,
      isOnline: isOnline ?? this.isOnline,
      albumId: albumId ?? this.albumId,
      artistId: artistId ?? this.artistId,
      quality: quality ?? this.quality,
      albumAudioId: albumAudioId ?? this.albumAudioId,
      fileId: fileId ?? this.fileId,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Song && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
