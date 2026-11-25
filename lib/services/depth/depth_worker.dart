import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:ort_dart/ort_dart.dart';

import 'depth_ort_raw.dart';
import 'depth_pipeline.dart';

/// Windows 深度推理 worker（在后台 isolate 内跑完整管线）。
///
/// 为什么整条管线（解码 → 推理 → 修补 → 编码 PNG → 落盘）都放这边：
/// UI isolate 只发请求、收路径。`package:image` 的 PNG/JPEG 解码与编码是纯
/// Dart 计算（400×400 解码 + 3 张分层编码实测数百毫秒），留在主 isolate 会
/// 直接卡住播放页动画；ORT 推理（q4f16 @378）更要紧。
///
/// 会话常驻：由 `WindowsDartDepthEngine` 首次需要时 spawn 一次，进程内复用 ——
/// createSession（q4f16 19MB / migan 11MB）实测几百毫秒，不该每首歌重来。
///
/// 消息协议：[DepthRequest] → [DepthReply]（都是纯 String/num/List，可跨 isolate；
/// 不含 ffi.Pointer —— 张量指针**严禁**离开本 isolate，ORT 内存随 OrtValue 释放失效）。

/// worker 命令。
enum DepthCommand {
  /// 打开深度模型会话（必须先于任何 generate）。
  loadDepth,

  /// 打开 MI-GAN 神经修补会话（可选；设置项关闭时不发）。
  loadInpaint,

  /// shader 路径：深度图 + 修补背景。
  generateDepth,

  /// 多层降级路径：3 张分层 PNG。
  generateLayers,
}

/// 请求载荷（字段均为可跨 isolate 传递的原始类型）。
class DepthRequest {
  const DepthRequest({
    required this.command,
    this.dllPath,
    this.modelPath,
    this.inpaintModelPath,
    this.sourcePath,
    this.outDir,
  });

  final DepthCommand command;
  final String? dllPath;
  final String? modelPath;
  final String? inpaintModelPath;
  final String? sourcePath;
  final String? outDir;
}

/// 应答：`ok == false` 时看 [error]；成功时填对应结果字段。
class DepthReply {
  const DepthReply({
    required this.ok,
    this.error,
    this.depthPath,
    this.bgFillPath,
    this.depthStd,
    this.inpaintSource,
    this.layers,
  });

  final bool ok;
  final String? error;

  /// generateDepth：`<outDir>/depth.png`
  final String? depthPath;

  /// generateDepth：`<outDir>/bg_fill.png`（修补背景）
  final String? bgFillPath;

  /// generateDepth：深度图标准差（自适应强度用）
  final double? depthStd;

  /// generateDepth：'migan' / 'pushpull'，仅入 meta 供核对
  final String? inpaintSource;

  /// generateLayers：`[layer0, layer1, layer2]` 绝对路径
  final List<String>? layers;

  factory DepthReply.fail(String error) => DepthReply(ok: false, error: error);
}

/// isolate 入口。
///
/// 握手协议：worker 建一个 ReceivePort，把它的 **SendPort 回给主 isolate**；
/// 之后主 isolate 往那个端口发 [DepthRequest]，worker 把 [DepthReply] 发回
/// 给 `mainPort`（同一条端口，靠消息类型区分）。
void runDepthWorker(SendPort mainPort) {
  final inbox = ReceivePort();
  mainPort.send(inbox.sendPort);
  inbox.listen((message) async {
    if (message is! DepthRequest) return;
    final reply = await _handle(message);
    mainPort.send(reply);
  });
}

// ── isolate 内全局状态（进程内一次；会话跨请求复用）─────────────────────────

OrtSession? _depthSession;
OrtSession? _inpaintSession;
String? _depthInputName;
String? _miganImageName;
String? _miganMaskName;
OrtRunOptions? _runOptions;

Future<DepthReply> _handle(DepthRequest req) async {
  try {
    switch (req.command) {
      case DepthCommand.loadDepth:
        return _loadDepth(req);
      case DepthCommand.loadInpaint:
        return _loadInpaint(req);
      case DepthCommand.generateDepth:
        return _generateDepth(req);
      case DepthCommand.generateLayers:
        return _generateLayers(req);
    }
  } catch (e, s) {
    // 异常不外抛：worker 崩了就再没有 3D 封面了，主 isolate 按失败走平面封面。
    // 堆栈只取前三行：跨 isolate 传全文没意义，主 isolate 会带命令名一起打日志。
    final head = s.toString().split('\n').take(3).join(' << ');
    return DepthReply.fail('$e | $head');
  }
}

