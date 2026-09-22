import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/danmaku/danmaku_entry.dart';
import 'package:md3music/core/danmaku/danmaku_source.dart';
import 'package:md3music/core/danmaku/local_danmaku_store.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('danmaku_source_test');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('LocalDanmakuSource 读取对应 key 的弹幕', () async {
    final store = LocalDanmakuStore(root: root);
    await store.append('mv:1', const DanmakuEntry(
      time: Duration(seconds: 1), text: 'hi'));
    final source = LocalDanmakuSource(store: store, key: 'mv:1');
    final loaded = await source.load();
    expect(loaded.single.text, 'hi');
  });

  test('load 失败时返回空列表而不抛出（弹幕不得中断播放）', () async {
    final source = LocalDanmakuSource(
      store: _ThrowingStore(),
      key: 'mv:1',
    );
    expect(await source.load(), isEmpty);
  });
}

/// 模拟磁盘异常。
class _ThrowingStore extends LocalDanmakuStore {
  _ThrowingStore() : super(root: Directory.systemTemp);

  @override
  Future<List<DanmakuEntry>> load(String key) async {
    throw const FileSystemException('simulated');
  }
}
