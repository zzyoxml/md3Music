// 顶栏尾部胶囊（睡眠定时 / 一起听 / 更多）的几何、动效与收回时机。
//
// 直接测 [TopBarTrailingCapsule]：它只吃 `TopBarTrailingSegment` 数据与回调，
// 不碰 provider，于是能在没有真实房间会话（RoomSession 一构造就起轮询定时器，
// 测试里会留 pending timer）和真实倒计时的情况下验证。
//
// 三种形态共用**同一颗连体背景**：竖屏收缩态只露图标、点一下先展开（擦出一开始
// 之后再点就执行，不必等动画跑完）；宽屏与关掉「胶囊按钮收缩」时常显文案、点一下
// 直接执行。**⋯ 与长按恒为一步**（菜单入口和音量面板不需要「先看清再按」）。
// 展开后**不再定时自动收回**，改由按到胶囊以外才收回（见 [_tapOutside]）。
// 背景盖到 ⋯ **之前**为止（⋯ 是裸图标），
// 所以这里的断言大多是「背景宽度 == 整行宽度 − ⋯ 那一格 40dp」这一条。
//
// 另两组覆盖宿主的 segments 增删：被移除那格淡出并让出占宽、新格淡入，
// 且格子的展开状态按 `semanticsLabel` 存 —— 中间那格没了不会把状态留给邻居。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:md3music/widgets/player_top_bar_actions.dart';

const Color _bg = Color(0xFFE6E6E6);
const Color _fg = Color(0xFF111111);
const Color _dot = Color(0xFFFF0000);

/// 文案擦出时长（组件内私有 `_kMorphIn` / `_kMorphOut`）与格子进出场时长。
///
/// 顶栏这颗每次点击都要播，所以是 240/160ms 而不是发现页问候胶囊的 720ms。
const Duration _kMorphIn = Duration(milliseconds: 240);
const Duration _kMorphOut = Duration(milliseconds: 160);
const Duration _kPresence = Duration(milliseconds: 220);

TopBarTrailingSegment _segment({
  required String label,
  IconData icon = Icons.timer_outlined,
  required void Function()? onTap,
  VoidCallback? onLongPress,
  bool pinnedOpen = false,
  bool collapseOnlyWithPeers = false,
  String? semanticsLabel,
}) => TopBarTrailingSegment(
  icon: icon,
  label: label,
  // 展开状态与进出场都按 semanticsLabel 认格子（见组件里的 `_keyOf`），所以
  // helper 造的每一格必须有各自唯一的标签；默认拿文案当标签（同屏各格文案不同），
  // 需要贴近真实宿主时用显式的 semanticsLabel（音质 / 定时关闭 / 一起听）。
  semanticsLabel: semanticsLabel ?? label,
  onTap: onTap,
  onLongPress: onLongPress,
  pinnedOpen: pinnedOpen,
  collapseOnlyWithPeers: collapseOnlyWithPeers,
);

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

/// 胶囊背景。
///
/// 只认「带 StadiumBorder 且涂了胶囊底色」的 Material：M3 的 IconButton 自带
/// StadiumBorder 形状（透明底），不按颜色筛就会被算进来。
Finder _background() => find.byWidgetPredicate(
  (w) => w is Material && w.shape is StadiumBorder && w.color == _bg,
);

/// 整行的宽度 = 胶囊尺寸减去尾部那 2dp 外边距。
///
/// 不直接找 Row：每一格里还有自己的 Row（图标 + 文案），`byType(Row)` 会命中多个。
double _rowWidth(WidgetTester tester) =>
    tester.getSize(find.byType(TopBarTrailingCapsule)).width - 2;

double _rowHeight(WidgetTester tester) =>
    tester.getSize(find.byType(TopBarTrailingCapsule)).height;

/// 某一格已擦出的文案宽度（按图标定位到它所在的那一格）。
double _labelWidthOf(WidgetTester tester, IconData icon) {
  final clip = find.descendant(
    of: find.ancestor(
      of: find.byIcon(icon),
      matching: find.byType(InkWell),
    ).first,
    matching: find.byType(ClipRect),
  );
  if (clip.evaluate().isEmpty) return 0;
  return tester.getSize(clip.first).width;
}

