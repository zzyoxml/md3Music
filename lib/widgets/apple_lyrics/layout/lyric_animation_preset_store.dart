import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/build_flags.dart';
import 'lyric_preferences.dart';

/// 单个歌词动画预设。
///
/// 只承载「歌词动画」页的 18 项参数（见
/// [LyricPreferences.animationValueKeys]），不包含模糊/辉光/动态颜色开关。
/// [platform] 记录该预设的来源平台（android / windows / tv），用于导入导出
/// 时展示平台标签与跨平台识别。
class LyricAnimationPreset {
  LyricAnimationPreset({
    required String name,
    required Map<String, Object?> values,
    this.createdAt,
    String platform = '',
  })  : name = normalizeName(name),
        platform = LyricAnimationPresetStore.normalizePlatform(platform),
        values = Map<String, Object?>.unmodifiable(
          LyricPreferences.sanitizeAnimationValues(values),
        );

  /// 预设名称（已 trim、截断到 [LyricAnimationPresetStore.maxNameLength]）。
  final String name;

  /// 来源平台标签（'' = 未知；已知值见
  /// [LyricAnimationPresetStore.normalizePlatform]）。
  final String platform;

  /// 参数表（键为 `LyricPreferences` getter 名，值类型见
  /// [LyricPreferences.sanitizeAnimationValues]）。
  final Map<String, Object?> values;

  /// 创建/更新时间（导入时缺省为 null）。
  final DateTime? createdAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        if (platform.isNotEmpty) 'platform': platform,
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
        'values': values,
      };

  /// 解析单个预设对象（`{name, platform, values, createdAt}`），
  /// 非法或空参数返回 null。
  ///
  /// [defaultPlatform] 用于 JSON 未携带平台标签时补全来源。
  static LyricAnimationPreset? fromJson(
    Object? raw, {
    String defaultPlatform = '',
  }) {
    if (raw is! Map) return null;
    final values = LyricPreferences.sanitizeAnimationValues(raw['values']);
    if (values.isEmpty) return null;
    final rawName = raw['name'];
    final rawCreatedAt = raw['createdAt'];
    final name = rawName is String ? rawName.trim() : '';
    final rawPlatform = raw['platform'];
    final entryPlatform = LyricAnimationPresetStore.normalizePlatform(rawPlatform);
    return LyricAnimationPreset(
      // 落盘数据缺名时给稳定兜底；导入路径不走本方法，空名会在导入时编号。
      name: name.isEmpty ? '导入预设' : name,
      values: values,
      platform: entryPlatform.isEmpty ? defaultPlatform : entryPlatform,
      createdAt:
          rawCreatedAt is String ? DateTime.tryParse(rawCreatedAt) : null,
    );
  }

  /// 名称归一：trim + 超长截断（允许空串，由调用方决定兜底策略）。
  static String normalizeName(String raw) {
    final trimmed = raw.trim();
    if (trimmed.length <= LyricAnimationPresetStore.maxNameLength) {
      return trimmed;
    }
    return trimmed.substring(0, LyricAnimationPresetStore.maxNameLength);
  }
}

/// 歌词动画多档预设仓库（单例 + [ChangeNotifier]）。
///
/// 预设独立存储在 [storageKey]，不参与 `LyricPreferences.reset()` /
/// 设置页「还原所有设置」，避免用户资产被一并清掉。
class LyricAnimationPresetStore extends ChangeNotifier {
  LyricAnimationPresetStore._();

  static final LyricAnimationPresetStore instance = LyricAnimationPresetStore._();

  /// SharedPreferences 存储键（值为导出格式的 JSON 字符串）。
  static const String storageKey = 'lyric_animation_presets_v1';

  /// 导出文档标识（导入时不做强校验，仅作来源说明）。
  static const String formatTag = 'md3music.lyric_animation';

  /// 导出文档版本。
  static const int formatVersion = 1;

  /// 预设名称最大长度（输入框与导入共用）。
  static const int maxNameLength = 20;

  /// 内置性能预设名称（保留名称，用户预设不可占用）。
  ///
  /// 保留 [defaultPresetName] 作为别名，供旧代码/旧文档引用。
  static const String performancePresetName = '性能优先';

