import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/data/models/song.dart';
import 'package:md3music/providers/cloud_upload_provider.dart';

/// CloudUploadProvider 队列状态机测试：串行顺序、失败/重试、取消、
/// 路径去重、匹配开关传递、进度回传与完成代次。
///
/// 上传执行器注入 fake（不触网）；文件读取走真实临时文件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late List<Uint8ListFake> calls; // 上传调用记录（matchUpload + 字节数）
  late CloudUploadProvider provider;
  var nextStatus = 1;
  var nextMatched = false;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('cloud_upload_test');
    calls = <Uint8ListFake>[];
    nextStatus = 1;
    nextMatched = false;
    provider = CloudUploadProvider(
      isLoggedInFn: () => true,
      uploadFn: (body,
          {required extendname,
          name,
          authorName,
          timelen,
          required matchUpload,
          onProgress,
          onStage}) async {
        calls.add(
          Uint8ListFake(
            bytes: body.length,
            matchUpload: matchUpload,
            name: name ?? '',
            extendname: extendname,
          ),
        );
        return {
          'status': nextStatus,
          if (nextStatus == 0) 'msg': '上游拒绝',
          'matchInfo': {'matched': nextMatched},
        };
      },
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Song songOf(String fileName) {
    final file = File('${tempDir.path}/$fileName')
      ..writeAsBytesSync(List.generate(16, (i) => i));
    return Song(
      id: 'local_${file.path}',
      title: fileName.replaceAll('.mp3', ''),
      artist: '测试歌手',
      album: '',
      duration: const Duration(milliseconds: 3000),
      localPath: file.path,
      isOnline: false,
    );
  }

  Future<void> pumpUntilIdle() async {
    for (var i = 0; i < 400 && provider.isRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  test('队列按顺序串行上传，全部成功后递增完成代次', () async {
    final added = provider.enqueueSongs([songOf('a.mp3'), songOf('b.mp3')]);
    expect(added, 2);
    await pumpUntilIdle();

    expect(provider.isRunning, isFalse);
    expect(provider.successCount, 2);
    expect(provider.failedCount, 0);
    expect(calls.map((c) => c.name).toList(), ['a', 'b']);
    expect(provider.completedGeneration, 1);
    expect(provider.tasks.every((t) => t.status == CloudUploadStatus.success),
        isTrue);
    // 进度应被推进到 100%
    expect(provider.overallProgress, 1.0);
  });

  test('服务端 status:0 → 任务标记失败并带原因，重试后转成功', () async {
    nextStatus = 0;
    provider.enqueueSongs([songOf('fail.mp3')]);
    await pumpUntilIdle();

    expect(provider.failedCount, 1);
    expect(provider.tasks.first.status, CloudUploadStatus.failed);
    expect(provider.tasks.first.error, '上游拒绝');
    expect(provider.completedGeneration, 0);

    nextStatus = 1;
    expect(provider.retryFailed(), 1);
    await pumpUntilIdle();

    expect(provider.successCount, 1);
    expect(calls.length, 2, reason: '重试应再次调用上传');
  });

  test('单任务重试只影响该任务', () async {
    nextStatus = 0;
    provider.enqueueSongs([songOf('x.mp3'), songOf('y.mp3')]);
    await pumpUntilIdle();
    expect(provider.failedCount, 2);

    nextStatus = 1;
    final ok = provider.retryTask(provider.tasks.first.id);
    expect(ok, isTrue);
    await pumpUntilIdle();

    expect(provider.successCount, 1);
    expect(provider.failedCount, 1);
    expect(calls.length, 3);
  });

  test('cancelWaiting 只移除未开始任务', () async {
    // 第一首上传前先入队三首，再在首个任务执行期间取消等待任务
    final barrier = Completer<void>();
    provider = CloudUploadProvider(
      isLoggedInFn: () => true,
      uploadFn: (body,
          {required extendname,
          name,
          authorName,
          timelen,
          required matchUpload,
          onProgress,
          onStage}) async {
        await barrier.future;
        return {'status': 1};
      },
    );
    provider.enqueueSongs([songOf('hold.mp3'), songOf('w1.mp3'), songOf('w2.mp3')]);
    // 等第一个任务进入 uploading
    for (var i = 0;
        i < 200 &&
            provider.currentTask?.status != CloudUploadStatus.uploading;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(provider.cancelWaiting(), 2, reason: '两首等待任务应被移除');
    expect(provider.tasks.length, 1);
    barrier.complete();
    await pumpUntilIdle();
    expect(provider.successCount, 1);
  });

  test('同路径去重；失败路径重新入队会重置为等待', () async {
    final s = songOf('dup.mp3');
    expect(provider.enqueueSongs([s]), 1);
    expect(provider.enqueueSongs([s]), 0, reason: '重复路径不再入队');

    nextStatus = 0;
    await pumpUntilIdle();
    expect(provider.failedCount, 1);

    // 失败后重新选择同一路径：重置为等待并重新上传
    nextStatus = 1;
    expect(provider.enqueueSongs([s]), 1);
    await pumpUntilIdle();
    expect(provider.successCount, 1);
    expect(calls.length, 2);
  });

  test('匹配开关实时传递给上传调用', () async {
    await provider.setMatchEnabled(false);
    provider.enqueueSongs([songOf('off.mp3')]);
    await pumpUntilIdle();
    expect(calls.single.matchUpload, isFalse);

    await provider.setMatchEnabled(true);
    provider.enqueueSongs([songOf('on.mp3')]);
    await pumpUntilIdle();
    expect(calls.last.matchUpload, isTrue);
  });

  test('进度回调回填 uploaded/total，命中标记来自 matchInfo', () async {
    provider = CloudUploadProvider(
      isLoggedInFn: () => true,
      uploadFn: (body,
          {required extendname,
          name,
          authorName,
          timelen,
          required matchUpload,
          onProgress,
          onStage}) async {
        onStage?.call('matching');
        onProgress?.call(body.length ~/ 2, body.length);
        await Future<void>.delayed(Duration.zero);
        onProgress?.call(body.length, body.length);
        return {
          'status': 1,
          'matchInfo': {'matched': true},
        };
      },
    );
    provider.enqueueSongs([songOf('prog.mp3')]);
    // matching 状态只存在于两次补丁之间（同步），轮询抓不到 ——
    // 用监听器在每次 notifyListeners 时同步快照
    var sawMatching = false;
    var sawPartialProgress = false;
    void snapshot() {
      final t = provider.tasks.first;
      if (t.matching) sawMatching = true;
      if (t.status == CloudUploadStatus.uploading &&
          t.uploaded > 0 &&
          t.uploaded < t.total) {
        sawPartialProgress = true;
      }
    }

    provider.addListener(snapshot);
    await pumpUntilIdle();
    provider.removeListener(snapshot);

    final task = provider.tasks.first;
    expect(task.status, CloudUploadStatus.success);
    expect(task.matched, isTrue);
    expect(task.uploaded, task.total);
    expect(task.total, 16);
    expect(sawMatching, isTrue, reason: '应观察到 matching 阶段');
    expect(sawPartialProgress, isTrue, reason: '应观察到中间进度');
  });
}

class Uint8ListFake {
  Uint8ListFake({
    required this.bytes,
    required this.matchUpload,
    required this.name,
    required this.extendname,
  });

  final int bytes;
  final bool matchUpload;
  final String name;
  final String extendname;
}
