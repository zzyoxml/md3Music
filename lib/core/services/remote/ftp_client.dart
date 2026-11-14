import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// FTP 目录条目（与 WebDavEntry 同构）。
class FtpEntry {
  final String path;
  final String name;
  final bool isDirectory;
  final int size;

  const FtpEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.size = 0,
  });
}

/// 轻量 FTP 客户端（只读场景）：connect / list / retrieve。
///
/// 仅实现被动模式（PASV）+ 二进制传输（TYPE I），覆盖列目录与下载两个需求。
/// 每命令走「控制连接发指令 → 被动数据连接传数据」的标准流程。
class FtpClient {
  final String host;
  final int port;
  final String username;
  final String password;

  Socket? _control;
  StreamSubscription<List<int>>? _controlSub;

  /// 控制连接行缓冲（**实例级**，非 static：避免多连接/并发串扰）。
  /// 在 [connect] 时清空。
  StringBuffer _lineBuffer = StringBuffer();

  /// 已从控制连接解析出的完整响应行队列。
  final List<String> _lineQueue = [];

  /// 等待新行的信号（队列为空时挂起）。
  Completer<void>? _lineSignal;

  /// 本次连接当前所在目录（由 PWD 得到）。
  String? _currentDir;

  bool _closed = false;

  /// 当前所在目录（登录时由 PWD 得到）。
  String? get currentDirectory => _currentDir;

  FtpClient({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
  });

