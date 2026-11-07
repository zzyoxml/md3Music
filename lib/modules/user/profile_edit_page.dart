import 'package:dpad/dpad.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/build_flags.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_text_context_menu.dart';
import '../../core/utils/app_toast.dart';
import '../../providers/kugou_provider.dart';

/// 编辑资料页：我的页面点击头像进入。
///
/// 字段对应 /user/update（昵称/性别/生日/签名/省份/城市/备注/标签，
/// 仅提交有变化的项；签名/生日/标签空串表示清空），头像走
/// /user/update/avatar（相册选图；TV 无相册选择器，引导用手机版）。
class ProfileEditPage extends StatefulWidget {
  const ProfileEditPage({super.key});

  @override
  State<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends State<ProfileEditPage> {
  late final TextEditingController _nicknameCtrl;
  late final TextEditingController _signatureCtrl;
  late final TextEditingController _provinceCtrl;
  late final TextEditingController _cityCtrl;
  late final TextEditingController _memoCtrl;
  late final TextEditingController _tagsCtrl;

  // 初值快照：详情接口未返回的字段在 UI 上是空，但服务端可能有值——
  // 用户没碰过的字段绝不能提交（空串对可空字段是"清空"语义）。
  late final String _initialNickname;
  late final String _initialSignature;
  late final String _initialProvince;
  late final String _initialCity;
  late final String _initialMemo;
  late final String _initialTags;

  /// 0 女 / 1 男 / 2 保密（/user/update 的 sex 取值）
  late int? _sex;
  late String? _birthday;
  late final int? _initialSex;
  late final String? _initialBirthday;
  bool _saving = false;
  bool _uploadingAvatar = false;

  @override
  void initState() {
    super.initState();
    final info = context.read<KugouProvider>().userInfo;
    _initialNickname = info?.nickname ?? '';
    _initialSignature = info?.signature ?? '';
    _initialProvince = info?.province ?? '';
    _initialCity = info?.city ?? '';
    _initialMemo = info?.memo ?? '';
    _initialTags = info?.tags ?? '';
    _initialSex = info?.sex;
    _initialBirthday = info?.birthday;
    _nicknameCtrl = TextEditingController(text: _initialNickname);
    _signatureCtrl = TextEditingController(text: _initialSignature);
    _provinceCtrl = TextEditingController(text: _initialProvince);
    _cityCtrl = TextEditingController(text: _initialCity);
    _memoCtrl = TextEditingController(text: _initialMemo);
    _tagsCtrl = TextEditingController(text: _initialTags);
    _sex = info?.sex;
    _birthday = info?.birthday;
  }

  @override
  void dispose() {
    _nicknameCtrl.dispose();
    _signatureCtrl.dispose();
    _provinceCtrl.dispose();
    _cityCtrl.dispose();
    _memoCtrl.dispose();
    _tagsCtrl.dispose();
    super.dispose();
  }

  // ── 头像 ──

  Future<void> _pickAndUploadAvatar() async {
    if (_uploadingAvatar) return;
    // tv: TV 无相册选择器，头像修改引导用手机版
    if (kTvBuild) {
      showToast('请使用手机版修改头像');
      return;
    }
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

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('更换头像'),
        content: const Text('将所选图片上传为账号头像？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('上传'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final bytes = await file.readAsBytes();
    if (!mounted) return;
    setState(() => _uploadingAvatar = true);
    final (ok, msg) = await context.read<KugouProvider>().updateUserAvatar(bytes);
    if (!mounted) return;
    setState(() => _uploadingAvatar = false);
    showToast(ok ? '头像已更新，生效需要一点时间' : (msg ?? '头像上传失败，请稍后重试'));
  }

  // ── 生日 ──

  Future<void> _pickBirthday() async {
    DateTime? initial;
    if (_birthday != null) {
      initial = DateTime.tryParse(_birthday!);
    }
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial ?? DateTime(2000, 1, 1),
      firstDate: DateTime(1900),
      lastDate: now,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _birthday =
          '${picked.year.toString().padLeft(4, '0')}-'
          '${picked.month.toString().padLeft(2, '0')}-'
          '${picked.day.toString().padLeft(2, '0')}';
    });
  }

  // ── 保存 ──

