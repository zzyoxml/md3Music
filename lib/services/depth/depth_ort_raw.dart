import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:ort_dart/generated_bindings.dart' as bg;
import 'package:ort_dart/ort_dart.dart';

/// OrtValue ↔ 原始 TypedData 的低开销通道。
///
/// 为什么不直接用上游 `OrtValueTensor.value` / `createTensorWithDataList`：
/// - **输出**侧上游会把张量 `reshape` 成 4 层嵌套 `List<List<...>>`
///   （`list_shape_extension.dart`）。378×378 深度图 ≈ 14 万个中间 List 对象、
///   MI-GAN 输出（3×400×400 u8）≈ 48 万个分片复制，纯浪费；本文件用
///   `GetTensorMutableData` + `asTypedList` 直读（**该内存属 ORT，随 OrtValue
///   释放即失效**：不能存字段、不能跨 isolate 传递，必须当场消费完）。
/// - **输入**侧上游要求传 `List` 并自己走 flatten + calloc；本仓的张量已经是
///   现成的 Float32List/Uint8List，直接 memcpy 一次即可。
///
/// 内存归属与上游一致：输入缓冲区由 calloc 分配，挂在 `OrtValueTensor(ptr,
/// dataPtr)` 上，`release()` 时一并 free（`CreateTensorWithDataAsOrtValue`
/// 不拷贝数据，只包装指针 —— 所以缓冲区必须活到 OrtValue 释放为止）。
///
/// 仅供后台 isolate 内使用（OrtEnv / session 都是 isolate 级）。

/// ONNX 张量元素类型（`ONNX_TENSOR_ELEMENT_DATA_TYPE_*` 的两个子集）。
const int _dtFloat32 = 1;
const int _dtUint8 = 2;

/// 用调用方的 TypedData 建 CPU 输入张量；返回值的 `release()` 会同时释放缓冲区。
///
/// 支持 Float32List（f32）与 Uint8List（u8）—— 本仓只用这两种：
/// ViT-S 深度模型输入 f32、MI-GAN 图像/掩码输入 u8。
OrtValueTensor createTensorFromTypedData(TypedData data, List<int> shape) {
  final dtype = data is Float32List
      ? _dtFloat32
      : data is Uint8List
          ? _dtUint8
          : throw ArgumentError('只支持 Float32List / Uint8List，收到 ${data.runtimeType}');
  final elemBytes = dtype == _dtFloat32 ? 4 : 1;
  var elementCount = 1;
  for (final s in shape) {
    elementCount *= s;
  }
  if (elementCount * elemBytes != data.lengthInBytes) {
    throw ArgumentError(
        '形状与数据长度不符：shape=$shape bytes=${data.lengthInBytes}');
  }
  final api = OrtEnv.instance.ortApiPtr.ref;
  final bytes = elementCount * elemBytes;
  final buf = calloc<ffi.Uint8>(bytes);
  // dart:ffi 的指针只给 `asTypedList`（ByteBuffer 才有 asUint8List）。
  buf.asTypedList(bytes).setRange(
      0, bytes, data.buffer.asUint8List(data.offsetInBytes, bytes));

  final shapePtr = calloc<ffi.Int64>(shape.length);
  for (var i = 0; i < shape.length; i++) {
    shapePtr[i] = shape[i];
  }
  final memInfoPtrPtr = calloc<ffi.Pointer<bg.OrtMemoryInfo>>();
  final valuePtrPtr = calloc<ffi.Pointer<bg.OrtValue>>();
  ffi.Pointer<bg.OrtMemoryInfo>? memInfo;
  try {
    _check(api.CreateCpuMemoryInfo.asFunction<
        bg.OrtStatusPtr Function(
            int, int, ffi.Pointer<ffi.Pointer<bg.OrtMemoryInfo>>)>()(
        bg.OrtAllocatorType.OrtDeviceAllocator, bg.OrtMemType.OrtMemTypeCPU,
        memInfoPtrPtr));
    memInfo = memInfoPtrPtr.value;
    _check(api.CreateTensorWithDataAsOrtValue.asFunction<
        bg.OrtStatusPtr Function(
            ffi.Pointer<bg.OrtMemoryInfo>,
            ffi.Pointer<ffi.Void>,
            int,
            ffi.Pointer<ffi.Int64>,
            int,
            int,
            ffi.Pointer<ffi.Pointer<bg.OrtValue>>)>()(
      memInfo,
      buf.cast(),
      bytes,
      shapePtr,
      shape.length,
      dtype,
      valuePtrPtr,
    ));
    // 第二个参数是「数据缓冲区」：OrtValueTensor.release() 会 calloc.free 它。
    return OrtValueTensor(valuePtrPtr.value, buf.cast());
  } catch (_) {
    calloc.free(buf);
    rethrow;
  } finally {
    calloc.free(shapePtr);
    calloc.free(memInfoPtrPtr);
    calloc.free(valuePtrPtr);
    // MemoryInfo 在 OrtValue 建好后即可释放（ORT 不持有它的引用）。
    if (memInfo != null && memInfo != ffi.nullptr) {
      api.ReleaseMemoryInfo
          .asFunction<void Function(ffi.Pointer<bg.OrtMemoryInfo>)>()(memInfo);
    }
  }
}

