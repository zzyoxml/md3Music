class KugouEndpoints {
  KugouEndpoints._();

  static String baseUrl = 'http://localhost:8080';

  static const String registerDev = '/register/dev';
  static const String search = '/search';
  static const String songUrl = '/song/url';
  static const String lyric = '/lyric';
  static const String playlistDetail = '/playlist/detail';
  static const String rankList = '/rank/list';
  static const String recommendDaily = '/everyday/recommend';
  static const String songDetail = '/audio';
  static const String comment = '/comment/music';
  static const String artistDetail = '/artist/detail';
  static const String artistAlbums = '/artist/albums';
  static const String artistAudios = '/artist/audios';
  static const String albumDetail = '/album/detail';
  static const String albumSongs = '/album/songs';
  static const String hotSearch = '/search/hot';
  static const String searchSuggest = '/search/suggest';
  static const String playlist = '/top/playlist';
  static const String playlistInfo = '/playlist/detail';
  static const String playlistSongs = '/playlist/track/all';
  static const String personalFm = '/personal/fm';
  static const String searchComplex = '/search/complex';
  static const String rankInfo = '/rank/info';
  static const String rankTop = '/rank/top';
  static const String singerList = '/singer/list';
  static const String songClimax = '/song/climax';
  static const String songRanking = '/song/ranking';
  static const String sheetExplore = '/sheet/explore';
  static const String sheetDetail = '/sheet/detail';
  static const String sheetSong = '/sheet/song';
  static const String topSong = '/top/song';
  static const String recommendSongs = '/recommend/songs';
  static const String searchDefault = '/search/default';

  static String get fullSearch => '$baseUrl$search';
  static String get fullSongUrl => '$baseUrl$songUrl';
  static String get fullLyric => '$baseUrl$lyric';
  static String get fullPlaylistDetail => '$baseUrl$playlistDetail';
  static String get fullRankList => '$baseUrl$rankList';
  static String get fullRecommendDaily => '$baseUrl$recommendDaily';
  static String get fullSongDetail => '$baseUrl$songDetail';
  static String get fullComment => '$baseUrl$comment';
  static String get fullArtistDetail => '$baseUrl$artistDetail';
  static String get fullArtistAlbums => '$baseUrl$artistAlbums';
  static String get fullArtistAudios => '$baseUrl$artistAudios';
  static String get fullAlbumDetail => '$baseUrl$albumDetail';
  static String get fullAlbumSongs => '$baseUrl$albumSongs';
  static String get fullHotSearch => '$baseUrl$hotSearch';
  static String get fullSearchSuggest => '$baseUrl$searchSuggest';
  static String get fullPlaylist => '$baseUrl$playlist';
  static String get fullPlaylistInfo => '$baseUrl$playlistInfo';
  static String get fullPlaylistSongs => '$baseUrl$playlistSongs';
  static String get fullPersonalFm => '$baseUrl$personalFm';
  static String get fullSearchComplex => '$baseUrl$searchComplex';
  static String get fullRankInfo => '$baseUrl$rankInfo';
  static String get fullRankTop => '$baseUrl$rankTop';
  static String get fullSingerList => '$baseUrl$singerList';
  static String get fullSongClimax => '$baseUrl$songClimax';
  static String get fullSongRanking => '$baseUrl$songRanking';
  static String get fullSheetExplore => '$baseUrl$sheetExplore';
  static String get fullSheetDetail => '$baseUrl$sheetDetail';
  static String get fullSheetSong => '$baseUrl$sheetSong';
  static String get fullTopSong => '$baseUrl$topSong';
  static String get fullRecommendSongs => '$baseUrl$recommendSongs';
  static String get fullSearchDefault => '$baseUrl$searchDefault';
}

class KugouQuality {
  KugouQuality._();

  static const String hires = 'hires';
  static const String sq = 'sq';
  static const String flac = 'flac';
  static const String hq320 = '320';
  static const String standard = '128';
}