  Future<void> _save() async {
    if (_saving) return;
    final nickname = _nicknameCtrl.text.trim();
    if (nickname.isEmpty) {
      showToast('昵称不能为空');
      return;
    }

    // 仅提交有变化的字段（/user/update 要求至少一项）
    final String? signature = _changedText(_initialSignature, _signatureCtrl.text);
    final String? province = _changedText(_initialProvince, _provinceCtrl.text);
    final String? city = _changedText(_initialCity, _cityCtrl.text);
    final String? memo = _changedText(_initialMemo, _memoCtrl.text);
    final String? tags = _changedText(_initialTags, _tagsCtrl.text);
    // 生日/性别仅用户显式改过才提交（null = 未动过）
    final String? birthday =
        (_birthday != null && _birthday != _initialBirthday) ? _birthday : null;
    final int? sex = (_sex != null && _sex != _initialSex) ? _sex : null;
    final bool hasChange = signature != null ||
        birthday != null ||
        province != null ||
        city != null ||
        memo != null ||
        tags != null ||
        sex != null ||
        nickname != _initialNickname;
    if (!hasChange) {
      showToast('资料没有变化');
      return;
    }

    setState(() => _saving = true);
    final (ok, msg) = await context.read<KugouProvider>().updateUserProfile(
          nickname: nickname != _initialNickname ? nickname : null,
          sex: sex,
          birthday: birthday,
          signature: signature,
          province: province,
          city: city,
          memo: memo,
          tags: tags,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      showToast('资料已更新');
      Navigator.of(context).pop();
    } else {
      showToast(msg ?? '保存失败，请稍后重试');
    }
  }

  /// 文本字段变更判定：
  /// - 与初值相同 → null（不提交）；
  /// - 初值非空、现值空白 → 提交空串（用户意图清空，服务端空串=清空语义）；
  /// - 初值为空（详情未返回该字段）、现值空白 → null（避免误清服务端数据）。
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
      appBar: AppBar(title: const Text('编辑资料')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        children: [
          _buildAvatarSection(cs),
          const Gap(AppSpacing.xl),
          _buildLabel('昵称'),
          _buildTextField(
            controller: _nicknameCtrl,
            hint: '请输入昵称',
            maxLength: 30,
          ),
          const Gap(AppSpacing.lg),
          _buildLabel('性别'),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('女'), icon: Icon(Icons.female)),
              ButtonSegment(value: 1, label: Text('男'), icon: Icon(Icons.male)),
              ButtonSegment(value: 2, label: Text('保密'), icon: Icon(Icons.lock_outline)),
            ],
            selected: {_sex ?? 2},
            onSelectionChanged: (selection) =>
                setState(() => _sex = selection.first),
          ),
          const Gap(AppSpacing.lg),
          _buildLabel('生日'),
          _buildPickerRow(
            value: _birthday,
            hint: '选择生日',
            icon: Icons.cake_outlined,
            onTap: _pickBirthday,
          ),
          const Gap(AppSpacing.lg),
          _buildLabel('个性签名'),
          _buildTextField(
            controller: _signatureCtrl,
            hint: '介绍一下自己（留空表示清空）',
            maxLength: 100,
            maxLines: 2,
          ),
          const Gap(AppSpacing.lg),
          _buildLabel('地区'),
          Row(
            children: [
              Expanded(
                child: _buildTextField(
                  controller: _provinceCtrl,
                  hint: '省份名称',
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _buildTextField(
                  controller: _cityCtrl,
                  hint: '城市名称',
                ),
              ),
            ],
          ),
          const Gap(AppSpacing.lg),
          _buildLabel('备注'),
          _buildTextField(
            controller: _memoCtrl,
            hint: '个人备注',
            maxLength: 100,
            maxLines: 2,
          ),
          const Gap(AppSpacing.lg),
          _buildLabel('标签'),
          _buildTextField(
            controller: _tagsCtrl,
            hint: '多个标签用逗号分隔（留空表示清空）',
            maxLength: 50,
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

  Widget _buildAvatarSection(ColorScheme cs) {
    final info = context.watch<KugouProvider>().userInfo;
    final avatarUrl = info?.avatar;
    final child = Column(
      children: [
        Stack(
          children: [
            CircleAvatar(
              radius: 48,
              backgroundColor: cs.primary.withValues(alpha: 0.15),
              backgroundImage:
                  avatarUrl == null || avatarUrl.isEmpty ? null : NetworkImage(avatarUrl),
              child: avatarUrl == null || avatarUrl.isEmpty
                  ? Icon(Icons.person, size: 44, color: cs.onPrimaryContainer)
                  : null,
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: CircleAvatar(
                radius: 14,
                backgroundColor: cs.primary,
                child: _uploadingAvatar
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
          '点击更换头像',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
        ),
      ],
    );
    return Center(
      child: InkWell(
        onTap: _pickAndUploadAvatar,
        customBorder: const CircleBorder(),
        child: Padding(padding: const EdgeInsets.all(AppSpacing.xs), child: child),
      ),
    );
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
        fillColor:
            Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
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

  Widget _buildPickerRow({
    required String? value,
    required String hint,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    final row = InkWell(
      onTap: onTap,
      borderRadius: AppRadius.xlAll,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: AppRadius.xlAll,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: cs.onSurfaceVariant),
            const Gap(AppSpacing.md),
            Expanded(
              child: Text(
                value == null || value.isEmpty ? hint : value,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: value == null || value.isEmpty
                          ? cs.onSurfaceVariant
                          : cs.onSurface,
                    ),
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
    // TV：自定义 InkWell 行不是天然停点，包 DpadFocusable 单停点
    if (kTvBuild) {
      return DpadFocusable(
        debugLabel: 'profile-edit/birthday',
        onSelect: onTap,
        child: row,
      );
    }
    return row;
  }
}
