import 'package:dio/dio.dart';

import 'kugou_api_client.dart';
import 'kugou_endpoints.dart';

/// 一起听域异常。
///
/// [code] 为上游 error_code（0 表示无业务码，如网络失败）；
/// [payload] 保留原始响应体，便于上层做二次判定（例如解散文案识别）。
class ListenTogetherApiError implements Exception {
  final String message;
  final int code;
  final Object? payload;

  const ListenTogetherApiError(this.message, [this.code = 0, this.payload]);

  @override
  String toString() => 'ListenTogetherApiError($code): $message';
}

/// 已验证的错误码 → 中文文案。
///
/// 注意：20002 在房间域表示「群组不存在」，不是通用鉴权错误；
/// 鉴权失败使用 51002。
String listenTogetherErrorMessage(int code) {
  if (code == 51002) return '请先登录后再使用一起听';
  if (code == 20003) return '房间音乐配置不完整';
  if (code == 20006) return '账号当前已有未结束的众乐房会话';
  if (code == 55004) return '已达到房间创建上限，请先管理已有房间';
  if (code == 55006) return '房间不存在或已解散';
  return code > 0 ? '一起听服务暂不可用（$code）' : '一起听服务暂不可用';
}

/// 把接口异常转成可直接展示给用户的文案。
///
/// 上游 `error_msg` 通常已是用户可读的中文（例如「房间音乐配置不完整」），
/// 直接保留；仅当文案缺失或明显是技术串（不含中文）时才回退到错误码映射，
/// 避免把 `create group failed` 这类内部串原样抛给用户。
String listenTogetherErrorText(ListenTogetherApiError e) {
  final msg = e.message.trim();
  if (msg.isNotEmpty && RegExp(r'[\u4e00-\u9fa5]').hasMatch(msg)) return msg;
  return listenTogetherErrorMessage(e.code);
}

/// 解散类错误判定：55006 / 20005，或 20002 且文案表明房间不存在。
bool isDissolvedRoomError(Object error) {
  if (error is! ListenTogetherApiError) return false;
  if (error.code == 55006 || error.code == 20005) return true;
  if (error.code == 20002) {
    const hints = ['群组不存在', '已解散', '房间不存在'];
    if (hints.any(error.message.contains)) return true;
    final p = error.payload;
    if (p is String && hints.any(p.contains)) return true;
  }
  return false;
}

/// 20006 会话冲突判定（join/create 收到后应查会话状态恢复，不显示失败）。
bool isSessionConflictError(Object error) =>
    error is ListenTogetherApiError && error.code == 20006;

int _asInt(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim()) ?? 0;
  return 0;
}

/// 业务成功判定（HTTP 200 ≠ 成功）。
///
/// 上游可能返回 HTTP 200 但业务失败：`status == 0` 或 `error_code != 0`。
/// 成功时原样返回响应体（保留 data 包裹，交给模型层的解包函数处理）；
/// 失败时抛 [ListenTogetherApiError]，文案优先取上游 error_msg/error/msg。
Map<String, dynamic>? ensureSuccess(Object? payload) {
  if (payload is! Map) return null;
  final rec = Map<String, dynamic>.from(payload);
  final code = _asInt(rec['error_code'] ?? rec['errcode'] ?? rec['err_code'] ?? 0);
  final status = _asInt(rec['status'] ?? 1);
  if (status != 0 && code == 0) return rec;
  final msg = (rec['error_msg'] ?? rec['error'] ?? rec['msg'] ?? '').toString().trim();
  throw ListenTogetherApiError(
    msg.isNotEmpty ? msg : listenTogetherErrorMessage(code),
    code,
    rec,
  );
}

/// 进程内请求序列号，用于拼接防缓存时间戳。
int _requestSequence = 0;

