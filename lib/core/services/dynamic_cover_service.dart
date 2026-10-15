import 'package:connectivity_plus/connectivity_plus.dart';

import '../../data/models/dy_cover_models.dart';
import '../../data/models/song.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_endpoints.dart';

/// 是否应加载动态封面（纯函数，便于单测）。
///
/// [isWifi] 语义与 `PlayerProvider` 的网络判定一致：连接类型列表不含
/// [ConnectivityResult.mobile] 即按 WiFi 处理（覆盖 wifi / ethernet / vpn / none）。
bool shouldLoadDynamicCover({
  required bool enabled,
  required bool allowOnMobile,
  required bool isWifi,
}) {
  if (!enabled) return false;
  return isWifi || allowOnMobile;
}

/// 元数据预检结论。**必须区分「确定没有」与「这次没查到」**：
/// 前者可以永久跳过，后者若也跳过就会让一次瞬时失败（回环服务器未就绪、
/// 上游抖动、非 200）演变成「该专辑整个会话都不再显示动态封面」的静默失效。
enum DyCoverProbe { present, absent, unknown }

/// 元数据响应 → 预检结论（纯函数，便于单测）。
///
/// [json] 为 null 表示请求失败（`getAlbumDyCoverRaw` 的 null 语义），结论是
/// [DyCoverProbe.unknown]，**不得**据此写负缓存。
DyCoverProbe mapDyCoverProbe(Map<String, dynamic>? json, String albumAudioId) {
  if (json == null) return DyCoverProbe.unknown;
  final info = DyCoverInfo.fromResponse(json, albumAudioId: albumAudioId);
  return info == null ? DyCoverProbe.absent : DyCoverProbe.present;
}

/// 播放页「界面设置」菜单里「当前歌曲动态封面」的展示文案（纯函数，便于单测）。
///
/// - 非在线音频 / 缺 albumAudioId（本地歌曲、云盘无专辑信息）→ `不适用`
/// - [known] 非 null → `有` / `无`
/// - [known] 为 null：正在请求（[probing]）→ `检测中…`；请求已结束仍未拿到
///   确定结果（查询失败）→ `未获取到`（**不显示 `无`**，避免把失败说成没有）
String dyCoverStatusText({
  required bool isOnline,
  required String albumAudioId,
  required bool? known,
  bool probing = false,
}) {
  if (!isOnline || albumAudioId.isEmpty) return '不适用';
  if (known != null) return known ? '有' : '无';
  return probing ? '检测中…' : '未获取到';
}

/// 专辑动态封面门控与元数据预检。
///
/// 职责边界（刻意保持很窄）：
/// - **只管「该不该加载」与「有没有动态封面」**，不管字节怎么传；
/// - 媒体字节由回环代理流式转发，`video_player` 直接消费（公开构建 = 每次流式；
///   私有构建命中本地文件时改播本地文件，见 `dynamic_cover_view.dart` 的扩展点）；
/// - 因此本服务**不落盘、不缓存文件**，公开树里不存在任何缓存代码路径。
class DynamicCoverService {
  DynamicCoverService._();
  static final DynamicCoverService instance = DynamicCoverService._();

  /// 每个专辑最近一次的**确定性**探测结果：true = 有动态封面，false = 确定没有。
  ///
  /// - 用作快速路径，避免同一专辑被反复请求；
  /// - [DyCoverProbe.unknown]（查询失败）**绝不写入** —— 否则一次瞬时失败会让该
  ///   专辑整个会话都不再显示动态封面（静默且无法自愈），见 [mapDyCoverProbe]；
  /// - 同时供界面设置菜单经 [lastKnownResult] 即时显示「当前歌曲是否有动态封面」。
  final Map<String, bool> _lastProbe = {};
  /// 进行中的元数据查询：并发去重
  final Map<String, Future<DyCoverProbe>> _inflight = {};

  /// 该歌曲当前是否满足加载条件（在线 + 主开关 + 网络门控）。
  Future<bool> shouldLoad(Song song) async {
    if (!song.isOnline) return false;
    final settings = SettingsRepository();
    final enabled = await settings.getDynamicAlbumCover();
    if (!enabled) return false;
    if (await _detectIsWifi()) return true;
    return settings.getDynamicAlbumCoverOnMobile();
  }

  /// 回环代理播放地址（本地服务器明文回环已在 network_security_config 放行）。
  ///
  /// 客户端始终经此地址取字节：CDN 明文域名不进入 ExoPlayer，CDN 的具体
  /// 域名/签名/时效逻辑全部留在 Rust 侧。
  String streamUrlFor(String albumAudioId) =>
      '${KugouEndpoints.baseUrl}${KugouEndpoints.dyCoverMedia}'
      '?album_audio_id=$albumAudioId';

  /// 该专辑是否存在动态封面。
  ///
  /// 只有**确定**的结果（有 / 无）写入缓存；查询失败返回 false 但**不**缓存，
  /// 因此下一首切回该专辑会重新探测，不会静默失效。
  Future<bool> hasDynamicCover(String albumAudioId) async {
    final cached = _lastProbe[albumAudioId];
    if (cached != null) return cached;
    final running = _inflight[albumAudioId];
    if (running != null) return (await running) == DyCoverProbe.present;

    final task = _probe(albumAudioId);
    _inflight[albumAudioId] = task;
    try {
      final result = await task;
      if (result != DyCoverProbe.unknown) {
        _lastProbe[albumAudioId] = result == DyCoverProbe.present;
      }
      return result == DyCoverProbe.present;
    } finally {
      _inflight.remove(albumAudioId);
    }
  }

  /// 已探测到的确定结果（null = 尚未探测过，或上次查询失败）。
  /// 仅供 UI 即时展示，不会触发请求。
  bool? lastKnownResult(String albumAudioId) => _lastProbe[albumAudioId];

  Future<DyCoverProbe> _probe(String albumAudioId) async {
    try {
      final json = await KugouApiClient().getAlbumDyCoverRaw(albumAudioId);
      return mapDyCoverProbe(json, albumAudioId);
    } catch (_) {
      return DyCoverProbe.unknown;
    }
  }

  /// 清空会话内探测结果（切账号 / 测试场景使用）。
  void resetSessionCache() {
    _lastProbe.clear();
    _inflight.clear();
  }

  /// 网络判定：与 PlayerProvider 保持一致（不含移动数据即 WiFi；探测失败按 WiFi）。
  Future<bool> _detectIsWifi() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return !results.contains(ConnectivityResult.mobile);
    } catch (_) {
      return true;
    }
  }
}
