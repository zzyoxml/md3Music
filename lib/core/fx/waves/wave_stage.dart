import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'distortion_wave_style.dart';
import 'wave_front.dart';

/// 波的两段片元着色器，整个进程只加载一次。
class WavePrograms {
  WavePrograms._(this.lens, this.band);

  final ui.FragmentProgram lens;
  final ui.FragmentProgram band;

  static Future<WavePrograms?>? _loading;
  static WavePrograms? _ready;

  /// 加载完之后的 program；之前、或者这台设备加载不了时是 null —— 那就退成
  /// 淡入淡出。
  static WavePrograms? get ready => _ready;

  static Future<WavePrograms?> load() => _loading ??= _load();

  static Future<WavePrograms?> _load() async {
    try {
      final lens = await ui.FragmentProgram.fromAsset('shaders/distortion_wave_lens.frag');
      final band = await ui.FragmentProgram.fromAsset('shaders/distortion_wave_band.frag');
      _warmUp(lens, band);
      return _ready = WavePrograms._(lens, band);
    } catch (_) {
      return null;
    }
  }

  /// 第一次用某个 program 画的时候才会建它的管线，那会落在第一道波的头几帧上；
  /// 这里先离屏画一次，把这件事提前做掉。
  static void _warmUp(ui.FragmentProgram lens, ui.FragmentProgram band) {
    final blank = ui.PictureRecorder();
    Canvas(blank).drawPaint(Paint());
    final pixel = blank.endRecording();
    final image = pixel.toImageSync(1, 1);
    pixel.dispose();
    final lensShader = lens.fragmentShader();
    for (var i = 0; i < 3; i++) {
      lensShader.setImageSampler(i, image);
    }
    final bandShader = band.fragmentShader();
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..drawRect(const Rect.fromLTWH(0, 0, 2, 2), Paint()..shader = lensShader)
      ..drawRect(const Rect.fromLTWH(0, 0, 2, 2), Paint()..shader = bandShader);
    final picture = recorder.endRecording();
    picture.toImageSync(2, 2).dispose();
    picture.dispose();
    lensShader.dispose();
    bandShader.dispose();
    image.dispose();
  }
}

/// [WaveStage] 的两面。
enum WaveSide { revealed, content }

/// 进度 [progress] 处的过场：先新页，再压在上面的旧页，最后是颜色和小点。
/// 屏幕上的一切都由这一个数推出来，中间经过 [WaveFront]。
///
/// 鼓包阶段每一面都从它自己的快照画（旧页若不在本树里，就用 [contentImage]：
/// 路由下面那一页）。[plain] 或没有 [programs] 时退成淡入淡出。
///
/// [revealedLive] 打开时新页不走着色器：它作为实时的子树直接画在底下，只用旧页
/// 那一面的覆盖掩膜（波前后 ±60pt 的交叉淡入）把旧页压在上面。带视频的页面
/// （`video_player` 的 Texture）每帧整屏快照再两遍高斯太贵，而且外部纹理能不能
/// 被 `toImageSync` 抓到要看后端 —— 这一档把两者都绕开。
class WaveStage extends SlottedMultiChildRenderObjectWidget<WaveSide, RenderBox> {
  const WaveStage({
    super.key,
    required this.progress,
    required this.style,
    required this.palette,
    required this.programs,
    required this.pixelRatio,
    this.source,
    this.focus,
    this.plain = false,
    this.content,
    this.contentImage,
    required this.revealed,
    this.revealedLiveOnceCrossed = false,
    this.revealedLive = false,
    this.reverse = false,
  });

  final Animation<double> progress;
  final DistortionWaveStyle style;
  final DistortionWavePalette palette;
  final WavePrograms? programs;
  final double pixelRatio;

  /// 波从哪个框出发，用本组件的坐标；null 用类型默认的（[waveDefaultSource]）。
  final Rect? source;
  final Offset? focus;
  final bool plain;
  final Widget? content;
  final ui.Image? contentImage;
  final Widget revealed;

  /// 波前扫过整屏就把触摸交给新页（路由的页面），而不是等波整段走完。
  final bool revealedLiveOnceCrossed;

  /// 新页实时画、不快照、不过 shader（见类注释）。旧页那一面的覆盖掩膜负责分界。
  final bool revealedLive;

