import 'dart:io';

import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/build_flags.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_text_context_menu.dart';
import '../../core/utils/app_toast.dart';
import '../../data/models/playlist.dart';
import '../../services/kugou_api/kugou_api_client.dart';
import '../../widgets/smart_artwork_image.dart';
import 'cover_prepare.dart';

/// 编辑歌单页（自建 / 已收藏歌单的名称、标签、简介、自定义封面）。
///
/// 走 `/playlist/update`（`module/playlist_update.js` → `/v1/modify_list`），
/// 上游是云歌单服务，需要 `total_ver` 当乐观锁（见
/// `KugouApiClient.lastKnownPlaylistTotalVer`）。
///
/// 两个必须遵守的契约：
/// 1. **`name` / `pic` 缺省 = 不改动**（不是清空）。只有用户真的改了才下发，
///    否则空串会让上游把歌单改名成空 / 清掉封面（不可逆）。
/// 2. **`type` 语义与删除类端点相反**：这里 0 = 自建/我喜欢，1 = 收藏
///    （删除类端点是 1 = 自建、0 = 收藏）。
///
/// 封面分两条路：
/// - 自定义封面：相册选图 → `/playlist/pic/upload` 拿 FileName →
///   随本次 `/playlist/update` 的 `pic: 'custom/<FileName>'` 一起提交。
/// - 系统内置封面：`KugouApiClient.setPlaylistCover`（`/playlist/pic`）。
///   本页暂不渲染该入口（没有权威的内置封面清单，硬编码路径会 404），
///   端点与客户端方法已就绪，待补封面库后在 [_pickCover] 里加一项即可。
class PlaylistEditPage extends StatefulWidget {
  const PlaylistEditPage({
    super.key,
    required this.playlist,
    this.totalVer = 0,
    this.type = 0,
  });

  final Playlist playlist;

  /// 歌单总版本号（`/user/playlist` 的 `total_ver`），写接口的乐观锁。
  final int totalVer;

  /// 0 = 自建/我喜欢，1 = 收藏。
  final int type;

  @override
  State<PlaylistEditPage> createState() => _PlaylistEditPageState();
}