DepthReply _loadDepth(DepthRequest req) {
  final dll = req.dllPath;
  final model = req.modelPath;
  if (dll == null || model == null) return DepthReply.fail('缺少 dll/model 路径');
  if (!File(dll).existsSync()) return DepthReply.fail('未找到运行时: $dll');
  if (!File(model).existsSync()) return DepthReply.fail('未找到深度模型: $model');
  if (_depthSession != null) return DepthReply(ok: true);

  // 必须在**首次触碰 ort_dart 任何顶层 final 之前**注入库句柄：App 由用户双击
  // 启动时当前工作目录不可靠，传 exe 同目录的绝对路径，彻底不依赖 cwd。
  initializeOrtBindings(DynamicLibrary.open(dll));
  OrtEnv.instance.init();
  _runOptions ??= OrtRunOptions();

  // 官方全算子 dll 有融合内核，可以直接开图优化（Android 侧因裁剪版 so 必须
  // NO_OPT / DISABLE_ALL，这里不需要）。优化阶段失败退到 NO_OPT 再试一次。
  final options = OrtSessionOptions()
    ..setIntraOpNumThreads(4)
    ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
  final modelBytes = File(model).readAsBytesSync();
  try {
    _depthSession = OrtSession.fromBuffer(modelBytes, options);
  } catch (_) {
    // 图优化阶段失败（例如某融合内核缺失）：退到 NO_OPT 再试一次。
    final fallback = OrtSessionOptions()
      ..setIntraOpNumThreads(4)
      ..setSessionGraphOptimizationLevel(
          GraphOptimizationLevel.ortDisableAll);
    try {
      _depthSession = OrtSession.fromBuffer(modelBytes, fallback);
    } finally {
      fallback.release();
    }
  } finally {
    options.release();
  }
  final names = _depthSession!.inputNames;
  if (names.isEmpty) return DepthReply.fail('深度模型无输入名');
  _depthInputName = names.first;
  return DepthReply(ok: true);
}

DepthReply _loadInpaint(DepthRequest req) {
  final model = req.inpaintModelPath;
  if (model == null || !File(model).existsSync()) {
    return DepthReply.fail('未找到修补模型: $model');
  }
  if (_inpaintSession != null) return DepthReply(ok: true);
  final options = OrtSessionOptions()
    ..setIntraOpNumThreads(4)
    ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
  // 不用 fromFile：ORT 的 Windows 版 CreateSession 走 ORTCHAR_T（wchar_t）宽字符，
  // 而 Dart 侧 toNativeUtf8 是 UTF-8 字节 —— 非 ASCII 路径（或被 ANSI 代码页解析）
  // 会错位成「File doesn't exist」。fromBuffer 走 CreateSessionFromArray，零路径编码，
  // 探针实测 19MB q4f16 通过。
  final modelBytes = File(model).readAsBytesSync();
  try {
    _inpaintSession = OrtSession.fromBuffer(modelBytes, options);
  } finally {
    options.release();
  }
  // MI-GAN 两个输入：image [1,3,H,W] 与 mask [1,1,H,W]。按通道维（dims[1]）
  // 判定，不写死名字（导出时名字会变）——与 Kotlin 同一策略。
  for (final name in _inpaintSession!.inputNames) {
    final dims = sessionInputShape(_inpaintSession!, name);
    if (dims != null && dims.length >= 2 && dims[1] == 3) {
      _miganImageName = name;
    } else if (dims != null && dims.length >= 2 && dims[1] == 1) {
      _miganMaskName = name;
    }
  }
  if (_miganImageName == null || _miganMaskName == null) {
    _inpaintSession?.release();
    _inpaintSession = null;
    return DepthReply.fail('MI-GAN 输入名/形状不符合预期');
  }
  return DepthReply(ok: true);
}

/// 解码封面为 RGBA 字节 + 宽高（`package:image`，纯 Dart）。失败返回 null。
(img.Image, Uint8List)? _decodeCover(String sourcePath) {
  final file = File(sourcePath);
  if (!file.existsSync()) return null;
  final decoded = img.decodeImage(file.readAsBytesSync());
  if (decoded == null) return null;
  // 统一转 uint8 / 4 通道，后面所有像素级算法只认这一种布局。
  final rgba = decoded.convert(format: img.Format.uint8, numChannels: 4);
  return (rgba, rgba.getBytes(order: img.ChannelOrder.rgba));
}

