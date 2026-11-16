import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';

void main() {
  test('本地 SAF 歌词随歌曲缓存往返保存', () {
    const song = Song(
      id: 'local_usb-track',
      title: 'USB Track',
      artist: 'Artist',
      album: 'Album',
      duration: Duration(minutes: 3),
      localPath: 'content://provider/document/123',
      artworkUri: 'file:///app/cache/local_music_artwork/123.img',
      localLyrics: '[00:01.00]line',
    );

    final restored = Song.fromJson(song.toJson());

    expect(restored.localLyrics, '[00:01.00]line');
    expect(restored.artworkUri, song.artworkUri);
    expect(restored.localPath, song.localPath);
  });
}