  /// 兼容别名：内置预设原名（等价于 [performancePresetName]）。
  static const String defaultPresetName = performancePresetName;

  /// 内置「流畅优先」预设名称（保留名称）。
  static const String smoothPresetName = '流畅优先';

  /// 所有内置预设名称（只读，不可删除 / 重命名 / 覆盖）。
  static const Set<String> builtInPresetNames = <String>{
    performancePresetName,
    smoothPresetName,
  };

  /// 内置预设的补充说明（展示在名称下方，拼接在内置提示之前）。
  static const Map<String, String> builtInPresetDescriptions = <String, String>{
    performancePresetName: '完整动画',
  };

  /// 是否为内置（只读）预设名称。
  static bool isBuiltInPreset(String name) =>
      builtInPresetNames.contains(name.trim());

  /// 内置「性能优先」预设（列表首位，不可删除 / 重命名 / 覆盖）。
  ///
  /// 这套参数动画最完整（错峰 990ms、上浮 2.5px、衰减 1.1x），
  /// 故在界面副标题里标注「完整动画」。
  /// Windows 的辉光固定时长上限为 900ms（见
  /// `maxGlowFixedThresholdMsForCurrentPlatform`），此处按平台折算，
  /// 保证应用后与预设值完全一致（对勾可正确命中）。
  static final LyricAnimationPreset performancePreset = LyricAnimationPreset(
    name: performancePresetName,
    platform: 'windows',
    values: <String, Object?>{
      'inactiveScale': 0.85,
      'alignPosition': 0.34844447355541364,
      'liftHeightPx': 2.5,
      'interludeDotsStartX': 1.1901128231999865,
      'interludeDotRadius': 0.20063305441385973,
      'interludeDotSpacing': 0.9,
      'cascadeMaxDelayMs': 990.0,
      'cascadeBaseStepMs': 80.0,
      'cascadeDecayX': 1.1,
      'preStartBiasMs': 118.49028694318446,
      'dynamicColorMixRatio': 0.15,
      'blurIntensity': 1.0,
      'glowIntensity': 1.0,
      'glowThresholdFactor': 1.2,
      'glowFixedThresholdMs': Platform.isWindows ? 900.0 : 1000.0,
      'staggerFromCurrentLine': false,
      'glowThresholdMode': 'fixed',
      'fillMode': 'sweep',
      // 透明度取默认：复刻引入该设置前的历史观感
      'playedOpacity': 1.0,
      'unplayedOpacity': 0.4,
    },
  );

  /// 兼容别名：旧的 [defaultPreset] 引用（等价于 [performancePreset]）。
  static LyricAnimationPreset get defaultPreset => performancePreset;

  /// 是否为内置性能预设名称（旧名 isDefaultPreset 保留兼容）。
  static bool isDefaultPreset(String name) =>
      name.trim() == performancePresetName;

  /// 内置「流畅优先」预设：错峰完全关闭，切行零滞后。
  ///
  /// 取向是「动画让位于流畅」：错峰上限/步长归零（渲染侧 lineDelay<=0
  /// 即立即释放）、衰减 1.00 不衰减、非当前行缩放压到 0.60 让当前行更醒目。
  static final LyricAnimationPreset smoothPreset = LyricAnimationPreset(
    name: smoothPresetName,
    platform: 'windows',
    values: <String, Object?>{
      'inactiveScale': 0.60,
      'alignPosition': 0.45,
      'liftHeightPx': 1.7,
      'interludeDotsStartX': 1.50,
      'interludeDotRadius': 0.18,
      'interludeDotSpacing': 0.90,
      'cascadeMaxDelayMs': 0.0,
      'cascadeBaseStepMs': 0.0,
      'cascadeDecayX': 1.0,
      'preStartBiasMs': 0.0,
      'dynamicColorMixRatio': 0.15,
      'blurIntensity': 1.0,
      'glowIntensity': 1.0,
      'glowThresholdFactor': 1.2,
      'glowFixedThresholdMs': 500.0,
      'staggerFromCurrentLine': true,
      'glowThresholdMode': 'fixed',
      'fillMode': 'sweep',
      // 透明度取默认：复刻引入该设置前的历史观感
      'playedOpacity': 1.0,
      'unplayedOpacity': 0.4,
    },
  );