/// 读取 f32 输出张量的原始视图（只在 OrtValue 存活期间、同一 isolate 内有效）。
Float32List floatTensorView(OrtValue tensor) {
  final pp = calloc<ffi.Pointer<ffi.Float>>();
  try {
    _check(OrtEnv.instance.ortApiPtr.ref.GetTensorMutableData.asFunction<
        bg.OrtStatusPtr Function(
            ffi.Pointer<bg.OrtValue>, ffi.Pointer<ffi.Pointer<ffi.Void>>)>()(
        tensor.ptr, pp.cast()));
    return pp.value.asTypedList(tensor.elementCount);
  } finally {
    calloc.free(pp);
  }
}

/// 读取 u8 输出张量的原始视图（生命周期约束同 [floatTensorView]）。
Uint8List uint8TensorView(OrtValue tensor) {
  final pp = calloc<ffi.Pointer<ffi.Uint8>>();
  try {
    _check(OrtEnv.instance.ortApiPtr.ref.GetTensorMutableData.asFunction<
        bg.OrtStatusPtr Function(
            ffi.Pointer<bg.OrtValue>, ffi.Pointer<ffi.Pointer<ffi.Void>>)>()(
        tensor.ptr, pp.cast()));
    return pp.value.asTypedList(tensor.elementCount);
  } finally {
    calloc.free(pp);
  }
}

/// 读取 OrtTensorTypeAndShapeInfo 的维度数组（调用方负责 release info）。
List<int> _dimensionsOf(
  bg.OrtApi api,
  ffi.Pointer<bg.OrtTensorTypeAndShapeInfo> info,
) {
  final countPtr = calloc<ffi.Size>();
  try {
    _check(api.GetDimensionsCount.asFunction<
            bg.OrtStatusPtr Function(
                ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>,
                ffi.Pointer<ffi.Size>)>()(info, countPtr));
    final dims = countPtr.value;
    if (dims == 0) return const <int>[];
    final dimBuf = calloc<ffi.Int64>(dims);
    try {
      _check(api.GetDimensions.asFunction<
          bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>,
              ffi.Pointer<ffi.Int64>, int)>()(info, dimBuf, dims));
      return List<int>.generate(dims, (i) => dimBuf[i]);
    } finally {
      calloc.free(dimBuf);
    }
  } finally {
    calloc.free(countPtr);
  }
}

