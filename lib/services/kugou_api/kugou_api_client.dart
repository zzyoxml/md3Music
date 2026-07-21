import 'dart:async';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'kugou_endpoints.dart';
import 'kugou_models.dart';

class KugouApiClient {
  static final KugouApiClient _instance = KugouApiClient._internal();

  factory KugouApiClient() => _instance;

  KugouApiClient._internal() {
    _dio = Dio(
      BaseOptions(
        baseUrl: KugouEndpoints.baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: {'Accept': 'application/json'},
        extra: {'withCredentials': true},
      ),
    );

    _dio.interceptors.add(InterceptorsWrapper(onRequest: _onRequest));

    _initFromStorage();
  }

  late final Dio _dio;

  /// 暴露 Dio 实例供外部使用（如 DownloadsProvider 下载封面图）。
  Dio get dio => _dio;

  String? _token;
  String? _userid;
  String? _vipToken;
  String? _dfid;
  bool _isInitialized = false;
  Completer<void>? _initCompleter;

  static const _loginPaths = {
    '/login/qr/key', '/login/qr/create', '/login/qr/check',
    '/login/cellphone', '/login/token', '/login',
    '/login/wx/create', '/login/wx/check',
    '/login/openplat', '/login/device', '/login/device/kick',
    '/captcha/sent',
    '/youth/day/vip', '/youth/day/vip/upgrade', '/youth/month/vip/record',
  };

  void _onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (!_isInitialized) {
      await _initCompleter?.future;
    }

    // 登录相关接口直接走云服务器，避免 local→cloud 双重签名
    if (_loginPaths.contains(options.path)) {
      options.baseUrl = 'http://115.29.236.96:5621';
    } else {
      options.baseUrl = KugouEndpoints.baseUrl;
    }

    // 关键修复：每次请求前验证用户身份
    if (_token != null && _userid != null) {
      // 把 vip_token 一并写入 Authorization，服务端的 cookieToJson
      // 会按 ; 切成 cookie 对象，song_url_new 等模块可直接读取。
      final authParts = <String>['token=$_token', 'userid=$_userid'];
      if (_vipToken != null && _vipToken!.isNotEmpty) {
        authParts.add('vip_token=$_vipToken');
      }
      options.headers['Authorization'] = authParts.join(';');

      // 调试日志：打印请求的用户身份（生产环境可移除）
      print('🌐 [API Request] User: $_userid, URL: ${options.path}');
          } else {
      // 未登录，清除 Authorization 头
      options.headers.remove('Authorization');
      print('⚠️ [API Request] 未登录状态, URL: ${options.path}');
          }

    if (_dfid != null) {
      options.queryParameters['dfid'] = _dfid;
    }

    // 调用方通过 options.extra['noCache'] = true 标记需要绕过 server_android 的 apicache。
    // server_android 的 apicache 中间件认 x-apicache-bypass / x-apicache-force-fetch 头
    // （util/apicache.js L596-597）。这样"我的收藏"新增/取消后下拉刷新能立刻拿到新数据，
    // 不必等 2 分钟过期。
    final extra = options.extra;
    if (extra['noCache'] == true) {
      options.headers['x-apicache-bypass'] = '1';
      options.headers['Cache-Control'] = 'no-cache';
      // 同时给查询参数加 t= 戳，避免部分路径在 cache 命中时跳过参数比对
      if (options.queryParameters['t'] == null) {
        options.queryParameters['t'] = DateTime.now().millisecondsSinceEpoch;
      }
    } else {
      options.headers.remove('x-apicache-bypass');
      options.headers.remove('Cache-Control');
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

  Future<Map<String, dynamic>?> _get(
    String path, {
    Map<String, dynamic>? queryParameters,
    bool noCache = false,
  }) async {
    try {
      final response = await _dio.get(
        path,
        queryParameters: queryParameters,
        options: Options(extra: {'noCache': noCache}),
      );
      if (response.statusCode == 200) {
        if (response.data is Map<String, dynamic>) {
          return response.data as Map<String, dynamic>;
        }
      }
      print('[API _get] Non-200 or non-map: status=${response.statusCode} data=${response.data}');
      return null;
    } on DioException catch (e) {
      print('[API _get] DioException: ${e.type} ${e.message} response=${e.response?.statusCode} ${e.response?.data}');
      return null;
    } catch (e) {
      print('[API _get] Error: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _post(
    String path, {
    Map<String, dynamic>? data,
    Map<String, dynamic>? queryParameters,
    bool noCache = false,
  }) async {
    try {
      final response = await _dio.post(
        path,
        data: data,
        queryParameters: queryParameters,
        options: Options(extra: {'noCache': noCache}),
      );
      if (response.statusCode == 200) {
        if (response.data is Map<String, dynamic>) {
          return response.data as Map<String, dynamic>;
        }
      }
      print('[API _post] Non-200 or non-map: status=${response.statusCode} data=${response.data}');
      return null;
    } on DioException catch (e) {
      print('[API _post] DioException: ${e.type} ${e.message} response=${e.response?.statusCode} ${e.response?.data}');
      return null;
    } catch (e) {
      print('[API _post] Error: $e');
      return null;
    }
  }

  Future<void> _initFromStorage() async {
    _initCompleter = Completer<void>();
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // 先读取当前登录的用户ID
      final currentUserid = prefs.getString('kugou_current_userid');
      
      if (currentUserid != null && currentUserid.isNotEmpty) {
        // 从用户隔离的键名读取
        final userTokenKey = 'kugou_token_$currentUserid';
        final userIdKey = 'kugou_userid_$currentUserid';
        final userVipKey = 'kugou_vip_token_$currentUserid';
        
        _token = prefs.getString(userTokenKey);
        _userid = prefs.getString(userIdKey);
        _vipToken = prefs.getString(userVipKey);
        
        if (_token != null && _userid != null) {
          print('✅ [Auth] 从存储恢复用户 $currentUserid 的登录状态');
        } else {
          print('⚠️ [Auth] 用户 $currentUserid 的凭证不完整，需要重新登录');
          _token = null;
          _userid = null;
          _vipToken = null;
        }
      } else {
        // 兼容旧版本：尝试读取全局键
        _token = prefs.getString('kugou_token');
        _userid = prefs.getString('kugou_userid');
        _vipToken = prefs.getString('kugou_vip_token');
        
        if (_token != null && _userid != null) {
          print('⚠️ [Auth] 检测到旧版本登录状态，建议重新登录');
        }
      }
      
      _dfid = prefs.getString('kugou_dfid');
          } catch (e) {
      print('❌ [Auth] 从存储初始化失败: $e');
          } finally {
      _isInitialized = true;
      _initCompleter?.complete();
    }
  }

  Future<void> setLoginCookies(
    String token,
    String userid, {
    String? vipToken,
  }) async {
    // 关键修复：先清除旧的用户数据，再设置新的
    await clearCookies();
    
    _token = token;
    _userid = userid;
    _vipToken = vipToken;
    
    // 使用用户隔离的键名，避免多用户数据混乱
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // 清除所有可能的旧键（兼容旧版本）
      await prefs.remove('kugou_token');
      await prefs.remove('kugou_userid');
      await prefs.remove('kugou_vip_token');
      await prefs.remove('kugou_dfid');
      
      // 使用带用户ID的键名存储（防止多用户冲突）
      final userTokenKey = 'kugou_token_$userid';
      final userIdKey = 'kugou_userid_$userid';
      final userVipKey = 'kugou_vip_token_$userid';
      final currentUserKey = 'kugou_current_userid';
      
      await prefs.setString(userTokenKey, token);
      await prefs.setString(userIdKey, userid);
      if (vipToken != null && vipToken.isNotEmpty) {
        await prefs.setString(userVipKey, vipToken);
      }
      
      // 记录当前登录的用户ID
      await prefs.setString(currentUserKey, userid);
      
      print('✅ [Auth] 登录成功，用户ID: $userid, Token已存储到: $userTokenKey');
          } catch (e) {
      print('❌ [Auth] 保存登录状态失败: $e');
          }
  }

  Future<void> clearCookies() async {
    final oldUserid = _userid;
    
    _token = null;
    _userid = null;
    _vipToken = null;
    _dfid = null;
    
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // 清除当前用户的键
      if (oldUserid != null) {
        await prefs.remove('kugou_token_$oldUserid');
        await prefs.remove('kugou_userid_$oldUserid');
        await prefs.remove('kugou_vip_token_$oldUserid');
      }
      
      // 清除全局键（兼容旧版本）
      await prefs.remove('kugou_token');
      await prefs.remove('kugou_userid');
      await prefs.remove('kugou_vip_token');
      await prefs.remove('kugou_dfid');
      await prefs.remove('kugou_current_userid');
      
      print('✅ [Auth] 已清除用户 $oldUserid 的登录状态');
          } catch (e) {
      print('❌ [Auth] 清除登录状态失败: $e');
          }
  }

