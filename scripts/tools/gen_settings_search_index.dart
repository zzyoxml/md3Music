// 设置搜索索引生成器（开发期工具，不参与 App 构建）。
//
// 用法：dart run scripts/tools/gen_settings_search_index.dart
// 产物：lib/modules/settings/settings_search_index.g.dart
//
// 索引从设置页源码推导：按 _SettingsPageState._categories 声明的分类顺序，
// 遍历每个分类的构建器，收集标题为字符串字面量的 ListTile/SwitchListTile 等
// 条目。新增或改名设置项后重新生成即可，无需手写索引。
//
// 可选标注（写在对应控件上方的注释里）：
//   // search: 别名1 别名2            给该 tile 追加搜索匹配词
//   // search: -                     该 tile 不进索引
//   // search-item: 标签 | 别名1 别名2  手写声明一条索引项，用于没有标题文本
//                                     的控件（纯图标滑块、标签与控件分离的按钮组）
//
// test/modules/settings/settings_search_index_test.dart 校验产物与源码一致。

import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// 索引条目结构（与 SettingsPage.extraSearchIndexEntries 保持一致）
typedef SettingsSearchEntry = ({String label, String category, String aliases});

const String kSettingsPageRelPath = 'lib/modules/settings/settings_page.dart';
const String kIndexOutputRelPath =
    'lib/modules/settings/settings_search_index.g.dart';

/// 视为「一条设置项」的 tile 类型
const Set<String> _tileTypes = {
  'ListTile',
  'SwitchListTile',
  'CheckboxListTile',
  'RadioListTile',
};

/// `// search: 别名1 别名2`（追加匹配词）与 `// search: -`（排除）
final RegExp _aliasPattern = RegExp(r'^//\s*search:\s*(.*)$');

/// `// search-item: 标签 | 别名1 别名2`（手写声明一条索引项）
final RegExp _manualPattern = RegExp(r'^//\s*search-item:\s*(.*)$');