  /// 全部内置预设（按展示顺序）。
  static final List<LyricAnimationPreset> builtInPresets =
      List<LyricAnimationPreset>.unmodifiable(<LyricAnimationPreset>[
    performancePreset,
    smoothPreset,
  ]);

  /// 已知平台标签。
  static const Set<String> knownPlatforms = <String>{'android', 'windows', 'tv'};

  /// 归一平台标签：仅接受已知值的小写形式，其他一律视为未知（''）。
  static String normalizePlatform(Object? raw) {
    if (raw is! String) return '';
    final value = raw.trim().toLowerCase();
    return knownPlatforms.contains(value) ? value : '';
  }

  /// 当前运行平台标签：TV 构建优先，其次 Windows，其余归为 Android。
  static String currentPlatformTag() {
    if (kTvBuild) return 'tv';
    return Platform.isWindows ? 'windows' : 'android';
  }

  /// 平台标签的展示名（未知返回空串）。
  static String platformLabel(String tag) {
    switch (tag) {
      case 'android':
        return 'Android';
      case 'windows':
        return 'Windows';
      case 'tv':
        return 'TV';
      default:
        return '';
    }
  }

  final List<LyricAnimationPreset> _presets = <LyricAnimationPreset>[];
  bool _loaded = false;
  Future<void>? _loading;

  List<LyricAnimationPreset> get presets =>
      List<LyricAnimationPreset>.unmodifiable(_presets);

  /// 展示用完整列表：内置默认预设 + 用户预设。
  List<LyricAnimationPreset> get allPresets =>
      List<LyricAnimationPreset>.unmodifiable(<LyricAnimationPreset>[
        ...builtInPresets,
        ..._presets,
      ]);

  bool get loaded => _loaded;

