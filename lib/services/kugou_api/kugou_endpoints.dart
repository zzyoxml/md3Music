class KugouEndpoints {
  KugouEndpoints._();

  /// 默认 API 服务地址。
  /// 启动时 KugouProvider 会从 SharedPreferences 读取用户配置的地址覆盖此值。
  static String baseUrl = 'http://115.29.236.96:3000';

  // Device
  static const String registerDev = '/register/dev';
  static const String serverNow = '/server/now';

  // Search
  static const String search = '/search';
  static const String searchComplex = '/search/complex';
  static const String searchDefault = '/search/default';
  static const String searchHot = '/search/hot';
  static const String searchSuggest = '/search/suggest';
  static const String searchLyric = '/search/lyric';
  static const String searchMixed = '/search/mixed';

  // Song
  static const String songUrl = '/song/url';
  static const String songUrlNew = '/song/url/new';
  static const String songDetail = '/audio';
  static const String songClimax = '/song/climax';
  static const String songRanking = '/song/ranking';
  static const String songRankingFilter = '/song/ranking/filter';
  static const String krmAudio = '/krm/audio';
  static const String kmrAudioMv = '/kmr/audio/mv';
  static const String audioRelated = '/audio/related';
  static const String audioAccompany = '/audio/accompany/matching';
  static const String audioKtvTotal = '/audio/ktv/total';
  static const String favoriteCount = '/favorite/count';
  static const String recommendSongs = '/recommend/songs';

  // Lyric
  static const String lyric = '/lyric';

  // Comment
  static const String commentMusic = '/comment/music';
  static const String commentMusicClassify = '/comment/music/classify';
  static const String commentMusicHotword = '/comment/music/hotword';
  static const String commentFloor = '/comment/floor';
  static const String commentPlaylist = '/comment/playlist';
  static const String commentAlbum = '/comment/album';
  static const String commentCount = '/comment/count';

  // Playlist
  static const String playlistDetail = '/playlist/detail';
  static const String playlistTrackAll = '/playlist/track/all';
  static const String playlistTrackAllNew = '/playlist/track/all/new';
  static const String playlistSimilar = '/playlist/similar';
  static const String playlistEffect = '/playlist/effect';
  static const String playlistTags = '/playlist/tags';
  static const String playlistAdd = '/playlist/add';
  static const String playlistDel = '/playlist/del';
  static const String playlistTracksAdd = '/playlist/tracks/add';
  static const String playlistTracksDel = '/playlist/tracks/del';

  // Sheet
  static const String sheetCollection = '/sheet/collection';
  static const String sheetDetail = '/sheet/detail';
  static const String sheetExplore = '/sheet/explore';
  static const String sheetRank = '/sheet/rank';
  static const String sheetSong = '/sheet/song';
  static const String sheetTags = '/sheet/tags';

  // Theme
  static const String themeMusic = '/theme/music';
  static const String themeMusicDetail = '/theme/music/detail';
  static const String themePlaylist = '/theme/playlist';
  static const String themePlaylistTrack = '/theme/playlist/track';

  // Rank
  static const String rankList = '/rank/list';
  static const String rankTop = '/rank/top';
  static const String rankVol = '/rank/vol';
  static const String rankInfo = '/rank/info';
  static const String rankAudio = '/rank/audio';

  // Everyday
  static const String everydayRecommend = '/everyday/recommend';
  static const String everydayHistory = '/everyday/history';
  static const String everydayStyleRecommend = '/everyday/style/recommend';
  static const String everydayFriend = '/everyday/friend';

  // Top
  static const String topAlbum = '/top/album';
  static const String topSong = '/top/song';
  static const String topPlaylist = '/top/playlist';
  static const String topCard = '/top/card';
  static const String topCardYouth = '/top/card/youth';
  static const String topIp = '/top/ip';

  // Yueku
  static const String yueku = '/yueku';
  static const String yuekuBanner = '/yueku/banner';
  static const String yuekuFm = '/yueku/fm';

  // IP (Edit Picks)
  static const String ipHome = '/ip/home';
  static const String ipDateil = '/ip/dateil';
  static const String ipPlaylist = '/ip/playlist';
  static const String ipZone = '/ip/zone';
  static const String ipZoneHome = '/ip/zone/home';

  // FM (Radio)
  static const String fmRecommend = '/fm/recommend';
  static const String fmClass = '/fm/class';
  static const String fmImage = '/fm/image';
  static const String fmSongs = '/fm/songs';

  // Personal FM
  static const String personalFm = '/personal/fm';

  // Scene
  static const String sceneLists = '/scene/lists';
  static const String sceneMusic = '/scene/music';
  static const String sceneModule = '/scene/module';
  static const String sceneModuleInfo = '/scene/module/info';
  static const String sceneCollectionList = '/scene/collection/list';
  static const String sceneVideoList = '/scene/video/list';
  static const String sceneAudioList = '/scene/audio/list';

  // Artist
  static const String singerList = '/singer/list';
  static const String artistDetail = '/artist/detail';
  static const String artistAlbums = '/artist/albums';
  static const String artistAudios = '/artist/audios';
  static const String artistVideos = '/artist/videos';
  static const String artistFollow = '/artist/follow';
  static const String artistUnfollow = '/artist/unfollow';
  static const String artistFollowNewsongs = '/artist/follow/newsongs';
  static const String images = '/images';
  static const String imagesAudio = '/images/audio';

  // Login
  static const String login = '/login';
  static const String loginCellphone = '/login/cellphone';
  static const String loginOpenplat = '/login/openplat';
  static const String loginQrKey = '/login/qr/key';
  static const String loginQrCreate = '/login/qr/create';
  static const String loginQrCheck = '/login/qr/check';
  static const String loginWxCreate = '/login/wx/create';
  static const String loginWxCheck = '/login/wx/check';
  static const String loginToken = '/login/token';
  static const String loginDevice = '/login/device';
  static const String loginDeviceKick = '/login/device/kick';
  static const String captchaSent = '/captcha/sent';

  // User
  static const String userDetail = '/user/detail';
  static const String userVipDetail = '/user/vip/detail';
  static const String userPlaylist = '/user/playlist';
  static const String userFollow = '/user/follow';
  static const String userFollowMessage = '/user/follow/message';
  static const String userCloud = '/user/cloud';
  static const String userCloudUrl = '/user/cloud/url';
  static const String userVideoCollect = '/user/video/collect';
  static const String userVideoLove = '/user/video/love';
  static const String userListen = '/user/listen';
  static const String userHistory = '/user/history';
  static const String playhistoryUpload = '/playhistory/upload';
  static const String lastestSongsListen = '/lastest/songs/listen';

  // Video
  static const String videoUrl = '/video/url';
  static const String videoDetail = '/video/detail';
  static const String videoPrivilege = '/video/privilege';
  static const String pcDiantai = '/pc/diantai';

  // Youth (Channel)
  static const String youthChannelAll = '/youth/channel/all';
  static const String youthChannelDetail = '/youth/channel/detail';
  static const String youthChannelAmway = '/youth/channel/amway';
  static const String youthChannelSimilar = '/youth/channel/similar';
  static const String youthChannelSub = '/youth/channel/sub';
  static const String youthChannelSong = '/youth/channel/song';
  static const String youthChannelSongDetail = '/youth/channel/song/detail';
  static const String youthDynamic = '/youth/dynamic';
  static const String youthDynamicRecent = '/youth/dynamic/recent';
  static const String youthListenSong = '/youth/listen/song';
  static const String youthUserSong = '/youth/user/song';
  static const String youthDayVip = '/youth/day/vip';
  static const String youthDayVipUpgrade = '/youth/day/vip/upgrade';
  static const String youthMonthVipRecord = '/youth/month/vip/record';
  static const String youthUnionVip = '/youth/union/vip';
  static const String youthVip = '/youth/vip';

  // Long Audio (Listen Books)
  static const String longaudioDailyRecommend = '/longaudio/daily/recommend';
  static const String longaudioRankRecommend = '/longaudio/rank/recommend';
  static const String longaudioVipRecommend = '/longaudio/vip/recommend';
  static const String longaudioWeekRecommend = '/longaudio/week/recommend';
  static const String longaudioAlbumDetail = '/longaudio/album/detail';
  static const String longaudioAlbumAudios = '/longaudio/album/audios';

  // Other
  static const String brush = '/brush';
  static const String aiRecommend = '/ai/recommend';
  static const String lastestSongsListenList = '/lastest/songs/listen';
  static const String ip = '/ip';
  static const String privilegeLite = '/privilege/lite';
  static const String albumInfo = '/album/info';
  static const String albumDetail = '/album/detail';
  static const String albumSongs = '/album/songs';
  static const String albumShop = '/album/shop';
  static const String artistLists = '/artist/lists';
  static const String artistHonour = '/artist/honour';
}