  /// 反向（回缩）：与刷刷路由的退出同一套画面。 [progress] 取 1−p 配合使用 ——
  /// p'=1 时源屏定格（revealed 槽）压满整屏，随波前从屏幕边缘收拢，目的屏截图
  /// （[contentImage]）走 side=+1 镜片从边缘带扭曲地长进来，最后旧帧在源头附近
  /// 淡出。与正向共用同一段着色器与几何，只是进度倒放 + 槽位角色对调。
  final bool reverse;

  @override
  Iterable<WaveSide> get slots => WaveSide.values;

  @override
  Widget? childForSlot(WaveSide slot) => switch (slot) {
    WaveSide.revealed => revealed,
    WaveSide.content => content,
  };

  @override
  RenderWaveStage createRenderObject(BuildContext context) => RenderWaveStage(
    progress: progress,
    style: style,
    palette: palette,
    programs: programs,
    pixelRatio: pixelRatio,
    source: source,
    focus: focus,
    plain: plain,
    contentImage: contentImage,
    revealedLiveOnceCrossed: revealedLiveOnceCrossed,
    revealedLive: revealedLive,
    reverse: reverse,
  );

  @override
  void updateRenderObject(BuildContext context, RenderWaveStage renderObject) {
    renderObject
      ..progress = progress
      ..style = style
      ..palette = palette
      ..programs = programs
      ..pixelRatio = pixelRatio
      ..source = source
      ..focus = focus
      ..plain = plain
      ..contentImage = contentImage
      ..revealedLiveOnceCrossed = revealedLiveOnceCrossed
      ..revealedLive = revealedLive
      ..reverse = reverse;
  }
}

class _SnapshotContext extends PaintingContext {
  _SnapshotContext(super.containerLayer, super.estimatedBounds);

  void finish() => stopRecordingIfNeeded();
}

/// 画 [WaveStage]。自己是一个 repaint boundary：波的每一帧都要重画，外面不需要。
class RenderWaveStage extends RenderBox with SlottedContainerRenderObjectMixin<WaveSide, RenderBox> {
  RenderWaveStage({
    required this._progress,
    required this._style,
    required this._palette,
    required this._programs,
    required this._pixelRatio,
    this._source,
    this._focus,
    this._plain = false,
    this._contentImage,
    this._revealedLiveOnceCrossed = false,
    this._revealedLive = false,
    this._reverse = false,
  });

  /// 第一张模糊副本的半径；第二张用 style 的完整半径。
  static const _nearBlur = 7.0;

  /// 模糊副本按一逻辑像素一个像素画：反正已经糊了，再高的分辨率没用。
  static const _blurScale = 1.0;

  Animation<double> _progress;
  set progress(Animation<double> value) {
    if (identical(value, _progress)) return;
    if (attached) _progress.removeListener(_onProgress);
    _progress = value;
    if (attached) _progress.addListener(_onProgress);
    _onProgress();
  }

  /// 上一次交给语义和触摸的那一面。
  RenderBox? _lastLive;

  void _onProgress() {
    markNeedsPaint();
    final live = _live;
    if (!identical(live, _lastLive)) {
      _lastLive = live;
      markNeedsSemanticsUpdate();
    }
  }

  DistortionWaveStyle _style;
  set style(DistortionWaveStyle value) {
    if (identical(value, _style)) return;
    _style = value;
    _particles = null;
    _releaseContentBlur();
    markNeedsPaint();
  }

  DistortionWavePalette _palette;
  set palette(DistortionWavePalette value) {
    if (value == _palette) return;
    _palette = value;
    _packedPalette = null;
    markNeedsPaint();
  }

  WavePrograms? _programs;
  set programs(WavePrograms? value) {
    if (identical(value, _programs)) return;
    _disposeShaders();
    _programs = value;
    markNeedsPaint();
  }

  double _pixelRatio;
  set pixelRatio(double value) {
    if (value == _pixelRatio) return;
    _pixelRatio = value;
    markNeedsPaint();
  }

  Rect? _source;
  set source(Rect? value) {
    if (value == _source) return;
    _source = value;
    markNeedsPaint();
  }

  Offset? _focus;
  set focus(Offset? value) {
    if (value == _focus) return;
    _focus = value;
    markNeedsPaint();
  }

  bool _plain;
  set plain(bool value) {
    if (value == _plain) return;
    _plain = value;
    markNeedsPaint();
  }

  ui.Image? _contentImage;
  set contentImage(ui.Image? value) {
    if (identical(value, _contentImage)) return;
    _contentImage = value;
    _releaseContentBlur();
    markNeedsPaint();
  }