  /// 从 SharedPreferences 加载预设（幂等；解析失败视为空列表）。
  ///
  /// 并发调用共用同一个 Future，避免页面 initState 与首次保存/导入同时
  /// 触发加载时互相清空列表。
  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loading ??= _loadFromStorage();
  }

  Future<void> _loadFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _presets.clear();
      final raw = prefs.getString(storageKey);
      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map && decoded['presets'] is List) {
            final documentPlatform =
                LyricAnimationPresetStore.normalizePlatform(decoded['platform']);
            final fallback = documentPlatform.isEmpty
                ? LyricAnimationPresetStore.currentPlatformTag()
                : documentPlatform;
            for (final item in decoded['presets'] as List) {
              final preset =
                  LyricAnimationPreset.fromJson(item, defaultPlatform: fallback);
              if (preset != null) _replaceOrAdd(preset);
            }
          }
        } catch (error) {
          debugPrint('[LyricAnimationPresetStore] 预设解析失败: $error');
        }
      }
    } finally {
      _loaded = true;
      _loading = null;
      notifyListeners();
    }
  }

  /// 把当前歌词动画参数保存为预设（同名覆盖）。
  ///
  /// 返回 true 表示新增，false 表示覆盖了同名预设。
  Future<bool> saveCurrentAsPreset(String name) async {
    await load();
    final normalizedName = LyricAnimationPreset.normalizeName(
      name.trim().isEmpty ? '未命名预设' : name,
    );
    // 内置默认预设为只读兜底：拒绝占用其保留名称
    if (isBuiltInPreset(normalizedName)) return false;
    final preset = LyricAnimationPreset(
      name: normalizedName,
      values: LyricPreferences.instance.exportAnimationValues(),
      createdAt: DateTime.now(),
      platform: LyricAnimationPresetStore.currentPlatformTag(),
    );
    final index = _indexOf(preset.name);
    final isNew = index < 0;
    if (isNew) {
      _presets.add(preset);
    } else {
      _presets[index] = preset;
    }
    await _persist();
    notifyListeners();
    return isNew;
  }

  /// 删除指定名称的预设，返回是否命中。
  Future<bool> deletePreset(String name) async {
    await load();
    final index = _indexOf(name);
    if (index < 0) return false;
    _presets.removeAt(index);
    await _persist();
    notifyListeners();
    return true;
  }

  /// 应用指定名称的预设；名称不存在时静默返回。
  Future<void> applyPreset(String name) async {
    await load();
    for (final preset in builtInPresets) {
      if (preset.name == name) {
        await LyricPreferences.instance.applyAnimationValues(preset.values);
        return;
      }
    }
    final index = _indexOf(name);
    if (index < 0) return;
    await LyricPreferences.instance
        .applyAnimationValues(_presets[index].values);
  }

  /// 当前参数完全匹配的预设名（按预设中出现的键做子集匹配）。
  String? activePresetName() {
    final current = LyricPreferences.instance.exportAnimationValues();
    for (final preset in builtInPresets) {
      if (_matches(preset, current)) return preset.name;
    }
    for (final preset in _presets) {
      if (_matches(preset, current)) return preset.name;
    }
    return null;
  }

  bool _matches(
    LyricAnimationPreset preset,
    Map<String, Object?> current,
  ) {
    for (final entry in preset.values.entries) {
      if (current[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// 解析 JSON 文本为预设列表（只解析，不写入仓库）。
  ///
  /// 兼容完整文档、单预设对象、裸参数对象与预设数组；无任何可识别参数时
  /// 抛 [FormatException]。返回条目的名称可能为空串，由调用方决定兜底。
  List<LyricAnimationPreset> parsePresetsFromJson(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('JSON 内容为空');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      throw const FormatException('不是有效的 JSON');
    }
    final incoming = _extractPresets(decoded);
    if (incoming.isEmpty) {
      throw const FormatException('JSON 中没有可识别的歌词动画参数');
    }
    return incoming;
  }

  /// 从 JSON 文本导入预设，返回导入/更新的预设数。
  ///
  /// 同名预设覆盖参数，不重复创建。
  Future<int> importFromJsonText(String text) async {
    final presets = parsePresetsFromJson(text);
    return importPresets(presets);
  }

  /// 导入已解析的预设。
  ///
  /// [names] 按索引提供自定义名称（导入前改名用）；缺失或空串时回退到
  /// JSON 内的名称，仍为空则用「导入预设」并按需追加序号。
  Future<int> importPresets(
    List<LyricAnimationPreset> presets, {
    List<String>? names,
  }) async {
    await load();
    if (presets.isEmpty) return 0;

    var imported = 0;
    for (var i = 0; i < presets.length; i++) {
      final preset = presets[i];
      var name =
          (names != null && i < names.length ? names[i] : preset.name).trim();
      // 内置预设名称为只读：导入时自动追加序号，避免出现同名只读项
      if (isBuiltInPreset(name)) {
        var suffix = 2;
        var candidate = '$name $suffix';
        while (isBuiltInPreset(candidate) || _indexOf(candidate) >= 0) {
          suffix++;
          candidate = '$name $suffix';
        }
        name = candidate;
      }
      if (name.isEmpty) {
        // 空名称按序号兜底，避免同一文档内多个无名预设互相覆盖。
        name = '导入预设';
        var suffix = 2;
        while (_indexOf(name) >= 0) {
          name = '导入预设 $suffix';
          suffix++;
        }
      }
      _replaceOrAdd(
        LyricAnimationPreset(
          name: name,
          values: preset.values,
          platform: preset.platform,
          createdAt: preset.createdAt ?? DateTime.now(),
        ),
      );
      imported++;
    }
    await _persist();
    notifyListeners();
    return imported;
  }

  /// 重命名预设。
  ///
  /// 返回 false：旧名称不存在、新名称为空、或新名称已被其他预设占用
  /// （不会静默覆盖另一档预设）。
  Future<bool> renamePreset(String oldName, String newName) async {
    await load();
    final index = _indexOf(oldName);
    if (index < 0) return false;
    final normalized = LyricAnimationPreset.normalizeName(newName);
    if (normalized.isEmpty) return false;
    if (isBuiltInPreset(normalized)) return false;
    if (normalized == oldName) return true;
    if (_indexOf(normalized) >= 0) return false;

    final old = _presets[index];
    _presets[index] = LyricAnimationPreset(
      name: normalized,
      values: old.values,
      platform: old.platform,
      createdAt: old.createdAt,
    );
    await _persist();
    notifyListeners();
    return true;
  }

  /// 导出单个预设为 JSON 文本；不存在返回 null。
  String? exportPresetAsJson(String name) {
    for (final preset in builtInPresets) {
      if (preset.name == name) {
        return _encode(<LyricAnimationPreset>[preset]);
      }
    }
    final index = _indexOf(name);
    if (index < 0) return null;
    return _encode(<LyricAnimationPreset>[_presets[index]]);
  }

  /// 把当前参数导出为单预设 JSON（[name] 为导出预设名，不写入预设库）。
  String exportCurrentAsJson({String name = '当前设置'}) {
    final preset = LyricAnimationPreset(
      name: name,
      values: LyricPreferences.instance.exportAnimationValues(),
      createdAt: DateTime.now(),
      platform: LyricAnimationPresetStore.currentPlatformTag(),
    );
    return _encode(<LyricAnimationPreset>[preset]);
  }

  /// 导出全部预设为 JSON 文本。
  String exportAllAsJson() => _encode(_presets);

  /// 仅测试使用：清空内存态，隔离单例在用例间的残留。
  @visibleForTesting
  void resetForTest() {
    _presets.clear();
    _loaded = false;
    _loading = null;
  }

  int _indexOf(String name) =>
      _presets.indexWhere((preset) => preset.name == name);

  void _replaceOrAdd(LyricAnimationPreset preset) {
    final index = _indexOf(preset.name);
    if (index < 0) {
      _presets.add(preset);
    } else {
      _presets[index] = preset;
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, exportAllAsJson());
  }

  String _encode(List<LyricAnimationPreset> presets) {
    final document = <String, Object?>{
      'app': 'md3music',
      'type': formatTag,
      'version': formatVersion,
      'platform': LyricAnimationPresetStore.currentPlatformTag(),
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'presets': presets.map((preset) => preset.toJson()).toList(growable: false),
    };
    return JsonEncoder.withIndent('  ').convert(document);
  }

  List<LyricAnimationPreset> _extractPresets(Object? decoded) {
    // 文档级平台标签作为各预设的兜底来源；缺失时按当前平台归入。
    final documentPlatform =
        decoded is Map ? LyricAnimationPresetStore.normalizePlatform(decoded['platform']) : '';
    final fallbackPlatform = documentPlatform.isEmpty
        ? LyricAnimationPresetStore.currentPlatformTag()
        : documentPlatform;

    final result = <LyricAnimationPreset>[];
    if (decoded is List) {
      for (final item in decoded) {
        final preset = _extractOne(item, fallbackPlatform);
        if (preset != null) result.add(preset);
      }
      return result;
    }
    if (decoded is Map) {
      final presets = decoded['presets'];
      if (presets is List) {
        for (final item in presets) {
          final preset = _extractOne(item, fallbackPlatform);
          if (preset != null) result.add(preset);
        }
        return result;
      }
      final preset = _extractOne(decoded, fallbackPlatform);
      if (preset != null) result.add(preset);
    }
    return result;
  }

  /// 从任意对象里提取一个预设：
  /// - `{name, platform, values, createdAt}`
  /// - `{values}`
  /// - 顶层直接是参数键的对象
  LyricAnimationPreset? _extractOne(Object? raw, String fallbackPlatform) {
    if (raw is! Map) return null;
    final valuesRaw = raw.containsKey('values') ? raw['values'] : raw;
    final values = LyricPreferences.sanitizeAnimationValues(valuesRaw);
    if (values.isEmpty) return null;
    final rawName = raw['name'];
    final rawCreatedAt = raw['createdAt'];
    final rawPlatform = raw['platform'];
    final entryPlatform = LyricAnimationPresetStore.normalizePlatform(rawPlatform);
    return LyricAnimationPreset(
      name: rawName is String ? rawName : '',
      values: values,
      platform: entryPlatform.isEmpty ? fallbackPlatform : entryPlatform,
      createdAt:
          rawCreatedAt is String ? DateTime.tryParse(rawCreatedAt) : null,
    );
  }
}