DepthReply _generateDepth(DepthRequest req) {
  final session = _depthSession;
  final source = req.sourcePath;
  final outDir = req.outDir;
  if (session == null) return DepthReply.fail('MODEL_NOT_LOADED');
  if (source == null || outDir == null) return DepthReply.fail('缺少参数');
  final decoded = _decodeCover(source);
  if (decoded == null) return DepthReply.fail('cannot decode cover');
  final cover = decoded.$1;
  final rgba = decoded.$2;
  final w = cover.width, h = cover.height;

  // 1) 推理 + min-max 归一化
  final normResult = _runDepthInference(session, rgba, w, h);
  if (normResult == null) return DepthReply.fail('深度推理失败');
  final norm = normResult.norm;
  final std = normResult.std;

  // 2) 背景修补（push-pull）→ 可选神经细化（MI-GAN）
  final inpaint = inpaintBackground(rgba: rgba, w: w, h: h, norm: norm);
  var usedNeural = false;
  final migan = _inpaintSession;
  if (migan != null) {
    usedNeural = _neuralRefine(rgba, w, h, inpaint, migan);
  }

  // 3) 落盘：bg_fill.png + depth.png（8bit 灰度）
  final dir = Directory(outDir)..createSync(recursive: true);
  final bgPath = _joinPath(dir.path, 'bg_fill.png');
  File(bgPath).writeAsBytesSync(
      encodeRgbaPng(argb32ToRgbaBytes(inpaint.filled), w, h));
  final depthPath = _joinPath(dir.path, 'depth.png');
  File(depthPath).writeAsBytesSync(
      encodeRgbaPng(depthToGrayPngPixels(norm), depthGridSize, depthGridSize));

  return DepthReply(
    ok: true,
    depthPath: depthPath,
    bgFillPath: bgPath,
    depthStd: std,
    inpaintSource: usedNeural ? 'migan' : 'pushpull',
  );
}

/// 推理结果：归一化深度 + 标准差（自适应强度用）。
class _InferResult {
  const _InferResult(this.norm, this.std);
  final List<double> norm;
  final double std;
}

/// 深度推理：装配 NCHW f32 输入 → run → 原始视图读出 → 归一化。
///
/// 输出形状兼容 (1,1,H,W) 与 (1,H,W)：只按元素数判定，与 Kotlin 的摊平处理一致。
_InferResult? _runDepthInference(
  OrtSession session,
  Uint8List rgba,
  int w,
  int h,
) {
  final input = buildModelInput(rgba: rgba, w: w, h: h);
  final tensor =
      createTensorFromTypedData(input, [1, 3, depthGridSize, depthGridSize]);
  final List<double> raw = <double>[];
  try {
    final outputs = session.run(_runOptions!, {_depthInputName!: tensor});
    final out = outputs.isEmpty ? null : outputs.first;
    if (out == null) return null;
    // 直读 ORT 内部缓冲区（**当场消费**：OrtValue 一 release 这段内存就失效）。
    raw.addAll(floatTensorView(out));
    for (final o in outputs) {
      o?.release();
    }
  } finally {
    tensor.release();
  }
  if (raw.isEmpty) return null;
  if (raw.length != depthGridSize * depthGridSize) {
    // 元素数对不上（例如输出被导出成 1×3×H×W 的三倍）：截取一份网格大小，
    // 与 Kotlin 的「摊平后按 DEPTH_SIZE×DEPTH_SIZE 用」保持同一宽容度。
    final trimmed = Float64List(depthGridSize * depthGridSize);
    for (var i = 0; i < trimmed.length && i < raw.length; i++) {
      trimmed[i] = raw[i];
    }
    raw
      ..clear()
      ..addAll(trimmed);
  }
  final norm = normalizeDepth(raw);
  return _InferResult(norm, depthStd(norm));
}

/// MI-GAN 二次填充：成功时把 [inpaint].filled 整体覆盖为网络输出并返回 true。
///
/// 任何异常都吞掉返回 false（保底 push-pull 结果）—— 与 Kotlin neuralRefine 的
/// try/catch 同语义：神经细化是增益，不能因为它把整个 3D 封面搞没。
bool _neuralRefine(
  Uint8List rgba,
  int w,
  int h,
  InpaintResult inpaint,
  OrtSession session,
) {
  try {
    final imageTensor = createTensorFromTypedData(miganImageTensor(rgba, w, h), [1, 3, h, w]);
    final maskTensor = createTensorFromTypedData(miganMaskTensor(inpaint.maskGrid, w, h), [1, 1, h, w]);
    try {
      final outputs = session.run(_runOptions!, {
        _miganImageName!: imageTensor,
        _miganMaskName!: maskTensor,
      });
      final out = outputs.isEmpty ? null : outputs.first;
      if (out == null) return false;
      final nchw = uint8TensorView(out);
      final filled = miganOutputToArgb(nchw, w, h);
      // 官方 pipeline 保证洞外像素与原图一致，故整体覆盖。
      final target = inpaint.filled;
      for (var i = 0; i < target.length && i < filled.length; i++) {
        target[i] = filled[i];
      }
      for (final o in outputs) {
        o?.release();
      }
      return true;
    } finally {
      imageTensor.release();
      maskTensor.release();
    }
  } catch (_) {
    return false;
  }
}

