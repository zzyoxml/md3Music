enum DownloadStatus { waiting, downloading, completed, failed }

class DownloadTask {
  final String songId;
  final String title;
  final String artist;
  final String? artworkUri;
  final String downloadUrl;
  final String? localPath;
  final DownloadStatus status;
  final double progress;
  final String? error;

  const DownloadTask({
    required this.songId,
    required this.title,
    required this.artist,
    this.artworkUri,
    required this.downloadUrl,
    this.localPath,
    this.status = DownloadStatus.waiting,
    this.progress = 0.0,
    this.error,
  });

  DownloadTask copyWith({
    String? localPath,
    DownloadStatus? status,
    double? progress,
    String? error,
  }) {
    return DownloadTask(
      songId: songId,
      title: title,
      artist: artist,
      artworkUri: artworkUri,
      downloadUrl: downloadUrl,
      localPath: localPath ?? this.localPath,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      error: error ?? this.error,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'songId': songId,
      'title': title,
      'artist': artist,
      'artworkUri': artworkUri,
      'downloadUrl': downloadUrl,
      'localPath': localPath,
      'status': status.index,
      'progress': progress,
      'error': error,
    };
  }

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    return DownloadTask(
      songId: json['songId'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String,
      artworkUri: json['artworkUri'] as String?,
      downloadUrl: json['downloadUrl'] as String,
      localPath: json['localPath'] as String?,
      status: DownloadStatus.values[json['status'] as int],
      progress: (json['progress'] as num).toDouble(),
      error: json['error'] as String?,
    );
  }
}