/// 生成防缓存时间戳：毫秒 + 3 位递增序列号。
///
/// 上游按「hostname + 完整 URL（含 query）」缓存 2 分钟，有副作用的操作
/// 必须让每次 URL 不同；同毫秒内的连续调用靠序列号区分。
String buildCacheBustingTimestamp({int? nowMs, int? seq}) {
  final ms = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  _requestSequence = (seq ?? (_requestSequence + 1)) % 1000;
  return '$ms${_requestSequence.toString().padLeft(3, '0')}';
}

/// 一起听 API。
///
/// 全部请求经 [KugouApiClient.dio]（已内置 baseUrl、本地服务器就绪等待、
/// Authorization cookie 注入、登录态 apicache bypass），并以
/// `query[operation]` + `query[timestamp]` + JSON body 平铺参数的形式发出。
class ListenTogetherApi {
  final Dio _dio;

  ListenTogetherApi({Dio? dio}) : _dio = dio ?? KugouApiClient().dio;

  Future<Map<String, dynamic>?> _call(
    String endpoint,
    String operation, {
    Map<String, dynamic> body = const {},
  }) async {
    try {
      final resp = await _dio.post(
        endpoint,
        data: body,
        queryParameters: {
          'operation': operation,
          'timestamp': buildCacheBustingTimestamp(),
        },
        options: Options(extra: {'noCache': true}),
      );
      return ensureSuccess(resp.data);
    } on ListenTogetherApiError {
      rethrow;
    } on DioException catch (e) {
      // 上游业务错误常以 4xx/5xx 承载 JSON body，这里抢救出来按业务规则判定
      final data = e.response?.data;
      if (data is Map) return ensureSuccess(Map<String, dynamic>.from(data));
      final msg = e.message?.trim();
      throw ListenTogetherApiError(
        (msg != null && msg.isNotEmpty) ? msg : '一起听网络请求失败',
        0,
        e,
      );
    } catch (e) {
      throw ListenTogetherApiError(e.toString(), 0, e);
    }
  }

  // ===== discovery（发现/广场）=====

  /// 众乐房广场（概念版广场列表）。
  Future<Map<String, dynamic>?> gentingSquare({int page = 1, int pageSize = 20}) =>
      _call(KugouEndpoints.listenTogetherDiscovery, 'genting_square', body: {
        'page': page,
        'pagesize': pageSize,
        'order_type': 1,
      });

  /// 账号历史众乐房（「我的房间」数据源，last_id 分页）。
  /// 账号无历史记录时上游可能报业务错误，调用方按空列表处理。
  Future<Map<String, dynamic>?> roomHistory({int lastId = 0}) =>
      _call(KugouEndpoints.listenTogetherMusic, 'history', body: {'last_id': lastId});

  // ===== room（房间生命周期）=====

  /// 创建众乐房。
  ///
  /// [roomPrivacy] 概念版房型：1 = 公开房（可挂频道歌单），2 = 私密房（凭房间号进入，
  /// 受 [capacity] 人数上限约束）。默认私密。
  Future<Map<String, dynamic>?> createMusicRoom({
    required String roomName,
    String backgroundUrl = '',
    int roomPrivacy = 2,
    int capacity = 5,
  }) =>
      _call(KugouEndpoints.listenTogetherRoom, 'create', body: {
        'biz': 1009,
        'introduction': roomName.trim(),
        'room_privacy': roomPrivacy,
        'capacity': capacity,
        if (backgroundUrl.isNotEmpty) 'background_url': backgroundUrl,
      });

  Future<Map<String, dynamic>?> joinRoom(String roomId) =>
      _call(KugouEndpoints.listenTogetherRoom, 'join', body: {
        'room_id': roomId,
        'biz': 1009,
      });

  /// 查询账号当前会话；[roomId] 为空即「创建/加入前预检」。
  Future<Map<String, dynamic>?> roomStatus({String roomId = ''}) =>
      _call(KugouEndpoints.listenTogetherRoom, 'status', body: {
        'room_id': roomId,
        'biz': 1009,
      });

  Future<Map<String, dynamic>?> heartbeat(String roomId) =>
      _call(KugouEndpoints.listenTogetherRoom, 'heartbeat', body: {
        'room_id': roomId,
        'biz': 1009,
      });

