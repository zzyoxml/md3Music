import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/services/remote/ftp_client.dart';

void main() {
  test('connect + list 解析文件/目录并跳过 . 与 ..', () async {
    final server = MockFtpServer(listing: {
      '/music': [
        MockFtpFile('song.mp3', 2048),
        MockFtpFile('cover.jpg', 512),
        MockFtpFile('sub', 0, isDir: true),
      ],
    });
    await server.start();
    addTearDown(server.close);

    final client = FtpClient(
      host: '127.0.0.1',
      port: server.port,
      username: 'mock',
      password: 'pass',
    );
    await client.connect();
    addTearDown(client.disconnect);

    final entries = await client.list('/music');
    expect(entries.map((e) => e.name).toList(), ['song.mp3', 'cover.jpg', 'sub']);

    final song = entries.firstWhere((e) => e.name == 'song.mp3');
    expect(song.size, 2048);
    expect(song.isDirectory, isFalse);
    expect(song.path, '/music/song.mp3');

    final sub = entries.firstWhere((e) => e.name == 'sub');
    expect(sub.isDirectory, isTrue);
    expect(sub.size, 0);
    expect(sub.path, '/music/sub');
  });

  test('retrieve 下载文件字节（内容一致）', () async {
    final payload = List<int>.generate(128, (i) => i % 256);
    final server = MockFtpServer(contents: {'/music/a.mp3': payload});
    await server.start();
    addTearDown(server.close);

    final client = FtpClient(
      host: '127.0.0.1',
      port: server.port,
      username: 'mock',
      password: 'pass',
    );
    await client.connect();
    addTearDown(client.disconnect);

    final bytes = await client.retrieve('/music/a.mp3');
    expect(bytes, hasLength(128));
    expect(bytes.toList(), payload);
  });

  test('同连接内连续多次 list/retrieve 互不串扰', () async {
    final payload = List<int>.filled(64, 7);
    final server = MockFtpServer(
      listing: {
        '/music': [MockFtpFile('a.mp3', 64)],
      },
      contents: {'/music/a.mp3': payload},
    );
    await server.start();
    addTearDown(server.close);

    final client = FtpClient(
      host: '127.0.0.1',
      port: server.port,
      username: 'mock',
      password: 'pass',
    );
    await client.connect();
    addTearDown(client.disconnect);

    final first = await client.list('/music');
    final bytes = await client.retrieve('/music/a.mp3');
    final second = await client.list('/music');

    expect(first.map((e) => e.name), ['a.mp3']);
    expect(bytes, hasLength(64));
    expect(second.map((e) => e.name), ['a.mp3']);
  });
}

// ---- Mock FTP server（确定性时序）----

class MockFtpFile {
  final String name;
  final int size;
  final bool isDir;
  MockFtpFile(this.name, this.size, {this.isDir = false});
}

/// 最小可控 FTP 服务端：控制连接 + PASV 数据连接，实现只读会话。
///
/// 时序确定性要点：
/// - 收到 PASV 时创建数据 ServerSocket 并缓存；
/// - 收到 LIST/RETR 时先回 150 → 接受数据连接 → 写完并**关闭**数据连接 → 再回 226。
///   即 226 一定在数据连接关闭之后发出，客户端「先读完数据再读 226」不会竞态。
class MockFtpServer {
  final Map<String, List<MockFtpFile>> listing;
  final Map<String, List<int>> contents;

  ServerSocket? _ctrlServer;
  ServerSocket? _dataServer;

  MockFtpServer({
    this.listing = const {},
    this.contents = const {},
  });

  int get port => _ctrlServer!.port;

  Future<void> start() async {
    _ctrlServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _ctrlServer!.listen(_handleControl);
  }

  Future<void> close() async {
    try {
      await _dataServer?.close();
    } catch (_) {}
    await _ctrlServer?.close();
  }