  String? get token => _token;
  String? get userid => _userid;
  String? get vipToken => _vipToken;
  String? get dfid => _dfid;
  bool get isLoggedIn => _token != null && _userid != null;
  bool get hasVipToken => _vipToken != null && _vipToken!.isNotEmpty;

  Future<void> registerDevice() async {
    try {
      final json = await _get(KugouEndpoints.registerDev);
      if (json != null) {
        final data = json['data'] as Map<String, dynamic>?;
        if (data != null && data['dfid'] != null) {
          _dfid = data['dfid'].toString();
                  }
      }
    } catch (e) {
          }
  }

  bool _hasCandidates(Map<String, dynamic> json) {
    final candidates = json['candidates'];
    return candidates is List && candidates.isNotEmpty;
  }

  // ==================== Search ====================

  Future<KugouSearchResult?> search(
    String keywords, {
    int page = 1,
    int pagesize = 30,
    String type = 'song',
  }) async {
    final json = await _get(
      KugouEndpoints.search,
      queryParameters: {
        'keywords': keywords,
        'page': page,
        'pagesize': pagesize,
        'type': type,
      },
    );
    if (json == null) return null;
    try {
      return KugouSearchResult.fromJson(json);
    } catch (e) {
            return null;
    }
  }

  Future<List<KugouAlbumBrief>?> searchAlbums(String keywords, {int page = 1, int pagesize = 20}) async {
    final json = await _get(
      KugouEndpoints.searchAlbum,
      queryParameters: {'keyword': keywords, 'page': page, 'pagesize': pagesize},
    );
    if (json == null) return null;
    try {
      final data = json['data'];
      List<dynamic> list = [];
      if (data is List) {
        list = data;
      } else if (data is Map) {
        list = data['info'] ?? data['list'] ?? [];
      }
      return list
          .map((e) => KugouAlbumBrief.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
            return null;
    }
  }

  Future<List<KugouPlaylistBrief>?> searchPlaylists(String keywords, {int page = 1, int pagesize = 20}) async {
    final json = await _get(
      KugouEndpoints.searchSpecial,
      queryParameters: {'keyword': keywords, 'page': page, 'pagesize': pagesize},
    );
    if (json == null) return null;
    try {
      final data = json['data'];
      List<dynamic> list = [];
      if (data is List) {
        list = data;
      } else if (data is Map) {
        list = data['info'] ?? data['list'] ?? [];
      }
      return list
          .map((e) => KugouPlaylistBrief.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
            return null;
    }
  }

  Future<Map<String, dynamic>?> searchComplex(String keywords) async {
    return await _get(
      KugouEndpoints.searchComplex,
      queryParameters: {'keywords': keywords},
    );
  }

  Future<String?> searchDefault() async {
    final json = await _get(KugouEndpoints.searchDefault);
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      return data['keyword']?.toString();
    } catch (e) {
      return null;
    }
  }

  Future<List<String>?> getHotSearch() async {
    final json = await _get(KugouEndpoints.searchHot);
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
      return list
          .map((e) {
            if (e is String) return e;
            final m = e as Map<String, dynamic>;
            return (m['searchword'] ?? m['keyword'] ?? m['name'] ?? '')
                .toString();
          })
          .where((e) => e.isNotEmpty)
          .cast<String>()
          .toList();
    } catch (e) {
            return null;
    }
  }

  Future<List<String>?> getSearchSuggest(String keywords) async {
    final json = await _get(
      KugouEndpoints.searchSuggest,
      queryParameters: {'keywords': keywords},
    );
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
                  if (hintInfo is String && hintInfo.isNotEmpty) {
                    items.add(hintInfo);
                  } else if (hintInfo is Map<String, dynamic>) {
                    final word =
                        hintInfo['HintWords'] ?? hintInfo['keyword'] ?? '';
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
            return null;
    }
  }

  // ==================== Song ====================

