import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/utils/app_toast.dart';
import '../../providers/kugou_provider.dart';
import '../login/login_page.dart';

/// 听歌偏好设置页：账号管理面板入口进入（登录态作用域，与黑名单管理同级）。
///
/// 数据源 /user/preference，保存走 /user/preference/update（Rust
/// `user_preference.rs`）：mode/gender/age 直接传 id（空串=清除），lang/style
/// 传 JSON 串（选中 100 / 其余 ≤50，>50 视为启用），song_lang 传 JSON 串
/// （0 屏蔽 / 50 默认 / 100 加大）。仅提交有变化的字段；lang/style/song_lang
/// 三组标签 ID 相互独立，不做互转。保存前校验官方约束：语种不可全部屏蔽、
/// 加大 DJ 强度时不可同时屏蔽翻唱。
class MusicPreferencePage extends StatefulWidget {
  const MusicPreferencePage({super.key});

  @override
  State<MusicPreferencePage> createState() => _MusicPreferencePageState();
}

class _MusicPreferencePageState extends State<MusicPreferencePage> {
  // ── 标签词表（标准版安卓客户端口径，见接口文档字段取值表）──

  static const List<(String, String)> _ageOptions = [
    ('1', '00后'),
    ('7', '05后'),
    ('6', '10后'),
    ('8', '95后'),
    ('2', '90后'),
    ('9', '85后'),
    ('3', '80后'),
    ('10', '75后'),
    ('4', '70后'),
    ('11', '65后'),
    ('12', '60后'),
    ('0', '其它'),
  ];

  static const List<(String, String)> _langOptions = [
    ('1', '国语'),
    ('2', '粤语'),
    ('4', '英语'),
    ('5', '日语'),
    ('6', '韩语'),
    ('7', '德语'),
    ('8', '法语'),
    ('9', '意大利语'),
    ('11', '葡萄牙语'),
    ('13', '俄语'),
    ('18', '小语种'),
    ('19', '闽南语'),
    ('20', '藏语'),
    ('21', '泰语'),
    ('22', '越南语'),
  ];

  static const List<(String, String)> _styleOptions = [
    ('1', '流行'),
    ('2', '摇滚'),
    ('3', '电子'),
    ('4', '古典乐'),
    ('5', '舞曲'),
    ('6', '嘻哈'),
    ('7', '爵士'),
    ('9', '纯音乐'),
    ('10', '民谣'),
    ('12', '乡村'),
    ('14', 'R&B'),
    ('15', 'DJ'),
    ('16', 'ACG'),
    ('21', '国风'),
    ('23', '传统民歌'),
  ];

  /// 歌曲推荐强度标签（song_lang；与 lang/style 的数字 ID 独立，不应互转）。
  static const List<(String, String)> _songLangTags = [
    ('L1', '国语'),
    ('L2', '英语'),
    ('L5', '粤语'),
    ('L4', '韩语'),
    ('L3', '日语'),
    ('L6', '纯音乐'),
    ('S9', 'DJ'),
    ('T1', '翻唱'),
    ('N2', '现场'),
    ('S28', 'AI 歌曲'),
  ];

  /// song_lang 中的语种标签（官方约束：不可全部屏蔽；L6 纯音乐不算语种）。
  static const Set<String> _songLangLanguages = {'L1', 'L2', 'L5', 'L4', 'L3'};
  static const String _tagDj = 'S9';
  static const String _tagCover = 'T1';

  bool _loading = true;
  bool _loadFailed = false;
  bool _saving = false;

  // 服务器快照（diff 基准）
  String _serverMode = '';
  String _serverGender = '';
  String _serverAge = '';
  Map<String, int> _serverLang = const {};
  Map<String, int> _serverStyle = const {};
  Map<String, int> _serverSongLang = const {};

  // 可编辑状态
  String _mode = '';
  String _gender = '';
  String _age = '';
  Set<String> _langs = {};
  Set<String> _styles = {};