  Future<Map<String, dynamic>?> leaveRoom(String roomId) =>
      _call(KugouEndpoints.listenTogetherRoom, 'leave', body: {
        'room_id': roomId,
        'biz': 1009,
      });

  Future<Map<String, dynamic>?> dismissRoom(String roomId) =>
      _call(KugouEndpoints.listenTogetherRoom, 'dismiss', body: {
        'room_id': roomId,
        'biz': 1009,
      });

  /// 房主开关房间聊天（room/update_chat：chat 1=开启 2=关闭）。
  Future<Map<String, dynamic>?> updateChat(String roomId, {required bool allow}) =>
      _call(KugouEndpoints.listenTogetherRoom, 'update_chat', body: {
        'room_id': roomId,
        'biz': 1009,
        'chat': allow ? 1 : 2,
      });

  /// 查询房间存活状态（room/state；room_state==1 为存活）。
  /// 用于加入前预检：已解散的房间在预览阶段就拦截并从列表移除。
  Future<Map<String, dynamic>?> roomState(String roomId) =>
      _call(KugouEndpoints.listenTogetherRoom, 'state', body: {
        'room_id': roomId,
        'biz': 1009,
      });

  // ===== music（众乐房领域）=====

  /// 推荐房间列表（广场回落源）。
  Future<Map<String, dynamic>?> recommendRooms({int page = 1, int pageSize = 20}) =>
      _call(KugouEndpoints.listenTogetherMusic, 'list', body: {
        'page': page,
        'pagesize': pageSize,
        'loop_pick': 0,
        'tags': '',
      });

  /// 我创建的房间列表（study 域，`/v1/study/user_create_room_list`）。
  Future<Map<String, dynamic>?> createdRooms() =>
      _call(KugouEndpoints.listenTogetherStudy, 'created_rooms');

  Future<Map<String, dynamic>?> roomDetail(String roomId) =>
      _call(KugouEndpoints.listenTogetherMusic, 'detail', body: {'room_id': roomId});

  Future<Map<String, dynamic>?> members(String roomId, {int page = 1, int pageSize = 100}) =>
      _call(KugouEndpoints.listenTogetherMusic, 'members', body: {
        'room_id': roomId,
        'page': page,
        'pagesize': pageSize,
      });

  /// 房主创建房间后初始化歌单（audios 上限 50，可携带当前播放进度）。
  Future<Map<String, dynamic>?> initializeRoom({
    required String roomId,
    required List<Map<String, dynamic>> audios,
    Map<String, dynamic>? progressInfo,
  }) =>
      _call(KugouEndpoints.listenTogetherMusic, 'initialize', body: {
        'room_id': roomId,
        'sendall': 1,
        'audios': audios.take(50).toList(),
        'progress_info': ?progressInfo,
      });

  /// 拉取当前播放状态（房主与成员都会轮询）。
  Future<Map<String, dynamic>?> syncPlayer(String roomId) =>
      _call(KugouEndpoints.listenTogetherMusic, 'sync_player', body: {'room_id': roomId});

  /// 房主歌单；[cursorAudio] 非空时以该歌曲为游标继续翻页。
  Future<Map<String, dynamic>?> playlist(
    String roomId, {
    Map<String, dynamic>? cursorAudio,
  }) =>
      _call(KugouEndpoints.listenTogetherMusic, 'playlist', body: {
        'room_id': roomId,
        'pagesize': 50,
        'audio': ?cursorAudio,
      });

  /// 听众端近期队列（一次替换，不翻页）。
  Future<Map<String, dynamic>?> recentPlaylist(String roomId) =>
      _call(KugouEndpoints.listenTogetherMusic, 'recent_playlist', body: {'room_id': roomId});