  Map<String, dynamic> _extractData(dynamic rawData) {
    if (rawData is Map<String, dynamic>) return rawData;
    if (rawData is List && rawData.isNotEmpty) {
      final first = rawData.first;
      if (first is Map<String, dynamic>) return first;
    }
    return {};
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

    // VIP 用户优先用 /song/url/new（→ /v6/priv_url），它会读取
    // Authorization 头里的 vip_token，能拿到完整音质。
    // 注意：如果 _getSongUrlNew 因为 priv_status=0 / fail_process 等
    // 原因返回 null，说明酷狗没认 VIP。这种情况继续走 /song/url
    // 也只会拿到 30s 试听片段，必须直接返回 null，让上层提示
    // 用户 VIP 不生效或登录失效。
    if (hasVipToken) {
      final vipUrl = await _getSongUrlNew(
        hash,
        quality: quality,
        albumId: albumId,
        albumAudioId: albumAudioId,
      );
      if (vipUrl != null) return vipUrl;
            return null;
    }

    var json = await _get(KugouEndpoints.songUrl, queryParameters: params);
    if (json == null) return null;

    var data = _extractData(json['data'] ?? json);
    final errcode = data['errcode'];

    if (errcode != null && errcode == 20028) {
            await registerDevice();
      if (_dfid == null) return null;

      json = await _get(KugouEndpoints.songUrl, queryParameters: params);
      if (json == null) return null;
      data = _extractData(json['data'] ?? json);
    }

    final status = data['status'];
    final errorCode = data['error_code'];
    if (status == 2 &&
        errorCode == 20018 &&
        _token != null &&
        _userid != null) {
            final refreshed = await _tryRefreshToken();
      if (refreshed) {
        // refresh 后 vip_token 也会更新，重试 /song/url/new 一次
        if (hasVipToken) {
          final vipUrl = await _getSongUrlNew(
            hash,
            quality: quality,
            albumId: albumId,
            albumAudioId: albumAudioId,
          );
          if (vipUrl != null) return vipUrl;
        }
        json = await _get(KugouEndpoints.songUrl, queryParameters: params);
        if (json == null) return null;
        data = _extractData(json['data'] ?? json);
        if (data['url'] != null) {
          return KugouPlayUrl.fromJson(data);
        }
      }
    }

    try {
      if (data['url'] != null) {
        return KugouPlayUrl.fromJson(data);
      }

      final failProcess = data['fail_process'];
      if (failProcess is List &&
          failProcess.contains('buy') &&
          quality != KugouQuality.standard) {
                params['quality'] = KugouQuality.standard;
        json = await _get(KugouEndpoints.songUrl, queryParameters: params);
        if (json != null) {
          final fallbackData = _extractData(json['data'] ?? json);
          if (fallbackData['url'] != null) {
            return KugouPlayUrl.fromJson(fallbackData);
          }
        }
      }

      // VIP 用户不要再走 free_part=1 主动拉 30 秒试听。
      // 试听只对未登录 / 没有 VIP 凭证的人兜底。
      if (hasVipToken) {
                return null;
      }

            final freeParams = Map<String, dynamic>.from(params);
      freeParams['free_part'] = 1;
      final freeJson = await _get(
        KugouEndpoints.songUrl,
        queryParameters: freeParams,
      );
      if (freeJson != null) {
        final freeData = _extractData(freeJson['data'] ?? freeJson);
        if (freeData['url'] != null) {
          return KugouPlayUrl.fromJson(freeData);
        }
      }

          } catch (e) {
          }
    return null;
  }

  /// /song/url/new 走的是 /v6/priv_url，服务端会读 cookie 里的 vip_token
  /// 并作为 tracker_param.viptoken 上传给酷狗。返回结构通常为：
  ///   { data: { url: [...], bitRate, priv_status, fail_process, ... } }
  ///
  /// 关键：必须检查 `priv_status`，0 表示酷狗没认 VIP，返回的是 30s/1min
  /// 试听片段；`fail_process` 含 `buy` 时也是同样情况。这两种情况下
  /// 即便 url 字段非空也不能直接拿来用，否则会播放到片段末尾就跳结束。
  Future<KugouPlayUrl?> _getSongUrlNew(
    String hash, {
    String quality = KugouQuality.standard,
    String? albumId,
    String? albumAudioId,
  }) async {
    final query = <String, dynamic>{
      'hash': hash.toLowerCase(),
      'quality': quality,
    };
    if (albumId != null) query['album_id'] = albumId;
    if (albumAudioId != null) query['album_audio_id'] = albumAudioId;
    try {
      final json = await _get(
        KugouEndpoints.songUrlNew,
        queryParameters: query,
      );
      if (json == null) {
                return null;
      }
      final data = _extractData(json['data'] ?? json);
      final rawUrl = data['url'];
      final hasUrl = rawUrl is List
          ? rawUrl.isNotEmpty
          : (rawUrl is String && rawUrl.isNotEmpty);

      if (hasUrl) {
        // 1) priv_status 显式标记 VIP 是否生效。
        //    酷狗约定：1 = VIP 验证通过给完整音源，0 = 走试听/包月/购买。
        final privStatus = _parseInt(data['priv_status']);
        if (privStatus == 0) {
                    return null;
        }

        // 2) fail_process 含 buy/pkg 时也是试听兜底，丢弃。
        final failProcess = data['fail_process'];
        if (failProcess is List && failProcess.isNotEmpty) {
                    return null;
        }

        // 3) 用 fileSize 兜底识别：3~5 分钟的普通歌曲通常 > 2MB，
        //    如果不到 200KB 几乎一定是 30s 试听片段。
        final fileSize = _parseInt(data['fileSize'] ?? data['file_size']);
        if (fileSize > 0 && fileSize < 200 * 1024) {
                    return null;
        }

                return KugouPlayUrl.fromJson({...data, 'quality': quality});
      }
          } catch (e) {
          }
    return null;
  }