  /// 建立控制连接并完成登录（220 → USER/331 → PASS/230 → TYPE I/200 → PWD/257）。
  Future<void> connect() async {
    _lineBuffer = StringBuffer();
    _lineQueue.clear();
    _closed = false;
    _control = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 8),
    );
    _controlSub = _control!.listen(
      _onControlData,
      onError: (Object e, StackTrace s) => _onControlClosed(e),
      onDone: () => _onControlClosed(null),
    );

    await _expect(220);
    await _send('USER $username');
    await _expect(331);
    await _send('PASS $password');
    await _expect(230);
    await _send('TYPE I');
    await _expect(200);
    await _send('PWD');
    final pwd = await _expect(257);
    _currentDir = _extractQuoted(pwd);
  }

  /// 关闭控制连接。
  Future<void> disconnect() async {
    try {
      _control?.write('QUIT\r\n');
      await _control?.flush();
    } catch (_) {
      // 连接可能已断开，忽略
    }
    await _controlSub?.cancel();
    _controlSub = null;
    _control?.destroy();
    _control = null;
    _lineQueue.clear();
    _lineBuffer = StringBuffer();
  }

  /// 列出 [path] 目录内容。
  Future<List<FtpEntry>> list(String path) {
    return _withDataConnection((dataSocket) async {
      await _send('LIST $path');
      await _expect(150);
      final bytes = await _readAll(dataSocket);
      final text = utf8.decode(bytes, allowMalformed: true);
      final entries = <FtpEntry>[];
      for (final line in const LineSplitter().convert(text)) {
        final e = _parseListLine(line, path);
        if (e != null) entries.add(e);
      }
      await _expect(226);
      return entries;
    });
  }

  /// 下载 [path] 文件全部字节。
  Future<Uint8List> retrieve(String path) {
    return _withDataConnection((dataSocket) async {
      await _send('RETR $path');
      await _expect(150);
      final bytes = await _readAll(dataSocket);
      await _expect(226);
      return bytes;
    });
  }

  /// 被动模式封装：PASV → 连接数据端口 → 执行 [handler] → 关闭数据连接。
  Future<T> _withDataConnection<T>(
    Future<T> Function(Socket dataSocket) handler,
  ) async {
    await _send('PASV');
    final resp = await _expect(227);
    final (dataHost, dataPort) = _parsePasv(resp);
    final dataSocket = await Socket.connect(
      dataHost,
      dataPort,
      timeout: const Duration(seconds: 8),
    );
    try {
      return await handler(dataSocket);
    } finally {
      dataSocket.destroy();
    }
  }

  /// 读取数据连接的全部字节，直到对端关闭。
  Future<Uint8List> _readAll(Socket socket) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in socket) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _send(String cmd) async {
    final c = _control;
    if (c == null) throw StateError('FTP 未连接');
    c.write('$cmd\r\n');
    await c.flush();
  }

  /// 等待一个完整响应（处理多行响应 `xyz-...` 直到 `xyz `）。
  Future<String> _expect(int code) async {
    final line = await _nextResponseLine();
    final actual =
        line.length >= 3 ? (int.tryParse(line.substring(0, 3)) ?? -1) : -1;
    if (actual != code) {
      throw StateError('FTP 期望 $code 实际 $actual: $line');
    }
    return line;
  }

  Future<String> _nextResponseLine() async {
    final first = await _dequeueLine();
    // 多行响应：第 4 个字符为 '-' 表示后续还有行，直到第 4 个字符为 ' '
    if (first.length >= 4 && first[3] == '-') {
      final buf = StringBuffer(first);
      while (true) {
        final next = await _dequeueLine();
        buf.write('\n');
        buf.write(next);
        if (next.length >= 4 && next[3] == ' ') break;
      }
      return buf.toString();
    }
    return first;
  }

  Future<String> _dequeueLine() async {
    while (_lineQueue.isEmpty) {
      if (_closed) throw StateError('FTP 控制连接已关闭');
      final signal = Completer<void>();
      _lineSignal = signal;
      await signal.future;
    }
    return _lineQueue.removeAt(0);
  }

  /// 控制连接数据到达：按 `\r\n` 切分完整行入队（正确处理 TCP 分片）。
  void _onControlData(List<int> chunk) {
    // 状态行均为 ASCII，逐字节转字符串安全
    _lineBuffer.write(String.fromCharCodes(chunk));
    final s = _lineBuffer.toString();
    var start = 0;
    while (true) {
      final idx = s.indexOf('\r\n', start);
      if (idx < 0) break;
      _lineQueue.add(s.substring(start, idx));
      start = idx + 2;
    }
    if (start > 0) {
      _lineBuffer = StringBuffer(s.substring(start));
    }
    _wake();
  }

  void _onControlClosed(Object? error) {
    _closed = true;
    _wake();
  }

  void _wake() {
    final signal = _lineSignal;
    if (signal != null && !signal.isCompleted) {
      signal.complete();
    }
    _lineSignal = null;
  }

  static String _extractQuoted(String line) {
    final start = line.indexOf('"');
    final end = line.lastIndexOf('"');
    if (start >= 0 && end > start) return line.substring(start + 1, end);
    return '/';
  }

  /// 解析 `227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)`。
  static (String, int) _parsePasv(String line) {
    final m = RegExp(r'(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)').firstMatch(line);
    if (m == null) throw StateError('PASV 响应无法解析: $line');
    final dataHost = '${m.group(1)}.${m.group(2)}.${m.group(3)}.${m.group(4)}';
    final dataPort = int.parse(m.group(5)!) * 256 + int.parse(m.group(6)!);
    return (dataHost, dataPort);
  }

  /// 解析 Unix 风格 LIST 行：
  /// `-rw-r--r-- 1 owner group 1234 Jan 01 00:00 name`
  /// 目录（权限位首字符 d 或名字以 / 结尾）置 isDirectory；跳过 `.` 与 `..`。
  FtpEntry? _parseListLine(String rawLine, String parentPath) {
    final line = rawLine.trimRight();
    final re = RegExp(
      r'^([\-dl])[rwxstST\-]{9}\s+\d+\s+\S+\s+\S+\s+(\d+)\s+\S+\s+\S+\s+\S+\s+(.+)$',
    );
    final m = re.firstMatch(line);
    if (m == null) return null;

    final isDir = m.group(1) == 'd';
    final size = int.tryParse(m.group(2)!) ?? 0;
    var name = m.group(3)!.trim();
    final hasDirSuffix = name.endsWith('/');
    if (hasDirSuffix) name = name.substring(0, name.length - 1);

    if (name.isEmpty || name == '.' || name == '..') return null;

    final normalized = parentPath.endsWith('/') ? parentPath : '$parentPath/';
    return FtpEntry(
      path: '$normalized$name',
      name: name,
      isDirectory: isDir || hasDirSuffix,
      size: isDir ? 0 : size,
    );
  }
}