  Future<void> _handleControl(Socket socket) async {
    final reader = _LineReader(socket);
    socket.write('220 Mock FTP ready\r\n');
    try {
      await for (final line in reader.stream) {
        final cmd = line.trim();
        final upper = cmd.toUpperCase();
        if (upper.startsWith('USER')) {
          socket.write('331 need password\r\n');
        } else if (upper.startsWith('PASS')) {
          socket.write('230 logged in\r\n');
        } else if (upper == 'TYPE I') {
          socket.write('200 type set to I\r\n');
        } else if (upper == 'PWD') {
          socket.write('257 "/music" is current directory\r\n');
        } else if (upper == 'PASV') {
          final ds = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
          _dataServer = ds;
          final p = ds.port;
          socket.write(
            '227 Entering Passive Mode (127,0,0,1,${p >> 8},${p & 0xFF})\r\n',
          );
        } else if (upper.startsWith('LIST')) {
          final path = cmd.length > 4 ? cmd.substring(4).trim() : '/music';
          await _serveData(socket, () {
            final buf = StringBuffer();
            // 真实服务器常返回 . 与 ..，客户端需跳过
            buf.write('drwxr-xr-x 2 owner group 4096 Jan 01 00:00 .\r\n');
            buf.write('drwxr-xr-x 2 owner group 4096 Jan 01 00:00 ..\r\n');
            for (final f in listing[path] ?? const <MockFtpFile>[]) {
              buf.write(f.isDir
                  ? 'drwxr-xr-x 2 owner group 4096 Jan 01 00:00 ${f.name}\r\n'
                  : '-rw-r--r-- 1 owner group ${f.size} Jan 01 00:00 ${f.name}\r\n');
            }
            return utf8.encode(buf.toString());
          });
        } else if (upper.startsWith('RETR')) {
          final path = cmd.length > 4 ? cmd.substring(4).trim() : '';
          await _serveData(socket, () async => contents[path] ?? const <int>[]);
        } else if (upper == 'QUIT') {
          socket.write('221 bye\r\n');
          await socket.flush();
          socket.destroy();
          return;
        } else {
          socket.write('200 ok\r\n');
        }
      }
    } catch (_) {
      // 连接被对端关闭等，忽略
    }
  }

  Future<void> _serveData(
    Socket ctrl,
    FutureOr<List<int>> Function() produce,
  ) async {
    ctrl.write('150 opening data connection\r\n');
    final ds = _dataServer;
    if (ds == null) {
      ctrl.write('425 no data connection\r\n');
      return;
    }
    _dataServer = null;
    try {
      final dataSocket = await ds.first; // 客户端已在 PASV 后连接
      final bytes = await produce();
      if (bytes.isNotEmpty) {
        dataSocket.add(bytes);
        await dataSocket.flush();
      }
      await dataSocket.close(); // 先关闭数据连接，标志传输结束
    } finally {
      try {
        await ds.close();
      } catch (_) {}
    }
    ctrl.write('226 transfer complete\r\n'); // 数据连接关闭后再回 226
  }
}

/// 按 `\r\n` 切行的字节缓冲读取器（正确处理 TCP 分片）。
class _LineReader {
  final StreamController<String> _controller = StreamController<String>();
  final List<int> _buf = [];

  _LineReader(Socket socket) {
    socket.listen(
      (chunk) {
        _buf.addAll(chunk);
        while (true) {
          final idx = _indexOfCrLf(_buf);
          if (idx < 0) break;
          final line = utf8.decode(_buf.sublist(0, idx), allowMalformed: true);
          _buf.removeRange(0, idx + 2);
          _controller.add(line);
        }
      },
      onDone: () => _controller.close(),
      onError: (Object e) => _controller.addError(e),
    );
  }

  Stream<String> get stream => _controller.stream;

  static int _indexOfCrLf(List<int> b) {
    for (var i = 0; i + 1 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10) return i;
    }
    return -1;
  }
}