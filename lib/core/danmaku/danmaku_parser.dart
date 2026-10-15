import 'danmaku_entry.dart';

/// 把上游或本地文件中的弹幕原始数据解析为按时间升序的 [DanmakuEntry] 列表。
///
/// 字段名与类型均做容错（与 `data/models/mv_models.dart` 的风格一致），
/// 因为酷狗各接口的弹幕字段命名不统一。**任何异常都不得向上抛出** ——
/// 弹幕是锦上添花的功能，解析失败必须退化为「无弹幕」而不是中断播放。
List<DanmakuEntry> parseDanmakuList(dynamic raw) {
  final items = _extractList(raw);
  final result = <DanmakuEntry>[];
  for (final item in items) {
    if (item is! Map) continue;
    final map = item.cast<String, dynamic>();

    final text = _pickString(map, const ['text', 'content', 'msg', 'danmaku']);
    if (text == null || text.trim().isEmpty) continue;

    final ms = _pickInt(map, const [
      'time', 'progress', 'timepoint', 'position', 'offset', 'playat',
    ]);
    if (ms == null || ms < 0) continue;

    result.add(DanmakuEntry(
      time: Duration(milliseconds: ms),
      text: text.trim(),
      colorValue: (_pickInt(map, const ['color', 'fontcolor']) ?? 0xFFFFFF) & 0xFFFFFF,
      mode: _mapMode(_pickInt(map, const ['type', 'mode', 'position_type'])),
      id: _pickString(map, const ['id', 'danmaku_id', 'dmid']) ?? '',
      selfSend: map['self'] == true,
    ));
  }
  result.sort((a, b) => a.time.compareTo(b.time));
  return result;
}

/// 从若干常见包装中取出数组主体。
List<dynamic> _extractList(dynamic raw) {
  if (raw is List) return raw;
  if (raw is Map) {
    final map = raw.cast<String, dynamic>();
    for (final key in const ['data', 'list', 'barrage_list', 'comments', 'result']) {
      final v = map[key];
      if (v is List) return v;
      if (v is Map) {
        final nested = _extractList(v);
        if (nested.isNotEmpty) return nested;
      }
    }
  }
  return const [];
}

String? _pickString(Map<String, dynamic> map, List<String> keys) {
  for (final k in keys) {
    final v = map[k];
    if (v is String && v.trim().isNotEmpty) return v;
    if (v is num) return v.toString();
  }
  return null;
}

int? _pickInt(Map<String, dynamic> map, List<String> keys) {
  for (final k in keys) {
    final v = map[k];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) {
      final parsed = int.tryParse(v.trim());
      if (parsed != null) return parsed;
    }
  }
  return null;
}

/// Bilibili 弹幕约定：1=滚动，4=底部，5=顶部。未知值回退为滚动。
DanmakuMode _mapMode(int? raw) => switch (raw) {
      4 => DanmakuMode.bottom,
      5 => DanmakuMode.top,
      _ => DanmakuMode.scroll,
    };