  bool _revealedLiveOnceCrossed;
  set revealedLiveOnceCrossed(bool value) {
    if (value == _revealedLiveOnceCrossed) return;
    _revealedLiveOnceCrossed = value;
    _onProgress();
  }

  bool _revealedLive;
  set revealedLive(bool value) {
    if (value == _revealedLive) return;
    _revealedLive = value;
    markNeedsPaint();
  }

  bool _reverse;
  set reverse(bool value) {
    if (value == _reverse) return;
    _reverse = value;
    markNeedsPaint();
  }

  RenderBox? get _revealed => childForSlot(WaveSide.revealed);
  RenderBox? get _content => childForSlot(WaveSide.content);

  /// 这一次跑不出快照（某一面里有平台视图）：剩下的路都走淡入淡出。
  bool _failed = false;

  ui.FragmentShader? _revealedShader;
  ui.FragmentShader? _contentShader;
  ui.FragmentShader? _bandShader;
  final _revealedPaint = Paint();
  final _contentPaint = Paint();
  final _bandPaint = Paint();
  final _dotPaint = Paint();
  final _imagePaint = Paint()..filterQuality = FilterQuality.low;
  final _revealedOpacity = LayerHandle<OpacityLayer>();
  final _contentOpacity = LayerHandle<OpacityLayer>();
  final _lumps = Float64List(WaveRim.count * 3);
  Float32List? _packedPalette;
  List<WaveParticle>? _particles;

  /// 这一帧的快照和模糊副本，下一帧释放。
  final _frameImages = <ui.Image>[];

  /// [_contentImage] 的模糊副本，只做一次：波扫过时它不变。
  ui.Image? _contentNear;
  ui.Image? _contentFar;