  /// song_lang 十个标签的当前档位（0 屏蔽 / 50 默认 / 100 加大），
  /// 服务端未出现的标签默认 50。
  Map<String, int> _songLang = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    final pref = await context.read<KugouProvider>().getUserPreference();
    if (!mounted) return;
    if (pref == null) {
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
      return;
    }
    setState(() {
      _serverMode = pref.mode;
      _serverGender = pref.gender;
      _serverAge = pref.age;
      _serverLang = pref.lang;
      _serverStyle = pref.style;
      _serverSongLang = pref.songLang;
      _mode = pref.mode;
      _gender = pref.gender;
      _age = pref.age;
      _langs = _selectedOf(pref.lang);
      _styles = _selectedOf(pref.style);
      _songLang = {
        for (final (id, _) in _songLangTags)
          id: (pref.songLang[id] ?? 50).clamp(0, 100),
      };
      _loading = false;
    });
  }

  // ── 保存 ──

  Future<void> _save() async {
    if (_saving) return;
    // 官方约束：语种不可全部屏蔽；加大 DJ 强度时不可同时屏蔽翻唱。
    final allLanguagesBlocked = _songLangLanguages
        .every((id) => (_songLang[id] ?? 50) == 0);
    if (allLanguagesBlocked) {
      showToast('语种不可全部屏蔽，至少保留一个非屏蔽语种');
      return;
    }
    if ((_songLang[_tagDj] ?? 50) > 50 && (_songLang[_tagCover] ?? 50) == 0) {
      showToast('加大 DJ 强度时不可同时屏蔽翻唱');
      return;
    }

    // 仅提交有变化的字段（update 要求至少一项；空串对可清字段=清除语义）。
    final String? mode = _mode != _serverMode ? _mode : null;
    final String? gender = _gender != _serverGender ? _gender : null;
    final String? age = _age != _serverAge ? _age : null;
    final String? lang =
        _setEquals(_langs, _selectedOf(_serverLang)) ? null : _buildWeightJson(_langs, _serverLang);
    final String? style = _setEquals(_styles, _selectedOf(_serverStyle))
        ? null
        : _buildWeightJson(_styles, _serverStyle);
    final bool songLangChanged =
        _songLangTags.any((t) => (_songLang[t.$1] ?? 50) != (_serverSongLang[t.$1] ?? 50));
    final String? songLang = songLangChanged ? _buildSongLangJson() : null;

    if (mode == null &&
        gender == null &&
        age == null &&
        lang == null &&
        style == null &&
        songLang == null) {
      showToast('偏好没有变化');
      return;
    }

    setState(() => _saving = true);
    final (ok, msg) = await context.read<KugouProvider>().updateUserPreference(
          mode: mode,
          gender: gender,
          age: age,
          lang: lang,
          style: style,
          songLang: songLang,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      showToast('偏好已更新');
      Navigator.of(context).pop();
    } else {
      showToast(msg ?? '保存失败，请稍后重试');
    }
  }

  /// 服务端权重 map 中「启用」的标签集合（>50 视为启用，与文档口径一致）。
  Set<String> _selectedOf(Map<String, int> map) =>
      map.entries.where((e) => e.value > 50).map((e) => e.key).toSet();

  bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  /// lang/style 的 JSON 串：选中 → 100；未选 → 保持服务端已知值（>50 压回 50），
  /// 服务端从未出现过的未选标签不提交（官方示例只带选中的 100 与已知降权的 50）。
  String _buildWeightJson(Set<String> selected, Map<String, int> serverMap) {
    final keys = <String>{...serverMap.keys, ...selected};
    final map = <String, int>{};
    for (final k in keys) {
      if (selected.contains(k)) {
        map[k] = 100;
      } else {
        final serverVal = serverMap[k];
        map[k] = serverVal == null ? 50 : (serverVal > 50 ? 50 : serverVal);
      }
    }
    return jsonEncode(map);
  }

  /// song_lang 的 JSON 串：固定标签序 + 服务端返回的未知标签原样保留
  /// （官方词表可能随版本扩充，不认识的不丢）。
  String _buildSongLangJson() {
    final map = <String, int>{};
    for (final (id, _) in _songLangTags) {
      map[id] = _songLang[id] ?? 50;
    }
    _serverSongLang.forEach((k, v) {
      if (!map.containsKey(k)) map[k] = v;
    });
    return jsonEncode(map);
  }

  // ── 构建 ──

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final loggedIn = context.watch<KugouProvider>().isLoggedIn;
    return Scaffold(
      appBar: AppBar(title: const Text('听歌偏好')),
      body: !loggedIn
          ? _buildLoginPrompt(cs)
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : _loadFailed
                  ? _buildErrorView(cs)
                  : _buildForm(),
    );
  }

  Widget _buildLoginPrompt(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.tune,
            size: 56,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const Gap(AppSpacing.md),
          Text(
            '登录后可设置听歌偏好',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
          const Gap(AppSpacing.lg),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute(builder: (_) => const LoginPage()),
              );
            },
            icon: const Icon(Icons.login),
            label: const Text('去登录'),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorView(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.error_outline,
            size: 48,
            color: cs.onSurfaceVariant.withValues(alpha: 0.6),
          ),
          const Gap(AppSpacing.md),
          Text(
            '偏好加载失败，请检查网络后重试',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
          const Gap(AppSpacing.lg),
          OutlinedButton(onPressed: _load, child: const Text('重试')),
        ],
      ),
    );
  }

  Widget _buildForm() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      children: [
        _buildSectionLabel('推荐模式'),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('默认')),
            ButtonSegment(value: 1, label: Text('熟悉')),
            ButtonSegment(value: 2, label: Text('尝鲜')),
          ],
          selected: {_mode.isEmpty ? 0 : (int.tryParse(_mode) ?? 0)},
          onSelectionChanged: (selection) =>
              setState(() => _mode = selection.first.toString()),
        ),
        const Gap(AppSpacing.sm),
        _buildCaption('熟悉偏向常听的内容，尝鲜会引入更多新内容'),
        const Gap(AppSpacing.lg),
        _buildSectionLabel('性别'),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 1, label: Text('女'), icon: Icon(Icons.female)),
            ButtonSegment(value: 2, label: Text('男'), icon: Icon(Icons.male)),
          ],
          // 未设置性别时账号回传空串，selected 只能是空集；SegmentedButton 默认
          // 断言 selected 非空（debug 包整页被全局 _FallbackErrorWidget 顶成
          // 「此处内容加载出错」，2026-10-12 真机堆栈），故显式允许空选择，
          // 并靠 onSelectionChanged 的 isEmpty 分支实现「再点一次=清除」。
          emptySelectionAllowed: true,
          selected: _gender.isEmpty ? {} : {int.tryParse(_gender) ?? 0},
          onSelectionChanged: (selection) => setState(() {
            _gender = selection.isEmpty ? '' : selection.first.toString();
          }),
        ),
        const Gap(AppSpacing.lg),
        _buildSectionLabel('年龄段'),
        _buildSingleChoiceChips(_ageOptions, _age, (v) => _age = v),
        const Gap(AppSpacing.lg),
        _buildSectionLabel('语言偏好'),
        _buildMultiChoiceChips(_langOptions, _langs),
        const Gap(AppSpacing.lg),
        _buildSectionLabel('风格偏好'),
        _buildMultiChoiceChips(_styleOptions, _styles),
        const Gap(AppSpacing.lg),
        _buildSectionLabel('歌曲推荐强度'),
        _buildCaption('屏蔽后不再推荐该类内容；语种不可全部屏蔽，加大 DJ 强度时不可同时屏蔽翻唱'),
        for (final (id, label) in _songLangTags) _buildSongLangRow(id, label),
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
    );
  }

  Widget _buildSectionLabel(String text) {
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

  Widget _buildCaption(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }

  /// 单选芯片组（年龄段）：点选中的芯片取消选择（服务端空串=清除）。
  Widget _buildSingleChoiceChips(
    List<(String, String)> options,
    String current,
    ValueChanged<String> onChanged,
  ) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        for (final (id, label) in options)
          ChoiceChip(
            label: Text(label),
            selected: current == id,
            onSelected: (sel) => onChanged(sel ? id : ''),
          ),
      ],
    );
  }

  /// 多选芯片组（语言 / 风格）：选中=100、取消=50，提交时才构建 JSON。
  Widget _buildMultiChoiceChips(
    List<(String, String)> options,
    Set<String> selected,
  ) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        for (final (id, label) in options)
          FilterChip(
            label: Text(label),
            selected: selected.contains(id),
            onSelected: (sel) {
              setState(() {
                if (sel) {
                  selected.add(id);
                } else {
                  selected.remove(id);
                }
              });
            },
          ),
      ],
    );
  }

  /// song_lang 单行：标签名 + 三档分段（0 屏蔽 / 50 默认 / 100 加大）。
  Widget _buildSongLangRow(String id, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const Gap(AppSpacing.md),
          Expanded(
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('屏蔽')),
                ButtonSegment(value: 50, label: Text('默认')),
                ButtonSegment(value: 100, label: Text('加大')),
              ],
              selected: {_songLang[id] ?? 50},
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onSelectionChanged: (selection) =>
                  setState(() => _songLang[id] = selection.first),
            ),
          ),
        ],
      ),
    );
  }
}