  int _parseInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  Future<List<KugouSongDetail>?> getRecommendSongs() async {
    final json = await _get(KugouEndpoints.recommendSongs);
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      final list =
          data['song_list'] ??
          data['songs'] ??
          data['list'] ??
          data['info'] ??
          [];
      return (list as List<dynamic>)
          .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return null;
    }
  }

  Future<KugouSongDetail?> getSongDetail(String hash) async {
    final json = await _get(
      KugouEndpoints.songDetail,
      queryParameters: {'hash': hash},
    );
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
            return null;
    }
  }

  Future<KugouSongClimax?> getSongClimax(
    String hash, {
    String? albumAudioId,
  }) async {
    final params = <String, dynamic>{'hash': hash};
    if (albumAudioId != null) params['album_audio_id'] = albumAudioId;
    final json = await _get(KugouEndpoints.songClimax, queryParameters: params);
    if (json == null) return null;
    try {
      return KugouSongClimax.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  Future<KugouSongRanking?> getSongRanking(String hash) async {
    final json = await _get(
      KugouEndpoints.songRanking,
      queryParameters: {'hash': hash},
    );
    if (json == null) return null;
    try {
      return KugouSongRanking.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  Future<List<KugouSongDetail>?> getAudioRelated(String hash) async {
    final json = await _get(
      KugouEndpoints.audioRelated,
      queryParameters: {'hash': hash},
    );
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      final list = data['list'] ?? data['songs'] ?? data['info'] ?? [];
      return (list as List<dynamic>)
          .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return null;
    }
  }

  // ==================== Lyric ====================

  Future<KugouLyric?> getLyric(
    String hash, {
    String? accesskey,
    String? songName,
    String fmt = 'lrc',
    bool decode = true,
  }) async {
    String? lyricId;
    String? lyricAccesskey;

    Map<String, dynamic>? searchResult = await _get(
      KugouEndpoints.searchLyric,
      queryParameters: {'hash': hash.toLowerCase()},
    );

    if (searchResult != null &&
        !_hasCandidates(searchResult) &&
        songName != null &&
        songName.isNotEmpty) {
            searchResult = await _get(
        KugouEndpoints.searchLyric,
        queryParameters: {'keywords': songName, 'hash': hash.toLowerCase()},
      );
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
              }
    }

    if (lyricId == null) {
            return null;
    }

    // 默认 fmt='lrc' 触发并发双请求（LRC + KRC）；显式传 fmt='krc' 走单请求路径（向后兼容）
    final bool dualRequest = (fmt == 'lrc');

    if (dualRequest) {
      // 并发双请求：Future.wait 同时发起，每个请求独立 try/catch 防止单点失败
      final results = await Future.wait([
        _fetchLyricContent(lyricId, lyricAccesskey, 'lrc', decode),
        _fetchLyricContent(lyricId, lyricAccesskey, 'krc', decode),
      ]);
      final lrcJson = results[0];
      final krcJson = results[1];
      return mergeLyricResponses(lrcJson, krcJson);
    }

    // 单请求路径（显式 fmt=krc 等非 lrc 场景）
    final json = await _fetchLyricContent(lyricId, lyricAccesskey, fmt, decode);
    if (json == null) return null;
    try {
      return KugouLyric.fromJson(json);
    } catch (e) {
            return null;
    }
  }

  /// 抽取的私有方法：发起单个歌词下载请求，返回响应中的 data 节点。
  /// 任何异常都吞掉返回 null，确保并发场景下单个请求失败不影响另一个。
  Future<Map<String, dynamic>?> _fetchLyricContent(
    String lyricId,
    String? lyricAccesskey,
    String fmt,
    bool decode,
  ) async {
    try {
      final params = <String, dynamic>{
        'id': lyricId,
        'fmt': fmt,
        'decode': decode.toString(),
      };
      if (lyricAccesskey != null) params['accesskey'] = lyricAccesskey;
      final json = await _get(KugouEndpoints.lyric, queryParameters: params);
      if (json == null) return null;
      return json['data'] as Map<String, dynamic>? ?? json;
    } catch (e) {
      // 单点失败不影响另一个并发请求
      return null;
    }
  }

  /// 合并 LRC 与 KRC 两个响应，构造同时携带两种明文的 KugouLyric。
  /// 抽为静态方法便于单元测试（无需 mock HTTP）。
  ///
  /// 字段映射规则（依 spec.md "Requirement: KRC 双请求与降级"）：
  /// - LRC 响应的 `decodeContent` → `KugouLyric.decodedContent`
  /// - KRC 响应的 `decodeContent` → `KugouLyric.decodedKrcContent`
  ///
  /// 注意：`KugouLyric.fromJson` 会把 `decodeContent` 统一映射到 `decodedContent`，
  /// 因此对 KRC 响应不能直接用 fromJson 的 `decodedKrcContent` 字段（除非上游
  /// 显式返回 `decodeKrcContent` / `decoded_krc_content` / `krcContent`）。
  /// 这里对 KRC 响应做特殊处理：优先取专用字段，否则把 `decodeContent` 作为 KRC 明文。
  /// 两者都为 null 时返回 null。
  static KugouLyric? mergeLyricResponses(
    Map<String, dynamic>? lrcJson,
    Map<String, dynamic>? krcJson,
  ) {
    if (lrcJson == null && krcJson == null) return null;

    final lrcLyric =
        lrcJson != null ? KugouLyric.fromJson(lrcJson) : null;
    final krcLyric =
        krcJson != null ? KugouLyric.fromJson(krcJson) : null;

    // KRC 明文：优先用专用字段，否则把 KRC 响应的 decodeContent 当作 KRC 明文
    String? krcContent;
    if (krcJson != null) {
      final explicitKrc = krcJson['decodeKrcContent'] ??
          krcJson['decoded_krc_content'] ??
          krcJson['krcContent'];
      if (explicitKrc != null) {
        krcContent = explicitKrc.toString();
      } else if (krcJson['decodeContent'] != null) {
        krcContent = krcJson['decodeContent'].toString();
      }
    }

    return KugouLyric(
      content: lrcLyric?.content ?? krcLyric?.content ?? '',
      decodedContent: lrcLyric?.decodedContent,
      decodedKrcContent: krcContent,
      translatedContent:
          lrcLyric?.translatedContent ?? krcLyric?.translatedContent,
    );
  }

  // ==================== Comment ====================

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
    final json = await _get(
      KugouEndpoints.commentMusic,
      queryParameters: params,
    );
    if (json == null) return null;
    try {
      return KugouCommentList.fromJson(json);
    } catch (e) {
            return null;
    }
  }

  Future<KugouCommentList?> getCommentsByClassify(
    String hash, {
    String? classify,
    int page = 1,
    int pagesize = 20,
  }) async {
    final params = <String, dynamic>{
      'hash': hash,
      'page': page,
      'pagesize': pagesize,
    };
    if (classify != null) params['classify'] = classify;
    final json = await _get(
      KugouEndpoints.commentMusicClassify,
      queryParameters: params,
    );
    if (json == null) return null;
    try {
      return KugouCommentList.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  Future<KugouCommentList?> getCommentsByHotword(
    String hash, {
    String? hotword,
    int page = 1,
  }) async {
    final params = <String, dynamic>{'hash': hash, 'page': page};
    if (hotword != null) params['hotword'] = hotword;
    final json = await _get(
      KugouEndpoints.commentMusicHotword,
      queryParameters: params,
    );
    if (json == null) return null;
    try {
      return KugouCommentList.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  Future<KugouCommentList?> getFloorComments(
    String commentId, {
    int page = 1,
  }) async {
    final json = await _get(
      KugouEndpoints.commentFloor,
      queryParameters: {'commentid': commentId, 'page': page},
    );
    if (json == null) return null;
    try {
      return KugouCommentList.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  Future<KugouCommentList?> getPlaylistComments(
    String specialId, {
    int page = 1,
  }) async {
    final json = await _get(
      KugouEndpoints.commentPlaylist,
      queryParameters: {'specialid': specialId, 'page': page},
    );
    if (json == null) return null;
    try {
      return KugouCommentList.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  Future<KugouCommentList?> getAlbumComments(
    String albumId, {
    int page = 1,
  }) async {
    final json = await _get(
      KugouEndpoints.commentAlbum,
      queryParameters: {'album_id': albumId, 'page': page},
    );
    if (json == null) return null;
    try {
      return KugouCommentList.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  // ==================== Playlist ====================

  Future<KugouPlaylistCategory?> getPlaylist({
    String? categoryId,
    int page = 1,
  }) async {
    final params = <String, dynamic>{'page': page};
    if (categoryId != null) params['category_id'] = categoryId;

    final json = await _get(
      KugouEndpoints.topPlaylist,
      queryParameters: params,
    );
    if (json == null) return null;
    try {
      return KugouPlaylistCategory.fromJson(json);
    } catch (e) {
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
            return null;
    }
  }

  Future<KugouPlaylistSongs?> getPlaylistSongs(
    String globalCollectionId, {
    int page = 1,
    int pagesize = 30,
    bool noCache = false,
  }) async {
    final params = <String, dynamic>{
      'global_collection_id': globalCollectionId,
      'page': page,
      'pagesize': pagesize,
    };
    final json = await _get(
      KugouEndpoints.playlistTrackAll,
      queryParameters: params,
      noCache: noCache,
    );
    if (json == null) return null;
    try {
      return KugouPlaylistSongs.fromJson(json);
    } catch (e) {
            return null;
    }
  }

  Future<KugouPlaylistSongs?> getPlaylistSongsByListid({
    required String listid,
    int page = 1,
    int pagesize = 30,
    bool noCache = false,
  }) async {
    final params = <String, dynamic>{
      'listid': listid,
      'page': page,
      'pagesize': pagesize,
    };
    final json = await _get(
      KugouEndpoints.playlistTrackAllNew,
      queryParameters: params,
      noCache: noCache,
    );
    if (json == null) return null;
    try {
      return KugouPlaylistSongs.fromJson(json);
    } catch (e) {
            return null;
    }
  }

  Future<Map<String, dynamic>?> getPlaylistSimilar(String id) async {
    return await _get(
      KugouEndpoints.playlistSimilar,
      queryParameters: {'id': id},
    );
  }

  Future<Map<String, dynamic>?> getPlaylistEffect() async {
    return await _get(KugouEndpoints.playlistEffect);
  }

  Future<Map<String, dynamic>?> getPlaylistTags() async {
    return await _get(KugouEndpoints.playlistTags);
  }

  // ==================== Sheet ====================

  Future<Map<String, dynamic>?> getSheetExplore({int page = 1}) async {
    return await _get(
      KugouEndpoints.sheetExplore,
      queryParameters: {'page': page},
    );
  }

  Future<Map<String, dynamic>?> getSheetDetail(String id) async {
    return await _get(KugouEndpoints.sheetDetail, queryParameters: {'id': id});
  }

  Future<Map<String, dynamic>?> getSheetSong(String id) async {
    return await _get(KugouEndpoints.sheetSong, queryParameters: {'id': id});
  }

  Future<Map<String, dynamic>?> getSheetTags() async {
    return await _get(KugouEndpoints.sheetTags);
  }

  // ==================== Theme ====================

  Future<Map<String, dynamic>?> getThemeMusic() async {
    return await _get(KugouEndpoints.themeMusic);
  }

  Future<Map<String, dynamic>?> getThemeMusicDetail(String id) async {
    return await _get(
      KugouEndpoints.themeMusicDetail,
      queryParameters: {'id': id},
    );
  }

  Future<Map<String, dynamic>?> getThemePlaylist() async {
    return await _get(KugouEndpoints.themePlaylist);
  }

  Future<Map<String, dynamic>?> getThemePlaylistTrack(String id) async {
    return await _get(
      KugouEndpoints.themePlaylistTrack,
      queryParameters: {'id': id},
    );
  }

  // ==================== Rank ====================

  Future<KugouRankList?> getRankList({int withsong = 1}) async {
    final json = await _get(
      KugouEndpoints.rankList,
      queryParameters: {'withsong': withsong},
    );
    if (json == null) return null;
    try {
      return KugouRankList.fromJson(json);
    } catch (e) {
            return null;
    }
  }

  Future<Map<String, dynamic>?> getRankTop() async {
    return await _get(KugouEndpoints.rankTop);
  }

  Future<Map<String, dynamic>?> getRankVol(String rankId) async {
    return await _get(
      KugouEndpoints.rankVol,
      queryParameters: {'rankid': rankId},
    );
  }

  Future<Map<String, dynamic>?> getRankInfo(String rankId) async {
    return await _get(
      KugouEndpoints.rankInfo,
      queryParameters: {'rankid': rankId},
    );
  }

  Future<List<KugouSongDetail>?> getRankAudio({
    required String rankId,
    int rankCid = 0,
    int page = 1,
    int pagesize = 30,
  }) async {
    final json = await _get(
      KugouEndpoints.rankAudio,
      queryParameters: {
        'rankid': rankId,
        'rank_cid': rankCid,
        'page': page,
        'pagesize': pagesize,
      },
    );
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      final list =
          data['songlist'] ??
          data['list'] ??
          data['songs'] ??
          data['info'] ??
          [];
      return (list as List<dynamic>)
          .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
            return null;
    }
  }

  // ==================== Everyday ====================

  Future<List<KugouSongDetail>?> getRecommendDaily() async {
    final json = await _get(KugouEndpoints.everydayRecommend);
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      final list =
          data['song_list'] ??
          data['songs'] ??
          data['list'] ??
          data['info'] ??
          [];
      return (list as List<dynamic>)
          .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
            return null;
    }
  }

  Future<Map<String, dynamic>?> getEverydayHistory() async {
    return await _get(KugouEndpoints.everydayHistory);
  }

  Future<Map<String, dynamic>?> getEverydayStyleRecommend() async {
    return await _get(KugouEndpoints.everydayStyleRecommend);
  }

  // ==================== Top ====================

  Future<Map<String, dynamic>?> getTopAlbum({int page = 1}) async {
    return await _get(KugouEndpoints.topAlbum, queryParameters: {'page': page});
  }

  Future<Map<String, dynamic>?> getTopSong({int page = 1}) async {
    return await _get(KugouEndpoints.topSong, queryParameters: {'page': page});
  }

  // ==================== Yueku ====================

  Future<Map<String, dynamic>?> getYueku() async {
    return await _get(KugouEndpoints.yueku);
  }

  Future<Map<String, dynamic>?> getYuekuBanner() async {
    return await _get(KugouEndpoints.yuekuBanner);
  }

  Future<Map<String, dynamic>?> getYuekuFm() async {
    return await _get(KugouEndpoints.yuekuFm);
  }

  // ==================== IP (Edit Picks) ====================

  Future<Map<String, dynamic>?> getIpHome() async {
    return await _get(KugouEndpoints.ipHome);
  }

  Future<Map<String, dynamic>?> getIpDateil() async {
    return await _get(KugouEndpoints.ipDateil);
  }

  Future<Map<String, dynamic>?> getIpPlaylist() async {
    return await _get(KugouEndpoints.ipPlaylist);
  }

  Future<Map<String, dynamic>?> getIpZone() async {
    return await _get(KugouEndpoints.ipZone);
  }

  Future<Map<String, dynamic>?> getIpZoneHome(String zoneId) async {
    return await _get(
      KugouEndpoints.ipZoneHome,
      queryParameters: {'zone_id': zoneId},
    );
  }

  // ==================== FM (Radio) ====================

  Future<Map<String, dynamic>?> getFmRecommend() async {
    return await _get(KugouEndpoints.fmRecommend);
  }

  Future<Map<String, dynamic>?> getFmClass() async {
    return await _get(KugouEndpoints.fmClass);
  }

  Future<Map<String, dynamic>?> getFmImage() async {
    return await _get(KugouEndpoints.fmImage);
  }

  Future<Map<String, dynamic>?> getFmSongs(String fmId) async {
    return await _get(KugouEndpoints.fmSongs, queryParameters: {'id': fmId});
  }

  // ==================== Personal FM ====================

  Future<List<KugouSongDetail>?> getPersonalFm({
    String? mode,
    int? songPoolId,
    String? hash,
    String? songId,
    String? action,
  }) async {
    final params = <String, dynamic>{};
    if (mode != null) params['mode'] = mode;
    if (songPoolId != null) params['song_pool_id'] = songPoolId.toString();
    if (hash != null) params['hash'] = hash;
    if (songId != null) params['songid'] = songId;
    if (action != null) params['action'] = action;

    final json = await _get(KugouEndpoints.personalFm, queryParameters: params);
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      final list =
          data['song_list'] ??
          data['songs'] ??
          data['list'] ??
          data['info'] ??
          [];
      return (list as List<dynamic>)
          .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
            return null;
    }
  }

  // ==================== Scene ====================

  Future<Map<String, dynamic>?> getSceneLists() async {
    return await _get(KugouEndpoints.sceneLists);
  }

  Future<Map<String, dynamic>?> getSceneMusic() async {
    return await _get(KugouEndpoints.sceneMusic);
  }

  Future<Map<String, dynamic>?> getSceneModule(String moduleId) async {
    return await _get(
      KugouEndpoints.sceneModule,
      queryParameters: {'id': moduleId},
    );
  }

  Future<Map<String, dynamic>?> getSceneModuleInfo(String moduleId) async {
    return await _get(
      KugouEndpoints.sceneModuleInfo,
      queryParameters: {'id': moduleId},
    );
  }

  Future<Map<String, dynamic>?> getSceneCollectionList(String moduleId) async {
    return await _get(
      KugouEndpoints.sceneCollectionList,
      queryParameters: {'id': moduleId},
    );
  }

  Future<Map<String, dynamic>?> getSceneVideoList(String moduleId) async {
    return await _get(
      KugouEndpoints.sceneVideoList,
      queryParameters: {'id': moduleId},
    );
  }

  Future<Map<String, dynamic>?> getSceneAudioList(
    String moduleId, {
    String? collectionId,
  }) async {
    final params = <String, dynamic>{'id': moduleId};
    if (collectionId != null) params['collection_id'] = collectionId;
    return await _get(KugouEndpoints.sceneAudioList, queryParameters: params);
  }

  // ==================== Artist ====================

  Future<Map<String, dynamic>?> getSingerList({int page = 1}) async {
    return await _get(
      KugouEndpoints.singerList,
      queryParameters: {'page': page},
    );
  }

  Future<KugouArtistDetail?> getArtistDetail(String artistId) async {
    final json = await _get(
      KugouEndpoints.artistDetail,
      queryParameters: {'singerid': artistId},
    );
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      return KugouArtistDetail.fromJson(data);
    } catch (e) {
            return null;
    }
  }

  Future<KugouArtistAlbums?> getArtistAlbums(
    String artistId, {
    int page = 1,
    int pagesize = 30,
  }) async {
    final json = await _get(
      KugouEndpoints.artistAlbums,
      queryParameters: {
        'singerid': artistId,
        'page': page,
        'pagesize': pagesize,
      },
    );
    if (json == null) return null;
    try {
      return KugouArtistAlbums.fromJson(json);
    } catch (e) {
            return null;
    }
  }

  Future<KugouArtistAudios?> getArtistAudios(
    String artistId, {
    int page = 1,
    int pagesize = 30,
  }) async {
    final json = await _get(
      KugouEndpoints.artistAudios,
      queryParameters: {
        'singerid': artistId,
        'page': page,
        'pagesize': pagesize,
      },
    );
    if (json == null) return null;
    try {
      return KugouArtistAudios.fromJson(json);
    } catch (e) {
            return null;
    }
  }

  Future<Map<String, dynamic>?> getArtistVideos(String artistId) async {
    return await _get(
      KugouEndpoints.artistVideos,
      queryParameters: {'singerid': artistId},
    );
  }

  Future<Map<String, dynamic>?> followArtist(String artistId) async {
    return await _post(
      KugouEndpoints.artistFollow,
      data: {'singerid': artistId},
    );
  }

  Future<Map<String, dynamic>?> unfollowArtist(String artistId) async {
    return await _post(
      KugouEndpoints.artistUnfollow,
      data: {'singerid': artistId},
    );
  }

  Future<Map<String, dynamic>?> getFollowNewsongs() async {
    return await _get(KugouEndpoints.artistFollowNewsongs);
  }

  // ==================== Login ====================

  Future<Map<String, dynamic>?> loginByCellphone(
    String mobile,
    String code, {
    String? userid,
  }) async {
    final params = <String, dynamic>{'mobile': mobile, 'code': code};
    if (userid != null) params['userid'] = userid;
    return await _get(KugouEndpoints.loginCellphone, queryParameters: params);
  }

  Future<Map<String, dynamic>?> loginByUsername(
    String username,
    String password,
  ) async {
    return await _get(
      KugouEndpoints.login,
      queryParameters: {'username': username, 'password': password},
    );
  }

  Future<KugouQrKey?> getLoginQrKey() async {
    final json = await _get(
      KugouEndpoints.loginQrKey,
      queryParameters: {
        'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
      },
    );
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      return KugouQrKey.fromJson(data);
    } catch (e) {
            return null;
    }
  }

  Future<KugouQrCreate?> createLoginQr(String key) async {
    final json = await _get(
      KugouEndpoints.loginQrCreate,
      queryParameters: {
        'key': key,
        'qrimg': 'true',
        'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
      },
    );
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      return KugouQrCreate.fromJson(data);
    } catch (e) {
            return null;
    }
  }

  Future<KugouQrCheck?> checkLoginQr(String key) async {
    final json = await _get(
      KugouEndpoints.loginQrCheck,
      queryParameters: {
        'key': key,
        'timestamp': DateTime.now().millisecondsSinceEpoch.toString(),
      },
    );
    if (json == null) return null;
    try {
            return KugouQrCheck.fromJson(json);
    } catch (e) {
            return null;
    }
  }

  Future<Map<String, dynamic>?> refreshLogin({
    String? token,
    String? userid,
  }) async {
    final params = <String, dynamic>{};
    if (token != null) params['token'] = token;
    if (userid != null) params['userid'] = userid;
    return await _get(KugouEndpoints.loginToken, queryParameters: params);
  }

  // 发送手机验证码
  Future<Map<String, dynamic>?> sendLoginCaptcha(String mobile) async {
    return await _get(
      KugouEndpoints.captchaSent,
      queryParameters: {'mobile': mobile},
    );
  }

  // 开放平台登录 (微信 code 换取酷狗 token)
  Future<Map<String, dynamic>?> loginByOpenplat(String code) async {
    return await _get(
      KugouEndpoints.loginOpenplat,
      queryParameters: {'code': code},
    );
  }

  // 微信扫码 - 生成 uuid + 二维码
  Future<Map<String, dynamic>?> createLoginWx() async {
    return await _get(KugouEndpoints.loginWxCreate);
  }

  // 微信扫码 - 轮询状态
  Future<Map<String, dynamic>?> checkLoginWx(String uuid) async {
    return await _get(
      KugouEndpoints.loginWxCheck,
      queryParameters: {
        'uuid': uuid,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
    );
  }

  Future<bool> _tryRefreshToken() async {
    if (_token == null || _userid == null) return false;
    try {
            final result = await refreshLogin(token: _token, userid: _userid);
      if (result == null) {
                return false;
      }
      final status = result['status'];
      final data = result['data'] as Map<String, dynamic>?;
      if (status == 1 && data != null) {
        final newToken = data['token']?.toString();
        final newUserid = data['userid']?.toString();
        final newVipToken = data['vip_token']?.toString();
        if (newToken != null && newUserid != null) {
          await setLoginCookies(newToken, newUserid, vipToken: newVipToken);
                    return true;
        }
      }
            return false;
    } catch (e) {
            return false;
    }
  }

  Future<Map<String, dynamic>?> sendCaptcha(String mobile) async {
    return await _get(
      KugouEndpoints.captchaSent,
      queryParameters: {'mobile': mobile},
    );
  }

  // ==================== User ====================

  Future<KugouUserDetail?> getUserDetail() async {
    final json = await _get(KugouEndpoints.userDetail);
    if (json == null) return null;
    try {
      return KugouUserDetail.fromJson(json);
    } catch (e) {
            return null;
    }
  }

  Future<KugouUserVipDetail?> getUserVipDetail() async {
    final json = await _get(KugouEndpoints.userVipDetail);
    if (json == null) return null;
    try {
      return KugouUserVipDetail.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> getUserPlaylist({
    int page = 1,
    int pagesize = 30,
    int? type, // 0=歌单, 1=专辑
    bool noCache = false,
  }) async {
    final params = <String, dynamic>{
      'page': page,
      'pagesize': pagesize,
      if (isLoggedIn && userid != null) 'userid': userid!,
    };
    if (type != null) params['type'] = type;
    return await _get(
      KugouEndpoints.userPlaylist,
      queryParameters: params,
      noCache: noCache,
    );
  }

  Future<Map<String, dynamic>?> getUserFollow() async {
    return await _get(KugouEndpoints.userFollow);
  }

  Future<Map<String, dynamic>?> getUserFollowMessage(
    String userId, {
    int pagesize = 30,
  }) async {
    return await _get(
      KugouEndpoints.userFollowMessage,
      queryParameters: {'id': userId, 'pagesize': pagesize},
    );
  }

  Future<Map<String, dynamic>?> getUserCloudUrl(
    String hash, {
    String? albumId,
    String? name,
    String? albumAudioId,
  }) async {
    final params = <String, dynamic>{'hash': hash};
    if (albumId != null) params['album_id'] = albumId;
    if (name != null) params['name'] = name;
    if (albumAudioId != null) params['album_audio_id'] = albumAudioId;
    return await _get(KugouEndpoints.userCloudUrl, queryParameters: params);
  }

  Future<Map<String, dynamic>?> getUserVideoCollect({
    int page = 1,
    int pagesize = 30,
  }) async {
    return await _get(
      KugouEndpoints.userVideoCollect,
      queryParameters: {'page': page, 'pagesize': pagesize},
    );
  }

  Future<Map<String, dynamic>?> getUserVideoLove({int pagesize = 30}) async {
    return await _get(
      KugouEndpoints.userVideoLove,
      queryParameters: {'pagesize': pagesize},
    );
  }

  Future<Map<String, dynamic>?> getUserListen({int type = 0}) async {
    return await _get(
      KugouEndpoints.userListen,
      queryParameters: {'type': type},
    );
  }

  Future<Map<String, dynamic>?> getUserHistory() async {
    return await _get(KugouEndpoints.userHistory);
  }

  Future<Map<String, dynamic>?> uploadPlayHistory(
    String hash,
    String songName, {
    String? albumAudioId,
  }) async {
    final params = <String, dynamic>{
      'hash': hash,
      'songname': songName,
    };
    if (albumAudioId != null) params['album_audio_id'] = albumAudioId;
    return await _get(
      KugouEndpoints.playhistoryUpload,
      queryParameters: params,
    );
  }

  // ==================== Playlist Management ====================

  Future<Map<String, dynamic>?> createPlaylist(
    String name, {
    int type = 0,
    int isPri = 0,
    String? listCreateUserid,
    String? listCreateListid,
    String? globalCollectionId,
  }) async {
    String userid = listCreateUserid ?? _userid ?? '0';
    String listid = listCreateListid ?? '0';

    if (globalCollectionId != null && globalCollectionId.isNotEmpty) {
      final parts = globalCollectionId.split('_');
      if (parts.length >= 4) {
        userid = parts[2];
        listid = parts[3];
      }
    }

    final params = <String, dynamic>{
      'name': name,
      'type': type,
      'is_pri': isPri,
      'list_create_userid': userid,
      'list_create_listid': listid,
    };
    return await _get(KugouEndpoints.playlistAdd, queryParameters: params);
  }

  Future<Map<String, dynamic>?> deletePlaylist(String listid, {int type = 1}) async {
    return await _get(
      KugouEndpoints.playlistDel,
      queryParameters: {'listid': listid, 'type': type},
    );
  }

  Future<Map<String, dynamic>?> addPlaylistTracks(
    String listid,
    String data,
  ) async {
    return await _get(
      KugouEndpoints.playlistTracksAdd,
      queryParameters: {'listid': listid, 'data': data},
    );
  }

  Future<Map<String, dynamic>?> deletePlaylistTracks(
    String listid,
    String fileids,
  ) async {
    return await _get(
      KugouEndpoints.playlistTracksDel,
      queryParameters: {'listid': listid, 'fileids': fileids},
    );
  }

  Future<Map<String, dynamic>?> collectSheet(String specialId) async {
    return await _post(
      KugouEndpoints.sheetCollection,
      data: {'specialid': specialId},
    );
  }

  // ==================== Video ====================

  Future<Map<String, dynamic>?> getVideoUrl(String hash) async {
    return await _get(KugouEndpoints.videoUrl, queryParameters: {'hash': hash});
  }

  Future<Map<String, dynamic>?> getVideoDetail(String hash) async {
    return await _get(
      KugouEndpoints.videoDetail,
      queryParameters: {'hash': hash},
    );
  }

  Future<Map<String, dynamic>?> getVideoPrivilege(String hash) async {
    return await _get(
      KugouEndpoints.videoPrivilege,
      queryParameters: {'hash': hash},
    );
  }

  // ==================== Youth Channel ====================

  Future<Map<String, dynamic>?> getYouthChannels() async {
    return await _get(KugouEndpoints.youthChannelAll);
  }

  Future<Map<String, dynamic>?> getYouthChannelDetail(String channelId) async {
    return await _get(
      KugouEndpoints.youthChannelDetail,
      queryParameters: {'id': channelId},
    );
  }

  Future<Map<String, dynamic>?> getYouthChannelAmway() async {
    return await _get(KugouEndpoints.youthChannelAmway);
  }

  Future<Map<String, dynamic>?> getYouthChannelSimilar(String channelId) async {
    return await _get(
      KugouEndpoints.youthChannelSimilar,
      queryParameters: {'channelid': channelId},
    );
  }

  Future<Map<String, dynamic>?> subscribeYouthChannel(String channelId) async {
    return await _get(
      KugouEndpoints.youthChannelSub,
      queryParameters: {'channelid': channelId},
    );
  }

  Future<Map<String, dynamic>?> getYouthChannelSong(String channelId) async {
    return await _get(
      KugouEndpoints.youthChannelSong,
      queryParameters: {'channelid': channelId},
    );
  }

  Future<Map<String, dynamic>?> getYouthChannelSongDetail(
    String channelId,
  ) async {
    return await _get(
      KugouEndpoints.youthChannelSongDetail,
      queryParameters: {'id': channelId},
    );
  }

  // ==================== Long Audio ====================

  Future<Map<String, dynamic>?> getLongaudioDaily() async {
    return await _get(KugouEndpoints.longaudioDailyRecommend);
  }

  Future<Map<String, dynamic>?> getLongaudioRank() async {
    return await _get(KugouEndpoints.longaudioRankRecommend);
  }

  Future<Map<String, dynamic>?> getLongaudioVip() async {
    return await _get(KugouEndpoints.longaudioVipRecommend);
  }

  Future<Map<String, dynamic>?> getLongaudioWeek() async {
    return await _get(KugouEndpoints.longaudioWeekRecommend);
  }

  Future<Map<String, dynamic>?> getLongaudioAlbumDetail(String albumId) async {
    return await _get(
      KugouEndpoints.longaudioAlbumDetail,
      queryParameters: {'album_id': albumId},
    );
  }

  Future<Map<String, dynamic>?> getLongaudioAlbumAudios(String albumId) async {
    return await _get(
      KugouEndpoints.longaudioAlbumAudios,
      queryParameters: {'album_id': albumId},
    );
  }

  // ==================== Other ====================

  Future<Map<String, dynamic>?> getBrush() async {
    return await _get(KugouEndpoints.brush);
  }

  Future<Map<String, dynamic>?> getAiRecommend() async {
    return await _get(KugouEndpoints.aiRecommend);
  }

  Future<Map<String, dynamic>?> getServerNow() async {
    return await _get(KugouEndpoints.serverNow);
  }

  Future<Map<String, dynamic>?> getAlbumInfo(String albumId) async {
    return await _get(
      KugouEndpoints.albumInfo,
      queryParameters: {'album_id': albumId},
    );
  }

  Future<KugouAlbumDetail?> getAlbumDetail(String albumId) async {
    final json = await _get(
      KugouEndpoints.albumDetail,
      queryParameters: {'album_id': albumId},
    );
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      return KugouAlbumDetail.fromJson(data);
    } catch (e) {
            return null;
    }
  }

  Future<KugouAlbumSongs?> getAlbumSongs(
    String albumId, {
    int page = 1,
    int pagesize = 30,
  }) async {
    final json = await _get(
      KugouEndpoints.albumSongs,
      queryParameters: {
        'album_id': albumId,
        'page': page,
        'pagesize': pagesize,
      },
    );
    if (json == null) return null;
    try {
      return KugouAlbumSongs.fromJson(json);
    } catch (e) {
            return null;
    }
  }

  Future<List<KugouSongDetail>?> getPlaylistTrackAll({
    required String id,
    int page = 1,
    int pagesize = 30,
  }) async {
    final params = <String, dynamic>{
      'global_collection_id': id,
      'page': page,
      'pagesize': pagesize,
    };
    final json = await _get(
      KugouEndpoints.playlistTrackAll,
      queryParameters: params,
    );
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      final list = data['list'] ?? data['songs'] ?? data['info'] ?? [];
      return (list as List<dynamic>)
          .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
            return null;
    }
  }

  Future<List<KugouSongDetail>?> getPlaylistTrackAllNew({
    required String listid,
    int page = 1,
    int pagesize = 30,
  }) async {
    final json = await _get(
      KugouEndpoints.playlistTrackAllNew,
      queryParameters: {
        'listid': listid,
        'page': page,
        'pagesize': pagesize,
      },
    );
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      final list = data['list'] ?? data['songs'] ?? data['info'] ?? [];
      return (list as List<dynamic>)
          .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
            return null;
    }
  }

  Future<List<KugouSongDetail>?> getLastestSongsListen() async {
    final json = await _get(KugouEndpoints.lastestSongsListen);
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      final list = data['list'] ?? data['songs'] ?? data['info'] ?? [];
      return (list as List<dynamic>)
          .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> getYouthListenSong() async {
    return await _get(KugouEndpoints.youthListenSong);
  }

  Future<Map<String, dynamic>?> getYouthUserSong(String userId) async {
    return await _get(
      KugouEndpoints.youthUserSong,
      queryParameters: {'userid': userId},
    );
  }

  Future<Map<String, dynamic>?> getYouthDynamic() async {
    return await _get(KugouEndpoints.youthDynamic);
  }

  Future<Map<String, dynamic>?> getYouthDynamicRecent() async {
    return await _get(KugouEndpoints.youthDynamicRecent);
  }

  Future<Map<String, dynamic>?> getPrivilegeLite(String hash) async {
    return await _get(
      KugouEndpoints.privilegeLite,
      queryParameters: {'hash': hash},
    );
  }

  Future<Map<String, dynamic>?> getAlbumShop(String albumId) async {
    return await _get(
      KugouEndpoints.albumShop,
      queryParameters: {'album_id': albumId},
    );
  }

  Future<Map<String, dynamic>?> getArtistLists(String artistId) async {
    return await _get(
      KugouEndpoints.artistLists,
      queryParameters: {'singerid': artistId},
    );
  }

  Future<Map<String, dynamic>?> getArtistHonour(String artistId) async {
    return await _get(
      KugouEndpoints.artistHonour,
      queryParameters: {'singerid': artistId},
    );
  }

  Future<Map<String, dynamic>?> getPcDiantai() async {
    return await _get(KugouEndpoints.pcDiantai);
  }

  Future<Map<String, dynamic>?> getImages(String hash) async {
    return await _get(KugouEndpoints.images, queryParameters: {'hash': hash});
  }

  Future<Map<String, dynamic>?> getImagesAudio(String hash) async {
    return await _get(
      KugouEndpoints.imagesAudio,
      queryParameters: {'hash': hash},
    );
  }

  Future<Map<String, dynamic>?> getKrmAudio(String hash) async {
    return await _get(KugouEndpoints.krmAudio, queryParameters: {'hash': hash});
  }

  Future<Map<String, dynamic>?> getKmrAudioMv(String hash) async {
    return await _get(
      KugouEndpoints.kmrAudioMv,
      queryParameters: {'hash': hash},
    );
  }

  Future<Map<String, dynamic>?> getAudioAccompany(String hash) async {
    return await _get(
      KugouEndpoints.audioAccompany,
      queryParameters: {'hash': hash},
    );
  }

  Future<Map<String, dynamic>?> getAudioKtvTotal(String hash) async {
    return await _get(
      KugouEndpoints.audioKtvTotal,
      queryParameters: {'hash': hash},
    );
  }

  Future<Map<String, dynamic>?> getYouthVip() async {
    return await _get(KugouEndpoints.youthVip);
  }

  Future<Map<String, dynamic>?> getYouthUnionVip() async {
    return await _get(KugouEndpoints.youthUnionVip);
  }

  Future<Map<String, dynamic>?> claimDayVip(String receiveDay) async {
    // 还原到最初项目的签到架构：优先调用 /youth/day/vip（需传 receive_day）。
    // 若该接口已被酷狗停用（error_code 20028 等拒领码）或请求失败，
    // 自动回退到可用的 /youth/vip，保证手动/自动签到仍能完成。
    final primary = await _post(
      KugouEndpoints.youthDayVip,
      data: {'receive_day': receiveDay},
    );
    final errCode = primary?['error_code'] as int?;
    final isRefusedOrFailed = primary == null || errCode == 20028;
    if (!isRefusedOrFailed) {
      return primary; // 成功 / 今日已签到 等正常响应，直接返回
    }
    try {
      final fallback = await _post(KugouEndpoints.youthVip, data: {});
      if (fallback != null) return fallback;
    } catch (_) {}
    return primary; // 回退也失败，返回原始响应供上层提示
  }

  Future<Map<String, dynamic>?> upgradeDayVip() async {
        return await _post(KugouEndpoints.youthDayVipUpgrade);
  }

  Future<Map<String, dynamic>?> getYouthMonthVipRecord({String? month}) async {
    final query = <String, dynamic>{};
    if (month != null && month.isNotEmpty) {
      query['month'] = month;
    }
    return await _get(
      KugouEndpoints.youthMonthVipRecord,
      queryParameters: query.isNotEmpty ? query : null,
    );
  }
}
