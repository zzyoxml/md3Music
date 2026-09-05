import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:m3e_core/m3e_core.dart' hide M3EPullToRefreshIndicator;

import '../../core/utils/app_toast.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../services/kugou_api/kugou_models.dart';

/// 导入流程所处阶段。
enum _ImportPhase {
  idle, // 未开始，展示表单
  uploading, // 截图逐张上传中
  submitting, // 正在创建云端导入任务
  polling, // 任务已创建，轮询云端状态
  success, // 导入成功
  failure, // 导入失败
}

/// 导入外部歌单功能页。
///
/// 支持两种方式（均走 /import/playlist，operation 区分）：
/// 1. 链接导入：粘贴外部歌单链接 → add_task(task_type=0)；
/// 2. 截图导入：选择歌单截图 → 逐张 submit_img → add_task(task_type=1)。
/// 任务创建后轮询 query_task_status：状态 3=成功、>=10=失败、其余=处理中；
/// 成功后用返回的 listid 调 query_task 展示导入结果。
///
/// 导入成功返回 `true`，收藏页据此刷新歌单列表。
class ImportPlaylistPage extends StatefulWidget {
  const ImportPlaylistPage({super.key});

  @override
  State<ImportPlaylistPage> createState() => _ImportPlaylistPageState();
}

class _ImportPlaylistPageState extends State<ImportPlaylistPage> {
  final KugouApiClient _api = KugouApiClient();

  _ImportPhase _phase = _ImportPhase.idle;
  String _statusText = '';
  String? _errorMsg;

  // 链接导入
  final TextEditingController _urlController = TextEditingController();

  // 截图导入
  final ImagePicker _picker = ImagePicker();
  List<XFile> _images = [];
  static const int _maxImages = 9;
  final TextEditingController _listNameController = TextEditingController();

  /// 截图导入目标：false=新建歌单（可填名称），true=导入到已有歌单。
  bool _targetExisting = false;
  List<KugouPlaylistBrief> _existingPlaylists = [];
  KugouPlaylistBrief? _selectedPlaylist;

  /// 轮询上限：2 秒一次、最多 60 次（约 2 分钟）。
  static const int _maxPollCount = 60;

