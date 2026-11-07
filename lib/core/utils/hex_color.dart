import 'package:material_ui/material_ui.dart';

/// 合法色号：可选 `#` 前缀 + 3 位或 6 位十六进制数字。
///
/// 刻意不接受 8 位——Android 的 `AARRGGBB` 与 CSS 的 `RRGGBBAA` 语义冲突，
/// 猜错即给错色；种子色本身也不需要透明通道。
final RegExp _hexPattern = RegExp(r'^#?([0-9a-fA-F]{6}|[0-9a-fA-F]{3})$');

/// 解析用户输入的十六进制色号，如 `#1E88E5` / `1e88e5` / `#abc`。
///
/// 大小写与 `#` 前缀可选、首尾空白忽略；格式非法返回 null。
/// 返回的颜色恒定不透明（alpha = 0xFF）。
Color? parseHexColor(String input) {
  final text = input.trim();
  if (!_hexPattern.hasMatch(text)) return null;
  final digits = text.startsWith('#') ? text.substring(1) : text;
  var value = int.parse(digits, radix: 16);
  if (digits.length == 3) {
    // 短写按位复制展开：#abc → #aabbcc
    final r = (value >> 8) & 0xF;
    final g = (value >> 4) & 0xF;
    final b = value & 0xF;
    value = (r << 20) | (r << 16) | (g << 12) | (g << 8) | (b << 4) | b;
  }
  return Color(0xFF000000 | value);
}

/// 颜色 → 规范色号 `#RRGGBB`（大写）。alpha 被丢弃：种子色不参与透明合成。
String formatHexColor(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