/// 取 session 某个输入的维度（MI-GAN 靠 `dims[1]==3` 区分 image / mask）。
///
/// 上游没有暴露「按输入名取形状」，这里走 C API：
/// `SessionGetInputTypeInfo` → `CastTypeInfoToTensorInfo` → `GetDimensions`。
/// 动态维（如 MI-GAN 的 H/W）在 ORT 里是 0 或 -1，调用方只用静态维（N/C）。
List<int>? sessionInputShape(OrtSession session, String inputName) {
  final api = OrtEnv.instance.ortApiPtr.ref;
  final index = session.inputNames.indexOf(inputName);
  if (index < 0) return null;
  // 上游只暴露 `address`（int），这里按地址还原指针 —— 生命周期由 session 持有。
  final sessionPtr = ffi.Pointer<bg.OrtSession>.fromAddress(session.address);
  final typeInfoPtrPtr = calloc<ffi.Pointer<bg.OrtTypeInfo>>();
  try {
    _check(api.SessionGetInputTypeInfo.asFunction<
            bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSession>, int,
                ffi.Pointer<ffi.Pointer<bg.OrtTypeInfo>>)>()(
        sessionPtr, index, typeInfoPtrPtr));
    final tensorInfoPtrPtr = calloc<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>();
    try {
      _check(api.CastTypeInfoToTensorInfo.asFunction<
              bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtTypeInfo>,
                  ffi.Pointer<
                      ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>)>()(
          typeInfoPtrPtr.value, tensorInfoPtrPtr));
      final tensorInfo = tensorInfoPtrPtr.value;
      if (tensorInfo == ffi.nullptr) return null; // 非张量输入
      return _dimensionsOf(api, tensorInfo);
    } finally {
      calloc.free(tensorInfoPtrPtr);
    }
  } finally {
    if (typeInfoPtrPtr.value != ffi.nullptr) {
      api.ReleaseTypeInfo.asFunction<
          void Function(ffi.Pointer<bg.OrtTypeInfo>)>()(typeInfoPtrPtr.value);
    }
    calloc.free(typeInfoPtrPtr);
  }
}

extension OrtValueElementCount on OrtValue {
  /// 元素总数（各维乘积）。上游的形状信息是私有字段，这里走公开 C API 自算。
  int get elementCount {
    final api = OrtEnv.instance.ortApiPtr.ref;
    final infoPtrPtr = calloc<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>();
    try {
      _check(api.GetTensorTypeAndShape.asFunction<
              bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtValue>,
                  ffi.Pointer<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>)>()(
          ptr, infoPtrPtr));
      final info = infoPtrPtr.value;
      final countPtr = calloc<ffi.Size>();
      try {
        _check(api.GetDimensionsCount.asFunction<
                bg.OrtStatusPtr Function(
                    ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>,
                    ffi.Pointer<ffi.Size>)>()(info, countPtr));
        final dims = countPtr.value;
        if (dims == 0) return 0;
        final dimBuf = calloc<ffi.Int64>(dims);
        try {
          _check(api.GetDimensions.asFunction<
              bg.OrtStatusPtr Function(
                  ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>,
                  ffi.Pointer<ffi.Int64>, int)>()(info, dimBuf, dims));
          var total = 1;
          for (var i = 0; i < dims; i++) {
            total *= dimBuf[i];
          }
          return total;
        } finally {
          calloc.free(dimBuf);
        }
      } finally {
        calloc.free(countPtr);
      }
    } finally {
      calloc.free(infoPtrPtr);
    }
  }
}

void _check(ffi.Pointer<bg.OrtStatus>? status) {
  if (status == null || status == ffi.nullptr) return;
  final api = OrtEnv.instance.ortApiPtr.ref;
  final msg = api.GetErrorMessage.asFunction<
          ffi.Pointer<ffi.Char> Function(ffi.Pointer<bg.OrtStatus>)>()(status)
      .cast<Utf8>()
      .toDartString();
  api.ReleaseStatus
      .asFunction<void Function(ffi.Pointer<bg.OrtStatus>)>()(status);
  throw OrtRawException(msg);
}

/// ORT C API 调用失败。
class OrtRawException implements Exception {
  OrtRawException(this.message);

  final String message;

  @override
  String toString() => 'OrtRawException: $message';
}
