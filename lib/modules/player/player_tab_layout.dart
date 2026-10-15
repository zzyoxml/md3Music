// 全屏播放器底部导航条与 PlayerTabPager 的 tab 结构推导（纯逻辑，不依赖 Flutter）。
//
// tab 顺序固定为 [播放列表] [封面?] [控制?] [歌词] [评论?]：
//   * 封面 tab：只在窄屏（手机竖屏）出现。横屏/平板的封面常驻左栏、歌名固定在
//     封面下方，因此不需要该 tab。
//   * 控制 tab：宽屏且用户开启「横屏控制面板独立页」时出现（进度条/传输行/音量条
//     移入独立页签，歌词/歌单/评论获得整栏高度）；窄屏与车机面板（dockMode）永远没有。
//     紧跟播放列表，左滑一下即达，且与封面 tab 互斥（一个只在窄屏、一个只在宽屏，
//     所以两者同为下标 1 不会撞车）。
//   * 歌词 / 评论恒在控制 tab 之后，且歌词、评论的相对顺序不变。
//
// 三处消费方必须由同一份结构派生，否则 PageView 会因 children 数量与
// TabController.length 不一致而抛断言，PlayerTabStrip 的分段宽度也按 items 数量算：
//   1. TabController.length
//   2. PlayerTabPager.children
//   3. 底部导航条 PlayerTabStrip.items

/// tab 结构的语义描述：[hasCover] / [hasComments] / [hasControls] 为 false 时对应 tab 不存在。
typedef PlayerTabLayout = ({bool hasCover, bool hasComments, bool hasControls});

/// 播放页页签结构跟随播放器实际可用宽度；嵌入/车机模式也可能处于宽分栏。
bool isWidePlayerTabLayout({
  required bool dockMode,
  required bool deviceIsPad,
  required double width,
}) => width >= 600 || (!dockMode && deviceIsPad);

/// 页签的身份。结构变化（转屏 / 切歌 / 开关控制页）时按**身份**而不是按裸下标
/// 决定落到哪一页，见 [PlayerTabLayoutX.indexAfterChangeFrom]。
enum PlayerTabKind { playlist, cover, controls, lyrics, comments }

/// 由「是否宽屏布局」「是否本地歌曲」「是否关闭本地音乐评论」「是否开启控制独立页」
/// 推导 tab 结构。
///
/// [closeLocalMusicComments] 为 true 时本地歌曲不显示评论 tab
/// （对应设置项「关闭本地音乐评论区」默认开启）。
/// [showControlsPage] 为调用方算好的「用户开启且允许」信号；本函数再与
/// [isWideLayout] 求与——控制页只在宽屏存在，保证「children 里有控制页」
/// 与「build 走的是宽屏分支」由同一份字段决定，杜绝两处各算一套导致断言崩溃。
PlayerTabLayout resolvePlayerTabLayout({
  required bool isWideLayout,
  required bool isLocalSong,
  required bool closeLocalMusicComments,
  required bool showControlsPage,
}) => (
  hasCover: !isWideLayout,
  hasComments: !isLocalSong || !closeLocalMusicComments,
  hasControls: showControlsPage && isWideLayout,
);

extension PlayerTabLayoutX on PlayerTabLayout {
  /// 从左到右的页身份序列 —— **顺序的唯一真值**，下面的下标与落点都由它派生，
  /// 避免「算术公式」与「导航条 items」各写一份而漂移。
  List<PlayerTabKind> get tabKinds => [
    PlayerTabKind.playlist,
    if (hasCover) PlayerTabKind.cover,
    if (hasControls) PlayerTabKind.controls,
    PlayerTabKind.lyrics,
    if (hasComments) PlayerTabKind.comments,
  ];

  /// 某页身份的下标；该页不存在时为 -1。
  int indexOfKind(PlayerTabKind kind) => tabKinds.indexOf(kind);

  /// TabController.length，也等于 PlayerTabPager.children 的数量。
  int get length => tabKinds.length;

  /// 歌词 tab 下标（歌词 tab 恒存在）。
  int get lyricsIndex => indexOfKind(PlayerTabKind.lyrics);

  /// 封面的 tab 下标（恒为 1）。**没有封面 tab 时为 -1**。
  ///
  /// 宽屏（横屏 / 平板）没有封面 tab：封面常驻左侧栏、与 tab 无关，永远可见。
  /// 窄屏（手机竖屏）封面只在封面 tab 里；切到播放列表 / 控制 / 歌词 / 评论后
  /// 封面并不显示，消费方据此判断「封面此刻是否真的可见」（如封面形变的资格判定）。
  int get coverIndex => hasCover ? indexOfKind(PlayerTabKind.cover) : -1;

  /// 控制 tab 下标（恒为 1，与只存在于窄屏的封面 tab 互斥，两者不会撞车）。
  /// 控制页不存在时为 -1。
  int get controlsIndex => hasControls ? indexOfKind(PlayerTabKind.controls) : -1;

  /// 评论 tab 下标。评论 tab 不存在时为 -1。
  ///
  /// **不能**用 `length - 1` 反推：本地歌曲关掉评论区时最后一项是歌词，
  /// 反推会指到歌词。评论恒在歌词之后、是最后一项。
  int get commentsIndex => hasComments ? indexOfKind(PlayerTabKind.comments) : -1;

  /// 结构变化（转屏 / 切歌增删评论 / 开关控制页）后应落在的下标：**记住上一页的内容**。
  ///
  /// [from] 是变化**前**的结构，[oldIndex] 是当时 `_tabController.index`。
  /// 裸下标在不同结构里指向不同的页（窄屏 1 = 封面、宽屏 1 = 控制），
  /// 所以先按 [from] 翻成页身份，再到新结构里找同一身份的下标；播放列表与歌词
  /// 因此会跟着用户走，不再被强行拽回歌词页。
  /// 该页在新结构中不存在时，先取它的**跨形态替身**（见 [_twinKind]），
  /// 替身也不存在才落到歌词：
  ///   * 评论消失 = 它恒为末位，去掉后歌词就是最近邻（与旧的钳制行为一致）。
  int indexAfterChangeFrom(int oldIndex, PlayerTabLayout from) {
    final kinds = from.tabKinds;
    if (oldIndex < 0 || oldIndex >= kinds.length) return lyricsIndex;
    final kind = kinds[oldIndex];
    final target = indexOfKind(kind);
    if (target >= 0) return target;
    final twin = _twinKind(kind);
    if (twin != null) {
      final twinIndex = indexOfKind(twin);
      if (twinIndex >= 0) return twinIndex;
    }
    return lyricsIndex;
  }

  /// 竖屏「专辑页」与横屏「控制页」互为跨形态替身：
  /// 专辑页在宽屏不存在（封面改常驻左栏），而宽屏空出来的那一页正是控制页；
  /// 反过来转回竖屏时，控制区又回到屏幕底部常驻。所以两个方向都跟着它走，
  /// 用户旋转前后停在「同一件事」上，而不是被丢回歌词。
  PlayerTabKind? _twinKind(PlayerTabKind kind) => switch (kind) {
    PlayerTabKind.cover => PlayerTabKind.controls,
    PlayerTabKind.controls => PlayerTabKind.cover,
    _ => null,
  };
}
