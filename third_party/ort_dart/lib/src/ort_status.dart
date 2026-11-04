import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:ort_dart/src/bindings/onnxruntime_bindings_generated.dart'
    as bg;
import 'package:ort_dart/src/ort_env.dart';

/// Description of the ort status.
class OrtStatus {
  OrtStatus._();

  /// Check ort status.
  static void checkOrtStatus(bg.OrtStatusPtr? ptr) {
    if (ptr == null || ptr == ffi.nullptr) {
      return;
    }
    final errorMessage = OrtEnv.instance.ortApiPtr.ref.GetErrorMessage
        .asFunction<ffi.Pointer<ffi.Char> Function(bg.OrtStatusPtr)>()(ptr)
        .cast<Utf8>()
        .toDartString();
    final errorCode = OrtEnv.instance.ortApiPtr.ref.GetErrorCode
        .asFunction<int Function(bg.OrtStatusPtr)>()(ptr);
    final ortErrorCode = _OrtErrorCode.valueOf(errorCode);
    OrtEnv.instance.ortApiPtr.ref.ReleaseStatus
        .asFunction<void Function(bg.OrtStatusPtr)>()(ptr);
    if (ortErrorCode == _OrtErrorCode.ok) {
      return;
    }
    throw _OrtException(ortErrorCode, errorMessage);
  }
}

class _OrtException implements Exception {
  final String? message;
  final _OrtErrorCode code;

  const _OrtException([this.code = _OrtErrorCode.unknown, this.message]);

  @override
  String toString() {
    return 'code=${code.value}, message=$message';
  }
}

enum _OrtErrorCode {
  unknown(-1),
  ok(bg.OrtErrorCode.ORT_OK),
  fail(bg.OrtErrorCode.ORT_FAIL),
  invalidArgument(bg.OrtErrorCode.ORT_INVALID_ARGUMENT),
  noSuchFile(bg.OrtErrorCode.ORT_NO_SUCHFILE),
  noModel(bg.OrtErrorCode.ORT_NO_MODEL),
  engineError(bg.OrtErrorCode.ORT_ENGINE_ERROR),
  runtimeException(bg.OrtErrorCode.ORT_RUNTIME_EXCEPTION),
  invalidProtobuf(bg.OrtErrorCode.ORT_INVALID_PROTOBUF),
  modelLoaded(bg.OrtErrorCode.ORT_MODEL_LOADED),
  notImplemented(bg.OrtErrorCode.ORT_NOT_IMPLEMENTED),
  invalidGraph(bg.OrtErrorCode.ORT_INVALID_GRAPH),
  epFail(bg.OrtErrorCode.ORT_EP_FAIL);

  final int value;

  const _OrtErrorCode(this.value);

  static _OrtErrorCode valueOf(int type) {
    switch (type) {
      case bg.OrtErrorCode.ORT_OK:
        return ok;
      case bg.OrtErrorCode.ORT_FAIL:
        return fail;
      case bg.OrtErrorCode.ORT_INVALID_ARGUMENT:
        return invalidArgument;
      case bg.OrtErrorCode.ORT_NO_SUCHFILE:
        return noSuchFile;
      case bg.OrtErrorCode.ORT_NO_MODEL:
        return noModel;
      case bg.OrtErrorCode.ORT_ENGINE_ERROR:
        return engineError;
      case bg.OrtErrorCode.ORT_RUNTIME_EXCEPTION:
        return runtimeException;
      case bg.OrtErrorCode.ORT_INVALID_PROTOBUF:
        return invalidProtobuf;
      case bg.OrtErrorCode.ORT_MODEL_LOADED:
        return modelLoaded;
      case bg.OrtErrorCode.ORT_NOT_IMPLEMENTED:
        return notImplemented;
      case bg.OrtErrorCode.ORT_INVALID_GRAPH:
        return invalidGraph;
      case bg.OrtErrorCode.ORT_EP_FAIL:
        return epFail;
      default:
        return unknown;
    }
  }
}
