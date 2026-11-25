/// 演示卡共用的假数据：不与真实歌曲/歌词耦合，避免演示卡去读播放器状态。
library;

import '../../widgets/apple_lyrics/layout/duet_layout.dart';

/// 「歌词效果」演示卡用的对唱片段。
///
/// 性别标记由 [kPreviewDuetPrefixes] 单独给出（左=男 / 右=女），
/// 与真实对唱口径一致：播放页的 [DuetLayout.process] 会剥掉「男：」「女：」
/// 前缀再按性别分左右（duet_layout.dart:182-183, 211-229），
/// 所以演示卡也不能把前缀留在正文里。
const List<String> kPreviewDuetTexts = <String>[
  '夜色沉入海面',
  '星光落进眼睛',
];

/// 对唱片段的性别标记（与 [kPreviewDuetTexts] 等长、同下标）。
///
/// 男→左对齐、女→右对齐、合→居中（见 [DuetAlignment] 的映射口径）。
const List<String> kPreviewDuetPrefixes = <String>['男', '女'];

/// 「歌词效果」演示卡用的非对唱片段。
const List<String> kPreviewSingleTexts = <String>[
  '上一句歌词在这里',
  '把晚安说给风听',
  '它就会替我去见你',
];
