// 全屏播放器底部导航条与 TabBarView 的 tab 结构推导（纯逻辑，不依赖 Flutter）。
//
// tab 顺序固定为 [播放列表] [封面?] [歌词] [评论?]：
//   * 封面 tab：只在窄屏（手机竖屏）出现。横屏/平板的封面常驻左栏、歌名固定在
//     封面下方，因此不需要该 tab。
//   * 评论 tab：本地歌曲且用户开启了「关闭本地音乐评论区」（设置项默认值）时隐藏；
//     在线歌曲永远显示。
//
// 三处消费方必须由同一份结构派生，否则 TabBarView 会因 children 数量与
// TabController.length 不一致而抛断言，PlayerTabStrip 的分段宽度也按 items 数量算：
//   1. TabController.length
//   2. TabBarView.children
//   3. 底部导航条 PlayerTabStrip.items

/// tab 结构的语义描述：[hasCover] / [hasComments] 为 false 时对应 tab 不存在。
typedef PlayerTabLayout = ({bool hasCover, bool hasComments});

/// 由「是否宽屏布局」「是否本地歌曲」「是否关闭本地音乐评论」推导 tab 结构。
///
/// [closeLocalMusicComments] 为 true 时本地歌曲不显示评论 tab
/// （对应设置项「关闭本地音乐评论区」默认开启）。
PlayerTabLayout resolvePlayerTabLayout({
  required bool isWideLayout,
  required bool isLocalSong,
  required bool closeLocalMusicComments,
}) => (
  hasCover: !isWideLayout,
  hasComments: !isLocalSong || !closeLocalMusicComments,
);

extension PlayerTabLayoutX on PlayerTabLayout {
  /// TabController.length，也等于 TabBarView.children 的数量。
  int get length => 2 + (hasCover ? 1 : 0) + (hasComments ? 1 : 0);

  /// 歌词 tab 下标。顺序固定 [播放列表, 封面?, 歌词, 评论?]，故无封面 tab 时为 1。
  int get lyricsIndex => hasCover ? 2 : 1;

  /// 结构变化后应落在的下标。
  ///
  /// - 新结构无封面 tab（进入横屏/平板）：一律落到歌词 tab，沿用历史行为
  ///   （原 `_checkPadMode` 的 `initialIndex: newTabLength == 3 ? 1 : currentIndex`）。
  ///   注意该分支**优先于** `hasComments`：无封面 ⇒ 恒为 [lyricsIndex]，
  ///   即使当前在播放列表 tab 上也会切到歌词（与改动前一致）。
  /// - 否则保持原下标并钳制进新长度：评论 tab 消失时 3 → 2（歌词）。
  int indexAfterChangeFrom(int oldIndex) =>
      hasCover ? oldIndex.clamp(0, length - 1) : lyricsIndex;
}