  @override
  void initState() {
    super.initState();
    if (_api.isLoggedIn) {
      _loadExistingPlaylists();
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _listNameController.dispose();
    super.dispose();
  }

  bool get _busy =>
      _phase == _ImportPhase.uploading ||
      _phase == _ImportPhase.submitting ||
      _phase == _ImportPhase.polling;

  // ==================== 数据加载与解析 ====================

  /// 加载用户自建歌单（截图导入时可选作目标歌单）。
  Future<void> _loadExistingPlaylists() async {
    try {
      final resp = await _api.getUserPlaylist(page: 1, pagesize: 100);
      if (!mounted) return;
      final data = resp?['data'];
      List<dynamic>? list;
      if (data is List) {
        list = data;
      } else if (data is Map<String, dynamic>) {
        list = data['info'] as List<dynamic>? ?? data['list'] as List<dynamic>?;
      }
      if (list == null) return;

      final created = <KugouPlaylistBrief>[];
      for (final e in list) {
        if (e is! Map<String, dynamic>) continue;
        try {
          final brief = KugouPlaylistBrief.fromJson(e);
          // 仅自建歌单可作导入目标，且需要有效 listid
          if (brief.type == 0 && brief.listId.isNotEmpty) created.add(brief);
        } catch (_) {}
      }
      if (mounted) setState(() => _existingPlaylists = created);
    } catch (e) {
      if (kDebugMode) debugPrint('[ImportPlaylist] load playlists error: $e');
    }
  }

  int? _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v == null) return null;
    return int.tryParse('$v');
  }

  /// 从 add_task 响应中提取任务 ID（兼容 data 为对象/数组两种结构）。
  int? _extractTaskId(Map<String, dynamic>? resp) {
    if (resp == null || resp['status'] != 1) return null;
    final data = resp['data'];
    if (data is Map<String, dynamic>) {
      return _toInt(data['id'] ?? data['task_id'] ?? data['taskid']);
    }
    if (data is List && data.isNotEmpty && data.first is Map<String, dynamic>) {
      final m = data.first as Map<String, dynamic>;
      return _toInt(m['id'] ?? m['task_id'] ?? m['taskid']);
    }
    return _toInt(resp['id'] ?? resp['task_id'] ?? resp['taskid']);
  }

  /// 从 query_task_status 响应中取出指定任务的条目。
  Map<String, dynamic>? _extractTaskEntry(
    Map<String, dynamic>? resp,
    int taskId,
  ) {
    if (resp == null) return null;
    final data = resp['data'];
    if (data is List) {
      for (final e in data) {
        if (e is! Map<String, dynamic>) continue;
        final id = _toInt(e['id'] ?? e['task_id'] ?? e['taskid']);
        if (id == taskId) return e;
      }
      // 单条目且未带 id 字段时兜底使用
      if (data.length == 1 && data.first is Map<String, dynamic>) {
        return data.first as Map<String, dynamic>;
      }
      return null;
    }
    if (data is Map<String, dynamic>) return data;
    return null;
  }

  /// 任务条目中的目标歌单 listid（导入成功后的新歌单）。
  String? _entryListid(Map<String, dynamic> entry) {
    final v = entry['listid'] ?? entry['list_id'];
    if (v == null) return null;
    final s = '$v'.trim();
    return s.isEmpty || s == '0' ? null : s;
  }

  /// 从 query_task 响应中提取歌曲名列表（结构兜底多种形态）。
  List<String> _extractSongNames(Map<String, dynamic>? resp) {
    if (resp == null) return const [];
    dynamic data = resp['data'];
    if (data is Map<String, dynamic>) {
      data = data['list'] ?? data['info'] ?? data['songs'] ?? data['data'];
    }
    if (data is! List) return const [];
    final names = <String>[];
    for (final e in data) {
      if (e is! Map<String, dynamic>) continue;
      final name = e['name'] ?? e['songname'] ?? e['filename'];
      final s = '$name'.trim();
      if (s.isNotEmpty) names.add(s);
    }
    return names;
  }

  /// 提取业务错误描述。
  String _describeError(Map<String, dynamic>? resp, String fallback) {
    if (resp == null) return '$fallback（网络或本地服务异常）';
    final msg = resp['error_msg'] ?? resp['err_msg'] ?? resp['message'];
    final code = resp['error_code'] ?? resp['err_code'];
    if (msg != null && '$msg'.trim().isNotEmpty) {
      return '$fallback：$msg${code != null ? '（$code）' : ''}';
    }
    if (code != null) return '$fallback（错误码 $code）';
    return fallback;
  }

  // ==================== 流程 ====================

  void _fail(String msg) {
    if (!mounted) return;
    setState(() {
      _phase = _ImportPhase.failure;
      _errorMsg = msg;
      _statusText = '';
    });
  }

  /// 链接导入：add_task(task_type=0, url) → 轮询状态 → 查询结果。
  Future<void> _startLinkImport() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      showToast('请输入歌单链接');
      return;
    }
    if (!_api.isLoggedIn) {
      showToast('请先登录后再导入');
      return;
    }
    setState(() {
      _phase = _ImportPhase.submitting;
      _statusText = '正在创建导入任务…';
      _errorMsg = null;
    });

    final resp = await _api.importPlaylistByUrl(url);
    if (!mounted) return;
    final taskId = _extractTaskId(resp);
    if (taskId == null) {
      _fail(_describeError(resp, '创建导入任务失败'));
      return;
    }
    await _pollUntilDone(taskId);
  }

  /// 选择歌单截图（可多次追加）。
  Future<void> _pickImages() async {
    try {
      final picked = await _picker.pickMultiImage(imageQuality: 90);
      if (picked.isEmpty || !mounted) return;
      setState(() {
        _images = [..._images, ...picked].take(_maxImages).toList();
      });
      if (_images.length >= _maxImages) {
        showToast('最多支持 $_maxImages 张截图');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[ImportPlaylist] pick images error: $e');
      showToast('选择图片失败');
    }
  }

  /// 截图导入：逐张 submit_img → add_task(task_type=1) → 轮询状态。
  Future<void> _startImageImport() async {
    if (_images.isEmpty) {
      showToast('请先添加歌单截图');
      return;
    }
    if (!_api.isLoggedIn) {
      showToast('请先登录后再导入');
      return;
    }
    if (_targetExisting && _selectedPlaylist == null) {
      showToast('请选择目标歌单');
      return;
    }

    // 目标歌单：已有歌单用其 listid；新建歌单 listid=0 并可选名称
    String listid = '0';
    String? listName;
    if (_targetExisting && _selectedPlaylist != null) {
      listid = _selectedPlaylist!.listId;
    } else {
      final name = _listNameController.text.trim();
      if (name.isNotEmpty) listName = name;
    }

    // task_sn：userid + 毫秒时间戳（同一次导入的所有截图共用）
    final taskSn =
        '${_api.userid ?? ''}${DateTime.now().millisecondsSinceEpoch}';

    setState(() {
      _phase = _ImportPhase.uploading;
      _errorMsg = null;
    });

    // 第一步：逐张上传截图
    for (int i = 0; i < _images.length; i++) {
      if (!mounted) return;
      setState(() => _statusText = '正在上传截图 ${i + 1}/${_images.length}…');
      try {
        final bytes = await _images[i].readAsBytes();
        final b64 = base64Encode(bytes);
        final resp = await _api.importPlaylistSubmitImg(
          taskSn: taskSn,
          imgBase64: b64,
        );
        if (resp == null) {
          _fail('截图上传失败（第 ${i + 1} 张）：网络或本地服务异常');
          return;
        }
        final status = resp['status'];
        if (status != null && status != 1) {
          _fail(_describeError(resp, '截图上传失败（第 ${i + 1} 张）'));
          return;
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[ImportPlaylist] submit_img error: $e');
        }
        _fail('截图上传失败（第 ${i + 1} 张）');
        return;
      }
    }
    if (!mounted) return;

    // 第二步：创建云端导入任务
    setState(() {
      _phase = _ImportPhase.submitting;
      _statusText = '正在创建导入任务…';
    });
    final resp = await _api.importPlaylistByImages(
      taskSn: taskSn,
      listid: listid,
      listName: listName,
    );
    if (!mounted) return;
    final taskId = _extractTaskId(resp);
    if (taskId == null) {
      _fail(_describeError(resp, '创建导入任务失败'));
      return;
    }
    await _pollUntilDone(taskId);
  }

  /// 轮询任务状态直到成功（3）/失败（>=10）/超时。
  Future<void> _pollUntilDone(int taskId) async {
    setState(() {
      _phase = _ImportPhase.polling;
      _statusText = '云端导入中，请稍候…';
    });
    for (int i = 0; i < _maxPollCount; i++) {
      if (!mounted) return;
      try {
        final resp = await _api.importPlaylistQueryTaskStatus([taskId]);
        final entry = _extractTaskEntry(resp, taskId);
        if (entry != null) {
          final status = _toInt(entry['status']);
          if (status == 3) {
            await _finishSuccess(_entryListid(entry));
            return;
          }
          if (status != null && status >= 10) {
            _fail('导入失败（任务状态码 $status），请确认链接/截图有效后重试');
            return;
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[ImportPlaylist] query_task_status error: $e');
        }
        // 单次轮询异常不终止，继续等待下一次
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    _fail('等待导入超时，任务可能仍在进行，请稍后下拉刷新歌单列表查看结果');
  }

  /// 导入成功：尽量用 query_task 取回导入歌曲清单作展示。
  Future<void> _finishSuccess(String? listid) async {
    List<String> names = const [];
    if (listid != null) {
      try {
        final resp = await _api.importPlaylistQueryTask(
          listid: listid,
          page: 1,
          pagesize: 30,
        );
        if (mounted) names = _extractSongNames(resp);
      } catch (e) {
        if (kDebugMode) debugPrint('[ImportPlaylist] query_task error: $e');
      }
    }
    if (!mounted) return;
    setState(() {
      _phase = _ImportPhase.success;
      _statusText = '';
      _errorMsg = null;
      _resultSongNames = names;
    });
  }

  List<String> _resultSongNames = const [];

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('导入外部歌单')),
        body: SafeArea(
          child: _phase == _ImportPhase.success
              ? _buildSuccessPanel(cs)
              : _phase == _ImportPhase.failure
                  ? _buildFailurePanel(cs)
                  : _busy
                      ? _buildWorkingPanel(cs)
                      : _buildForm(),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: '链接导入'),
              Tab(text: '截图导入'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildLinkTab(),
                _buildImageTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLinkTab() {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '支持从其他音乐平台复制的歌单分享链接，'
          '云端识别后将创建为酷狗歌单。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _urlController,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: '粘贴外部歌单链接',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _startLinkImport,
          icon: const Icon(Icons.input),
          label: const Text('开始导入'),
        ),
      ],
    );
  }

  Widget _buildImageTab() {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '对另一个平台的歌单逐屏截图后上传，云端通过图片识别歌曲。'
          '建议截图完整包含歌名与歌手名。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 16),
        // 已选截图网格
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (int i = 0; i < _images.length; i++)
              _ImageThumb(
                file: _images[i],
                onRemove: () => setState(() => _images.removeAt(i)),
              ),
            if (_images.length < _maxImages)
              InkWell(
                onTap: _pickImages,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    border: Border.all(color: cs.outlineVariant),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.add_photo_alternate_outlined,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
        if (_images.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '已选 ${_images.length} 张（最多 $_maxImages 张）',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
        ],
        const SizedBox(height: 24),
        // 导入目标
        RadioGroup<bool>(
          groupValue: _targetExisting,
          onChanged: (v) => setState(() => _targetExisting = v ?? false),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<bool>(
                contentPadding: EdgeInsets.zero,
                title: const Text('新建歌单'),
                subtitle: const Text('识别完成后创建一个新的酷狗歌单'),
                value: false,
              ),
              if (!_targetExisting)
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: TextField(
                    controller: _listNameController,
                    decoration: const InputDecoration(
                      hintText: '新歌单名称（可选）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              RadioListTile<bool>(
                contentPadding: EdgeInsets.zero,
                title: const Text('导入到已有歌单'),
                subtitle: _existingPlaylists.isEmpty
                    ? const Text('暂无可选的自建歌单')
                    : null,
                value: true,
                enabled: _existingPlaylists.isNotEmpty,
              ),
            ],
          ),
        ),
        if (_targetExisting)
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: DropdownButtonFormField<KugouPlaylistBrief>(
              initialValue: _selectedPlaylist,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12),
              ),
              items: _existingPlaylists
                  .map(
                    (p) => DropdownMenuItem(
                      value: p,
                      child: Text(
                        '${p.name}（${p.songCount}首）',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (p) => setState(() => _selectedPlaylist = p),
            ),
          ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _startImageImport,
          icon: const Icon(Icons.input),
          label: const Text('开始导入'),
        ),
      ],
    );
  }

  Widget _buildWorkingPanel(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const M3ELoadingIndicator(),
            const SizedBox(height: 24),
            Text(
              _statusText,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '云端识别可能需要一些时间，请勿关闭页面',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSuccessPanel(ColorScheme cs) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle,
              size: 72,
              color: cs.primary,
            ),
            const SizedBox(height: 16),
            Text(
              '导入成功',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              _resultSongNames.isNotEmpty
                  ? '已导入 ${_resultSongNames.length} 首歌曲'
                  : '歌单已创建，可在收藏页查看',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
            if (_resultSongNames.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final n in _resultSongNames.take(8))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          n,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    if (_resultSongNames.length > 8)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '等共 ${_resultSongNames.length} 首',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFailurePanel(ColorScheme cs) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 72, color: cs.error),
            const SizedBox(height: 16),
            Text(
              '导入失败',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              _errorMsg ?? '未知错误',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('返回'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: () => setState(() {
                    _phase = _ImportPhase.idle;
                    _errorMsg = null;
                  }),
                  child: const Text('重试'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 已选截图缩略图（带删除角标）。
class _ImageThumb extends StatelessWidget {
  const _ImageThumb({required this.file, required this.onRemove});

  final XFile file;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(file.path),
            width: 72,
            height: 72,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(
              width: 72,
              height: 72,
              color: cs.surfaceContainerHighest,
              child: const Icon(Icons.image_not_supported),
            ),
          ),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: Material(
            color: cs.errorContainer,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onRemove,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.close,
                  size: 14,
                  color: cs.onErrorContainer,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

