import 'local_danmaku_store.dart';
import 'danmaku_entry.dart';

/// 弹幕数据源抽象。
///
/// V1 只实装 [LocalDanmakuSource]（本地持久化）。官方弹幕源实装后
/// （见计划 Task 14），在 `MvDanmakuLayer` 前组合多个 source 即可，
/// 核心算法层无需任何改动。
abstract class DanmakuSource {
  /// 加载该视频的全部弹幕。**约定：实现不得抛出异常**，失败一律返回空列表。
  Future<List<DanmakuEntry>> load();
}

/// 本地弹幕源：读取用户自己发送并持久化的弹幕。
class LocalDanmakuSource implements DanmakuSource {
  final LocalDanmakuStore store;

  /// 视频 key，形如 `mv:<videoId>` 或 `mv:<hash>`。
  final String key;

  const LocalDanmakuSource({required this.store, required this.key});

  @override
  Future<List<DanmakuEntry>> load() async {
    try {
      return await store.load(key);
    } catch (_) {
      return const [];
    }
  }
}

/// 酷狗官方 MV 弹幕源。
///
/// [fetch] 由调用方注入（生产代码传 `KugouApiClient().getVideoBarrage` 的包装，
/// 内部经 [mapVideoBarrage] 映射），使核心层不依赖网络层，便于单测。
/// [duration] 为视频总时长 —— 上游弹幕池没有时间字段，映射时需要它来合成时间轴。
class KugouDanmakuSource implements DanmakuSource {
  final Future<List<DanmakuEntry>?> Function(String idOrHash, Duration duration) fetch;
  final String idOrHash;
  final Duration duration;

  const KugouDanmakuSource({
    required this.fetch,
    required this.idOrHash,
    required this.duration,
  });

  @override
  Future<List<DanmakuEntry>> load() async {
    try {
      final entries = await fetch(idOrHash, duration);
      if (entries == null) return const [];
      return [...entries]..sort((a, b) => a.time.compareTo(b.time));
    } catch (_) {
      return const [];
    }
  }
}
