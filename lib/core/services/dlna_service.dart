import 'dart:async';

import 'package:dlna_dart/dlna.dart';
import 'package:dlna_dart/xmlParser.dart';

/// DLNA 媒体类型，映射到 dlna_dart 的 PlayType MIME 枚举。
enum DlnaMediaType { audio, video }

/// DLNA 服务层：封装 dlna_dart 包的设备发现与传输控制。
/// 单例模式，与 [AudioService] 风格一致。
class DlnaService {
  static final DlnaService _instance = DlnaService._internal();
  factory DlnaService() => _instance;
  DlnaService._internal();

  DLNAManager? _searcher;
  DeviceManager? _deviceManager;
  DLNADevice? _connectedDevice;
  StreamSubscription<Map<String, DLNADevice>>? _deviceSub;
  StreamSubscription<PositionParser>? _positionSub;

  /// 设备发现回调，外部通过此 Stream 获取设备列表变化。
  final _devicesController =
      StreamController<List<DlnaDeviceInfo>>.broadcast();
  Stream<List<DlnaDeviceInfo>> get devicesStream => _devicesController.stream;

  /// 位置更新回调，投屏中每 2 秒推送一次。
  final _positionController = StreamController<Duration>.broadcast();
  Stream<Duration> get positionStream => _positionController.stream;

  /// 总时长更新回调。
  final _durationController = StreamController<Duration?>.broadcast();
  Stream<Duration?> get durationStream => _durationController.stream;

  bool get isCasting => _connectedDevice != null;
  String? get deviceName => _connectedDevice?.info.friendlyName;

  /// 开始 SSDP 搜索局域网内的 DLNA 渲染设备。
  Future<void> startSearch() async {
    await stopSearch();
    _searcher = DLNAManager();
    _deviceManager = await _searcher!.start();
    _deviceSub = _deviceManager!.devices.stream.listen((deviceMap) {
      final devices = deviceMap.values
          .map((d) => DlnaDeviceInfo(
                name: d.info.friendlyName,
                urlBase: d.info.URLBase,
                device: d,
              ))
          .toList();
      _devicesController.add(devices);
    });
  }

  /// 停止搜索。
  Future<void> stopSearch() async {
    await _deviceSub?.cancel();
    _deviceSub = null;
    _searcher?.stop();
    _searcher = null;
    _deviceManager = null;
  }

  /// 投屏：设置媒体 URL 并播放。
  /// [mediaType] 决定 DLNA 的 MIME 类型（音频/视频）。
  /// [overrideType] 可选，本地文件按扩展名映射的具体 PlayType；
  ///   传 null 时按 [mediaType] 兜底用 mpeg/mp4（保持向后兼容）。
  Future<bool> cast(
    String url, {
    String? title,
    required DlnaMediaType mediaType,
    PlayType? overrideType,
  }) async {
    final device = _connectedDevice;
    if (device == null) return false;

    // 显式声明为 PlayType，避免 switch 推断为 Object
    final PlayType playType = overrideType ?? switch (mediaType) {
      DlnaMediaType.audio => AudioMime.mpeg,
      DlnaMediaType.video => VideoMime.mp4,
    };

    try {
      await device.setUrl(url, title: title ?? '', type: playType);
      await device.play();
      // 切歌时先取消旧的位置监听，避免 listener 累积和旧事件干扰
      await _positionSub?.cancel();
      // 重置 position/duration，避免旧值残留导致自动切歌误触发
      _positionController.add(Duration.zero);
      _durationController.add(null);
      // 启动位置轮询
      device.positionPoller.start();
      _positionSub = device.currPosition.stream.listen((parser) {
        _positionController.add(Duration(seconds: parser.RelTimeInt));
        final dur = parser.TrackDurationInt;
        _durationController.add(
          dur > 0 ? Duration(seconds: dur) : null,
        );
      });
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 连接到指定设备（在选择设备时调用）。
  void connectDevice(DLNADevice device) {
    _connectedDevice = device;
  }

  Future<void> play() async {
    await _connectedDevice?.play();
  }

  Future<void> pause() async {
    await _connectedDevice?.pause();
  }

  /// 停止投屏并向设备发送 Stop 指令。
  Future<void> stop() async {
    _positionSub?.cancel();
    _positionSub = null;
    _connectedDevice?.positionPoller.stop();
    await _connectedDevice?.stop();
    _connectedDevice = null;
  }

  /// 跳转到指定位置。
  Future<void> seek(Duration position) async {
    final device = _connectedDevice;
    if (device == null) return;
    final target = PositionParser.toStr(position.inSeconds);
    await device.seek(target);
  }

  /// 设置音量（0-100）。
  Future<void> setVolume(int volume) async {
    await _connectedDevice?.volume(volume);
  }

  /// 获取当前音量（0-100）。
  Future<int?> getVolume() async {
    final device = _connectedDevice;
    if (device == null) return null;
    try {
      final text = await device.getVolume();
      return VolumeParser(text).current;
    } catch (_) {
      return null;
    }
  }

  /// 获取当前传输状态（PLAYING / PAUSED_PLAYBACK / STOPPED）。
  Future<String?> getTransportState() async {
    final device = _connectedDevice;
    if (device == null) return null;
    try {
      final text = await device.getTransportInfo();
      return TransportInfoParser(text).CurrentTransportState;
    } catch (_) {
      return null;
    }
  }

  /// 仅清理本地连接状态，不向设备发送 Stop。
  void disconnect() {
    _positionSub?.cancel();
    _positionSub = null;
    _connectedDevice?.positionPoller.stop();
    _connectedDevice = null;
  }

  void dispose() {
    stopSearch();
    _positionSub?.cancel();
    _devicesController.close();
    _positionController.close();
    _durationController.close();
  }
}

/// UI 层使用的设备信息数据类。
class DlnaDeviceInfo {
  final String name;
  final String urlBase;
  final DLNADevice device;

  DlnaDeviceInfo({
    required this.name,
    required this.urlBase,
    required this.device,
  });
}