  double get _value => _progress.value;

  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _progress.addListener(_onProgress);
    _lastLive = _live;
  }

  @override
  void detach() {
    _progress.removeListener(_onProgress);
    super.detach();
  }

  @override
  void dispose() {
    _releaseFrameImages();
    _releaseContentBlur();
    _disposeShaders();
    _revealedOpacity.layer = null;
    _contentOpacity.layer = null;
    super.dispose();
  }

  void _disposeShaders() {
    _revealedShader?.dispose();
    _contentShader?.dispose();
    _bandShader?.dispose();
    _revealedShader = _contentShader = _bandShader = null;
  }

  void _releaseFrameImages() {
    for (final image in _frameImages) {
      image.dispose();
    }
    _frameImages.clear();
  }

  void _releaseContentBlur() {
    _contentNear?.dispose();
    _contentFar?.dispose();
    _contentNear = _contentFar = null;
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() {
    final tight = BoxConstraints.tight(size);
    _revealed?.layout(tight);
    _content?.layout(tight);
  }

  /// 接触摸的那一面：波开始前是旧页，波走完之后是新页（路由的页面在波前扫过整屏
  /// 时就接），中间谁也不接。
  RenderBox? get _live {
    final p = _value;
    if (p >= 1) return _revealed;
    if (p <= 0) return _content;
    if (_revealedLiveOnceCrossed && hasSize && _frontAt(p).hasCleared) return _revealed;
    return null;
  }

  WaveFront _frontAt(double p) => WaveFront(
    progress: p,
    source: _source ?? waveDefaultSource(_style.type, size),
    size: size,
    style: _style,
    focus: _focus,
  );

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      _live?.hitTest(result, position: position) ?? false;

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final live = _live;
    if (live != null) visitor(live);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _releaseFrameImages();
    final p = _value;
    // 新的一次跑再给着色器一次机会。
    if (p <= 0 || p >= 1) _failed = false;
    final programs = _programs;
    if (_plain || programs == null || _failed) {
      _paintPlain(context, offset, p);
      return;
    }

    final source = _source ?? waveDefaultSource(_style.type, size);
    final front = _frontAt(p);
    final live = p > 0 && p < 1;
    final acting = live && front.energy > 0;
    final blurring = acting && _style.blur > 0;

    // —— 反向（回缩）：底层不画任何东西，**实时的**新页面直接透出来 ——
    // 旧帧走 side=-1 镜片压在波前**后方**（靠近源头的内区），随波前收拢缩进
    // 源头，尾段淡出。歌词/流光等活内容全程不被冻结（真机反馈：冻结版会让
    // 歌词与流光在波期间停摆、结束时跳变，已否决"目的屏截图"方案）。
    if (_reverse) {
      _revealedOpacity.layer = null;
      if (p <= 0) {
        _contentOpacity.layer = null;
        return; // 波已完全收进源头，新页面独占。
      }
      final content = _content;
      ui.Image? img = _contentImage;
      if (img == null && content != null) {
        img = _snapshot(content);
        if (img == null) return _fail(context, offset, p);
      }
      if (img != null) {
        var near = img;
        var far = img;
        if (blurring) {
          if (identical(img, _contentImage)) {
            near = _contentNear ??= _blurred(img, _nearBlur);
            far = _contentFar ??= _blurred(img, _style.blur);
          } else {
            near = _blurred(img, _nearBlur);
            far = _blurred(img, _style.blur);
            _frameImages.addAll([near, far]);
          }
        }
        final shader = _contentShader ??= programs.lens.fragmentShader();
        // 旧帧压在波前后方：波前收拢到哪里，前方（靠屏幕边缘）就露出底下
        // 实时的新页面，后方（靠源头）还压着正在缩回的旧帧。
        _setLens(shader, front, -1, img, near, far);
        // 尾段淡出：波前收到源头时半径仍有 startRadius，旧帧还剩源头附近一团
        // —— 用「波前走到哪了」（moved，1=满屏 0=已收进源头）最后 15% 行程的
        // 透明度收掉，落回真实页面时不出现硬切。
        final tailT = (front.moved / 0.15).clamp(0.0, 1.0);
        final tail = (tailT * tailT * (3 - 2 * tailT) * 255).round();
        if (tail >= 255) {
          _contentOpacity.layer = null;
          context.canvas.drawRect(offset & size, _contentPaint..shader = shader);
        } else {
          _contentOpacity.layer = context.pushOpacity(
            offset,
            tail,
            (ctx, off) => ctx.canvas.drawRect(
              off & size,
              _contentPaint..shader = shader,
            ),
            oldLayer: _contentOpacity.layer,
          );
        }
      } else {
        _contentOpacity.layer = null;
      }
      if (live) {
        _paintBand(context.canvas, offset, programs, front);
        _paintDots(context.canvas, offset, front, source);
      }
      return;
    }

    final revealedLens = !_revealedLive && front.launched && acting;
    // 发射之后，旧页这一面的覆盖掩膜一直留着，直到波前扫过整屏 —— 哪怕鼓包先
    // 一步没了（缓动很慢时会出现）。
    final contentLens = live && !front.hasCleared && (front.launched || front.gravity > 0);

    ui.Image? revealedImage;
    ui.Image? contentImage;
    final revealed = _revealed;
    final content = _content;
    if (revealedLens && revealed != null) {
      revealedImage = _snapshot(revealed);
      if (revealedImage == null) return _fail(context, offset, p);
    }
    if (contentLens) {
      contentImage = _contentImage;
      if (contentImage == null && content != null) {
        contentImage = _snapshot(content);
        if (contentImage == null) return _fail(context, offset, p);
      }
    }

    // 新页实时画在最底下，旧页的着色器再按覆盖掩膜压上去。
    if (_revealedLive && revealed != null) context.paintChild(revealed, offset);

    // context.canvas 每次绘制都要重新取：画一个 repaint boundary 子节点会把
    // canvas 结束掉。
    if (front.launched && !_revealedLive) {
      if (revealedImage != null) {
        var near = revealedImage;
        var far = revealedImage;
        if (blurring) {
          near = _blurred(revealedImage, _nearBlur);
          far = _blurred(revealedImage, _style.blur);
          _frameImages.addAll([near, far]);
        }
        final shader = _revealedShader ??= programs.lens.fragmentShader();
        _setLens(shader, front, -1, revealedImage, near, far);
        context.canvas.drawRect(offset & size, _revealedPaint..shader = shader);
      } else if (revealed != null) {
        context.paintChild(revealed, offset);
      }
    }
    if (!front.hasCleared) {
      if (contentLens && contentImage != null) {
        var near = contentImage;
        var far = contentImage;
        if (blurring) {
          if (identical(contentImage, _contentImage)) {
            near = _contentNear ??= _blurred(contentImage, _nearBlur);
            far = _contentFar ??= _blurred(contentImage, _style.blur);
          } else {
            near = _blurred(contentImage, _nearBlur);
            far = _blurred(contentImage, _style.blur);
            _frameImages.addAll([near, far]);
          }
        }
        final shader = _contentShader ??= programs.lens.fragmentShader();
        _setLens(shader, front, 1, contentImage, near, far);
        context.canvas.drawRect(offset & size, _contentPaint..shader = shader);
      } else {
        _paintContentPlain(context, offset);
      }
    }
    if (live) {
      final canvas = context.canvas;
      _paintBand(canvas, offset, programs, front);
      _paintDots(canvas, offset, front, source);
    }
  }

  void _fail(PaintingContext context, Offset offset, double p) {
    _releaseFrameImages();
    _failed = true;
    _paintPlain(context, offset, p);
  }

  /// 交叉淡入：新页在下面淡入，旧页在上面淡出。路由的页面自己就是旧页，所以
  /// 路由不画这一层。反向（回缩）时两端语义对调：p=1 是"旧页满屏"。
  void _paintPlain(PaintingContext context, Offset offset, double p) {
    final revealed = _revealed;
    final content = _content;
    // 静止时只画该显示的那一面。反向：p=1 是"源屏定格满屏"，p=0 是目的屏独占。
    if (p >= 1 || p <= 0) {
      _revealedOpacity.layer = _contentOpacity.layer = null;
      if (_reverse) {
        if (p <= 0) {
          final shown = content;
          if (shown != null) {
            context.paintChild(shown, offset);
          } else {
            final image = _contentImage;
            if (image != null) {
              context.canvas.drawImageRect(
                image,
                Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
                offset & size,
                _imagePaint,
              );
            }
          }
          return;
        }
        final shown = revealed;
        if (shown != null) context.paintChild(shown, offset);
        return;
      }
      final shown = p >= 1 ? revealed : content;
      if (shown != null) context.paintChild(shown, offset);
      return;
    }
    // 中段交叉淡入：revealed 随 p 淡入、content 随 p 淡出 —— 端点语义已由
    // 上面的反向/正向分支各自定义，中段两个方向恰好同形。
    final revealedAlpha = p;
    final contentAlpha = 1 - p;
    if (revealed != null) {
      _revealedOpacity.layer = context.pushOpacity(
        offset,
        (revealedAlpha * 255).round(),
        (context, offset) => context.paintChild(revealed, offset),
        oldLayer: _revealedOpacity.layer,
      );
    }
    if (content != null) {
      _contentOpacity.layer = context.pushOpacity(
        offset,
        (contentAlpha * 255).round(),
        (context, offset) => context.paintChild(content, offset),
        oldLayer: _contentOpacity.layer,
      );
    }
  }

  void _paintContentPlain(PaintingContext context, Offset offset) {
    final content = _content;
    final image = _contentImage;
    if (content != null) {
      context.paintChild(content, offset);
    } else if (image != null) {
      context.canvas.drawImageRect(
        image,
        Offset.zero & Size(image.width.toDouble(), image.height.toDouble()),
        offset & size,
        _imagePaint,
      );
    }
  }

  /// [child] 的一张图；里面有光栅化不了的东西（平台视图）时返回 null。
  ui.Image? _snapshot(RenderBox child) {
    final layer = OffsetLayer();
    final context = _SnapshotContext(layer, Offset.zero & size);
    context.paintChild(child, Offset.zero);
    context.finish();
    if (!layer.supportsRasterization()) {
      layer.dispose();
      return null;
    }
    final image = layer.toImageSync(Offset.zero & size, pixelRatio: _pixelRatio);
    layer.dispose();
    _frameImages.add(image);
    return image;
  }

  /// [image] 按 [radius] 模糊，尺寸按 [_blurScale]。
  ui.Image _blurred(ui.Image image, double radius) {
    final width = (size.width * _blurScale).ceil().clamp(1, 8192);
    final height = (size.height * _blurScale).ceil().clamp(1, 8192);
    final bounds = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    final sigma = radius * _blurScale;
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..saveLayer(
        bounds,
        Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp),
      )
      ..drawImageRect(image, Offset.zero & Size(image.width.toDouble(), image.height.toDouble()), bounds, _imagePaint)
      ..restore();
    final picture = recorder.endRecording();
    final out = picture.toImageSync(width, height);
    picture.dispose();
    return out;
  }

  void _setLens(ui.FragmentShader shader, WaveFront f, double side, ui.Image sharp, ui.Image near, ui.Image far) {
    var i = 0;
    shader
      ..setFloat(i++, size.width)
      ..setFloat(i++, size.height)
      ..setFloat(i++, f.origin.dx)
      ..setFloat(i++, f.origin.dy)
      ..setFloat(i++, f.spine)
      ..setFloat(i++, f.radius)
      ..setFloat(i++, f.squash)
      ..setFloat(i++, f.time)
      ..setFloat(i++, f.swell)
      ..setFloat(i++, f.tilt)
      ..setFloat(i++, f.energy)
      ..setFloat(i++, f.gravity)
      ..setFloat(i++, f.ring ? 1 : 0)
      ..setFloat(i++, f.hold)
      ..setFloat(i++, _style.amplitude)
      ..setFloat(i++, _style.lensWidth)
      ..setFloat(i++, _style.aberration)
      ..setFloat(i++, side)
      ..setFloat(i++, _style.blur)
      ..setFloat(i++, _style.blurAhead)
      ..setFloat(i++, _style.blurBehind)
      ..setFloat(i++, f.launched ? 1 : 0)
      ..setImageSampler(0, sharp, filterQuality: FilterQuality.low)
      ..setImageSampler(1, near, filterQuality: FilterQuality.low)
      ..setImageSampler(2, far, filterQuality: FilterQuality.low);
  }

  /// OKLab 三元组补齐成 vec4：最多八种颜色，再加前后两道色边；最后是颜色数量。
  static Float32List _packPalette(DistortionWavePalette palette) {
    final colors = palette.colors.isEmpty ? [palette.ahead] : palette.colors.take(8).toList();
    final out = Float32List(10 * 4 + 1);
    for (var k = 0; k < 8; k++) {
      out.setRange(k * 4, k * 4 + 3, waveOklab(colors[k % colors.length]));
    }
    out.setRange(32, 35, waveOklab(palette.ahead));
    out.setRange(36, 39, waveOklab(palette.behind));
    out[40] = colors.length.toDouble();
    return out;
  }

  void _paintBand(Canvas canvas, Offset offset, WavePrograms programs, WaveFront f) {
    final s = _style;
    WaveRim.lumps(_lumps, time: f.time, size: size, cornerRadius: s.cornerRadius, pulse: s.rimPulse);
    final palette = _packedPalette ??= _packPalette(_palette);
    final shader = _bandShader ??= programs.band.fragmentShader();
    var i = 0;
    shader
      ..setFloat(i++, size.width)
      ..setFloat(i++, size.height)
      ..setFloat(i++, f.origin.dx)
      ..setFloat(i++, f.origin.dy)
      ..setFloat(i++, f.spine)
      ..setFloat(i++, f.radius)
      ..setFloat(i++, f.squash)
      ..setFloat(i++, f.time)
      ..setFloat(i++, f.swell)
      ..setFloat(i++, f.tilt)
      ..setFloat(i++, f.glow)
      ..setFloat(i++, f.rim)
      ..setFloat(i++, f.clearRadius)
      ..setFloat(i++, f.hairClearRadius)
      ..setFloat(i++, f.ring ? 1 : 0)
      ..setFloat(i++, f.hold)
      ..setFloat(i++, s.lead)
      ..setFloat(i++, s.tail)
      ..setFloat(i++, s.strength)
      ..setFloat(i++, s.rimWidth)
      ..setFloat(i++, s.rimSoftness)
      ..setFloat(i++, s.cornerRadius)
      ..setFloat(i++, s.rimUnevenness)
      ..setFloat(i++, s.rimPulse)
      ..setFloat(i++, s.hairlineWidth)
      ..setFloat(i++, s.hairlineOpacity)
      ..setFloat(i++, s.hairlineWhite)
      ..setFloat(i++, palette[40])
      ..setFloat(i++, 0)
      ..setFloat(i++, 0);
    for (var k = 0; k < 40; k++) {
      shader.setFloat(i++, palette[k]);
    }
    for (var k = 0; k < WaveRim.count; k++) {
      shader
        ..setFloat(i++, _lumps[k * 3])
        ..setFloat(i++, _lumps[k * 3 + 1])
        ..setFloat(i++, _lumps[k * 3 + 2])
        ..setFloat(i++, 0);
    }
    canvas.drawRect(offset & size, _bandPaint..shader = shader);
  }

  /// 小点：在颜色上面，平涂的白。
  void _paintDots(Canvas canvas, Offset offset, WaveFront front, Rect source) {
    final particles = _particles ??= [for (var i = 0; i < _style.particleCount; i++) WaveParticle(i, _style)];
    for (final particle in particles) {
      final opacity = particle.opacity(front);
      if (opacity <= 0) continue;
      _dotPaint.color = Color.fromRGBO(255, 255, 255, opacity.clamp(0.0, 1.0));
      canvas.drawCircle(particle.point(front, source) + offset, particle.size / 2, _dotPaint);
    }
  }
}
