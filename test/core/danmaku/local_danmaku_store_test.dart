import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/danmaku/danmaku_entry.dart';
import 'package:md3music/core/danmaku/local_danmaku_store.dart';

void main() {
  late Directory root;
  late LocalDanmakuStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('danmaku_store_test');
    store = LocalDanmakuStore(root: root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('不存在的 key 返回空列表', () async {
    expect(await store.load('mv:123'), isEmpty);
  });

  test('append 后 load 按时间升序返回', () async {
    await store.append('mv:123', const DanmakuEntry(
      time: Duration(milliseconds: 2000), text: 'b', id: 'local-2', selfSend: true));
    await store.append('mv:123', const DanmakuEntry(
      time: Duration(milliseconds: 1000), text: 'a', id: 'local-1', selfSend: true));

    final loaded = await store.load('mv:123');
    expect(loaded.map((e) => e.text).toList(), ['a', 'b']);
    expect(loaded.first.selfSend, isTrue);
    expect(loaded.first.id, 'local-1');
  });

  test('不同 key 互不干扰', () async {
    await store.append('mv:1', const DanmakuEntry(time: Duration.zero, text: 'one'));
    await store.append('mv:2', const DanmakuEntry(time: Duration.zero, text: 'two'));
    expect((await store.load('mv:1')).single.text, 'one');
    expect((await store.load('mv:2')).single.text, 'two');
  });

  test('key 中的路径分隔符与非法字符被净化，不会逃出根目录', () async {
    await store.append('mv:/../evil?name', const DanmakuEntry(
      time: Duration.zero, text: 'safe'));
    final files = root.listSync().whereType<File>().toList();
    expect(files.length, 1);
    expect(files.single.path.contains('..'), isFalse);
    expect((await store.load('mv:/../evil?name')).single.text, 'safe');
  });

  test('文件内容损坏时返回空列表且不抛异常', () async {
    final f = File('${root.path}/mv_corrupt.json');
    f.writeAsStringSync('{ this is not json');
    expect(await store.load('mv:corrupt'), isEmpty);
  });

  test('replaceAll 覆盖写入并按时间升序保存', () async {
    await store.replaceAll('mv:9', [
      const DanmakuEntry(time: Duration(milliseconds: 300), text: 'c'),
      const DanmakuEntry(time: Duration(milliseconds: 100), text: 'a'),
    ]);
    final loaded = await store.load('mv:9');
    expect(loaded.map((e) => e.text).toList(), ['a', 'c']);
    await store.replaceAll('mv:9', [
      const DanmakuEntry(time: Duration(milliseconds: 500), text: 'only'),
    ]);
    expect((await store.load('mv:9')).single.text, 'only');
  });

  test('写入的文件是合法 JSON 且含 toJson 的全部字段', () async {
    await store.append('mv:7', const DanmakuEntry(
      time: Duration(milliseconds: 1500), text: 'x', colorValue: 0x00FF00));
    final f = root.listSync().whereType<File>().single;
    final decoded = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final list = decoded['items'] as List;
    expect(list.length, 1);
    expect((list.single as Map)['text'], 'x');
    expect((list.single as Map)['time'], 1500);
    expect((list.single as Map)['color'], 0x00FF00);
  });

  test('连续快速 append 不丢条目（写入串行化）', () async {
    await Future.wait([
      store.append('mv:q', const DanmakuEntry(
        time: Duration(milliseconds: 100), text: 'a', selfSend: true)),
      store.append('mv:q', const DanmakuEntry(
        time: Duration(milliseconds: 200), text: 'b', selfSend: true)),
      store.append('mv:q', const DanmakuEntry(
        time: Duration(milliseconds: 300), text: 'c', selfSend: true)),
    ]);
    expect(
      (await store.load('mv:q')).map((e) => e.text).toSet(),
      {'a', 'b', 'c'},
    );
  });
}