  /// 房内歌曲授权播放地址（music_reqcmd，地址位于 data.url 数组）。
  Future<Map<String, dynamic>?> playbackUrl({
    required String roomId,
    required String hash,
    required String mixSongId,
  }) =>
      _call(KugouEndpoints.listenTogetherMusic, 'playback_url', body: {
        'room_id': roomId,
        'hash': hash,
        'mixsongid': mixSongId,
      });

  /// 房主切歌上报。
  Future<Map<String, dynamic>?> switchSong({
    required String roomId,
    required String hash,
    required String mixSongId,
    required String listVersion,
    bool isAuto = false,
  }) =>
      _call(KugouEndpoints.listenTogetherMusic, 'switch_song', body: {
        'room_id': roomId,
        'act_type': 1,
        'list_version': listVersion,
        'is_auto': isAuto ? 1 : 0,
        'hash': hash,
        'mixsongid': mixSongId,
      });

  /// 房主播放操作。
  ///
  /// action: 1 = 播放模式，2 = 进度（**单位秒**），3 = 暂停/恢复（playing ? 1 : 2）。
  Future<Map<String, dynamic>?> playerOperation({
    required String roomId,
    required int action,
    int playMode = 1,
    int progressSec = 0,
    bool playing = true,
  }) =>
      _call(KugouEndpoints.listenTogetherMusic, 'player_operation', body: {
        'room_id': roomId,
        'action': action,
        if (action == 1) 'play_mode': playMode,
        if (action == 2) 'progress': progressSec,
        if (action == 3) 'pause': playing ? 1 : 2,
      });

  /// 成员点歌。
  Future<Map<String, dynamic>?> orderSong({
    required String roomId,
    required String hash,
    required String mixSongId,
  }) =>
      _call(KugouEndpoints.listenTogetherMusic, 'order_song', body: {
        'room_id': roomId,
        'hash': hash,
        'mixsongid': mixSongId,
      });

  Future<Map<String, dynamic>?> songOrderList(String roomId) =>
      _call(KugouEndpoints.listenTogetherMusic, 'song_order_list', body: {'room_id': roomId});

  /// 房主忽略一条点歌请求。
  Future<Map<String, dynamic>?> removeSong({
    required String roomId,
    required String hash,
    required String mixSongId,
    required String orderUserId,
  }) =>
      _call(KugouEndpoints.listenTogetherMusic, 'remove_song', body: {
        'room_id': roomId,
        'hash': hash,
        'mixsongid': mixSongId,
        'order_userid': orderUserId,
      });

  /// 房主把歌曲加入房间歌单。
  ///
  /// [orderUserId] 非空表示「通过成员点歌」（action = 4），否则为房主主动加歌。
  Future<Map<String, dynamic>?> musicAdd({
    required String roomId,
    required List<Map<String, dynamic>> audios,
    required String listVersion,
    String? orderUserId,
    Map<String, dynamic>? progressInfo,
  }) {
    final hasRequester = orderUserId != null && orderUserId.isNotEmpty;
    return _call(KugouEndpoints.listenTogetherMusic, 'music_add', body: {
      'room_id': roomId,
      'action': hasRequester ? 4 : 1,
      'list_version': listVersion,
      'sendall': 1,
      'audios': audios.take(50).toList(),
      'progress_info': ?progressInfo,
      if (hasRequester) 'order_userid': orderUserId,
      if (hasRequester) 'source': 1,
    });
  }

  // ===== chat（聊天）=====

  Future<Map<String, dynamic>?> sendChat({
    required String roomId,
    required String text,
    required String nickname,
    String avatar = '',
  }) =>
      _call(KugouEndpoints.listenTogetherChat, 'send', body: {
        'room_id': roomId,
        'biz': 1009,
        'message': text,
        'alert': text,
        'nickname': nickname,
        'img': avatar,
      });

  Future<Map<String, dynamic>?> chatHistory(String roomId, {String maxId = '0'}) =>
      _call(KugouEndpoints.listenTogetherChat, 'history', body: {
        'room_id': roomId,
        'biz': 1009,
        'maxid': maxId,
        'pagesize': '50',
      });
}
