import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/kugou_account.dart';
import '../../data/models/mv_models.dart';
import 'kugou_endpoints.dart';
import 'kugou_models.dart';

/// 一次广告领取（/youth/vip → /youth/v1/ad/play_report）的判定结果。
enum AdClaimOutcome {
  /// 领取成功（status == 1），可继续下一轮
  success,

  /// 今日次数已用光（error_code == 30002），正常停止
  quotaDone,

  /// 领取失败（其他错误码或响应为空），停止并上报
  failure,
}

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

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: _onRequest,
      onResponse: (response, handler) {
        // dio 拿到了响应（无论 statusCode），视为服务端可达
        networkReachable.value = true;
        handler.next(response);
      },
      onError: (e, handler) {
        // 只有连接类错误才算"服务端不可达"；
        // 4xx/5xx 业务错误（如未登录）仍然代表网络可达
        if (e is DioException && _isConnectionError(e)) {
          networkReachable.value = false;
        }
        handler.next(e);
      },
    ));

    _initFromStorage();
  }

  /// 全局网络可达性状态。任意 dio 请求成功 → true；连接类错误 → false。
  /// 业务错误（4xx/5xx）不影响此值。
  /// FavoritesPage 等页面用它实时反映 banner 显示。
  static final ValueNotifier<bool> networkReachable = ValueNotifier(true);

  static bool _isConnectionError(DioException e) {
    return e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout;
  }

  late final Dio _dio;

  /// 暴露 Dio 实例供外部使用（如封面资源下载）。
  Dio get dio => _dio;

  String? _token;
  String? _userid;
  String? _vipToken;
  String? _dfid;
  bool _isInitialized = false;
  Completer<void>? _initCompleter;

  // ==================== 多账号管理 ====================
  /// 账号列表持久化键：JSON 序列化的 [KugouAccount] 数组。
  static const String _kAccountsKey = 'kugou_accounts';

  /// 等待 `_initFromStorage` 完成。
  ///
  /// `_initFromStorage` 在构造函数中异步启动（fire-and-forget），其旧版兼容
  /// 分支会重写内存 `_token`/`_userid`。若在初始化完成前调用登录/切换等方法，
  /// 会被随后完成的初始化覆盖。此处统一等待初始化完成后再操作，消除竞态。
  Future<void> _ensureInitialized() async {
    if (!_isInitialized) {
      await _initCompleter?.future;
    }
  }

  /// 已保存的账号摘要列表（按最近登录时间倒序）。
  final List<KugouAccount> _accounts = [];

  /// 只读暴露账号列表（调用方不得直接修改）。
  List<KugouAccount> get savedAccounts => List.unmodifiable(_accounts);

  /// 最近登录时间倒序排序后的账号列表（供 UI 展示与自动切换）。
  List<KugouAccount> get sortedAccounts {
    final list = List<KugouAccount>.of(_accounts)
      ..sort((a, b) => b.loginTime.compareTo(a.loginTime));
    return list;
  }

  /// 本地 API 服务器（Rust）就绪信号。
  ///
  /// P0: main.dart 已改为「runApp 不等待服务器启动」——so 加载与 UI 首帧并行。
  /// 首屏请求（发现页等）在服务器就绪前发出会连接拒绝失败，因此
  /// 拦截器在 `_serverReady` 完成前 await 它，就绪后自动放行。
  /// 由 [KugouApiServer] 在 TCP 探测成功（_waitForReady）后调用 [markServerReady]。
  static final Completer<void> _serverReady = Completer<void>();
  static bool _serverReadyMarked = false;

  /// 本地 API 服务器启动已明确失败（桌面缺 kugou_server.dll、端口 10 次全部
  /// 占用等）。此时 [_serverReady] 永远不会完成，若仍逐请求 await 其 8s 超时，
  /// 每个请求都要白等满 8 秒才失败（观感即"延迟极高"）。置位后直接快速失败。
  static bool _serverStartFailed = false;

  /// 标记本地 API 服务器已就绪（幂等，可重复调用）。
  static void markServerReady() {
    // restart() 成功时清除失败态，重新按就绪信号放行。
    _serverStartFailed = false;
    localServerAvailable.value = true;
    if (_serverReadyMarked) return;
    _serverReadyMarked = true;
    _serverReady.complete();
  }

  /// 标记本地 API 服务器启动失败。由 [KugouApiServer] 在所有启动路径都失败后
  /// 调用；已就绪时忽略（restart 中途的瞬时失败不该让已可用的服务器被判死）。
  static void markServerStartFailed() {
    if (_serverReadyMarked) return;
    _serverStartFailed = true;
    // 判据与拦截器短路一致：_applyPort 先于 TCP 就绪探测写入 baseUrl，
    // 慢设备上"探测超时但端口有效"的请求仍会成功，不该弹提示；
    // 只有连端口都没拿到（dlopen 失败等）才是真的不可用。
    localServerAvailable.value = KugouEndpoints.hasBaseUrl;
  }

  /// 本地 API 服务器可用性。启动失败（桌面缺 kugou_server.dll、端口全占用等）
  /// 时置 false，UI 据此显示"本地数据接口未启动"提示——否则用户只能看到
  /// 一片加载不出来的空页面，无从判断是网络问题还是安装包残缺。
  /// 初值 true：正常启动过程中不闪提示。
  static final ValueNotifier<bool> localServerAvailable = ValueNotifier(true);

  /// 服务器就绪 Future（带超时保护：启动失败时请求不会永久挂起）。
  static Future<void> get serverReady => _serverReady.future;

  void _onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (!_isInitialized) {
      await _initCompleter?.future;
    }

    // P0: 等待本地 API 服务器就绪。带 8s 超时：
    // 服务器异常时继续请求（失败由调用方处理），避免首屏永久转圈。
    // 启动已明确失败时跳过等待：_serverReady 永不完成，逐请求 await 会让
    // 每个请求都白等满 8s（Windows 缺 dll 时的"延迟极高"就是这么来的）。
    if (!_serverReadyMarked && !_serverStartFailed) {
      try {
        await serverReady.timeout(const Duration(seconds: 8));
      } catch (_) {}
    }

    // 登录等全部请求统一走本地 API 服务器（Rust），不再依赖第三方云端
    options.baseUrl = KugouEndpoints.baseUrl;

    // 关键修复：每次请求前验证用户身份
    // /images 接口不需要登录态，带 token 会导致上游返回不同响应（缺少 imgs 字段）
    final skipAuth = options.path.contains('/images');
    if (_token != null && _userid != null && !skipAuth) {
      // 把 vip_token 一并写入 Authorization，服务端的 cookieToJson
      // 会按 ; 切成 cookie 对象，song_url_new 等模块可直接读取。
      final authParts = <String>['token=$_token', 'userid=$_userid'];
      if (_vipToken != null && _vipToken!.isNotEmpty) {
        authParts.add('vip_token=$_vipToken');
      }
      options.headers['Authorization'] = authParts.join(';');

      // 已认证的请求绕过 Rust apicache：其缓存 key 不含 token，
      // 切账号后用户态接口会命中旧账号缓存（昵称/头像/VIP/歌单等串号）。
      options.headers['x-apicache-bypass'] = '1';
      options.headers['Cache-Control'] = 'no-cache';
    } else {
      // 未登录或 /images 路径，清除 Authorization 头
      options.headers.remove('Authorization');
    }

    // /images 也不注入 dfid（避免上游按 dfid 返回不同响应）
    if (_dfid != null && !skipAuth) {
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

  /// 服务器随机端口就绪后更新 baseUrl。不清登录态、不重新注册设备。
  void updateBaseUrl(String url) {
    final cleanUrl = url.replaceAll(RegExp(r'/+$'), '');
    KugouEndpoints.baseUrl = cleanUrl;
    _dio.options.baseUrl = cleanUrl;
  }

  void setBaseUrl(String url) {
    updateBaseUrl(url);
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
      print(
        '[API _get] Non-200 or non-map: path=$path status=${response.statusCode} data=${response.data}',
      );
      return null;
    } on DioException catch (e) {
      print(
        '[API _get] DioException: url=${e.requestOptions.uri} err=${e.type} response=${e.response?.statusCode} ${e.response?.data}',
      );
      return null;
    } catch (e) {
      print('[API _get] Error: $e');
      return null;
    }
  }

  /// 允许非 200 状态码的 GET（用于登录等场景：Rust 服务端把上游业务错误
  /// 如"手机号多账号"（error_code=34175）包装成 HTTP 502，但 body 里带
  /// `data.info_list` 账号列表，需读取而非丢弃）。
  Future<Map<String, dynamic>?> _getAllowNonOk(
    String path, {
    Map<String, dynamic>? queryParameters,
    bool noCache = false,
  }) async {
    try {
      final response = await _dio.get(
        path,
        queryParameters: queryParameters,
        options: Options(
          extra: {'noCache': noCache},
          validateStatus: (_) => true,
        ),
      );
      if (response.data is Map<String, dynamic>) {
        return response.data as Map<String, dynamic>;
      }
      return null;
    } on DioException catch (e) {
      // 连接类错误无响应体 → null；有响应体则返回（如 502 业务包装）
      final body = e.response?.data;
      if (body is Map<String, dynamic>) {
        return body;
      }
      print(
        '[API _getAllowNonOk] DioException: ${e.type} ${e.message} response=${e.response?.statusCode}',
      );
      return null;
    } catch (e) {
      print('[API _getAllowNonOk] Error: $e');
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
      print(
        '[API _post] Non-200 or non-map: status=${response.statusCode} data=${response.data}',
      );
      return null;
    } on DioException catch (e) {
      print(
        '[API _post] DioException: ${e.type} ${e.message} response=${e.response?.statusCode} ${e.response?.data}',
      );
      // 酷狗服务器在 4xx/5xx 响应体中通常仍返回 JSON（含 error_code），
      // 保留这些信息供调用方判断业务错误
      if (e.response?.data is Map<String, dynamic>) {
        return e.response?.data as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      print('[API _post] Error: $e');
      return null;
    }
  }

  /// 发送二进制 POST 请求（用于听歌识曲等接口）
  /// 使用 http 包直接发送，避免 Dio 把 Uint8List JSON 序列化成数组
  Future<Map<String, dynamic>?> _postBinary(
    String path, {
    required Uint8List body,
    Map<String, dynamic>? queryParameters,
  }) async {
    try {
      // 构建 URL
      var url = '${KugouEndpoints.baseUrl}$path';
      if (queryParameters != null && queryParameters.isNotEmpty) {
        final qs = queryParameters.entries
            .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value.toString())}')
            .join('&');
        url = '$url?$qs';
      }
      final headers = <String, String>{
        'Content-Type': 'application/octet-stream',
      };
      // 添加认证信息（与 Dio 请求一致）
      if (_token != null && _userid != null) {
        final cookieParts = <String>['token=$_token', 'userid=$_userid'];
        if (_dfid != null) cookieParts.add('dfid=$_dfid');
        headers['cookie'] = cookieParts.join(';');
        headers['Authorization'] = cookieParts.join(';');
      }
      final response = await http
          .post(
            Uri.parse(url),
            headers: headers,
            body: body,
          )
          // 上传大文件（云盘上传）耗时可长达数分钟，加超时兜底，
          // 避免服务器异常时前端永久挂起（批量上传卡在某一首）。
          .timeout(const Duration(minutes: 5));
      // 酷狗指纹接口在"未匹配"时返回 502 + JSON body（含 error_code），
      // 需要解析 body 以区分"未识别"和"真正的服务错误"
      try {
        final json = jsonDecode(response.body);
        if (json is Map<String, dynamic>) {
          return json;
        }
      } catch (_) {}
      print('[API _postBinary] Non-JSON body: status=${response.statusCode} body=${response.body.substring(0, response.body.length.clamp(0, 200))}');
      return null;
    } catch (e) {
      print('[API _postBinary] Error: $e');
      return null;
    }
  }

  Future<void> _initFromStorage() async {
    _initCompleter = Completer<void>();
    try {
      final prefs = await SharedPreferences.getInstance();
      // 敏感凭证（token/vip_token）从加密存储（Android Keystore）读取
      const secure = FlutterSecureStorage();

      // 读取已保存的账号列表（多账号）
      _accounts
        ..clear()
        ..addAll(KugouAccount.decodeList(prefs.getString(_kAccountsKey)));

      // 先读取当前登录的用户ID
      final currentUserid = prefs.getString('kugou_current_userid');

      if (currentUserid != null && currentUserid.isNotEmpty) {
        final userIdKey = 'kugou_userid_$currentUserid';

        // token/vip_token 从加密存储读取；userid 仍用 prefs（非机密、用于定位账号）
        _token = await secure.read(key: 'kugou_token_$currentUserid');
        _userid = prefs.getString(userIdKey);
        _vipToken = await secure.read(key: 'kugou_vip_token_$currentUserid');

        // 兼容旧版本明文存储：加密存储无值但存在明文 token → 迁移并删除明文
        final legacyToken = prefs.getString('kugou_token_$currentUserid');
        if (_token == null && legacyToken != null) {
          _token = legacyToken;
          await secure.write(
              key: 'kugou_token_$currentUserid', value: legacyToken);
          await prefs.remove('kugou_token_$currentUserid');
        }
        final legacyVip = prefs.getString('kugou_vip_token_$currentUserid');
        if (_vipToken == null && legacyVip != null) {
          _vipToken = legacyVip;
          await secure.write(
              key: 'kugou_vip_token_$currentUserid', value: legacyVip);
          await prefs.remove('kugou_vip_token_$currentUserid');
        }

        if (_token != null && _userid != null) {
          // 登录状态恢复成功
        } else {
          // 凭证不完整，清除残留状态
          _token = null;
          _userid = null;
          _vipToken = null;
        }
      } else {
        // 兼容旧版本：读取全局明文键，并迁移到按 userid 隔离的加密存储
        _token = prefs.getString('kugou_token');
        _userid = prefs.getString('kugou_userid');
        _vipToken = prefs.getString('kugou_vip_token');

        if (_token != null && _userid != null && _userid!.isNotEmpty) {
          final uid = _userid!;
          await secure.write(key: 'kugou_token_$uid', value: _token!);
          if (_vipToken != null && _vipToken!.isNotEmpty) {
            await secure.write(
                key: 'kugou_vip_token_$uid', value: _vipToken!);
          }
          await prefs.setString('kugou_userid_$uid', uid);
          await prefs.setString('kugou_current_userid', uid);
          // 删除全局明文凭证（保留 kugou_dfid，非机密且下方还需读取）
          await prefs.remove('kugou_token');
          await prefs.remove('kugou_userid');
          await prefs.remove('kugou_vip_token');
        }

        // 旧版本迁移：全局凭证存在且账号列表为空时，播种一个账号条目，
        // 保证老用户升级后账号出现在「账号管理」列表（昵称/头像留空，
        // 待 _autoConnect 拉取用户信息后回填）。
        if (_token != null &&
            _userid != null &&
            _userid!.isNotEmpty &&
            _accounts.isEmpty) {
          _accounts.add(
            KugouAccount(
              userid: _userid!,
              loginTime: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            ),
          );
          await prefs.setString(
            _kAccountsKey,
            KugouAccount.encodeList(_accounts),
          );
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
    // 多账号：登录新账号时**不再**清除其他账号的凭证，
    // 只把该账号写入按 userid 隔离的键，并维护账号列表与当前账号。

    // 等待 _initFromStorage 完成，避免其旧版分支覆盖本方法刚写入的内存凭证
    await _ensureInitialized();

    _token = token;
    _userid = userid;
    _vipToken = vipToken;

    try {
      final prefs = await SharedPreferences.getInstance();
      // 敏感凭证（token/vip_token）写入加密存储（Keystore），
      // userid/账号列表等非机密数据仍用 prefs（用于定位与展示）
      const secure = FlutterSecureStorage();

      // 仅清除旧版本全局键（一次性迁移清理，不碰其他账号的按用户键）
      await prefs.remove('kugou_token');
      await prefs.remove('kugou_userid');
      await prefs.remove('kugou_vip_token');
      await prefs.remove('kugou_dfid');

      // 使用带用户ID的键名存储（防止多用户冲突）
      final userIdKey = 'kugou_userid_$userid';
      final currentUserKey = 'kugou_current_userid';

      // token / vip_token → 加密存储；vipToken 为空时清除旧值
      await secure.write(key: 'kugou_token_$userid', value: token);
      if (vipToken != null && vipToken.isNotEmpty) {
        await secure.write(key: 'kugou_vip_token_$userid', value: vipToken);
      } else {
        await secure.delete(key: 'kugou_vip_token_$userid');
      }
      // 清除该账号历史明文 token（旧版本迁移遗留）
      await prefs.remove('kugou_token_$userid');
      await prefs.remove('kugou_vip_token_$userid');

      await prefs.setString(userIdKey, userid);

      // 记录当前登录的用户ID
      await prefs.setString(currentUserKey, userid);

      // 维护账号列表：已存在则更新登录时间并清除过期标记，否则新增条目
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final idx = _accounts.indexWhere((a) => a.userid == userid);
      if (idx >= 0) {
        _accounts[idx] = _accounts[idx].copyWith(loginTime: now, expired: false);
      } else {
        _accounts.add(KugouAccount(userid: userid, loginTime: now));
      }
      await prefs.setString(_kAccountsKey, KugouAccount.encodeList(_accounts));
    } catch (e) {
      print('❌ [Auth] 保存登录状态失败: $e');
    }
  }

  /// 切换到指定账号（读取其按 userid 隔离的凭证写入内存 + 更新当前账号）。
  /// 返回是否切换成功（凭证不完整时返回 false）。
  Future<bool> switchToUser(String userid) async {
    await _ensureInitialized();
    try {
      final prefs = await SharedPreferences.getInstance();
      // 凭证从加密存储读取
      const secure = FlutterSecureStorage();
      final userIdKey = 'kugou_userid_$userid';

      final token = await secure.read(key: 'kugou_token_$userid');
      final uid = prefs.getString(userIdKey);
      if (token == null || uid == null || uid.isEmpty) return false;

      _token = token;
      _userid = uid;
      _vipToken = await secure.read(key: 'kugou_vip_token_$userid');

      await prefs.setString('kugou_current_userid', uid);
      return true;
    } catch (e) {
      print('❌ [Auth] 切换账号失败: $e');
      return false;
    }
  }

  /// 标记账号登录态已过期（切换时校验 token 失败）。
  /// 过期账号在账号管理列表显示「登录已过期」，重新登录成功后由
  /// [setLoginCookies] 清除该标记。
  Future<void> markAccountExpired(String userid) async {
    if (userid.isEmpty) return;
    await _ensureInitialized();
    final idx = _accounts.indexWhere((a) => a.userid == userid);
    if (idx < 0) return;
    if (_accounts[idx].expired) return;
    _accounts[idx] = _accounts[idx].copyWith(expired: true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAccountsKey, KugouAccount.encodeList(_accounts));
    } catch (e) {
      print('❌ [Auth] 保存过期标记失败: $e');
    }
  }

  /// 更新账号列表中的昵称/头像（用于登录后回填展示信息）。
  Future<void> updateAccountProfile(
    String userid, {
    String? nickname,
    String? avatar,
  }) async {
    if (userid.isEmpty) return;
    await _ensureInitialized();
    final idx = _accounts.indexWhere((a) => a.userid == userid);
    if (idx < 0) return;
    final current = _accounts[idx];
    if ((nickname == null || nickname == current.nickname) &&
        (avatar == null || avatar == current.avatar)) {
      return;
    }
    _accounts[idx] = current.copyWith(nickname: nickname, avatar: avatar);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAccountsKey, KugouAccount.encodeList(_accounts));
    } catch (e) {
      print('❌ [Auth] 保存账号资料失败: $e');
    }
  }

  /// 删除指定账号：移除其按 userid 隔离的凭证与账号列表条目。
  /// 若删除的是当前账号，同时清空内存凭证与 `kugou_current_userid`。
  Future<void> removeAccount(String userid) async {
    await _ensureInitialized();
    try {
      final prefs = await SharedPreferences.getInstance();
      const secure = FlutterSecureStorage();
      // 清除加密存储中的凭证 + prefs 中的 userid 定位键与明文遗留
      await secure.delete(key: 'kugou_token_$userid');
      await secure.delete(key: 'kugou_vip_token_$userid');
      await prefs.remove('kugou_token_$userid');
      await prefs.remove('kugou_userid_$userid');
      await prefs.remove('kugou_vip_token_$userid');

      _accounts.removeWhere((a) => a.userid == userid);
      await prefs.setString(_kAccountsKey, KugouAccount.encodeList(_accounts));

      if (_userid == userid) {
        _token = null;
        _userid = null;
        _vipToken = null;
        await prefs.remove('kugou_current_userid');
      }
    } catch (e) {
      print('❌ [Auth] 删除账号失败: $e');
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
      const secure = FlutterSecureStorage();

      // 清除当前用户的加密凭证 + prefs 定位键（加密存储无旧全局键，无需清除）
      if (oldUserid != null) {
        await secure.delete(key: 'kugou_token_$oldUserid');
        await secure.delete(key: 'kugou_vip_token_$oldUserid');
        await prefs.remove('kugou_token_$oldUserid');
        await prefs.remove('kugou_userid_$oldUserid');
        await prefs.remove('kugou_vip_token_$oldUserid');
      }

      // 清除全局键（兼容旧版本，新版本加密存储无这些键）
      await prefs.remove('kugou_token');
      await prefs.remove('kugou_userid');
      await prefs.remove('kugou_vip_token');
      await prefs.remove('kugou_dfid');
      await prefs.remove('kugou_current_userid');

      // 多账号：全清时同时清空账号列表
      _accounts.clear();
      await prefs.remove(_kAccountsKey);
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
    } catch (e) {}
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
    final params = <String, dynamic>{
      'keywords': keywords,
      'page': page,
      'pagesize': pagesize,
      'type': type,
    };
    // 搜索接口需要 cookie 认证
    if (_token != null && _userid != null) {
      final cookieParts = <String>['token=$_token', 'userid=$_userid'];
      if (_dfid != null) cookieParts.add('dfid=$_dfid');
      params['cookie'] = cookieParts.join(';');
    }
    final json = await _get(
      KugouEndpoints.search,
      queryParameters: params,
    );
    if (json == null) return null;
    try {
      return KugouSearchResult.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  Future<List<KugouAlbumBrief>?> searchAlbums(
    String keywords, {
    int page = 1,
    int pagesize = 20,
  }) async {
    final params = <String, dynamic>{
      'keyword': keywords,
      'page': page,
      'pagesize': pagesize,
    };
    // 搜索接口需要 cookie 认证
    if (_token != null && _userid != null) {
      final cookieParts = <String>['token=$_token', 'userid=$_userid'];
      if (_dfid != null) cookieParts.add('dfid=$_dfid');
      params['cookie'] = cookieParts.join(';');
    }
    final json = await _get(
      KugouEndpoints.searchAlbum,
      queryParameters: params,
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
      final albums = list
          .map((e) => KugouAlbumBrief.fromJson(e as Map<String, dynamic>))
          .toList();
      return albums;
    } catch (e) {
      print('[SearchAlbums] parse error: $e');
      return null;
    }
  }

  Future<List<KugouPlaylistBrief>?> searchPlaylists(
    String keywords, {
    int page = 1,
    int pagesize = 20,
  }) async {
    final json = await _get(
      KugouEndpoints.searchSpecial,
      queryParameters: {
        'keyword': keywords,
        'page': page,
        'pagesize': pagesize,
      },
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

  Future<List<KugouArtistBrief>?> searchArtists(
    String keywords, {
    int page = 1,
    int pagesize = 20,
  }) async {
    final json = await _get(
      KugouEndpoints.searchArtist,
      queryParameters: {
        'keyword': keywords,
        'page': page,
        'pagesize': pagesize,
      },
    );
    if (json == null) return null;
    try {
      final data = json['data'];
      List<dynamic> list = [];
      if (data is List) {
        list = data;
      } else if (data is Map) {
        list = data['info'] ?? data['list'] ?? data['artists'] ?? [];
      }
      return list
          .map((e) => KugouArtistBrief.fromJson(e as Map<String, dynamic>))
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
    bool downgrade = true,
    String? ppageId,
  }) async {
    final params = <String, dynamic>{
      'hash': hash.toLowerCase(),
      'quality': quality,
    };
    if (albumId != null) params['album_id'] = albumId;
    if (albumAudioId != null) params['album_audio_id'] = albumAudioId;
    if (ppageId != null) params['ppage_id'] = ppageId;

    // VIP 用户优先用 /song/url/new（→ /v6/priv_url），它会读取
    // Authorization 头里的 vip_token，能拿到完整音质。
    // 如果 _getSongUrlNew 因 priv_status=0 / fail_process 等返回 null，
    // 继续走 /song/url 兜底，让 ppage_id（收藏页）有机会解锁已收藏的无版权歌曲。
    if (hasVipToken) {
      final vipUrl = await _getSongUrlNew(
        hash,
        quality: quality,
        albumId: albumId,
        albumAudioId: albumAudioId,
      );
      if (vipUrl != null) return vipUrl;
      // 不再直接 return null，继续走 /song/url 兜底
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
      // 先检查 fail_process：上游返回 fail_process: ['buy'] 时，
      // 说明该音质需要购买/VIP，返回的 URL 实际是试听片段。
      // 必须在此处拦截，不能让 data['url'] 检查抢先返回试听 URL。
      final failProcess = data['fail_process'];
      if (failProcess is List &&
          failProcess.contains('buy') &&
          quality != KugouQuality.standard) {
        if (downgrade) {
          // 降级到标准音质重新请求
          params['quality'] = KugouQuality.standard;
          json = await _get(KugouEndpoints.songUrl, queryParameters: params);
          if (json != null) {
            final fallbackData = _extractData(json['data'] ?? json);
            if (fallbackData['url'] != null) {
              return KugouPlayUrl.fromJson(fallbackData);
            }
          }
        }
        // 不降级则返回 null，让上层调用者处理降级
        return null;
      }

      if (data['url'] != null) {
        return KugouPlayUrl.fromJson(data);
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
          final trial = KugouPlayUrl.fromJson(freeData);
          return KugouPlayUrl(
            url: trial.url,
            fileSize: trial.fileSize,
            bitRate: trial.bitRate,
            quality: trial.quality,
            isTrial: true,
          );
        }
      }
    } catch (e) {}
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
    } catch (e) {}
    return null;
  }

  /// 根据请求音质返回降级链。
  /// 例如 'high' → ['high', 'flac', '320', '128']
  List<String> _getDowngradeChain(String quality) {
    switch (quality) {
      case KugouQuality.hires: // 'high'
        return [KugouQuality.hires, KugouQuality.lossless, KugouQuality.high, KugouQuality.standard];
      case KugouQuality.lossless: // 'flac'
        return [KugouQuality.lossless, KugouQuality.high, KugouQuality.standard];
      case KugouQuality.high: // '320'
        return [KugouQuality.high, KugouQuality.standard];
      default:
        return [KugouQuality.standard];
    }
  }

  /// 带自动降级的获取播放链接。
  ///
  /// 当请求的音质不可用时，按降级链依次尝试更低音质，
  /// 直到获取到可用链接或全部尝试完毕。
  /// 返回的 KugouPlayUrl 中 quality 字段反映实际获取到的音质。
  Future<KugouPlayUrl?> getSongUrlWithFallback(
    String hash, {
    String quality = KugouQuality.standard,
    String? albumId,
    String? albumAudioId,
  }) async {
    final chain = _getDowngradeChain(quality);

    for (final q in chain) {
      try {
        final result = await getSongUrl(
          hash,
          quality: q,
          albumId: albumId,
          albumAudioId: albumAudioId,
          downgrade: false,
        );
        // 跳过试听结果：非 VIP 用户在高等级音质请求时，getSongUrl 内部的
        // free_part=1 兜底可能返回 30s 试听 URL。如果在此处接受试听结果，
        // 降级链会被短路——更低音质的完整播放链接永远不会被尝试。
        // 试听兜底统一在本方法末尾（所有音质都尝试完毕后）执行。
        if (result != null && result.url.isNotEmpty && !result.isTrial) {
          // 用实际请求的音质覆盖返回值中的 quality 字段
          return KugouPlayUrl(
            url: result.url,
            fileSize: result.fileSize,
            bitRate: result.bitRate,
            quality: q,
            isTrial: false,
          );
        }
      } catch (_) {}
    }

    // 已收藏无版权歌曲兜底：用 ppage_id=356753938（收藏页）尝试获取完整播放链接。
    // 酷狗约定：歌曲被收藏后，即便无版权也可通过该 page_id 解锁播放。
    // 必须放在 free_part 试听兜底之前，否则试听 URL 会抢先返回 30s 片段。
    // 参考 EchoMusic 的 resolver.ts 中 getSongUrl(track.hash, '', 356753938) 实现。
    try {
      final result = await getSongUrl(
        hash,
        quality: KugouQuality.standard,
        albumId: albumId,
        albumAudioId: albumAudioId,
        downgrade: false,
        ppageId: '356753938',
      );
      if (result != null && result.url.isNotEmpty) {
        return result;
      }
    } catch (_) {}

    // 最后尝试带降级的 standard 请求
    // （会走 free_part=1 的 30s 试听兜底）
    try {
      return await getSongUrl(
        hash,
        quality: KugouQuality.standard,
        albumId: albumId,
        albumAudioId: albumAudioId,
        downgrade: true,
      );
    } catch (_) {}

    return null;
  }

  /// 查询歌曲实际可用的音质集合。
  ///
  /// 原理：调用 [getSongUrlWithFallback] 请求最高音质（Hi-Res），
  /// 返回的 actualQuality 即为该歌曲当前账号可获取的最高音质。
  /// 由于音质可用性递减（高音质可用 ⇒ 低音质必可用），
  /// 可直接从 actualQuality 推断完整可用集合。
  /// 失败时回退为仅 standard。
  Future<Set<String>> getAvailableQualities(
    String hash, {
    String? albumId,
    String? albumAudioId,
  }) async {
    try {
      final result = await getSongUrlWithFallback(
        hash,
        quality: KugouQuality.hires,
        albumId: albumId,
        albumAudioId: albumAudioId,
      );
      if (result == null || result.url.isEmpty) {
        return {KugouQuality.standard};
      }
      switch (result.quality) {
        case KugouQuality.hires:
          return {
            KugouQuality.standard,
            KugouQuality.high,
            KugouQuality.lossless,
            KugouQuality.hires,
          };
        case KugouQuality.lossless:
          return {KugouQuality.standard, KugouQuality.high, KugouQuality.lossless};
        case KugouQuality.high:
          return {KugouQuality.standard, KugouQuality.high};
        default:
          return {KugouQuality.standard};
      }
    } catch (_) {
      return {KugouQuality.standard};
    }
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
    Map<String, dynamic>? searchResult;

    // 从 /search/lyric 响应的 candidates 中取第一个候选，解析 lyricId/accesskey。
    void resolveCandidate(Map<String, dynamic>? result) {
      if (result == null) return;
      final candidates = result['candidates'];
      if (candidates is List && candidates.isNotEmpty) {
        final first = candidates.first as Map<String, dynamic>;
        lyricId = first['id']?.toString();
        lyricAccesskey = first['accesskey']?.toString();
      }
    }

    // 1) 有 hash 时先精确搜索（在线歌曲通常直接命中官方歌词）
    if (hash.isNotEmpty) {
      final byHash = await _get(
        KugouEndpoints.searchLyric,
        queryParameters: {'hash': hash.toLowerCase()},
      );
      if (byHash != null && _hasCandidates(byHash)) {
        searchResult = byHash;
        resolveCandidate(searchResult);
      }
    }

    // 2) hash 搜索未命中且是失效 hash → 歌曲搜索找回正确 hash 再 hash 搜索。
    // 优先走此路径是因为 keyword 歌词搜索可能命中无翻译版本，而用正确 hash
    // 搜索通常命中官方完整版（含翻译），与官方 App 行为一致。
    if (lyricId == null &&
        hash.isNotEmpty &&
        songName != null &&
        songName.isNotEmpty) {
      final recovered = await _recoverLyricIdBySongSearch(songName);
      if (recovered != null) {
        lyricId = recovered.$1;
        lyricAccesskey = recovered.$2;
      }
    }

    // 3) 仍无结果（本地歌曲 hash 为空等）→ 关键词歌词搜索兜底。
    // 只传 keywords，不携带原 hash：hash 在歌词库匹配失败时，酷狗会优先按
    // 无效 hash 过滤导致关键词搜索同样返回空（部分歌曲歌词空白）。
    if (lyricId == null && songName != null && songName.isNotEmpty) {
      searchResult = await _get(
        KugouEndpoints.searchLyric,
        queryParameters: {'keywords': songName},
      );
      resolveCandidate(searchResult);
    }

    if (lyricId == null) {
      return null;
    }

    // 闭包内赋值使类型仍为 String?，此处已确认非空，断言收窄
    final String resolvedLyricId = lyricId!;
    final String? resolvedAccesskey = lyricAccesskey;

    // 默认 fmt='lrc' 触发并发双请求（LRC + KRC）；显式传 fmt='krc' 走单请求路径（向后兼容）
    final bool dualRequest = (fmt == 'lrc');

    if (dualRequest) {
      // 并发双请求：Future.wait 同时发起，每个请求独立 try/catch 防止单点失败
      final results = await Future.wait([
        _fetchLyricContent(resolvedLyricId, resolvedAccesskey, 'lrc', decode),
        _fetchLyricContent(resolvedLyricId, resolvedAccesskey, 'krc', decode),
      ]);
      final lrcJson = results[0];
      final krcJson = results[1];
      return mergeLyricResponses(lrcJson, krcJson);
    }

    // 单请求路径（显式 fmt=krc 等非 lrc 场景）
    final json =
        await _fetchLyricContent(resolvedLyricId, resolvedAccesskey, fmt, decode);
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

  /// hash 找回：hash 搜索 + 关键词搜索都失败时，用歌曲搜索接口找回正确的
  /// 酷狗 hash，再用该 hash 查一次歌词。解决歌曲条目 hash 失效导致歌词空白。
  ///
  /// 返回 `(lyricId, lyricAccesskey?)`；找不到返回 null。
  Future<(String, String?)?> _recoverLyricIdBySongSearch(String songName) async {
    try {
      final searchResult = await search(songName, pagesize: 5);
      if (searchResult == null || searchResult.songs.isEmpty) {
        return null;
      }
      // 取第一首歌的 FileHash 作为正确 hash
      final correctHash = searchResult.songs.first.hash;
      if (correctHash.isEmpty) return null;
      final lyricSearch = await _get(
        KugouEndpoints.searchLyric,
        queryParameters: {'hash': correctHash.toLowerCase()},
      );
      if (lyricSearch != null) {
        final candidates = lyricSearch['candidates'];
        if (candidates is List && candidates.isNotEmpty) {
          final first = candidates.first as Map<String, dynamic>;
          final id = first['id']?.toString();
          if (id != null && id.isNotEmpty) {
            return (id, first['accesskey']?.toString());
          }
        }
      }
    } catch (_) {
      return null;
    }
    return null;
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

    final lrcLyric = lrcJson != null ? KugouLyric.fromJson(lrcJson) : null;
    final krcLyric = krcJson != null ? KugouLyric.fromJson(krcJson) : null;

    // KRC 明文：优先用专用字段，否则把 KRC 响应的 decodeContent 当作 KRC 明文
    String? krcContent;
    if (krcJson != null) {
      final explicitKrc =
          krcJson['decodeKrcContent'] ??
          krcJson['decoded_krc_content'] ??
          krcJson['krcContent'];
      if (explicitKrc != null) {
        krcContent = explicitKrc.toString();
      } else if (krcJson['decodeContent'] != null) {
        krcContent = krcJson['decodeContent'].toString();
      }
    }

    // 从 KRC [language:] 字段提取翻译和罗马音（酷狗翻译只在 KRC 里，LRC 接口无翻译）
    // 格式：[language:<base64>] 解码后是 JSON：
    //   {"content":[{"language":0,"lyricContent":[["行1"],["行2"],...]}, ...]}
    // language=0 是中文翻译，language=1 是音译（罗马音）
    // lyricContent 按行序对应 KRC 歌词行，无时间戳，需要从 KRC 明文提取每行时间戳合成 LRC
    String? translationLrc =
        lrcLyric?.translatedContent ?? krcLyric?.translatedContent;
    // 空字符串视为 null，允许后续 ??= 生效（避免 LRC JSON 返回空翻译截断 KRC 提取）
    if (translationLrc != null && translationLrc.trim().isEmpty) {
      translationLrc = null;
    }
    String? romaLrc;
    if (krcContent != null) {
      final extracted = _extractTranslationFromKrc(krcContent);
      translationLrc ??= extracted.translation;
      romaLrc = extracted.roma;
    }
    if (romaLrc != null && romaLrc.trim().isEmpty) {
      romaLrc = null;
    }

    final merged = KugouLyric(
      content: lrcLyric?.content ?? krcLyric?.content ?? '',
      decodedContent: lrcLyric?.decodedContent,
      decodedKrcContent: krcContent,
      translatedContent: translationLrc,
      romaContent: romaLrc,
    );
    return merged;
  }

  /// 从 KRC 明文中同时提取翻译和罗马音，各自合成 LRC 格式返回。
  ///
  /// KRC 明文包含：
  /// - 歌词行：`[start_ms,duration_ms]<offset,duration,0>字<offset,duration,0>字...`
  /// - 元数据行：`[language:<base64>]`，解码后为 JSON：
  ///   `{"content":[{"language":0,"lyricContent":[["行1"],["行2"],...]}, ...]}`
  ///
  /// - `language=0`：中文翻译，每行 `lyricContent` 是单元素数组 `[["整行翻译"]]`
  /// - `language=1`：音译/罗马音，每行是多元素数组 `[["yi","er","ta"]]`（一字一音节）
  ///
  /// 返回记录 `(translation, roma)`，任一为空表示无对应数据。
  /// 翻译/罗马音行的 startTime 来自对应 KRC 歌词行。
  static ({String? translation, String? roma}) _extractTranslationFromKrc(
      String krcContent) {
    try {
      final langMatch = RegExp(r'\[language:([^\]]*)\]').firstMatch(krcContent);
      if (langMatch == null) return (translation: null, roma: null);
      final b64 = langMatch.group(1)!;
      // Base64 padding 修正
      final padding = '=' * ((4 - b64.length % 4) % 4);
      final decoded = utf8.decode(base64.decode(b64 + padding));
      final json = jsonDecode(decoded) as Map<String, dynamic>;
      final contentList = json['content'] as List;

      // 提取 KRC 歌词行的 startTime（所有 language 共用同一套时间戳）
      final lineTimestampRegex = RegExp(r'^\[(\d+),(\d+)\]', multiLine: true);
      final lineMatches = lineTimestampRegex.allMatches(krcContent).toList();

      /// 把指定 entry 的 lyricContent 合成为 LRC 字符串
      String? buildLrcFromEntry(Map<String, dynamic>? entry) {
        if (entry == null) return null;
        final lyricContent = entry['lyricContent'] as List;
        final lines = <String>[];
        for (final line in lyricContent) {
          if (line is List && line.isNotEmpty) {
            // ★ 修复根因 B：多元素数组用空格拼接，而非 line.first
            // 翻译: ["而他的苍老感"] → "而他的苍老感"
            // 罗马音: ["yi","er","ta"] → "yi er ta"
            lines.add(line.map((e) => e.toString()).join(' '));
          } else {
            lines.add('');
          }
        }

        // 按 startTime 合成 LRC
        final sb = StringBuffer();
        final count = lineMatches.length < lines.length
            ? lineMatches.length
            : lines.length;
        for (int i = 0; i < count; i++) {
          final startMs = int.parse(lineMatches[i].group(1)!);
          final text = lines[i].trim();
          if (text.isEmpty) continue;
          final mm = (startMs ~/ 60000).toString().padLeft(2, '0');
          final ss = ((startMs % 60000) ~/ 1000).toString().padLeft(2, '0');
          final xx = ((startMs % 1000) ~/ 10).toString().padLeft(2, '0');
          sb.writeln('[$mm:$ss.$xx]$text');
        }
        final result = sb.toString();
        return result.isEmpty ? null : result;
      }

      // 收集所有条目，按数组结构分类：
      // - 单元素数组（整行）→ 翻译
      // - 多元素数组（按字/词拆分）→ 罗马音/拟声词
      // 不依赖字符特征：汉字拟声词也含 CJK，与真正翻译混淆；
      // 而数组结构（单元素 vs 多元素）与酷狗数据标注一致（见方法上方注释），
      // 且天然兼容"汉字拟声词 + 拉丁罗马音"混杂情况（两者都是多元素数组，归入 roma），
      // 与每个元素是汉字还是拉丁词无关
      Map<String, dynamic>? translationEntry;
      Map<String, dynamic>? romaEntry;
      for (final e in contentList) {
        final entry = e as Map<String, dynamic>;
        final lc = entry['lyricContent'] as List;
        // 任一行是多元素数组 → 按字/词拆分风格 → 拟声词/罗马音
        final isSyllableStyle =
            lc.any((line) => line is List && line.length > 1);
        if (isSyllableStyle) {
          romaEntry ??= entry;
        } else if (lc.any((line) => line is List && line.isNotEmpty)) {
          // 单元素数组（整行翻译），且非全空条目
          translationEntry ??= entry;
        }
      }

      return (
        translation: buildLrcFromEntry(translationEntry),
        roma: buildLrcFromEntry(romaEntry),
      );
    } catch (_) {
      return (translation: null, roma: null);
    }
  }

  // ==================== Comment ====================

  Future<KugouCommentList?> getComments(
    String hash, {
    String? albumAudioId,
    int page = 1,
    int pagesize = 30,
  }) async {
    // /comment/music 接口需要 mixsongid（即 album_audio_id）
    // hash 作为备选标识，实际评论拉取依赖 mixsongid
    final params = <String, dynamic>{
      'mixsongid': albumAudioId ?? hash,
      'page': page,
      'pagesize': pagesize,
      'show_classify': 1,
      'show_hotword_list': 1,
    };
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

  /// 获取歌曲评论「最热」列表（按点赞数全局降序）。
  ///
  /// [childrenId] 为评论区 id，取 [KugouCommentList.childrenId]（/comment/music
  /// 响应顶层的 childrenid）或评论项的 [KugouComment.specialId]。上游不接受用
  /// mixsongid 代替，缺少它会返回「参数错误」。
  ///
  /// 与 [getComments]（cmtlist，加权混排、与点赞数无关）是两个不同的列表，
  /// 但不返回歌手评论/精彩评论，那两个列表仍需 [getComments]。
  Future<KugouCommentList?> getToplikedComments(
    String childrenId, {
    int page = 1,
    int pagesize = 30,
  }) async {
    if (childrenId.isEmpty) return null;
    final json = await _get(
      KugouEndpoints.commentMusicTopliked,
      queryParameters: {
        'childrenid': childrenId,
        'page': page,
        'pagesize': pagesize,
      },
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

  /// 获取楼层评论（楼中楼回复），按时间倒序返回（新的在前）。
  ///
  /// [specialId] 歌曲对应的 special_id（从评论数据中获取）
  /// [tid] 评论 ID
  /// [mixSongId] 歌曲 ID
  /// [code] 评论 code（部分接口返回），同时决定走歌曲还是歌单/专辑的楼层接口
  /// [pagesize] 上游硬上限为 50，传更大的值会被静默截断成 50
  Future<KugouCommentList?> getFloorComments({
    required String specialId,
    required String tid,
    String? mixSongId,
    String? code,
    int page = 1,
    int pagesize = 50,
  }) async {
    if (specialId.isEmpty || tid.isEmpty) return null;
    final params = <String, dynamic>{
      'special_id': specialId,
      'tid': tid,
      'page': page,
      'pagesize': pagesize,
    };
    if (mixSongId != null && mixSongId.isNotEmpty) {
      params['mixsongid'] = mixSongId;
    }
    if (code != null && code.isNotEmpty) {
      params['code'] = code;
    }
    final json = await _get(
      KugouEndpoints.commentFloor,
      queryParameters: params,
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
      queryParameters: {'id': specialId, 'page': page},
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
      queryParameters: {'id': albumId, 'page': page},
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
      queryParameters: {'ids': id},
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

  /// 编辑精选主列表（/top/ip → musicadservice 每日推荐）。
  Future<Map<String, dynamic>?> getIpHome() async {
    return await _get(KugouEndpoints.topIp);
  }

  /// 编辑精选数据（/ip → /openapi/v1/ip/{type}）。
  /// [type] 支持 audios / albums / videos / author_list，非法值回退 audios。
  Future<Map<String, dynamic>?> getIpData(
    String id, {
    String type = 'audios',
    int page = 1,
    int pagesize = 30,
  }) async {
    final safeType = ['audios', 'albums', 'videos', 'author_list'].contains(type)
        ? type
        : 'audios';
    return await _get(
      KugouEndpoints.ip,
      queryParameters: {
        'id': id,
        'type': safeType,
        'page': page,
        'pagesize': pagesize,
      },
    );
  }

  Future<Map<String, dynamic>?> getIpDateil() async {
    return await _get(KugouEndpoints.ipDateil);
  }

  /// 编辑精选歌单（/ip/playlist → /ocean/v6/pubsongs/list_info_for_ip）。
  Future<Map<String, dynamic>?> getIpPlaylist(
    String id, {
    int page = 1,
    int pagesize = 30,
  }) async {
    return await _get(
      KugouEndpoints.ipPlaylist,
      queryParameters: {'id': id, 'page': page, 'pagesize': pagesize},
    );
  }

  Future<Map<String, dynamic>?> getIpZone() async {
    return await _get(KugouEndpoints.ipZone);
  }

  /// 编辑精选专区详情（/ip/zone/home），query 参数名 `id` 与服务端一致。
  Future<Map<String, dynamic>?> getIpZoneHome(String id) async {
    return await _get(
      KugouEndpoints.ipZoneHome,
      queryParameters: {'id': id},
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

  /// [noCache] 供「同一游标要下一批」的续播场景使用：本地服务端的 apicache 按
  /// URL 缓存，而 [_onRequest] 只在 noCache 时才加 bypass 头和 t= 戳（登录态在
  /// L183 设的那份 bypass 头会被 L207-209 的 else 分支删掉），否则同参数请求
  /// 会被原样回放，续播拿到的永远是同一批歌。
  Future<List<KugouSongDetail>?> getPersonalFm({
    String? mode,
    int? songPoolId,
    String? hash,
    String? songId,
    String? action,
    bool noCache = false,
  }) async {
    final params = <String, dynamic>{};
    if (mode != null) params['mode'] = mode;
    if (songPoolId != null) params['song_pool_id'] = songPoolId.toString();
    if (hash != null) params['hash'] = hash;
    if (songId != null) params['songid'] = songId;
    if (action != null) params['action'] = action;

    final json = await _get(
      KugouEndpoints.personalFm,
      queryParameters: params,
      noCache: noCache,
    );
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

  /// 场景音乐列表（/scene/lists → GET /scene/v1/scene/list）。
  Future<Map<String, dynamic>?> getSceneLists() async {
    return await _get(KugouEndpoints.sceneLists);
  }

  /// 场景音乐推荐（/scene/music → POST /genesisapi/v1/scene_music/rec_music）。
  /// 仅供发现页「场景音乐」横滑区块使用。
  Future<Map<String, dynamic>?> getSceneMusic() async {
    return await _get(KugouEndpoints.sceneMusic);
  }

  /// 场景音乐详情：场景下的模块列表（/scene/module?id=scene_id）。
  Future<Map<String, dynamic>?> getSceneModule(String sceneId) async {
    return await _get(
      KugouEndpoints.sceneModule,
      queryParameters: {'id': sceneId},
    );
  }

  /// 场景音乐讨论区（/scene/lists/v2?id=scene_id）。
  /// [sort] 支持 rec（推荐）/ hot（热门）/ new（最新）。
  Future<Map<String, dynamic>?> getSceneListsV2(
    String sceneId, {
    int page = 1,
    int pagesize = 30,
    String sort = 'rec',
  }) async {
    return await _get(
      KugouEndpoints.sceneListsV2,
      queryParameters: {
        'id': sceneId,
        'page': page,
        'pagesize': pagesize,
        'sort': sort,
      },
    );
  }

  /// 场景音乐模块 Tag（/scene/module/info?id=scene_id&module_id=module_id）。
  Future<Map<String, dynamic>?> getSceneModuleInfo({
    required String sceneId,
    required String moduleId,
  }) async {
    return await _get(
      KugouEndpoints.sceneModuleInfo,
      queryParameters: {'id': sceneId, 'module_id': moduleId},
    );
  }

  /// 场景音乐歌单列表（/scene/collection/list?tag_id=tag_id）。
  Future<Map<String, dynamic>?> getSceneCollectionList(
    String tagId, {
    int page = 1,
    int pagesize = 30,
  }) async {
    return await _get(
      KugouEndpoints.sceneCollectionList,
      queryParameters: {'tag_id': tagId, 'page': page, 'pagesize': pagesize},
    );
  }

  /// 场景音乐视频列表（/scene/video/list?tag_id=tag_id）。
  Future<Map<String, dynamic>?> getSceneVideoList(
    String tagId, {
    int page = 1,
    int pagesize = 30,
  }) async {
    return await _get(
      KugouEndpoints.sceneVideoList,
      queryParameters: {'tag_id': tagId, 'page': page, 'pagesize': pagesize},
    );
  }

  /// 场景音乐音乐列表（/scene/audio/list?id=scene_id&module_id=module_id&tag=tag_id）。
  Future<Map<String, dynamic>?> getSceneAudioList({
    required String sceneId,
    required String moduleId,
    required String tag,
    int page = 1,
    int pagesize = 30,
  }) async {
    return await _get(
      KugouEndpoints.sceneAudioList,
      queryParameters: {
        'id': sceneId,
        'module_id': moduleId,
        'tag': tag,
        'page': page,
        'pagesize': pagesize,
      },
    );
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
      queryParameters: {'id': artistId},
    );
    if (json == null) return null;
    try {
      final data = json['data'] as Map<String, dynamic>? ?? json;
      return KugouArtistDetail.fromJson(data);
    } catch (e) {
      print('[ArtistDetail] parse error: $e');
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
    bool noCache = false,
  }) async {
    final json = await _get(
      KugouEndpoints.artistAudios,
      queryParameters: {
        'id': artistId,
        'page': page,
        'pagesize': pagesize,
      },
      noCache: noCache,
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
      queryParameters: {'id': artistId},
      noCache: true,
    );
  }

  Future<Map<String, dynamic>?> unfollowArtist(String artistId) async {
    return await _post(
      KugouEndpoints.artistUnfollow,
      queryParameters: {'id': artistId},
      noCache: true,
    );
  }

  Future<Map<String, dynamic>?> getFollowNewsongs() async {
    return await _get(KugouEndpoints.artistFollowNewsongs);
  }

  // ==================== Video / MV ====================

  /// 根据 album_audio_id/MixSongID 获取歌曲对应的 MV。
  /// 对应服务端 `/kmr/audio/mv`，上游 openapi.kugou.com。
  /// 注意：服务端模块从 query 参数读取 album_audio_id（见 server.js:458），
  /// 故客户端必须用 GET + query 传递，不能用 POST body。
  /// 返回 [MvInfo]，[MvInfo.hasMv] 为 false 表示该歌曲无 MV。
  Future<MvInfo?> getMvByAlbumAudioId(String albumAudioId, {String fields = ''}) async {
    if (albumAudioId.isEmpty) return null;
    final json = await _get(
      KugouEndpoints.kmrAudioMv,
      queryParameters: {
        'album_audio_id': albumAudioId,
        'fields': fields,
      },
    );
    if (json == null) {
      print('[getMvByAlbumAudioId] response null for album_audio_id=$albumAudioId');
      return null;
    }
    print('[getMvByAlbumAudioId] response: $json');
    try {
      // 真实响应：{ data: [[ {video_id, mv_name, ...}, ... ]], status, err_code }
      // data 是二维数组：外层按 album_audio_id 分组，内层是该歌曲的多个 MV 版本。
      final data = json['data'];
      if (data is List && data.isNotEmpty) {
        final first = data.first;
        // 二维数组：first 是 [ {mv1}, {mv2}, ... ]
        if (first is List && first.isNotEmpty) {
          final mv = first.first;
          if (mv is Map<String, dynamic>) {
            return MvInfo.fromJson(mv);
          }
          return null;
        }
        // 一维数组兜底：first 是 {mv1}
        if (first is Map<String, dynamic>) {
          return MvInfo.fromJson(first);
        }
        return null;
      }
      if (data is Map<String, dynamic>) {
        return MvInfo.fromJson(data);
      }
      return MvInfo.fromJson(json);
    } catch (e) {
      print('[getMvByAlbumAudioId] parse error: $e');
      return null;
    }
  }

  /// 获取视频详情（含多清晰度 hash）。
  /// 对应服务端 `/video/detail`，上游 kmr.service.kugou.com。
  /// show_resolution=1 在服务端模块内硬编码（video_detail.js:21），客户端无需传。
  /// 服务端从 query 读取 id，故客户端用 GET + query。
  Future<MvDetail?> getVideoDetail(String mvId) async {
    if (mvId.isEmpty) return null;
    final json = await _get(
      KugouEndpoints.videoDetail,
      queryParameters: {'id': mvId},
    );
    if (json == null) return null;
    try {
      // 响应结构：{ data: [ {video_id, title, sv:[...], ...} ] } 或 { data: {...} }
      final data = json['data'];
      if (data is List && data.isNotEmpty) {
        final first = data.first;
        if (first is Map<String, dynamic>) {
          return MvDetail.fromJson(first, mvId);
        }
        return null;
      }
      if (data is Map<String, dynamic>) {
        return MvDetail.fromJson(data, mvId);
      }
      return MvDetail.fromJson(json, mvId);
    } catch (e) {
      print('[getVideoDetail] parse error: $e');
      return null;
    }
  }

  /// 根据 视频 hash 获取视频播放地址。
  /// 对应服务端 `/video/url`（GET），上游 trackermv.kugou.com。
  Future<String?> getVideoUrl(String hash) async {
    if (hash.isEmpty) return null;
    final json = await _get(
      KugouEndpoints.videoUrl,
      queryParameters: {'hash': hash},
    );
    if (json == null) return null;
    try {
      // 真实响应：{ data: { "<hash_lower>": { downurl, backupdownurl, filesize } } }
      // 注意：MV 视频 CDN（如 fsmvpc.tx.kugou.com）仅支持 HTTP，不支持 HTTPS，
      // 不能做 http→https 转换（会 Source error）。明文由 network_security_config
      // 按域名精确放行，故这里保持返回原始 downurl。
      final data = json['data'];
      if (data is Map<String, dynamic>) {
        // 优先用 hash 小写匹配 key
        final key = hash.toLowerCase();
        final entry = data[key];
        if (entry is Map<String, dynamic>) {
          return entry['downurl'] as String?;
        }
        // 兜底：取第一个 entry
        if (data.values.isNotEmpty) {
          final first = data.values.first;
          if (first is Map<String, dynamic>) {
            return first['downurl'] as String?;
          }
        }
      }
      return null;
    } catch (e) {
      print('[getVideoUrl] parse error: $e');
      return null;
    }
  }

  /// 获取视频权限信息。
  /// 对应服务端 `/video/privilege`，上游 media.store.kugou.com。
  /// 服务端从 query 读取 hash，故客户端用 GET + query。
  Future<Map<String, dynamic>?> getVideoPrivilege(String hash) async {
    if (hash.isEmpty) return null;
    return await _get(
      KugouEndpoints.videoPrivilege,
      queryParameters: {'hash': hash},
    );
  }

  // ==================== Login ====================

  Future<Map<String, dynamic>?> loginByCellphone(
    String mobile,
    String code, {
    String? userid,
  }) async {
    final params = <String, dynamic>{'mobile': mobile, 'code': code};
    if (userid != null) params['userid'] = userid;
    // 使用 _getAllowNonOk：Rust 服务端把多账号响应（error_code=34175）
    // 包装成 HTTP 502，但 body 里带 data.info_list 账号列表，需读取。
    return await _getAllowNonOk(
      KugouEndpoints.loginCellphone,
      queryParameters: params,
    );
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
    // 使用 noCache：Rust 端 apicache key 不含 token，切账号后
    // /user/detail 会命中旧账号的缓存，返回错误昵称/头像。
    // 用 _getAllowNonOk：Rust 端偶发把上游业务错误包装为 HTTP 502，
    // 但 body 里仍带 data 用户信息；若用 _get 会抛 badResponse 丢数据。
    final json = await _getAllowNonOk(
      KugouEndpoints.userDetail,
      noCache: true,
    );
    if (json == null) return null;
    // 业务失败（如 token 失效/未登录，error_code=20010）时返回 null，
    // 避免误判为「成功但无昵称」（此前会返回 nickname=null 的对象）。
    if (!_isBizOk(json)) return null;
    try {
      final detail = KugouUserDetail.fromJson(json);
      // ignore: avoid_print
      print(
        '[USER_DETAIL] userid=${detail.userid} nickname=${detail.nickname} raw=${json['data']}',
      );
      return detail;
    } catch (e) {
      // ignore: avoid_print
      print('[USER_DETAIL] parse error: $e json=$json');
      return null;
    }
  }

  /// 校验当前登录 token 是否仍有效（复用 /user/detail，精确判断业务状态）。
  /// 返回 true=有效；false=已过期/无效/请求失败（保守视为无效）。
  Future<bool> checkTokenValid() async {
    final json = await _getAllowNonOk(
      KugouEndpoints.userDetail,
      noCache: true,
    );
    if (json == null) return false;
    if (!_isBizOk(json)) return false;
    final data = json['data'];
    return data is Map && data.isNotEmpty;
  }

  /// 判断用户态接口响应的业务状态是否成功。
  /// 成功判定：error_code 为 0 或缺失，且 status 为 1 或缺失。
  static bool _isBizOk(Map<String, dynamic> json) {
    final errorCode = json['error_code'];
    if (errorCode is num && errorCode != 0) return false;
    final status = json['status'];
    if (status is num && status != 1) return false;
    return true;
  }

  Future<KugouUserVipDetail?> getUserVipDetail() async {
    // noCache=true：VIP 到期时间等是账号隔离且需实时展示的数据，
    // 避免 Rust apicache 命中上一账号（切换账号后不更新）的旧缓存。
    final json = await _get(KugouEndpoints.userVipDetail, noCache: true);
    if (json == null) return null;
    try {
      return KugouUserVipDetail.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  /// 查询/上报听歌等级信息（v2/lite 协议）。
  /// [dSec]/[diffSec] 同时传入时进入上报模式（同步本地累计时长）；都为空时为查询。
  /// noCache 默认 true：避免 Rust apicache 命中旧值（等级/时长需要实时）。
  Future<Map<String, dynamic>?> getGradeInfo({
    int? dSec,
    int? diffSec,
    bool noCache = true,
  }) async {
    final params = <String, dynamic>{};
    if (dSec != null) params['d_sec'] = dSec;
    if (diffSec != null) params['diff_sec'] = diffSec;
    return await _get(
      KugouEndpoints.userGradeInfo,
      queryParameters: params,
      noCache: noCache,
    );
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

  Future<Map<String, dynamic>?> getUserFollow({bool noCache = false}) async {
    return await _get(KugouEndpoints.userFollow, noCache: noCache);
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

  /// 获取用户上传到酷狗云盘的音乐列表。
  /// 返回原始 JSON，由调用方解析（云盘列表字段与标准歌单不同）。
  /// [noCache] 为 true 时绕过服务端 apicache（上传成功后刷新列表用）。
  Future<Map<String, dynamic>?> getUserCloud({
    int page = 1,
    int pagesize = 30,
    bool noCache = false,
  }) async {
    return await _get(
      KugouEndpoints.userCloud,
      queryParameters: {'page': page, 'pagesize': pagesize},
      noCache: noCache,
    );
  }

  /// 获取用户已购单曲列表（需登录）。返回原始 JSON，由调用方自适应解析。
  Future<Map<String, dynamic>?> getUserPurchasedSongs({
    int page = 1,
    int pagesize = 50,
    bool noCache = false,
  }) async {
    return await _get(
      KugouEndpoints.userPurchasedSongs,
      queryParameters: {'page': page, 'pagesize': pagesize},
      noCache: noCache,
    );
  }

  /// 获取用户已购专辑列表（需登录）。返回原始 JSON，由调用方自适应解析。
  Future<Map<String, dynamic>?> getUserPurchasedAlbums({
    int page = 1,
    int pagesize = 15,
    bool noCache = false,
  }) async {
    return await _get(
      KugouEndpoints.userPurchasedAlbums,
      queryParameters: {'page': page, 'pagesize': pagesize},
      noCache: noCache,
    );
  }

  /// 上传本地音乐文件到酷狗云盘。
  ///
  /// [body] 为文件完整二进制（octet-stream）；本地服务器端负责：
  /// 计算文件 MD5（作为 filename/hash）、分片上传（4MB/片）、
  /// 秒传判断与「添加到云盘」的 AES/RSA 加密签名。
  ///
  /// [filename] 可选，缺省时由服务端按文件内容自动计算 MD5；
  /// [extendname] 文件扩展名（如 mp3/flac，不带点）；
  /// [name] 上传后显示的歌名（缺省时服务端按 `作者 - MD5.ext` 生成）；
  /// [authorName] 歌手名；[bitrate] 码率等级（缺省 4）；
  /// [timelen] 时长（毫秒，可选）；[audioId]/[albumAudioId] 可选 ID 透传。
  Future<Map<String, dynamic>?> uploadCloudSong(
    Uint8List body, {
    String? filename,
    String extendname = 'mp3',
    String? name,
    String? authorName,
    int bitrate = 4,
    int? timelen,
    int? audioId,
    int? albumAudioId,
  }) async {
    final params = <String, dynamic>{
      'extendname': extendname,
      'bitrate': bitrate,
    };
    if (filename != null && filename.isNotEmpty) {
      params['filename'] = filename.toLowerCase();
    }
    if (name != null && name.isNotEmpty) params['name'] = name;
    if (authorName != null && authorName.isNotEmpty) {
      params['author_name'] = authorName;
    }
    if (timelen != null) params['timelen'] = timelen;
    if (audioId != null) params['audio_id'] = audioId;
    if (albumAudioId != null) params['album_audio_id'] = albumAudioId;
    return await _postBinary(
      KugouEndpoints.userCloudUpload,
      body: body,
      queryParameters: params,
    );
  }

  /// 删除云盘音乐（支持单首与批量）。
  /// [hashes] 歌曲 hash；[fileids] 云盘文件 ID（列表接口返回的 kv_id）；
  /// [albumAudioIds] 专辑音频 ID，与 [fileids] 一一对应。
  /// 三者至少传一个；服务端支持逗号分隔多值（数组会 join 成逗号串）。
  Future<Map<String, dynamic>?> deleteCloudSongs({
    List<String>? hashes,
    List<String>? fileids,
    List<String>? albumAudioIds,
  }) async {
    final params = <String, dynamic>{};
    if (hashes != null && hashes.isNotEmpty) {
      params['hashes'] = hashes.join(',');
    }
    if (fileids != null && fileids.isNotEmpty) {
      params['fileids'] = fileids.join(',');
    }
    if (albumAudioIds != null && albumAudioIds.isNotEmpty) {
      params['album_audio_ids'] = albumAudioIds.join(',');
    }
    return await _get(
      KugouEndpoints.userCloudDel,
      queryParameters: params,
      noCache: true,
    );
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

  /// 获取用户听歌历史排行。
  ///
  /// [type] 0 = 最近一周前 120 首，1 = 全部累计前 120 首
  Future<Map<String, dynamic>?> getUserListenRanking({int type = 0}) async {
    return await _get(
      KugouEndpoints.userListen,
      queryParameters: {'type': type},
    );
  }

  /// 提交听歌历史到云端（支持跨设备同步）。
  ///
  /// [mxid] 专辑音乐 id（album_audio_id 或 MixSongID）
  /// [playCount] 当前播放次数，可选
  Future<Map<String, dynamic>?> uploadPlayHistory(
    String mxid, {
    int? playCount,
  }) async {
    final params = <String, dynamic>{
      'mxid': mxid,
      'ot': DateTime.now().millisecondsSinceEpoch ~/ 1000, // 秒级时间戳
    };
    if (playCount != null) params['pc'] = playCount;
    return await _get(
      KugouEndpoints.playhistoryUpload,
      queryParameters: params,
    );
  }

  // ==================== Playlist Management ====================

  Future<Map<String, dynamic>?> createPlaylist(
    String name, {
    int type = 0,
    int source = 1,
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
      'source': source,
      'is_pri': isPri,
      'list_create_userid': userid,
      'list_create_listid': listid,
    };
    // 收藏歌单时需要传入 list_create_gid
    if (globalCollectionId != null && globalCollectionId.isNotEmpty) {
      params['list_create_gid'] = globalCollectionId;
    }
    return await _get(KugouEndpoints.playlistAdd, queryParameters: params);
  }

  /// 收藏专辑
  Future<Map<String, dynamic>?> collectAlbum(
    String name, {
    required String artistId,
    required String albumId,
  }) async {
    final params = <String, dynamic>{
      'name': name,
      'type': 1,
      'source': 2,
      'list_create_userid': artistId,
      'list_create_listid': albumId,
      'list_create_gid': '',
    };
    return await _get(KugouEndpoints.playlistAdd, queryParameters: params);
  }

  Future<Map<String, dynamic>?> deletePlaylist(
    String listid, {
    int type = 1,
  }) async {
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

  // ==================== Youth Channel ====================

  Future<Map<String, dynamic>?> getYouthChannels() async {
    return await _get(KugouEndpoints.youthChannelAll);
  }

  Future<Map<String, dynamic>?> getYouthChannelDetail(String channelId) async {
    return await _get(
      KugouEndpoints.youthChannelDetail,
      queryParameters: {'global_collection_id': channelId},
    );
  }

  Future<Map<String, dynamic>?> getYouthChannelAmway(String channelId) async {
    return await _get(
      KugouEndpoints.youthChannelAmway,
      queryParameters: {'global_collection_id': channelId},
    );
  }

  Future<Map<String, dynamic>?> getYouthChannelSimilar(String channelId) async {
    return await _get(
      KugouEndpoints.youthChannelSimilar,
      queryParameters: {'channel_id': channelId},
    );
  }

  Future<Map<String, dynamic>?> subscribeYouthChannel(
    String channelId, {
    int t = 1,
  }) async {
    return await _get(
      KugouEndpoints.youthChannelSub,
      queryParameters: {'global_collection_id': channelId, 't': t},
    );
  }

  Future<Map<String, dynamic>?> getYouthChannelSong(
    String channelId, {
    int page = 1,
    int pagesize = 30,
  }) async {
    return await _get(
      KugouEndpoints.youthChannelSong,
      queryParameters: {
        'global_collection_id': channelId,
        'page': page,
        'pagesize': pagesize,
      },
    );
  }

  Future<Map<String, dynamic>?> getYouthChannelSongDetail(
    String channelId,
    String fileid,
  ) async {
    return await _get(
      KugouEndpoints.youthChannelSongDetail,
      queryParameters: {'global_collection_id': channelId, 'fileid': fileid},
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

  Future<Map<String, dynamic>?> getLongaudioAlbumAudios(
    String albumId, {
    int page = 1,
    int pageSize = 30,
  }) async {
    return await _get(
      KugouEndpoints.longaudioAlbumAudios,
      queryParameters: {
        'album_id': albumId,
        'page': page,
        'pagesize': pageSize,
      },
    );
  }

  Future<Map<String, dynamic>?> getLongaudioSearch(String keyword) async {
    return await _get(
      KugouEndpoints.longaudioSearch,
      queryParameters: {'keyword': keyword},
    );
  }

  /// 免费听书库/分类榜单列表（Rust 转发 /longaudio/v1/album/list）。
  /// [tagId] 分类（906=有声小说…）、[sort] 排序、[gender] 0不限/1男/2女、
  /// [status] 0全部/1连载/2完结、[page]/[pageSize] 分页（上游固定 free=1）。
  Future<Map<String, dynamic>?> getLongaudioAlbumList({
    int tagId = 906,
    int sort = 0,
    int gender = 0,
    int status = 0,
    int page = 1,
    int pageSize = 20,
  }) async {
    return await _get(
      KugouEndpoints.longaudioAlbumList,
      queryParameters: {
        'tag_id': tagId,
        'sort': sort,
        'gender': gender,
        'status': status,
        'page': page,
        'page_size': pageSize,
      },
    );
  }

  /// 听书分类标签树（Rust 转发 /v3/list_audiobook_tags）。
  /// 响应 data[0] 为有声小说(906)，其 son[] 为 24 个子分类。
  Future<Map<String, dynamic>?> getLongaudioTagList() async {
    return await _get(KugouEndpoints.longaudioTagList);
  }

  // ==================== Other ====================

  Future<Map<String, dynamic>?> getBrush({int page = 1}) async {
    return await _get(KugouEndpoints.brush, queryParameters: {'page': page});
  }

  /// 根据专辑音乐 id（album_audio_id/MixSongID，可多个逗号分隔）获取 AI 推荐歌曲。
  ///
  /// 服务端 `/ai/recommend` 从 query 读取 `album_audio_id`（见 rust extras.rs::handle_ai_recommend）。
  Future<List<KugouSongDetail>?> getAiRecommend(String albumAudioId) async {
    final json = await _get(
      KugouEndpoints.aiRecommend,
      queryParameters: {'album_audio_id': albumAudioId},
    );
    if (json == null) return null;
    try {
      // /recommend 返回 data 可能是歌曲数组，也可能是嵌套列表字段，防御性解析
      final data = json['data'];
      List<dynamic> list;
      if (data is List) {
        list = data;
      } else if (data is Map<String, dynamic>) {
        list =
            (data['song_list'] ?? data['songs'] ?? data['list'] ?? data['info'] ?? [])
                as List<dynamic>;
      } else {
        list = [];
      }
      return list
          .map((e) => KugouSongDetail.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('[API getAiRecommend] parse error: $e');
      return null;
    }
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
      // 响应格式有多种可能：
      // 1. {status:0, data:{info:[...], ...}}  → 标准格式，data 是 Map
      // 2. {status:0, data:{album_id:..., intro:...}} → data 直接是专辑信息 Map
      // 3. {status:1, data:[]} → 查询失败，data 是空 List（如专辑下架）
      // 4. {status:0, data:[{album_id:..., intro:...}]} → data 是 List 包专辑信息
      final rawData = json['data'];
      Map<String, dynamic> albumData;
      if (rawData is Map<String, dynamic>) {
        // 情况 1/2：data 是 Map
        final info = rawData['info'];
        if (info is List && info.isNotEmpty) {
          albumData = info.first as Map<String, dynamic>;
        } else {
          albumData = rawData;
        }
      } else if (rawData is List && rawData.isNotEmpty) {
        // 情况 4：data 是 List，取第一个元素
        final first = rawData.first;
        if (first is Map<String, dynamic>) {
          albumData = first;
        } else {
          return null;
        }
      } else {
        // 情况 3：data 是空 List 或其他类型，专辑不可用
        return null;
      }
      return KugouAlbumDetail.fromJson(albumData);
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
      queryParameters: {'listid': listid, 'page': page, 'pagesize': pagesize},
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

  Future<Map<String, dynamic>?> getImages(String hash, {bool noCache = false}) async {
    return await _get(KugouEndpoints.images, queryParameters: {'hash': hash}, noCache: noCache);
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

  /// 解析一次广告领取响应的结果（纯函数，便于单测）。
  /// 与 kgcheckin main.js 判定一致：status==1 成功；error_code==30002 次数用光；其余失败。
  static AdClaimOutcome parseAdClaimOutcome(Map<String, dynamic>? resp) {
    if (resp == null) return AdClaimOutcome.failure;
    if (resp['status'] == 1) return AdClaimOutcome.success;
    if (resp['error_code'] == 30002) return AdClaimOutcome.quotaDone;
    return AdClaimOutcome.failure;
  }

  /// 听歌上报领取 VIP（/youth/listen/song → /youth/v2/report/listen_song）。
  /// error_code 130012 = 今日已领取。
  Future<Map<String, dynamic>?> listenSong() {
    return _post(KugouEndpoints.youthListenSong);
  }

  /// 广告播放上报领取 VIP（/youth/vip → /youth/v1/ad/play_report）。
  /// error_code 30002 = 今日次数已用光。
  Future<Map<String, dynamic>?> claimAdVip() {
    return _post(KugouEndpoints.youthVip);
  }

  Future<Map<String, dynamic>?> getYouthUnionVip() async {
    return await _get(KugouEndpoints.youthUnionVip);
  }

  /// 领取每日畅听会员（基础签到）
  ///
  /// 保持 POST 方式（与云服务器兼容性最好）。
  /// 传 receive_day 作为 body，云服务器 module 会读取 params.body.receive_day。
  Future<Map<String, dynamic>?> claimDayVip(String receiveDay) async {
    return await _post(
      KugouEndpoints.youthDayVip,
      data: {'receive_day': receiveDay},
    );
  }

  /// 升级每日概念会员（概念版双签到第二步）
  ///
  /// 保持 POST 方式。云服务器 app.use 接受所有方法，
  /// module 代码与 EchoMusic 后端（MakcRe/KuGouMusicApi）完全一致。
  Future<Map<String, dynamic>?> upgradeDayVip() async {
    return await _post(KugouEndpoints.youthDayVipUpgrade);
  }

  /// 获取验证码格式（/get/verify/info）。
  /// 签到/登录等接口返回 error_code=20028 时，响应中一般带 eventid（ssaCode），
  /// 用该 eventid 查询验证类型（v_type=23 腾讯滑块 / 32 短信）与 txappid。
  Future<Map<String, dynamic>?> getVerifyInfo(String eventid) async {
    return await _get(
      KugouEndpoints.getVerifyInfo,
      queryParameters: {'eventid': eventid},
      noCache: true,
    );
  }

  /// 提交验证码完成二次验证（/verify/user/info）。
  /// sid/edt 由本地 Rust 服务器自动生成（行为指纹模拟），前端无需传。
  Future<Map<String, dynamic>?> verifyUserInfo({
    required String eventid,
    required int vType,
    required String verifycode,
  }) async {
    return await _get(
      KugouEndpoints.verifyUserInfo,
      queryParameters: {
        'eventid': eventid,
        'v_type': vType,
        'verifycode': verifycode,
      },
      noCache: true,
    );
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

  /// 听歌识曲：发送 PCM 音频数据识别歌曲
  Future<Map<String, dynamic>?> audioMatch(Uint8List pcmData) async {
    return await _postBinary(
      KugouEndpoints.audioMatch,
      body: pcmData,
      queryParameters: {'timestamp': DateTime.now().millisecondsSinceEpoch},
    );
  }
}