/// 转成平台原生分隔符的路径（analyzer 只接受规范化的原生路径）
String localPath(String path) =>
    Platform.isWindows ? path.replaceAll('/', r'\') : path;

void main(List<String> args) {
  final root = Directory.current.path;
  final warnings = <String>[];
  final source = generateSettingsSearchIndexSource(
    projectRoot: root,
    onWarning: warnings.add,
  );
  File('$root/$kIndexOutputRelPath').writeAsStringSync(source);
  for (final w in warnings) {
    stderr.writeln('warning: $w');
  }
  stdout.writeln('已生成 $kIndexOutputRelPath');
}

/// 生成索引文件内容（生成器与一致性测试共用同一实现）
String generateSettingsSearchIndexSource({
  required String projectRoot,
  void Function(String)? onWarning,
}) {
  final entries = collectSettingsSearchEntries(
    projectRoot: projectRoot,
    onWarning: onWarning,
  );
  final buffer = StringBuffer()
    ..writeln('// GENERATED FILE — 请勿手改。')
    ..writeln('// 由 scripts/tools/gen_settings_search_index.dart 从设置页源码生成。')
    ..writeln('// 重新生成：dart run scripts/tools/gen_settings_search_index.dart')
    ..writeln()
    ..writeln('/// 设置搜索索引：label 取自各分类页 tile 的标题，category 为所属分类，')
    ..writeln('/// aliases 来自源码中的 `// search: ...` 标注（补充同义词匹配）。')
    ..writeln('const List<({String label, String category, String aliases})>')
    ..writeln('    kSettingsSearchIndex = [');
  for (final e in entries) {
    buffer.writeln(
      "  (label: '${_escape(e.label)}', "
      "category: '${_escape(e.category)}', "
      "aliases: '${_escape(e.aliases)}'),",
    );
  }
  buffer.writeln('];');
  return buffer.toString();
}

String _escape(String s) => s
    .replaceAll(r'\', r'\\')
    .replaceAll(r'$', r'\$')
    .replaceAll("'", r"\'");

/// 解析设置页源码，按分类顺序收集所有可索引的设置项
List<SettingsSearchEntry> collectSettingsSearchEntries({
  required String projectRoot,
  void Function(String)? onWarning,
}) {
  final units = _UnitCache(projectRoot);
  final unit = units.load('$projectRoot/$kSettingsPageRelPath');
  final host = _findClass(unit, '_SettingsPageState');
  if (host == null) {
    throw StateError('未在 $kSettingsPageRelPath 找到 _SettingsPageState');
  }
  final entries = <SettingsSearchEntry>[];
  for (final category in _parseCategories(host)) {
    _TileCollector(
      category: category.name,
      units: units,
      entries: entries,
      onWarning: onWarning,
      unit: unit,
      host: host,
    ).run(category.target);
  }
  return entries;
}

/// 解析 `_categories` 字面量列表：取分类名与其内容构建器。
/// 跳过 `...?SettingsPage.extraCategories`（私有构建注入，源码不可见）。
List<({String name, Expression target})> _parseCategories(
  ClassDeclaration host,
) {
  final getter = _methodNamed(host, '_categories');
  final body = getter?.body;
  final list = body is ExpressionFunctionBody ? body.expression : null;
  if (list is! ListLiteral) {
    throw StateError('_categories 不是表达式形式的列表字面量，生成器需同步调整');
  }
  final result = <({String name, Expression target})>[];
  for (final element in list.elements) {
    if (element is! RecordLiteral) continue;
    final fields = element.fields;
    if (fields.length < 3) continue;
    final name = fields.first;
    if (name is! StringLiteral) continue;
    final value = name.stringValue;
    if (value == null) continue;
    result.add((name: value, target: fields[2]));
  }
  return result;
}

/// 遍历单个分类的构建器，按源码顺序收集 tile 标题
class _TileCollector extends GeneralizingAstVisitor<void> {
  _TileCollector({
    required this.category,
    required this.units,
    required this.entries,
    required this.onWarning,
    required this.unit,
    required this.host,
  });

  final String category;
  final _UnitCache units;
  final List<SettingsSearchEntry> entries;
  final void Function(String)? onWarning;

  /// 当前所在源文件与类（用于解析私有方法 / 私有 widget 类）
  CompilationUnit unit;
  ClassDeclaration host;

  /// 防止相互调用导致的重复遍历
  final Set<String> _visited = <String>{};

  /// 已处理过的注释 offset（同一注释会挂在多个节点的首 token 上）
  final Set<int> _consumedComments = <int>{};

  void run(Expression target) {
    // 分类内容既可能是方法引用（_buildXxxSection），也可能是内联闭包
    if (target is SimpleIdentifier) {
      _followMethod(target.name);
    } else {
      target.accept(this);
    }
  }

  @override
  void visitNode(AstNode node) {
    _collectManualEntries(node);
    super.visitNode(node);
  }

  @override
  void visitNamedExpression(NamedExpression node) {
    // onTap / onChanged 等回调里构建的是交互结果，不是设置项本体
    if (node.name.label.name.startsWith('on')) return;
    super.visitNamedExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    // showDialog / showModalBottomSheet 等弹窗内容不入索引
    final name = node.methodName.name;
    if (name.startsWith('show')) return;
    // 解析期 `Foo(...)` 与函数调用同形，按标识符首字母区分构造调用
    if (node.target == null && _isTypeName(name)) {
      _handleConstruction(name, node.argumentList, node);
    }
    super.visitMethodInvocation(node);
    _followMethod(name);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _handleConstruction(
      node.constructorName.type.name.lexeme,
      node.argumentList,
      node,
    );
    super.visitInstanceCreationExpression(node);
  }

  void _handleConstruction(String type, ArgumentList arguments, AstNode node) {
    if (_tileTypes.contains(type)) {
      _record(arguments, node);
    } else {
      // 分类内容可能拆到独立 widget（如 UsbExclusiveSection、_LyricTimeOffsetTile）
      _followWidgetClass(type);
    }
  }

  /// 记录一条设置项；标题非字面量时告警跳过，`// search: -` 显式排除
  void _record(ArgumentList arguments, AstNode node) {
    final annotation = _searchAnnotation(node);
    if (annotation == '-') return;
    // 已用 `// search-item:` 显式声明标签的条目走手写分支，不再按标题提取
    if (_hasManualAnnotation(node)) return;
    final label = _literalTitle(arguments);
    if (label == null) {
      onWarning?.call('$category：tile 标题非字符串字面量，未入索引（${_where(node)}）');
      return;
    }
    entries.add((
      label: label,
      category: category,
      aliases: annotation ?? '',
    ));
  }

  /// 收集 `// search-item: 标签 | 别名…` 声明的条目。
  /// 用于没有标题文本的控件（纯图标滑块、标签与控件分离的按钮组等）。
  void _collectManualEntries(AstNode node) {
    Token? comment = node.beginToken.precedingComments;
    while (comment != null) {
      final current = comment;
      comment = comment.next;
      final match = _manualPattern.firstMatch(current.lexeme.trim());
      if (match == null) continue;
      // 同一条注释会挂在多个节点的首 token 上，去重后只登记一次
      if (!_consumedComments.add(current.offset)) continue;
      final parts = match.group(1)!.split('|');
      final label = parts.first.trim();
      if (label.isEmpty) continue;
      entries.add((
        label: label,
        category: category,
        aliases: parts.length > 1 ? parts[1].trim() : '',
      ));
    }
  }

  bool _hasManualAnnotation(AstNode node) {
    Token? comment = node.beginToken.precedingComments;
    while (comment != null) {
      if (_manualPattern.hasMatch(comment.lexeme.trim())) return true;
      comment = comment.next;
    }
    return false;
  }

  /// 取 `title: Text('…')` 中的字面量文本
  String? _literalTitle(ArgumentList arguments) {
    for (final argument in arguments.arguments) {
      if (argument is! NamedExpression) continue;
      if (argument.name.label.name != 'title') continue;
      final title = _asConstruction(argument.expression);
      if (title == null || title.name != 'Text') return null;
      for (final textArg in title.arguments.arguments) {
        if (textArg is NamedExpression) continue;
        return textArg is StringLiteral ? textArg.stringValue : null;
      }
    }
    return null;
  }

  /// 读取该 tile 对应的 `// search: …` 标注。
  /// 注释可能挂在 `child:`、`return` 等前置 token 上（注释总是绑定其后的 token），
  /// 因此沿 token 链向前找最近一条未被其他条目占用的标注。
  String? _searchAnnotation(AstNode node) {
    Token? token = node.beginToken;
    for (var step = 0; token != null && step < 60; step++) {
      Token? comment = token.precedingComments;
      Token? hit;
      String? value;
      while (comment != null) {
        final match = _aliasPattern.firstMatch(comment.lexeme.trim());
        if (match != null && !_consumedComments.contains(comment.offset)) {
          hit = comment;
          value = match.group(1)!.trim();
        }
        comment = comment.next;
      }
      if (hit != null) {
        _consumedComments.add(hit.offset);
        return value;
      }
      token = token.previous;
    }
    return null;
  }

  /// 跟进同类中返回 Widget 的私有辅助方法
  void _followMethod(String name) {
    if (!name.startsWith('_')) return;
    final method = _methodNamed(host, name);
    if (method == null || !_returnsWidget(method)) return;
    if (!_visited.add('${host.namePart.typeName.lexeme}.$name')) return;
    method.body.accept(this);
  }

  /// 跟进项目内声明的 widget 类（StatelessWidget 走自身，StatefulWidget 走 State）
  void _followWidgetClass(String type) {
    final located = units.findClass(type, preferUnit: unit);
    if (located == null) return;
    final (targetUnit, declaration) = located;
    final superName = declaration.extendsClause?.superclass.name.lexeme;
    if (superName != 'StatelessWidget' && superName != 'StatefulWidget') return;
    final target = superName == 'StatefulWidget'
        ? _findStateClass(targetUnit, type)
        : declaration;
    if (target == null) return;
    if (!_visited.add('class ${target.namePart.typeName.lexeme}')) return;
    final build = _methodNamed(target, 'build');
    if (build == null) return;
    final previousUnit = unit;
    final previousHost = host;
    unit = targetUnit;
    host = target;
    build.body.accept(this);
    unit = previousUnit;
    host = previousHost;
  }

  String _where(AstNode node) {
    final line = unit.lineInfo.getLocation(node.offset).lineNumber;
    return '${host.namePart.typeName.lexeme} 第 $line 行';
  }
}

ClassDeclaration? _findClass(CompilationUnit unit, String name) {
  for (final declaration in unit.declarations) {
    if (declaration is ClassDeclaration && declaration.namePart.typeName.lexeme == name) {
      return declaration;
    }
  }
  return null;
}

/// 标识符是否像类型名（可能是构造调用），含 `_Private` 形式
bool _isTypeName(String name) {
  final letter = name.startsWith('_') && name.length > 1 ? name[1] : name[0];
  return letter.toUpperCase() == letter && letter.toLowerCase() != letter;
}

/// 归一化「构造调用」：解析期 `Foo(...)` 是 MethodInvocation，
/// 只有 `const Foo(...)` / `new Foo(...)` 才是 InstanceCreationExpression。
({String name, ArgumentList arguments})? _asConstruction(Expression node) {
  if (node is InstanceCreationExpression) {
    return (
      name: node.constructorName.type.name.lexeme,
      arguments: node.argumentList,
    );
  }
  if (node is MethodInvocation && node.target == null) {
    return (name: node.methodName.name, arguments: node.argumentList);
  }
  return null;
}

/// 找 `class _XxxState extends State<Xxx>`
ClassDeclaration? _findStateClass(CompilationUnit unit, String widgetName) {
  for (final declaration in unit.declarations) {
    if (declaration is! ClassDeclaration) continue;
    final superclass = declaration.extendsClause?.superclass;
    if (superclass == null || superclass.name.lexeme != 'State') continue;
    final arguments = superclass.typeArguments?.arguments ?? const [];
    if (arguments.length != 1) continue;
    final argument = arguments.first;
    if (argument is NamedType && argument.name.lexeme == widgetName) {
      return declaration;
    }
  }
  return null;
}

MethodDeclaration? _methodNamed(ClassDeclaration host, String name) {
  // ClassBody.members 未纳入 analyzer 公开 API，这里仍用已弃用的 members
  // ignore: deprecated_member_use
  for (final member in host.members) {
    if (member is MethodDeclaration && member.name.lexeme == name) {
      return member;
    }
  }
  return null;
}

/// 返回类型是 `Widget` 或 `List<Widget>`
bool _returnsWidget(MethodDeclaration method) {
  final type = method.returnType;
  if (type is! NamedType) return false;
  final name = type.name.lexeme;
  if (name == 'Widget') return true;
  if (name != 'List') return false;
  final arguments = type.typeArguments?.arguments ?? const [];
  return arguments.length == 1 &&
      arguments.first is NamedType &&
      (arguments.first as NamedType).name.lexeme == 'Widget';
}

/// 解析结果缓存 + lib 下类名到文件的索引
class _UnitCache {
  _UnitCache(this.projectRoot);

  final String projectRoot;
  final Map<String, CompilationUnit> units = {};
  Map<String, String>? _classFiles;

  /// analyzer 要求平台原生分隔符的绝对路径，统一在此归一化
  CompilationUnit load(String path) {
    final native = localPath(path);
    return units.putIfAbsent(
      native,
      () => parseFile(
        path: native,
        featureSet: FeatureSet.latestLanguageVersion(),
      ).unit,
    );
  }

  (CompilationUnit, ClassDeclaration)? findClass(
    String name, {
    CompilationUnit? preferUnit,
  }) {
    if (preferUnit != null) {
      final declaration = _findClass(preferUnit, name);
      if (declaration != null) return (preferUnit, declaration);
    }
    final path = (_classFiles ??= _indexLibClasses())[name];
    if (path == null) return null;
    final unit = load(path);
    final declaration = _findClass(unit, name);
    return declaration == null ? null : (unit, declaration);
  }

  Map<String, String> _indexLibClasses() {
    final map = <String, String>{};
    final pattern = RegExp(r'^class\s+(\w+)', multiLine: true);
    final files = Directory(localPath('$projectRoot/lib'))
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      for (final match in pattern.allMatches(file.readAsStringSync())) {
        map.putIfAbsent(match.group(1)!, () => file.path);
      }
    }
    return map;
  }
}