/// 按真机帧长把动画推进 [ms] 毫秒。
///
/// 进出场期间不能用一次大跨度的 `pump`：AnimatedSize 每次子尺寸变化都会重启动画并
/// 停在起始值，一帧跳完量到的还是旧宽度（实测：一次 pump(110ms) 读到 120，逐帧推进
/// 才读到 100）。逐帧推才等于真机 60fps 的帧序列。
Future<void> _runFrames(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 某一格的进出场透明度（按图标定位到它外面那层 FadeTransition）。
///
/// ⋯ 那一格不进不出场、不套 FadeTransition，所以每个图标最多只有一个祖先。
double _opacityOf(WidgetTester tester, IconData icon) => tester
    .widget<FadeTransition>(
      find.ancestor(
        of: find.byIcon(icon),
        matching: find.byType(FadeTransition),
      ).first,
    )
    .opacity
    .value;

/// 背景是否盖到 ⋯ **之前**为止（⋯ 那一格 40dp 宽恒在底色之外）。
///
/// 让开的是固定一格宽，不是「最右展开格」：顶栏尾部整体右对齐、⋯ 恒在最右，
/// 所以文案擦出时这条边不动，不会有早期那版边缘跳动。
void _expectPillExcludesMoreCell(WidgetTester tester) {
  const moreCellWidth = 40.0;
  expect(
    tester.getSize(_background()).width,
    closeTo(_rowWidth(tester) - moreCellWidth, 0.5),
    reason: '背景必须让开 ⋯ 那一格：⋯ 是裸图标，不压在胶囊底色里',
  );
}

/// 按到**胶囊以外**：这是现在唯一的自动收回触发点（旧版是一条 3 秒倒计时）。
///
/// 走 `tester.tapAt(Offset.zero)` 而不是找某个具体控件：组件挂在 `Center` 里，
/// 画面左上角必然落在胶囊矩形之外；收回靠的是 `GestureBinding` 上的全局指针路由，
/// 旁听事件，不需要那个点上真有可点的东西。
Future<void> _tapOutside(WidgetTester tester) async {
  await tester.tapAt(Offset.zero);
  await tester.pump();
}

/// 按到胶囊以外并等收回落底。
Future<void> _tapOutsideAndSettle(WidgetTester tester) async {
  await _tapOutside(tester);
  await tester.pumpAndSettle();
}

void main() {
  group('TopBarTrailingCapsule 收缩态（竖屏默认）', () {
    testWidgets('收起态：两格文案都不占位，背景让开 ⋯ 那一格', (tester) async {
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [
              _segment(label: '12:03', onTap: () {}),
              _segment(label: '2/5', icon: Icons.groups, onTap: () {}),
            ],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_labelWidthOf(tester, Icons.timer_outlined), 0);
      expect(_labelWidthOf(tester, Icons.groups), 0);
      _expectPillExcludesMoreCell(tester);
    });

    testWidgets('点某一格：只有它擦出文案，⋯ 的背景不受影响', (tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [
              _segment(label: '12:03', onTap: () => taps++),
              _segment(label: '2/5', icon: Icons.groups, onTap: () {}),
            ],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final collapsedWidth = _rowWidth(tester);

      // 第一下只展开，不执行动作
      await tester.tap(find.byIcon(Icons.timer_outlined));
      await tester.pumpAndSettle();
      expect(taps, 0, reason: '收起态那一格只剩图标，第一下不该直接进房间/开面板');
      expect(
        _labelWidthOf(tester, Icons.timer_outlined),
        greaterThan(10),
        reason: '被点的那格擦出了文案',
      );
      expect(_labelWidthOf(tester, Icons.groups), 0, reason: '另一格保持收起');
      expect(_rowWidth(tester), greaterThan(collapsedWidth), reason: '整行长宽了');
      _expectPillExcludesMoreCell(tester);

      // 展开到位后的第二下才执行动作
      await tester.tap(find.byIcon(Icons.timer_outlined));
      await tester.pumpAndSettle();
      expect(taps, 1, reason: '展开后再点同一格才执行动作');
    });

    testWidgets('点 ⋯：一次即开菜单，不再代各格擦出文案', (tester) async {
      int moreTaps = 0;
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [
              _segment(label: '12:03', onTap: () {}),
              _segment(label: '2/5', icon: Icons.groups, onTap: () {}),
            ],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () => moreTaps++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_horiz));
      expect(
        moreTaps,
        1,
        reason: '菜单入口没有「先看清再按」的需求，两步只会让人以为 ⋯ 失灵',
      );
      await tester.pumpAndSettle();
      expect(
        _labelWidthOf(tester, Icons.timer_outlined),
        0,
        reason: '⋯ 不再把别的格子一起擦出来（要读哪格就点哪格）',
      );
      expect(_labelWidthOf(tester, Icons.groups), 0);
      _expectPillExcludesMoreCell(tester);
    });

    // G 轮的回归点：展开状态从「单个 _openIndex」改成「只增不减的集合」。
    // 旧实现里切到第二格会把第一格当场收回，两格宽度在同一帧互换 —— 就是闪现。
    testWidgets('先后点两格：前一格不会当场收回', (tester) async {
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [
              _segment(label: '12:03', onTap: () {}),
              _segment(label: '2/5', icon: Icons.groups, onTap: () {}),
            ],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.timer_outlined));
      await tester.pumpAndSettle();
      final firstLabel = _labelWidthOf(tester, Icons.timer_outlined);

      await tester.tap(find.byIcon(Icons.groups));
      await tester.pump();
      expect(
        _labelWidthOf(tester, Icons.timer_outlined),
        closeTo(firstLabel, 0.5),
        reason: '第二格开始擦出时，第一格必须留在满宽，不能当场跳回 0',
      );

      await tester.pump(const Duration(milliseconds: 200));
      expect(_labelWidthOf(tester, Icons.groups), greaterThan(0), reason: '新格在擦');
      expect(
        _labelWidthOf(tester, Icons.timer_outlined),
        closeTo(firstLabel, 0.5),
        reason: '同一时刻前一格仍然满宽（闪现的判据）',
      );

      await tester.pumpAndSettle();
      expect(_labelWidthOf(tester, Icons.timer_outlined), closeTo(firstLabel, 0.5));
      expect(_labelWidthOf(tester, Icons.groups), greaterThan(10));
      _expectPillExcludesMoreCell(tester);

      // 自动收回不再由倒计时驱动：等再久两格都留在满宽
      await tester.pump(const Duration(seconds: 8));
      expect(
        _labelWidthOf(tester, Icons.timer_outlined),
        closeTo(firstLabel, 0.5),
        reason: '没有 3 秒倒计时了，不会自己收回去',
      );

      // 点胶囊以外才收回，且两格一起走镜像时间轴，不留下一格「还开着」
      await _tapOutsideAndSettle(tester);
      expect(_labelWidthOf(tester, Icons.timer_outlined), 0, reason: '先展开的那格也收回了');
      expect(_labelWidthOf(tester, Icons.groups), 0);
      _expectPillExcludesMoreCell(tester);
    });

    testWidgets('收回途中再点同一格：这一直接执行，不被镜像动画吞掉', (tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [_segment(label: '12:03', onTap: () => taps++)],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.timer_outlined));
      await tester.pumpAndSettle();
      final full = _labelWidthOf(tester, Icons.timer_outlined);

      // 点胶囊以外触发收回，停在途中（收回 160ms，推进 80ms 就是「途中」）
      await _tapOutside(tester);
      await tester.pump(_kMorphOut * 0.5);
      expect(
        _labelWidthOf(tester, Icons.timer_outlined),
        lessThan(full),
        reason: '确实在收回途中（否则这条测试没有意义）',
      );

      // 旧版这里按「先展开」处理（要 reveal 满 1.0 才算展开），于是收回途中的这一
      // 被镜像动画吞掉。现在擦出进度 > 0 就算已经在眼前：这一必须落地。
      await tester.tap(find.byIcon(Icons.timer_outlined));
      await tester.pump();
      expect(taps, 1, reason: '收回途中那一格仍然看得见文案，不该再要第二下');
    });

    testWidgets('展开后不定时收回；按到胶囊以外才收回', (tester) async {
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [_segment(label: '12:03', onTap: () {})],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.timer_outlined));
      await tester.pumpAndSettle();
      expect(_labelWidthOf(tester, Icons.timer_outlined), greaterThan(10));

      // 旧版这里是一条 3 秒倒计时：慢用户会在「第一下又只是展开」里循环，
      // 而它本身也是顶栏上一处无人值守的持续产帧点。现在等再久也不自己收。
      await tester.pump(const Duration(seconds: 8));
      expect(
        _labelWidthOf(tester, Icons.timer_outlined),
        greaterThan(10),
        reason: '没有定时自动收回',
      );

      // 按在胶囊上（哪怕就是这一格）不收回
      await tester.tap(find.byIcon(Icons.timer_outlined));
      await tester.pumpAndSettle();
      expect(
        _labelWidthOf(tester, Icons.timer_outlined),
        greaterThan(10),
        reason: '按里面不该把文案收掉',
      );

      // 按到胶囊以外 → 收回
      await _tapOutsideAndSettle(tester);
      expect(_labelWidthOf(tester, Icons.timer_outlined), 0, reason: '点外面才收回');
      _expectPillExcludesMoreCell(tester);
    });

    testWidgets('pinnedOpen 的那一格不自动收回（「已脱离」引导必须常在）', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [
              _segment(
                label: '已脱离',
                icon: Icons.groups,
                onTap: () {},
                pinnedOpen: true,
              ),
            ],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () {},
          ),
        ),
      );
      // 钉住项的起播走 postFrameCallback，多推一帧
      await tester.pump();
      await tester.pumpAndSettle();
      expect(
        _labelWidthOf(tester, Icons.groups),
        greaterThan(10),
        reason: '不等点击就展开：那条引导收进 icon 等于没有',
      );

      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(
        _labelWidthOf(tester, Icons.groups),
        greaterThan(10),
        reason: '钉住项不参与自动收回',
      );

      // 「点外面才收回」这一条也不能把它收掉：那条引导必须常在
      await _tapOutsideAndSettle(tester);
      expect(
        _labelWidthOf(tester, Icons.groups),
        greaterThan(10),
        reason: 'pinnedOpen 对「按到胶囊以外」同样免疫',
      );
    });

    testWidgets('文案是擦出来的：中途只有一半宽，落定才满宽', (tester) async {
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [_segment(label: '12:03', onTap: () {})],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.timer_outlined));
      // Ticker 的首帧只建立基准时间，所以要白送一帧再计时
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final mid = _labelWidthOf(tester, Icons.timer_outlined);

      await tester.pumpAndSettle();
      final full = _labelWidthOf(tester, Icons.timer_outlined);
      expect(mid, greaterThan(0), reason: '200ms 已经在擦：背景不再单独占一相位');
      expect(mid, lessThan(full), reason: '实测中途 $mid / 满宽 $full');
    });

    testWidgets('高度在两态之间保持不变，顶栏不跳行', (tester) async {
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [_segment(label: '12:03', onTap: () {})],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final collapsedHeight = _rowHeight(tester);

      await tester.tap(find.byIcon(Icons.timer_outlined));
      await tester.pumpAndSettle();
      expect(_rowHeight(tester), collapsedHeight, reason: '展开只变宽不变高');
    });

    // 「压上下宽度」这次改的是**视觉**高度，热区必须留在 40：
    // 竖屏相邻格零间距，横向扩不了；若纵向也跟着缩到 32，一格就只有 40×32，
    // 离 Material 的 48 地板更远。所以两者解耦，这里把两个数分别钉住，
    // 防止以后有人把它们重新合成一个。
    testWidgets('视觉 32 / 触控 40 是解耦的', (tester) async {
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [
              _segment(label: '12:03', onTap: () {}),
              _segment(label: '2/5', icon: Icons.groups, onTap: () {}),
            ],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 触控：整行（= 每一格的盒子）高 40
      expect(
        _rowHeight(tester),
        40,
        reason: '热区高度必须仍是 40，缩的是视觉不是触点',
      );
      // 视觉：连体底色只画 32，上下各留 4dp 热区余量
      expect(
        tester.getSize(_background()).height,
        32,
        reason: '胶囊视觉高度 32（比顶栏行高上下各让出 4dp，不再显得贴边拥挤）',
      );
    });

    // 水波纹与按压高亮的**裁剪轮廓**必须落在视觉 32 那条带里，而不是整格 40 的盒子。
    // material_ui 的 InkWell 是 containedInkWell + 矩形高亮，涟漪与高亮都只按
    // customBorder 在整盒上取的路径来裁（ink_well 的 paintInkCircle / ink_highlight
    // 的 _paintHighlight），所以量这条路径的边界就等于真机看到的溢出量；热区仍由盒子
    // 决定、与 ink 无关，上一条测试继续钉 40。
    testWidgets('涟漪与高亮按视觉 32 带裁剪，不越出胶囊', (tester) async {
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [_segment(label: '12:03', onTap: () {})],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final wells = tester.widgetList<InkWell>(find.byType(InkWell)).toList();
      expect(wells, isNotEmpty, reason: '这一格本身就是 InkWell');
      for (final well in wells) {
        final border = well.customBorder;
        expect(border, isNotNull, reason: 'ink 轮廓必须显式给定，不留裸矩形');
        final bounds = border!
            .getOuterPath(const Rect.fromLTRB(0, 0, 40, 40))
            .getBounds();
        expect(
          bounds.height,
          closeTo(32, 0.01),
          reason: '涟漪/高亮高度 == 视觉胶囊 32，不再上下各溢 4dp',
        );
        expect(bounds.top, closeTo(4, 0.01));
        expect(bounds.bottom, closeTo(36, 0.01));
      }
    });
  });

  // 音质徽章并入胶囊后的专属规则：它只在有邻居时才收起（孤零零一颗「♪」比
  // 「无损音质」难认），且本地歌曲没有可执行动作 → 整格不响应点击。
  group('collapseOnlyWithPeers（音质格）与无动作格', () {
    TopBarTrailingCapsule _capsule(List<TopBarTrailingSegment> segments) =>
        TopBarTrailingCapsule(
          segments: segments,
          background: _bg,
          foreground: _fg,
          dotColor: _dot,
          onMore: () {},
        );

    testWidgets('唯一一格时不收起：文案常显、点一下直接执行', (tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _host(
          _capsule([
            _segment(
              label: '无损音质',
              icon: Icons.music_note,
              onTap: () => taps++,
              collapseOnlyWithPeers: true,
            ),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('无损音质'), findsOneWidget, reason: '没有邻居就没得让位，直接写着');
      await tester.tap(find.byIcon(Icons.music_note));
      await tester.pumpAndSettle();
      expect(taps, 1, reason: '常显态不需要「先展开」这一步');
      // ⋯ 也在这颗背景上（背景融合），所以整行只有一层底色
      _expectPillExcludesMoreCell(tester);
    });

    testWidgets('有邻居时缩成音符：第一下只展开，第二下才执行', (tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _host(
          _capsule([
            _segment(
              label: '无损音质',
              icon: Icons.music_note,
              onTap: () => taps++,
              collapseOnlyWithPeers: true,
            ),
            _segment(label: '12:03', onTap: () {}),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      expect(_labelWidthOf(tester, Icons.music_note), 0, reason: '缩成一颗音符');
      expect(_labelWidthOf(tester, Icons.timer_outlined), 0);
      _expectPillExcludesMoreCell(tester);

      await tester.tap(find.byIcon(Icons.music_note));
      await tester.pumpAndSettle();
      expect(taps, 0, reason: '第一下只展开');
      expect(_labelWidthOf(tester, Icons.music_note), greaterThan(10));
      expect(
        _labelWidthOf(tester, Icons.timer_outlined),
        0,
        reason: '别跟着把邻居也擦出来',
      );

      await tester.tap(find.byIcon(Icons.music_note));
      await tester.pumpAndSettle();
      expect(taps, 1, reason: '展开到位后再点才开音质选择');
    });

    testWidgets('onTap 为 null（本地歌曲）：点一下只展开，长按一步直达', (tester) async {
      int longPressed = 0;
      await tester.pumpWidget(
        _host(
          _capsule([
            _segment(
              label: '标准音质',
              icon: Icons.music_note,
              onTap: null,
              onLongPress: () => longPressed++,
              collapseOnlyWithPeers: true,
            ),
            _segment(label: '12:03', onTap: () {}),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      // ⋯ 不再代各格展开，所以这一格的文案只能靠自己点出来：
      // 「没有切换音质的动作」≠「读不到音质」。
      await tester.tap(find.byIcon(Icons.music_note));
      await tester.pumpAndSettle();
      expect(
        _labelWidthOf(tester, Icons.music_note),
        greaterThan(10),
        reason: '无动作的格子点一下负责擦出文案，读得到本地码率推断的音质',
      );

      // 长按恒为一步，不跟着走两步
      await tester.longPress(find.byIcon(Icons.music_note));
      await tester.pumpAndSettle();
      expect(longPressed, 1, reason: '长按一次就开音量面板（本地/在线同语义）');
    });

    testWidgets('无动作的音质格自己就能被点开，⋯ 不再代劳', (tester) async {
      await tester.pumpWidget(
        _host(
          _capsule([
            _segment(
              label: '标准音质',
              icon: Icons.music_note,
              onTap: null,
              collapseOnlyWithPeers: true,
            ),
            _segment(label: '12:03', onTap: () {}),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.music_note));
      await tester.pumpAndSettle();
      expect(
        _labelWidthOf(tester, Icons.music_note),
        greaterThan(10),
        reason: '它自己就能被读到',
      );
      expect(
        _labelWidthOf(tester, Icons.timer_outlined),
        0,
        reason: '只展开被点的那一格，不牵连邻居',
      );

      // ⋯ 现在只管开菜单，不会把邻居也擦出来
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      expect(_labelWidthOf(tester, Icons.timer_outlined), 0);
    });
  });

  group('音质格独立于「胶囊按钮收缩」开关', () {
    // 音质格的收/放只看旁边还有没有别的格（邻居），开关管不到它；睡眠定时 / 一起听
    // 那些格仍归开关管。所以「关掉收缩」不再等于「全都不收」。
    testWidgets('开关关闭 + 邻居在场：音质仍收成音符，邻居文案常显', (tester) async {
      addTearDown(() => kTopBarPillCollapseEnabled.value = true);
      kTopBarPillCollapseEnabled.value = false;
      var qualityTaps = 0;
      var moreTaps = 0;
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [
              _segment(
                label: '标准音质',
                icon: Icons.music_note,
                onTap: () => qualityTaps++,
                collapseOnlyWithPeers: true,
              ),
              _segment(label: '12:03', onTap: () {}),
            ],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () => moreTaps++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        _labelWidthOf(tester, Icons.music_note),
        0,
        reason: '音质格不看开关：邻居在场就让位收成音符',
      );
      expect(
        find.text('12:03'),
        findsOneWidget,
        reason: '其余格仍受开关管，关掉即常显',
      );

      await tester.tap(find.byIcon(Icons.more_horiz));
      expect(moreTaps, 1, reason: '⋯ 不被音质格的收缩拖成两步，一次即开菜单');

      await tester.tap(find.byIcon(Icons.music_note));
      await tester.pumpAndSettle();
      expect(qualityTaps, 0, reason: '音质格自己仍是两步：第一下只展开');
      expect(_labelWidthOf(tester, Icons.music_note), greaterThan(10));
      await tester.tap(find.byIcon(Icons.music_note));
      expect(qualityTaps, 1, reason: '展开到位后再点才执行动作');
    });

    testWidgets('开关关闭 + 没有邻居：音质常显，点一下直接执行', (tester) async {
      addTearDown(() => kTopBarPillCollapseEnabled.value = true);
      kTopBarPillCollapseEnabled.value = false;
      var qualityTaps = 0;
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [
              _segment(
                label: '无损音质',
                icon: Icons.music_note,
                onTap: () => qualityTaps++,
                collapseOnlyWithPeers: true,
              ),
            ],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('无损音质'),
        findsOneWidget,
        reason: '孤零零一颗音符比写明「无损音质」难认，没邻居就不收',
      );
      await tester.tap(find.byIcon(Icons.music_note));
      expect(qualityTaps, 1, reason: '没有可收的格子就没有「先展开」这一步');
    });

    testWidgets('开关打开：音质与邻居照旧一起收（原行为不变）', (tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [
              _segment(
                label: '标准音质',
                icon: Icons.music_note,
                onTap: () => taps++,
                collapseOnlyWithPeers: true,
              ),
              _segment(label: '12:03', onTap: () {}),
            ],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_labelWidthOf(tester, Icons.music_note), 0);
      expect(find.text('12:03'), findsNothing, reason: '开关开着，邻居也收');
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      expect(
        find.text('12:03'),
        findsNothing,
        reason: '⋯ 一步开菜单，不会代邻居把文案擦出来',
      );
      // 要读邻居就点它自己
      await tester.tap(find.byIcon(Icons.timer_outlined));
      await tester.pumpAndSettle();
      expect(find.text('12:03'), findsOneWidget);
    });
  });

  group('⋯ 不带背景', () {
    testWidgets('背景右缘停在 ⋯ 那一格之前，⋯ 用 moreIconColor 取色', (
      tester,
    ) async {
      const moreColor = Color(0xFF00FF00);
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [
              _segment(label: '无损音质', icon: Icons.music_note, onTap: () {}),
            ],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            moreIconColor: moreColor,
            onMore: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final bg = tester.getRect(_background());
      final more = tester.getRect(find.byIcon(Icons.more_horiz));
      expect(
        bg.right,
        lessThanOrEqualTo(more.left + 0.5),
        reason: '⋯ 必须完全在底色之外（背景 right ${bg.right} vs ⋯ left ${more.left}）',
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.more_horiz)).color,
        moreColor,
        reason: '裸图标贴在页面背景上，取色走 moreIconColor',
      );
      // 收缩/展开来回都不改变这条边：让开的是固定一格宽，不是最右展开格
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(_background()).right,
        lessThanOrEqualTo(tester.getRect(find.byIcon(Icons.more_horiz)).left + 0.5),
        reason: '文案擦出后 ⋯ 仍不在底色上',
      );
    });

    testWidgets('没有任何可展开项时仍是那颗裸 ⋯', (tester) async {
      var moreTaps = 0;
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: const [],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            moreIconColor: const Color(0xFF00FF00),
            onMore: () => moreTaps++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_background(), findsNothing, reason: '没有格子就没有底色');
      await tester.tap(find.byIcon(Icons.more_horiz));
      expect(moreTaps, 1);
    });
  });

  group('「胶囊按钮收缩」开关与钉住项', () {
    testWidgets('开关关闭：文案常显但仍是一整颗胶囊，点一下直接执行', (
      tester,
    ) async {
      addTearDown(() => kTopBarPillCollapseEnabled.value = true);
      kTopBarPillCollapseEnabled.value = false;
      int taps = 0;
      int moreTaps = 0;
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [_segment(label: '12:03', onTap: () => taps++)],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () => moreTaps++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('12:03'), findsOneWidget);
      // ⋯ 仍在同一行里（不是退化成 IconButton），但已不在底色之上
      expect(find.byType(IconButton), findsNothing);
      expect(_background(), findsOneWidget);
      _expectPillExcludesMoreCell(tester);

      await tester.tap(find.byIcon(Icons.timer_outlined));
      expect(taps, 1, reason: '不收缩就没有「先展开」这一步');

      await tester.tap(find.byIcon(Icons.more_horiz));
      expect(moreTaps, 1, reason: '同上，⋯ 也是一次即开菜单');
    });

    testWidgets('运行中改开关即刻换形态（顶栏不用重建）', (tester) async {
      addTearDown(() => kTopBarPillCollapseEnabled.value = true);
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [_segment(label: '12:03', onTap: () {})],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('12:03'), findsNothing, reason: '收缩态只露图标');

      kTopBarPillCollapseEnabled.value = false;
      await tester.pumpAndSettle();
      expect(find.text('12:03'), findsOneWidget, reason: '关掉收缩立刻常显文案');
    });

    testWidgets('钉住项（已脱离）本就是展开态，一次点击即执行', (tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [
              _segment(
                label: '已脱离',
                icon: Icons.groups,
                onTap: () => taps++,
                pinnedOpen: true,
              ),
            ],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(_labelWidthOf(tester, Icons.groups), greaterThan(10));

      await tester.tap(find.byIcon(Icons.groups));
      await tester.pumpAndSettle();
      expect(taps, 1, reason: '引导已经在眼前，不必再点第二下');
    });
  });

  group('TopBarTrailingCapsule 边界与宽屏形态', () {
    testWidgets('没有可展开项：只剩 ⋯，不凭空造一颗胶囊', (tester) async {
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: const [],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            onMore: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(IconButton), findsOneWidget);
      expect(_background(), findsNothing);
    });

    testWidgets('宽屏（collapsible=false）：文案常显、一颗连体胶囊、一次即执行', (
      tester,
    ) async {
      int taps = 0;
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [
              _segment(label: '12:03', onTap: () {}),
              _segment(label: '2/5', icon: Icons.groups, onTap: () => taps++),
            ],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            collapsible: false,
            onMore: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('12:03'), findsOneWidget);
      expect(find.text('2/5'), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);
      // 只有一颗背景，三格共用它（分颗会在顶栏糊成一排药丸）
      expect(_background(), findsOneWidget);
      _expectPillExcludesMoreCell(tester);

      await tester.tap(find.byIcon(Icons.groups));
      await tester.pumpAndSettle();
      expect(taps, 1, reason: '宽屏文案一直看得见，不需要先展开');
    });
  });

  // ── 两条用户诉求的落点 ──────────────────────────────────────────────────
  //
  // ① 胶囊正在擦出/收回的**途中**必须点得动：旧版 `_isOpen` 要 `reveal >= 1.0`，
  //    于是动画在飞的那 720ms 里落下的点击全被当成「又一次展开」无声吞掉。
  // ② segments 增删（睡眠定时起停、进出房间、本地/在线换曲）要有进出场动画，
  //    并且格子身份按 semanticsLabel 认 —— 中间那一格消失时，展开状态不会留给
  //    顶替它下标的邻居。
  group('擦出途中即可执行 与 格子进出场', () {
    TopBarTrailingCapsule _capsule(
      List<TopBarTrailingSegment> segments, {
      VoidCallback? onMore,
    }) => TopBarTrailingCapsule(
      segments: segments,
      background: _bg,
      foreground: _fg,
      dotColor: _dot,
      onMore: onMore ?? () {},
    );

    testWidgets('收起态点一格只展开；擦出途中再点同一格立刻执行', (tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _host(
          _capsule([
            _segment(label: '12:03', onTap: () => taps++),
            _segment(label: '2/5', icon: Icons.groups, onTap: () {}),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.timer_outlined));
      // Ticker 首帧只建立基准时间，所以要白送一帧再计时
      await tester.pump();
      await tester.pump(_kMorphIn * 0.5);
      expect(taps, 0, reason: '第一下仍然只负责展开（两步点击的语义没变）');
      final mid = _labelWidthOf(tester, Icons.timer_outlined);
      expect(mid, greaterThan(0), reason: '确实在擦出途中（否则这条测试没意义）');

      await tester.tap(find.byIcon(Icons.timer_outlined));
      await tester.pump();
      expect(
        taps,
        1,
        reason: '文案已经在擦了就已经看得清，这一不该等动画跑完',
      );
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        _labelWidthOf(tester, Icons.timer_outlined),
        greaterThan(mid),
        reason: '执行动作不会打断正在跑的擦出',
      );
    });

    testWidgets('⋯ 任何时候都是一次即触发，哪怕别的格子正在擦出', (tester) async {
      int moreTaps = 0;
      await tester.pumpWidget(
        _host(
          _capsule(
            [
              _segment(label: '12:03', onTap: () {}),
              _segment(label: '2/5', icon: Icons.groups, onTap: () {}),
            ],
            onMore: () => moreTaps++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 先让一格擦出到一半（此刻顶栏正处于动画在飞的状态）
      await tester.tap(find.byIcon(Icons.timer_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        _labelWidthOf(tester, Icons.timer_outlined),
        greaterThan(0),
        reason: '确实有格子正在擦出（否则这条测试没意义）',
      );

      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pump();
      expect(
        moreTaps,
        1,
        reason: '⋯ 一步开菜单，与别的格子是否在擦出无关',
      );
    });

    testWidgets('收回途中点另一格：把收回拽回来，前一格不回零', (tester) async {
      await tester.pumpWidget(
        _host(
          _capsule([
            _segment(label: '12:03', onTap: () {}),
            _segment(label: '2/5', icon: Icons.groups, onTap: () {}),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.timer_outlined));
      await tester.pumpAndSettle();
      final first = _labelWidthOf(tester, Icons.timer_outlined);

      // 点胶囊以外 → 开始收回，停在途中（收回 160ms）
      await _tapOutside(tester);
      await tester.pump(_kMorphOut * 0.5);
      expect(
        _labelWidthOf(tester, Icons.timer_outlined),
        lessThan(first),
        reason: '确实在收回途中',
      );

      // 另一格从未擦出（reveal 恰为 0）→ 仍按「先展开」处理，并中断这次收回
      await tester.tap(find.byIcon(Icons.groups));
      await tester.pumpAndSettle();
      expect(
        _labelWidthOf(tester, Icons.timer_outlined),
        closeTo(first, 0.5),
        reason: '点邻居时收回被拽回，前一格必须回到满宽而不是跳到 0',
      );
      expect(_labelWidthOf(tester, Icons.groups), greaterThan(10));
    });

    testWidgets('2 格变 1 格：被移除那格淡出仍在树里，宽度经 AnimatedSize 滑行', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          _capsule([
            _segment(label: '12:03', onTap: () {}),
            _segment(label: '2/5', icon: Icons.groups, onTap: () {}),
          ]),
        ),
      );
      await tester.pumpAndSettle();
      final wide = _rowWidth(tester);

      await tester.pumpWidget(
        _host(_capsule([_segment(label: '12:03', onTap: () {})])),
      );
      await tester.pump();
      await _runFrames(tester, _kPresence.inMilliseconds ~/ 2);

      expect(find.byIcon(Icons.groups), findsOneWidget, reason: '淡出期间仍要挂着');
      final opacity = _opacityOf(tester, Icons.groups);
      expect(opacity, lessThan(1.0), reason: '正在淡出');
      expect(opacity, greaterThan(0.0), reason: '还没落底');
      expect(find.byType(AnimatedSize), findsOneWidget);
      final mid = _rowWidth(tester);

      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.groups), findsNothing, reason: '淡出结束才真的卸载');
      final narrow = _rowWidth(tester);
      expect(mid, greaterThan(narrow), reason: '中途宽度还大于终态：是滑过去的');
      expect(mid, lessThan(wide), reason: '也不会等跑完才一跳');
      expect(
        wide - narrow,
        closeTo(40, 0.5),
        reason: '少一格图标正好让出 40dp（_kIconBox）',
      );
      _expectPillExcludesMoreCell(tester);
    });

    testWidgets('1 格变 2 格：新格从 <1 淡入到 1', (tester) async {
      await tester.pumpWidget(
        _host(_capsule([_segment(label: '12:03', onTap: () {})])),
      );
      await tester.pumpAndSettle();
      final narrow = _rowWidth(tester);

      await tester.pumpWidget(
        _host(
          _capsule([
            _segment(label: '12:03', onTap: () {}),
            _segment(label: '2/5', icon: Icons.groups, onTap: () {}),
          ]),
        ),
      );
      await tester.pump();
      await _runFrames(tester, _kPresence.inMilliseconds ~/ 2);

      final opacity = _opacityOf(tester, Icons.groups);
      expect(opacity, greaterThan(0.0), reason: '已经在淡入');
      expect(opacity, lessThan(1.0), reason: '中途还没满');
      expect(_rowWidth(tester), greaterThan(narrow));
      final mid = _rowWidth(tester);

      await tester.pumpAndSettle();
      expect(_opacityOf(tester, Icons.groups), 1.0);
      expect(_rowWidth(tester), greaterThan(mid));
      _expectPillExcludesMoreCell(tester);
    });

    testWidgets('中间那格消失不会把「已展开」留给邻居（按键不按序）', (
      tester,
    ) async {
      int timerTaps = 0;
      Widget tree(bool withQuality) => _host(
        _capsule([
          if (withQuality)
            _segment(
              label: '无损音质',
              icon: Icons.music_note,
              semanticsLabel: '音质',
              onTap: () {},
              collapseOnlyWithPeers: true,
            ),
          _segment(
            label: '12:03',
            semanticsLabel: '定时关闭',
            onTap: () => timerTaps++,
          ),
        ]),
      );

      await tester.pumpWidget(tree(true));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.music_note));
      await tester.pumpAndSettle();
      expect(_labelWidthOf(tester, Icons.music_note), greaterThan(10));
      expect(_labelWidthOf(tester, Icons.timer_outlined), 0);

      // 换成没有音质入口的本地歌曲：音质那格淡出，下标 0 现在归定时
      await tester.pumpWidget(tree(false));
      await tester.pump();
      await _runFrames(tester, _kPresence.inMilliseconds ~/ 2);
      expect(
        _labelWidthOf(tester, Icons.timer_outlined),
        0,
        reason: '邻居不该继承别人的展开状态',
      );

      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.music_note), findsNothing);
      expect(
        _labelWidthOf(tester, Icons.timer_outlined),
        0,
        reason: '淡出跑完也一样是收起态',
      );

      await tester.tap(find.byIcon(Icons.timer_outlined));
      await tester.pump();
      expect(timerTaps, 0, reason: '它仍是收起态：第一下只展开');
    });

    testWidgets('淡出途中的格子点不动：不触发动作、也不展开', (tester) async {
      int groupsTaps = 0;
      await tester.pumpWidget(
        _host(
          _capsule([
            _segment(label: '12:03', onTap: () {}),
            _segment(
              label: '2/5',
              icon: Icons.groups,
              onTap: () => groupsTaps++,
            ),
          ]),
        ),
      );
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        _host(_capsule([_segment(label: '12:03', onTap: () {})])),
      );
      await tester.pump();
      // 只推进一小截：淡出刚开始，那一格还宽得很，触点仍在它的盒子里
      await _runFrames(tester, _kPresence.inMilliseconds ~/ 5);
      expect(find.byIcon(Icons.groups), findsOneWidget);
      expect(_opacityOf(tester, Icons.groups), lessThan(1.0));

      await tester.tap(find.byIcon(Icons.groups));
      await tester.pump();
      expect(groupsTaps, 0, reason: '正在消失的那格不再是入口');
      expect(
        _labelWidthOf(tester, Icons.groups),
        0,
        reason: '连「展开」都不该被它触发，否则等于点了个死按钮',
      );

      await tester.pumpAndSettle();
      expect(groupsTaps, 0);
    });
  });

  // ── showBackground = false：横屏裸形态 ──────────────────────────────────
  //
  // 宽屏顶栏有整行宽度、文案又恒显，那层连体底色会把一串各自独立的操作框成一块
  // 面板，压在封面/壁纸上尤其显脏。裸掉之后必须「只是没有底」：格子照常渲染、
  // 照常一次即执行、红点照常报数，只是后面不再有一层 StadiumBorder。
  // 宿主侧的 wide → showBackground 接线由 full_player_landscape_controls_test 钉。
  group('showBackground = false（横屏裸形态）', () {
    testWidgets('没有连体底色，涟漪与点击语义都照常', (tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: [
              _segment(
                label: '无损音质',
                icon: Icons.music_note,
                onTap: () => taps++,
                semanticsLabel: '音质',
              ),
            ],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            collapsible: false,
            showBackground: false,
            onMore: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        _background(),
        findsNothing,
        reason: '裸形态不该有涂了底色的 StadiumBorder Material',
      );
      // 涟漪那层透明 Material 与两格 InkWell 都还在（不是把胶囊整颗藏了）
      expect(
        find.byType(InkWell),
        findsNWidgets(2),
        reason: '音质格 + ⋯ 两格仍在，仍可点',
      );

      await tester.tap(find.byIcon(Icons.music_note));
      await tester.pumpAndSettle();
      expect(taps, 1, reason: '常显形态一次即执行，裸不裸不改点击语义');
      expect(_labelWidthOf(tester, Icons.music_note), greaterThan(10));
    });

    testWidgets('红点不再描同色边（没有容器可融入，描了就是个环）', (tester) async {
      await tester.pumpWidget(
        _host(
          TopBarTrailingCapsule(
            segments: const [
              TopBarTrailingSegment(
                icon: Icons.groups,
                label: '2/5',
                semanticsLabel: '一起听',
                unreadDot: true,
              ),
            ],
            background: _bg,
            foreground: _fg,
            dotColor: _dot,
            collapsible: false,
            showBackground: false,
            onMore: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final decor = tester
          .widget<Container>(
            find.byWidgetPredicate(
              (w) =>
                  w is Container &&
                  w.decoration is BoxDecoration &&
                  (w.decoration! as BoxDecoration).shape == BoxShape.circle,
            ),
          )
          .decoration! as BoxDecoration;
      expect(decor.border, isNull, reason: '裸形态下红点应直接贴在页面背景上');
      expect(decor.color, _dot, reason: '红点本体照旧，只是不描边');
    });
  });
}