class _PlaylistEditPageState extends State<PlaylistEditPage> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _tagsCtrl;
  late final TextEditingController _introCtrl;

  // 初值快照：用于「只提交有变化的字段」判定（见 _changedText）。
  late final String _initialName;
  late final String _initialTags;
  late final String _initialIntro;

  /// 本次要提交的自定义封面（`custom/<FileName>`）。null = 不改封面。
  String? _pendingPic;

  bool _saving = false;
  bool _uploadingCover = false;

  /// 当前展示的封面 URL（服务端地址或本地预览由 SmartArtworkImage 处理兜底）。
  String? get _coverUrl => widget.playlist.artworkUri;

  /// 可写的 listid：优先用户订阅后的版本（收藏歌单只有这份有写权限），
  /// 其次原始 listCreateListid，最后回落 id。
  String get _listid => widget.playlist.subscribedListId ??
      widget.playlist.listCreateListid ??
      widget.playlist.id;

  @override
  void initState() {
    super.initState();
    _initialName = widget.playlist.name;
    _initialTags = widget.playlist.description ?? '';
    // 上游的 /user/playlist 只回 intro 到 description 字段，tags 没单独建模；
    // 标签留空由用户按需填写（清空语义与 intro 一致，见 _changedText）。
    _initialIntro = '';
    _nameCtrl = TextEditingController(text: _initialName);
    _tagsCtrl = TextEditingController();
    _introCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _tagsCtrl.dispose();
    _introCtrl.dispose();
    super.dispose();
  }

  // ── 封面 ──

  Future<void> _pickCover() async {
    if (_uploadingCover) return;
    // tv: TV 无相册选择器，与编辑资料页同一引导口径
    if (kTvBuild) {
      showToast('请使用手机版修改歌单封面');
      return;
    }

    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(sheetCtx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.pop(sheetCtx),
            ),
          ],
        ),
      ),
    );
    if (action != 'gallery' || !mounted) return;

    XFile? file;
    try {
      file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
    } catch (_) {
      showToast('选择图片失败');
      return;
    }
    if (file == null || !mounted) return;

    setState(() => _uploadingCover = true);
    // 上传与「保存」分开：上传只是拿到 FileName，用户点保存才真正改歌单。
    // 这样上传完后悔改可以直接退出，不会留下半改状态。
    //
    // 上游图床对封面有硬性尺寸/格式约束（详见 cover_prepare.dart 文档）：
    // image_picker 的 1024 下采样不放大小图、GIF 只留首帧、带 alpha 存 PNG，
    // 原样上传小图/异形图会被上游以 Bad width / Bad height 拒掉，
    // 因此先加工成 640×640 正方形 PNG，再把临时文件路径交给 Rust。
    File? tmpFile;
    try {
      final processed = await prepareCoverImage(await file.readAsBytes());
      if (!mounted) return;
      if (processed == null) {
        showToast('图片解析失败，请更换一张图片', long: true);
        return;
      }
      tmpFile = File(
        '${(await getTemporaryDirectory()).path}'
        '/cover_upload_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await tmpFile.writeAsBytes(processed);

      final api = KugouApiClient();
      final result = await api.uploadPlaylistCover(
        tmpFile.path,
        extendName: '.png',
      );
      if (!mounted) return;

      final fileName = result?['FileName']?.toString();
      if (result?['status'] != 1 || fileName == null || fileName.isEmpty) {
        // 上游英文 Message 映射为中文可操作文案（实测词汇表见 localizeCoverUploadError）
        showToast(localizeCoverUploadError(result?['msg']?.toString()), long: true);
        return;
      }
      setState(() => _pendingPic = 'custom/$fileName');
      showToast('封面已就绪，点「保存」后生效');
    } catch (e) {
      debugPrint('[PlaylistCover] upload failed: $e');
      if (mounted) showToast('封面上传失败，请稍后重试', long: true);
    } finally {
      // 临时文件即刻清理：Rust 已在上游请求结束前读完字节
      if (tmpFile != null) {
        try {
          await tmpFile.delete();
        } catch (_) {}
      }
      if (mounted) setState(() => _uploadingCover = false);
    }
  }

  // ── 保存 ──

  Future<void> _save() async {
    if (_saving) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      showToast('歌单名称不能为空');
      return;
    }
    if (_listid.isEmpty) {
      showToast('歌单ID无效', long: true);
      return;
    }

    // 只提交有变化的字段（name 与 pic 传 null 才是「不改动」）
    final String? changedName = name != _initialName ? name : null;
    final String? changedTags = _changedText(_initialTags, _tagsCtrl.text);
    final String? changedIntro = _changedText(_initialIntro, _introCtrl.text);
    final String? changedPic = _pendingPic;

    final hasChange = changedName != null ||
        changedTags != null ||
        changedIntro != null ||
        changedPic != null;
    if (!hasChange) {
      showToast('歌单没有变化');
      return;
    }

    setState(() => _saving = true);
    final api = KugouApiClient();
    final result = await api.updatePlaylistInfo(
      listid: _listid,
      totalVer: widget.totalVer,
      type: widget.type,
      name: changedName,
      tags: changedTags,
      intro: changedIntro,
      pic: changedPic,
      // 隐私/排序原样回传：v4 modify_list 官方恒发这两个字段，
      // 缺省或猜错会把隐私歌单改成公开 / 把歌单挪到列表顶部。
      isPri: widget.playlist.isPri,
      sort: widget.playlist.sort,
    );
    if (!mounted) return;
    setState(() => _saving = false);

    final ok = result != null &&
        (result['status'] == 1 || result['error_code'] == 0);
    if (ok) {
      showToast('歌单已更新');
      Navigator.of(context).pop(true);
      return;
    }
    // 上游拒绝时把原因透出来（版本过期是最常见的一种：需要在列表页刷新一次）。
    // 错误文案字段名各端点不统一（msg/error/err_msg 均见于酷狗云服务），逐个回退；
    // 只剩错误码时把码显示出来——2026-10-14 排查「编辑歌单无法保存」时发现上游
    // 业务拒绝可能不带 msg，旧逻辑会退化成无声的通用失败文案。
    debugPrint('[PlaylistSave] failed result=$result');
    final code = result?['error_code']?.toString();
    if (code == '20017' || code == '20018') {
      // 登录信息过期（token 失效或与签发平台不匹配，kugou_sdk 实网口径）。
      // v4 协议修复后正常不该出现；若出现，给可操作的提示而不是干蹦错误码。
      showToast('登录已过期，请重新登录后再保存', long: true);
      return;
    }
    final reason = _firstNonEmptyText([
      result?['msg'],
      result?['error'],
      result?['err_msg'],
      result?['errmsg'],
    ]);
    showToast(
      reason ??
          ((code != null && code.isNotEmpty)
              ? '保存失败（错误码 $code）'
              : '保存失败，请稍后重试'),
      long: true,
    );
  }

  /// 取第一个非空字符串；全是空/缺省返回 null。
  String? _firstNonEmptyText(List<dynamic> values) {
    for (final v in values) {
      final s = v?.toString();
      if (s != null && s.isNotEmpty) return s;
    }
    return null;
  }

  /// 文本字段变更判定：
  /// - 与初值相同 → null（不提交）；
  /// - 初值非空、现值空白 → 提交空串（用户意图清空，上游空串 = 清空该字段）；
  /// - 初值为空、现值空白 → null（避免把服务端已有值误清）。
  ///
  /// 与编辑资料页 `_changedText` 同一口径。
  String? _changedText(String initial, String current) {
    if (initial == current) return null;
    final trimmed = current.trim();
    if (initial.isEmpty && trimmed.isEmpty) return null;
    return trimmed;
  }

  // ── 构建 ──

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('编辑歌单')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        children: [
          _buildCoverSection(cs),
          const Gap(AppSpacing.xl),
          _buildLabel('歌单名称'),
          _buildTextField(
            controller: _nameCtrl,
            hint: '请输入歌单名称',
            maxLength: 30,
          ),
          const Gap(AppSpacing.lg),
          _buildLabel('标签'),
          _buildTextField(
            controller: _tagsCtrl,
            hint: '多个标签用逗号分隔（留空表示清空）',
            maxLength: 50,
          ),
          const Gap(AppSpacing.lg),
          _buildLabel('简介'),
          _buildTextField(
            controller: _introCtrl,
            hint: '介绍一下这个歌单（留空表示清空）',
            maxLength: 200,
            maxLines: 3,
          ),
          const Gap(AppSpacing.xl),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            ),
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _buildCoverSection(ColorScheme cs) {
    final child = Column(
      children: [
        Stack(
          children: [
            ClipRRect(
              borderRadius: AppRadius.mdAll,
              child: SizedBox(
                width: 120,
                height: 120,
                child: SmartArtworkImage(
                  artworkUri: _coverUrl,
                  size: 120,
                  borderRadius: AppRadius.md,
                ),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: CircleAvatar(
                radius: 14,
                backgroundColor: cs.primary,
                child: _uploadingCover
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.onPrimary,
                        ),
                      )
                    : Icon(Icons.camera_alt, size: 15, color: cs.onPrimary),
              ),
            ),
          ],
        ),
        const Gap(AppSpacing.sm),
        Text(
          _pendingPic != null ? '新封面已就绪，保存后生效' : '点击更换封面',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
        ),
      ],
    );

    final inkWell = InkWell(
      onTap: _uploadingCover ? null : _pickCover,
      borderRadius: AppRadius.mdAll,
      child: Padding(padding: const EdgeInsets.all(AppSpacing.xs), child: child),
    );
    // TV：自定义 InkWell 不是天然停点，包单停点（与编辑资料页同处理）
    if (kTvBuild) {
      return Center(
        child: DpadFocusable(
          debugLabel: 'playlist-edit/cover',
          onSelect: _pickCover,
          child: inkWell,
        ),
      );
    }
    return Center(child: inkWell);
  }

  Widget _buildLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    int maxLines = 1,
    int? maxLength,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      maxLength: maxLength,
      contextMenuBuilder: buildAppTextContextMenu,
      decoration: InputDecoration(
        hintText: hint,
        counterText: '',
        filled: true,
        fillColor: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.5),
        border: OutlineInputBorder(
          borderRadius: AppRadius.xlAll,
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
      ),
    );
  }
}