DepthReply _generateLayers(DepthRequest req) {
  final session = _depthSession;
  final source = req.sourcePath;
  final outDir = req.outDir;
  if (session == null) return DepthReply.fail('MODEL_NOT_LOADED');
  if (source == null || outDir == null) return DepthReply.fail('缺少参数');
  final decoded = _decodeCover(source);
  if (decoded == null) return DepthReply.fail('cannot decode cover');
  final cover = decoded.$1;
  final rgba = decoded.$2;
  final w = cover.width, h = cover.height;
  final pixels = rgbaToArgb32(rgba, w, h);

  final inferred = _runDepthInference(session, rgba, w, h);
  if (inferred == null) return DepthReply.fail('深度推理失败');
  final norm = inferred.norm;

  // layer0 从修补后的背景切割（主体被抠走处已填充，不再有透明洞）—— 与 Kotlin 同序。
  final inpaint =
      inpaintBackground(rgba: rgba, w: w, h: h, norm: norm, pixels: pixels);
  // 神经细化（MI-GAN）：Windows 端**多层路径是主路径**（桌面不跑 runtime shader，
  // 见 DepthCoverHost._useShaderPath），所以这里必须接上 MI-GAN —— 否则设置页的
  // 「AI 背景修补」开关在 Windows 上就是「看得见按不动」的死开关。
  // 注：Android 的 Kotlin `generate` 没接（其主路径是 shader），这里是 Windows 侧
  // 的有意增益；失败自动回落 push-pull（_neuralRefine 内部 try/catch）。
  final migan = _inpaintSession;
  if (migan != null) {
    _neuralRefine(rgba, w, h, inpaint, migan);
  }
  final dir = Directory(outDir)..createSync(recursive: true);
  // 修补底板（全尺寸、主体已被填补）：多层路径**必须**画它，否则修补不可见。
  //
  // 推理：三条深度带 0–0.40 / 0.35–0.70 / 0.65–1.00 铺满 0..1，合成后 = 原图完整；
  // 而 `inpaint.filled` 只喂给 layer0，layer0 的带只覆盖「背景深度」，主体（≈0.9）
  // 永远不在那一带里 —— 所以修补结果以前根本不进任何一层（视觉上「修补没生效」）。
  // 把整幅修补图作为底板垫在三层之下，前景移开后露出的才是「主体已被填掉的背景」。
  final platePath = _joinPath(dir.path, 'bg_fill.png');
  File(platePath)
      .writeAsBytesSync(encodeRgbaPng(argb32ToRgbaBytes(inpaint.filled), w, h));
  final paths = <String>[];
  for (var li = 0; li < depthBands.length; li++) {
    final band = depthBands[li];
    final src = li == 0 ? inpaint.filled : pixels;
    final layer = splitLayer(
      pixels: src,
      w: w,
      h: h,
      norm: norm,
      lo: band[0],
      hi: band[1],
      feather: layerFeather,
    );
    final path = _joinPath(dir.path, 'layer$li.png');
    File(path).writeAsBytesSync(encodeRgbaPng(argb32ToRgbaBytes(layer), w, h));
    paths.add(path);
  }
  return DepthReply(ok: true, layers: paths, bgFillPath: platePath);
}

/// 平台路径拼接（与 DepthCoverCache._join 同语义；本文件在 isolate 内跑，
/// 不引 cache 以免把它拖进 worker 的依赖图）。
String _joinPath(String a, String b) => '$a${Platform.pathSeparator}$b';

/// ARGB32（无符号 32 位）→ RGBA 字节。
///
/// **显式移位**写出，不走 `Uint32List.buffer`：小端下 0xAARRGGBB 在内存里是
/// `BB GG RR AA`，把 buffer 直接当 RGBA/ARGB 用会红蓝颠倒。
Uint8List argb32ToRgbaBytes(List<int> argb) {
  final out = Uint8List(argb.length * 4);
  for (var i = 0; i < argb.length; i++) {
    final p = argb[i] & 0xFFFFFFFF;
    final s = i * 4;
    out[s] = (p >> 16) & 0xFF;
    out[s + 1] = (p >> 8) & 0xFF;
    out[s + 2] = p & 0xFF;
    out[s + 3] = (p >> 24) & 0xFF;
  }
  return out;
}

/// RGBA 字节 → PNG（保留 alpha）。
Uint8List encodeRgbaPng(Uint8List rgba, int w, int h) {
  final image = img.Image.fromBytes(
    width: w,
    height: h,
    bytes: rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return img.encodePng(image);
}
