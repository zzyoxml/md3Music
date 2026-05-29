import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'kugou_endpoints.dart';
import 'kugou_models.dart';

class KugouApiClient {
  static final KugouApiClient _instance = KugouApiClient._internal();

  factory KugouApiClient() => _instance;

  KugouApiClient._internal() {
    _dio = Dio(BaseOptions(
      baseUrl: KugouEndpoints.baseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        'Accept': 'application/json',
      },
      extra: {'withCredentials': true},
    ));

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: _onRequest,
    ));

    _dio.interceptors.add(LogInterceptor(
      request: false,
      requestHeader: false,
      requestBody: false,
      responseHeader: false,
      responseBody: kDebugMode,
      error: true,
    ));
  }

  late final Dio _dio;
  String? _token;
  String? _userid;
  String? _dfid;

  void _onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (_token != null && _userid != null) {
      options.headers['Authorization'] = 'token=$_token;userid=$_userid';
    }
    if (_dfid != null) {
      options.queryParameters['dfid'] = _dfid;
    }
    handler.next(options);
  }

  void setBaseUrl(String url) {
    final cleanUrl = url.replaceAll(RegExp(r'/+$'), '');
    KugouEndpoints.baseUrl = cleanUrl;
    _dio.options.baseUrl = cleanUrl;
    _dfid = null;
    registerDevice();
  }

  Future<Map<String, dynamic>?> _get(String path, {Map<String, dynamic>? queryParameters}) async {
    try {
      final response = await _dio.get(path, queryParameters: queryParameters);
      if (response.statusCode == 200) {
        if (response.data is Map<String, dynamic>) {
          return response.data as Map<String, dynamic>;
        }
      }
      debugPrint('GET $path => ${response.statusCode}');
      return null;
    } on DioException catch (e) {
      debugPrint('GET $path error: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('GET $path error: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _post(String path, {Map<String, dynamic>? data, Map<String, dynamic>? queryParameters}) async {
    try {
      final response = await _dio.post(path, data: data, queryParameters: queryParameters);
      if (response.statusCode == 200) {
        if (response.data is Map<String, dynamic>) {
          return response.data as Map<String, dynamic>;
        }
      }
      debugPrint('POST $path => ${response.statusCode}');
      return null;
    } on DioException catch (e) {
      debugPrint('POST $path error: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('POST $path error: $e');
      return null;
    }
  }

  Future<void> setLoginCookies(String token, String userid) async {
    _token = token;
    _userid = userid;
    debugPrint('Login cookies saved: token=$token, userid=$userid');
  }

  Future<void> clearCookies() async {
    _token = null;
    _userid = null;
  }

  String? get token => _token;
  String? get userid => _userid;
  String? get dfid => _dfid;
  bool get isLoggedIn => _token != null && _userid != null;

  Future<void> registerDevice() async {
    try {
      final json = await _get(KugouEndpoints.registerDev);
      if (json != null) {
        final data = json['data'] as Map<String, dynamic>?;
        if (data != null && data['dfid'] != null) {
          _dfid = data['dfid'].toString();
          debugPrint('Device registered: dfid=$_dfid');
        }
      }
    } catch (e) {
      debugPrint('registerDevice error: $e');
    }
  }

  bool _hasCandidates(Map<String, dynamic> json) {
    final candidates = json['candidates'];
    return candidates is List && candidates.isNotEmpty;
  }

  Future<KugouSearchResult?> search(
    String keywords, {
    int page = 1,
    int pagesize = 30,
    String type = 'song',
  }) async {
    final json = await _get(KugouEndpoints.search, queryParameters: {
      'keywords': keywords,
      'page': page,
      'pagesize': pagesize,
      'type': type,
    });
    if (json == null) return null;
    try {
      return KugouSearchResult.fromJson(json);
    } catch (e) {
      debugPrint('search parse error: $e');
      return null;
    }
  }

  Future<KugouPlayUrl?> getSongUrl(
    String hash, {
    String quality = KugouQuality.standard,
    String? albumId,
    String? albumAudioId,
  }) async {
    final params = <String, dynamic>{
      'hash': hash.toLowerCase(),
      'quality': quality,
    };
    if (albumId != null) params['album_id'] = albumId;
    if (albumAudioId != null) params['album_audio_id'] = albumAudioId;

    var json = await _get(KugouEndpoints.songUrl, queryParameters: params);
    if (json == null) return null;

    var data = json['data'] as Map<String, dynamic>? ?? json;
    final errcode = data['errcode'];

    if (errcode != null && errcode == 20028) {
      debugPrint('getSongUrl: dfid invalid, re-registering device...');
      await registerDevice();
      if (_dfid == null) return null;

      json = await _get(KugouEndpoints.songUrl, queryParameters: params);
      if (json == null) return null;
      data = json['data'] as Map<String, dynamic>? ?? json;
    }

    try {
      if (data['url'] != null) {
        return KugouPlayUrl.fromJson(data);
      }

      final failProcess = data['fail_process'];
      if (failProcess is List && failProcess.contains('buy') && quality != KugouQuality.standard) {
        debugPrint('getSongUrl: VIP song, retrying with standard quality...');
        params['quality'] = KugouQuality.standard;
        json = await _get(KugouEndpoints.songUrl, queryParameters: params);
        if (json != null) {
          final fallbackData = json['data'] as Map<String, dynamic>? ?? json;
          if (fallbackData['url'] != null) {
            return KugouPlayUrl.fromJson(fallbackData);
          }
        }
      }

      debugPrint('getSongUrl: no url in response, status=${data['status']}, fail_process=${data['fail_process']}');
    } catch (e) {
      debugPrint('getSongUrl parse error: $e');
    }
    return null;
  }

  Future<KugouLyric?> getLyric(
    String hash, {
    String? accesskey,
    String? songName,
    String fmt = 'lrc',
    bool decode = true,
  }) async {
    String? lyricId;
    String? lyricAccesskey;

    Map<String, dynamic>? searchResult = await _get('/search/lyric', queryParameters: {
      'hash': hash.toLowerCase(),
    });

    if (searchResult != null && !_hasCandidates(searchResult) && songName != null && songName.isNotEmpty) {
      debugPrint('getLyric: hash search empty, retrying with keywords=$songName');
      searchResult = await _get('/search/lyric', queryParameters: {
        'keywords': songName,
        'hash': hash.toLowerCase(),
      });
    }

    if (searchResult != null) {
      try {
        final candidates = searchResult['candidates'];
        if (candidates is List && candidates.isNotEmpty) {
          final first = candidates.first as Map<String, dynamic>;
          lyricId = first['id']?.toString();
          lyricAccesskey = first['accesskey']?.toString();
        }
      } catch (e) {
        debugPrint('search lyric parse error: $e');
      }
    }

    if (lyricId == null) {
      debugPrint('getLyric: no lyric found for hash=$hash');
      return null;
    }

    final params = <String, dynamic>{
      'id': lyricId,
      'fmt': 'krc',
      'decode': decode.toString(),
    };
    if (lyricAccesskey != null) params['accesskey'] = lyricAccesskey;

    final json = await _get(KugouEndpoints.lyric, queryParameters: params);
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      return KugouLyric.fromJson(data);
    } catch (e) {
      debugPrint('getLyric parse error: $e');
      return null;
    }
  }

  Future<KugouRankList?> getRankList({int withsong = 1}) async {
    final json = await _get(KugouEndpoints.rankList, queryParameters: {
      'withsong': withsong,
    });
    if (json == null) return null;
    try {
      return KugouRankList.fromJson(json);
    } catch (e) {
      debugPrint('getRankList parse error: $e');
      return null;
    }
  }

  Future<List<KugouPlaylistBrief>?> getPlaylistDetail(String ids) async {
    final json = await _post(KugouEndpoints.playlistDetail, data: {'ids': ids});
    if (json == null) return null;
    try {
      final data = json['data'];
      if (data is List) {
        return data
            .map((e) => KugouPlaylistBrief.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      debugPrint('getPlaylistDetail parse error: $e');
      return null;
    }
  }

  Future<List<KugouSongDetail>?> getRecommendDaily() async {
    final json = await _get(KugouEndpoints.recommendDaily);
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      final list = data['song_list'] ?? data['songs'] ?? data['list'] ?? data['info'] ?? [];
      return (list as List<dynamic>)
          .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('getRecommendDaily parse error: $e');
      return null;
    }
  }

  Future<KugouSongDetail?> getSongDetail(String hash) async {
    final json = await _get(KugouEndpoints.songDetail, queryParameters: {
      'hash': hash,
    });
    if (json == null) return null;
    try {
      final rawData = json['data'] ?? json;
      Map<String, dynamic> data;
      if (rawData is List && rawData.isNotEmpty) {
        data = rawData.first as Map<String, dynamic>;
      } else if (rawData is Map<String, dynamic>) {
        data = rawData;
      } else {
        return null;
      }
      return KugouSongDetail.fromJson(data);
    } catch (e) {
      debugPrint('getSongDetail parse error: $e');
      return null;
    }
  }

  Future<KugouCommentList?> getComments(
    String hash, {
    String? albumAudioId,
    int page = 1,
    int pagesize = 20,
  }) async {
    final params = <String, dynamic>{
      'hash': hash,
      'page': page,
      'pagesize': pagesize,
    };
    if (albumAudioId != null) params['album_audio_id'] = albumAudioId;
    final json = await _get(KugouEndpoints.comment, queryParameters: params);
    if (json == null) return null;
    try {
      return KugouCommentList.fromJson(json);
    } catch (e) {
      debugPrint('getComments parse error: $e');
      return null;
    }
  }

  Future<KugouArtistDetail?> getArtistDetail(String artistId) async {
    final json = await _get(KugouEndpoints.artistDetail, queryParameters: {
      'singerid': artistId,
    });
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      return KugouArtistDetail.fromJson(data);
    } catch (e) {
      debugPrint('getArtistDetail parse error: $e');
      return null;
    }
  }

  Future<KugouArtistAlbums?> getArtistAlbums(
    String artistId, {
    int page = 1,
    int pagesize = 30,
  }) async {
    final json = await _get(KugouEndpoints.artistAlbums, queryParameters: {
      'singerid': artistId,
      'page': page,
      'pagesize': pagesize,
    });
    if (json == null) return null;
    try {
      return KugouArtistAlbums.fromJson(json);
    } catch (e) {
      debugPrint('getArtistAlbums parse error: $e');
      return null;
    }
  }

  Future<KugouArtistAudios?> getArtistAudios(
    String artistId, {
    int page = 1,
    int pagesize = 30,
  }) async {
    final json = await _get(KugouEndpoints.artistAudios, queryParameters: {
      'singerid': artistId,
      'page': page,
      'pagesize': pagesize,
    });
    if (json == null) return null;
    try {
      return KugouArtistAudios.fromJson(json);
    } catch (e) {
      debugPrint('getArtistAudios parse error: $e');
      return null;
    }
  }

  Future<KugouAlbumDetail?> getAlbumDetail(String albumId) async {
    final json = await _get(KugouEndpoints.albumDetail, queryParameters: {
      'album_id': albumId,
    });
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      return KugouAlbumDetail.fromJson(data);
    } catch (e) {
      debugPrint('getAlbumDetail parse error: $e');
      return null;
    }
  }

  Future<KugouAlbumSongs?> getAlbumSongs(
    String albumId, {
    int page = 1,
    int pagesize = 30,
  }) async {
    final json = await _get(KugouEndpoints.albumSongs, queryParameters: {
      'album_id': albumId,
      'page': page,
      'pagesize': pagesize,
    });
    if (json == null) return null;
    try {
      return KugouAlbumSongs.fromJson(json);
    } catch (e) {
      debugPrint('getAlbumSongs parse error: $e');
      return null;
    }
  }

  Future<List<String>?> getHotSearch() async {
    final json = await _get(KugouEndpoints.hotSearch);
    if (json == null) return null;
    try {
      final data = json['data'];
      List<dynamic> list;
      if (data is List) {
        list = data;
      } else if (data is Map) {
        list = data['list'] ?? data['info'] ?? [];
      } else {
        list = [];
      }
      return list.map((e) {
        if (e is String) return e;
        final m = e as Map<String, dynamic>;
        return (m['searchword'] ?? m['keyword'] ?? m['name'] ?? '').toString();
      }).where((e) => e.isNotEmpty).cast<String>().toList();
    } catch (e) {
      debugPrint('getHotSearch parse error: $e');
      return null;
    }
  }

  Future<List<String>?> getSearchSuggest(String keywords) async {
    final json = await _get(KugouEndpoints.searchSuggest, queryParameters: {
      'keywords': keywords,
    });
    if (json == null) return null;
    try {
      final data = json['data'];
      List<dynamic> items = [];
      if (data is List) {
        for (final category in data) {
          if (category is Map<String, dynamic>) {
            final recordDatas = category['RecordDatas'];
            if (recordDatas is List) {
              for (final record in recordDatas) {
                if (record is Map<String, dynamic>) {
                  final hintInfo = record['HintInfo'];
                  if (hintInfo is Map<String, dynamic>) {
                    final word = hintInfo['HintWords'] ?? hintInfo['keyword'] ?? '';
                    if (word.toString().isNotEmpty) {
                      items.add(word.toString());
                    }
                  }
                }
              }
            }
          }
        }
      } else if (data is Map) {
        final list = data['list'] ?? data['info'] ?? [];
        for (final e in list) {
          if (e is String) {
            items.add(e);
          } else if (e is Map<String, dynamic>) {
            final word = e['keyword'] ?? e['searchword'] ?? e['name'] ?? '';
            if (word.toString().isNotEmpty) {
              items.add(word.toString());
            }
          }
        }
      }
      return items.cast<String>().toList();
    } catch (e) {
      debugPrint('getSearchSuggest parse error: $e');
      return null;
    }
  }

  Future<KugouPlaylistCategory?> getPlaylist({
    String? categoryId,
    int page = 1,
  }) async {
    final params = <String, dynamic>{
      'page': page,
    };
    if (categoryId != null) params['category_id'] = categoryId;

    final json = await _get(KugouEndpoints.playlist, queryParameters: params);
    if (json == null) return null;
    try {
      return KugouPlaylistCategory.fromJson(json);
    } catch (e) {
      debugPrint('getPlaylist parse error: $e');
      return null;
    }
  }

  Future<KugouPlaylistSongs?> getPlaylistSongs(
    String globalCollectionId, {
    int page = 1,
    int pagesize = 30,
  }) async {
    final json = await _get(KugouEndpoints.playlistSongs, queryParameters: {
      'global_collection_id': globalCollectionId,
      'page': page,
      'pagesize': pagesize,
    });
    if (json == null) return null;
    try {
      return KugouPlaylistSongs.fromJson(json);
    } catch (e) {
      debugPrint('getPlaylistSongs parse error: $e');
      return null;
    }
  }

  Future<List<KugouSongDetail>?> getPersonalFm() async {
    final json = await _get(KugouEndpoints.personalFm);
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      final list = data['song_list'] ?? data['songs'] ?? data['list'] ?? data['info'] ?? [];
      return (list as List<dynamic>)
          .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('getPersonalFm parse error: $e');
      return null;
    }
  }

  Future<List<KugouSongDetail>?> getRankAudio({
    required String rankId,
    int rankCid = 0,
    int page = 1,
    int pagesize = 30,
  }) async {
    final json = await _get('/rank/audio', queryParameters: {
      'rankid': rankId,
      'rank_cid': rankCid,
      'page': page,
      'pagesize': pagesize,
    });
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      final list = data['songlist'] ?? data['list'] ?? data['songs'] ?? data['info'] ?? [];
      return (list as List<dynamic>)
          .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('getRankAudio parse error: $e');
      return null;
    }
  }

  Future<List<KugouSongDetail>?> getPlaylistTrackAll({
    required String id,
    int page = 1,
    int pagesize = 30,
  }) async {
    final params = <String, dynamic>{
      'id': id,
      'page': page,
      'pagesize': pagesize,
    };
    final json = await _get(KugouEndpoints.playlistSongs, queryParameters: params);
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      final list = data['list'] ?? data['songs'] ?? data['info'] ?? [];
      return (list as List<dynamic>)
          .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('getPlaylistTrackAll parse error: $e');
      return null;
    }
  }

  Future<KugouQrKey?> getLoginQrKey() async {
    final json = await _get('/login/qr/key', queryParameters: {
      'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
    });
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      return KugouQrKey.fromJson(data);
    } catch (e) {
      debugPrint('getLoginQrKey parse error: $e');
      return null;
    }
  }

  Future<KugouQrCreate?> createLoginQr(String key) async {
    final json = await _get('/login/qr/create', queryParameters: {
      'key': key,
      'qrimg': 'true',
      'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
    });
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      return KugouQrCreate.fromJson(data);
    } catch (e) {
      debugPrint('createLoginQr parse error: $e');
      return null;
    }
  }

  Future<KugouQrCheck?> checkLoginQr(String key) async {
    final json = await _get('/login/qr/check', queryParameters: {
      'key': key,
      'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
    });
    if (json == null) return null;
    try {
      debugPrint('checkLoginQr response: $json');
      return KugouQrCheck.fromJson(json);
    } catch (e) {
      debugPrint('checkLoginQr parse error: $e');
      return null;
    }
  }

  Future<KugouUserDetail?> getUserDetail() async {
    final json = await _get('/user/detail');
    if (json == null) return null;
    try {
      return KugouUserDetail.fromJson(json);
    } catch (e) {
      debugPrint('getUserDetail parse error: $e');
      return null;
    }
  }
}