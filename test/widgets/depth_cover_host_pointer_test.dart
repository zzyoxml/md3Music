import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 鼠标跟随在 DepthCoverHost 的接线契约（Windows 3D 封面）。
///
/// **背景**：Windows 端 3D 封面的视差驱动源是「封面矩形内的鼠标位置」，
/// 接线在 `DepthCoverHost._buildCover()` 的 `LayoutBuilder + MouseRegion`。
/// 这里有三个会被肉眼看不出地改坏的约束：
///
/// 1. **必须用 `event.localPosition`**，不能用 `event.position`：后者是全局
///    坐标（窗口原点），直接喂给 `DepthTiltController` 会让视差的中心偏移到
///    整个窗口左上角，方向与幅度全错（测试编译期和普通用例都发现不了）。
/// 2. **MouseRegion 必须 `hitTestBehavior: HitTestBehavior.translucent`**：
///    3D 封面的绘制层是纯 `CustomPaint`（`DepthShaderCover`），默认
///    `deferToChild` 会在「子级无命中目标」时整个丢失 hover 事件
///    （docs/agents/windows-desktop.md W8 同款坑）；而 `opaque` 会吞掉身后
///    的命中，挡住播放页封面的「长按 2s 进 Zen」「单击 peek」手势。
/// 3. **必须以 `_tilt!.usesPointerSource && _hasDepthContent` 门控**：
///    平面封面阶段挂 MouseRegion 等于给一张不动的图加无用命中测试；
///    Android/TV 的传感器分支根本不该进这段。
///
/// 用**源码结构断言**而不是 widget 测试：宿主构造依赖 SettingsRepository /
/// DepthCoverService / 深度缓存整串，构造成本高且脆弱；本条的实质是
/// 「这几行接线不得被挪走/误改」，源码断言更直接（与
/// `app_overlay_layers_anchor_space_test.dart` 同一选择）。
void main() {
  final source = File('lib/widgets/depth_cover_host.dart').readAsStringSync();
  // 剔行注释：符号名在注释里也出现，避免注释文字冒充接线点。
  final code = source
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  test('MouseRegion 接线必须存在且带 translucent 命中行为', () {
    expect(code.contains('MouseRegion('), isTrue, reason: '未找到 MouseRegion 接线');
    expect(
      code.contains('hitTestBehavior: HitTestBehavior.translucent'),
      isTrue,
      reason: 'translucent 是 hover 能收到 + 不吞手势的关键；'
          'deferToChild 会丢事件、opaque 会挡「长按进 Zen」',
    );
  });

  test('hover 回调必须用 localPosition + 本 State 的 RenderBox 尺寸', () {
    final cbIdx = code.indexOf('onHover: (event) {');
    expect(cbIdx, greaterThan(-1), reason: 'onHover 必须是有体的回调（需要在其中读尺寸）');
    final body = code.substring(cbIdx, code.indexOf('onExit:', cbIdx));
    expect(body.contains('event.localPosition'), isTrue,
        reason: '必须用封面矩形局部坐标');
    expect(body.contains('.position') && !body.contains('localPosition'), isFalse,
        reason: 'event.position 是全局坐标，会让中心偏移到窗口原点');
    expect(body.contains('handleHover'), isTrue,
        reason: '采样必须交给 DepthTiltController');
    expect(body.contains('findRenderObject'), isTrue,
        reason: '尺寸从本 State 的 RenderBox 读（layout 已完成），不要另建 RenderObject');
    expect(body.contains('hasSize'), isTrue,
        reason: '渲染对象可能尚未布局完成（首帧/离屏取用），必须守卫');
  });

  test('**禁止用 LayoutBuilder 取尺寸**（会 RenderBox was not laid out 卡死）', () {
    expect(code.contains('LayoutBuilder'), isFalse,
        reason: '2026-10-28 实测：播放页同时挂前后两张封面做淡入淡出、封面形变层还会'
            '离屏取用封面子树，LayoutBuilder 会出现「没 layout 就被 paint」——'
            '日志每帧刷 `RenderBox was not laid out: _RenderLayoutBuilder ... '
            'NEEDS-PAINT`，框架反复重试 → 整窗卡死。改用 hover 回调里的 RenderBox 尺寸。');
  });

  test('MouseRegion 必须以 usesPointerSource && _hasDepthContent 门控', () {
    final gateIndex = code.indexOf('usesPointerSource');
    expect(gateIndex, greaterThan(-1), reason: '未找到平台门控');
    final line = code.substring(gateIndex, code.indexOf('\n', gateIndex));
    expect(line, contains('_hasDepthContent'),
        reason: '平面封面阶段不挂 MouseRegion（无用命中测试）');
  });

  test('exit 必须归零（handleExit），指针离开封面后平滑回中', () {
    expect(code.contains('handleExit'), isTrue,
        reason: '未找到 onExit → handleExit 接线');
  });

  test('宿主不得再直接持有 sensors_plus 流（倾斜源归 DepthTiltController）', () {
    expect(code.contains('accelerometerEventStream'), isFalse,
        reason: '传感器流已下沉到 DepthTiltController；留在宿主会让 Windows 误报'
            '「无重力传感器」');
    expect(code.contains("import 'package:sensors_plus"), isFalse,
        reason: 'sensors_plus 的 import 也应一并移除');
  });

  // ── Windows 不得使用 runtime fragment shader（「打开 3D 封面整窗无响应」修复点）──
  //
  // 背景：`shaders/depth_parallax.frag` 每像素 16 层深度纹理采样；Windows 走
  // Impeller，本仓已踩过同类坑（windows-desktop.md W5.7：InkSparkle 这个**简单**
  // fragment shader 在桌面端「首次按下要等着色器编译/管线创建」→ 已回退 InkRipple）。
  // 更关键的是这条 shader 路径在 Windows 上从未跑过（功能此前整体死掉），一开就
  // 满帧重绘 → 整窗无响应；而 `_onShaderFailed` 只在**抛异常**时降级，
  // 「能编译但极慢」没有任何兜底。因此必须靠这道编译期可见的平台门控兜住。
  test('_useShaderPath 必须带 isWindowsDesktop 门控（禁用 Windows runtime shader）',
      () {
    final idx = code.indexOf('bool get _useShaderPath');
    expect(idx, greaterThan(-1), reason: '未找到 _useShaderPath');
    final end = code.indexOf(';', idx);
    final decl = code.substring(idx, end);
    expect(decl, contains('isWindowsDesktop'),
        reason: 'Windows 必须强制走多层视差：桌面端 runtime shader 会卡死 UI，'
            '且渲染慢不会触发 _onShaderFailed 降级');
    expect(decl.contains('!isWindowsDesktop'), isTrue,
        reason: '必须是取反（Windows → false），否则 shader 路径仍会在桌面端生效');
  });

  test('多层路径仍是 Windows 的实际渲染分支（不得被删/改名）', () {
    expect(code.contains('DepthParallaxCover('), isTrue,
        reason: 'Windows 3D 封面 = DepthParallaxCover 三层视差；删掉就没有 3D 效果了');
    expect(code.contains('generateLayers') || code.contains('service.request('),
        isTrue,
        reason: '多层分支必须发起 layers 生成');
  });

  test('_onReady 不得让旧的 depth 缓存堵死 layers 分支（Windows 只有 layers）', () {
    final start = code.indexOf('void _onReady()');
    expect(start, greaterThan(-1), reason: '未找到 _onReady');
    final end = code.indexOf('/// 倾斜源已由', start);
    final body = end == -1 ? code.substring(start) : code.substring(start, end);
    expect(body.contains('_useShaderPath'), isTrue,
        reason: '深度缓存的探测必须按 _useShaderPath 门控：旧版本在 Windows 生成过 '
            'depth.png 但没有 layer*.png，若先命中 _depthInfo 会把 layers 分支的 '
            '_depthInfo == null 守卫永久堵死 → 3D 开关打开却永远是平面封面');
  });

  // ── 修补底板接线（「图片修补没生效」修复）─────────────────────────────────
  test('多层渲染必须把修补底板传给 DepthParallaxCover', () {
    expect(code.contains('getLayerBackground'), isTrue,
        reason: '宿主必须主动取底板：bg_fill 是「主体已填补的背景」，缺了就是重影');
    final idx = code.indexOf('DepthParallaxCover(');
    expect(idx, greaterThan(-1));
    final call = code.substring(idx, code.indexOf(')', idx) + 1);
    expect(call.contains('backgroundPath'), isTrue,
        reason: '底板必须传给 DepthParallaxCover，否则不会被绘制（=修补不可见）');
  });
}
