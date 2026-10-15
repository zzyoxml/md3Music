# 裁剪版 ONNX Runtime 的重建流程（depth3d flavor 专用）

`android/app/libs/onnxruntime-android-1.30.0-custom-v8a.aar` 是**自编裁剪版**：
用 `--include_ops_by_config` 只编译两份深度模型实际需要的算子内核，把官方 33MB 的
`libonnxruntime.so` 压到 **13.2MB**（-60%）。AAR 已入库，日常构建不需要重建；
**只有在「模型变了」或「运行时又报某个算子找不到实现」时才需要按下文重编。**

| 项 | 值 |
|---|---|
| 目标 ABI | `arm64-v8a`（depth3d flavor 只出该 ABI） |
| 入库 so | `jni/arm64-v8a/libonnxruntime.so` = 13,201,664 B，md5 `7c21e6fbb6e9680fbc1d5e950c83c4db` |
| 保留不动 | `jni/arm64-v8a/libonnxruntime4j_jni.so` = 111,648 B，md5 `a93742b352152a09a41b21e895f81abf`（官方 JNI 绑定层） |
| 算子配置 | `android/app/libs/ort-ops/depth_migan_union_v3.config`（本目录） |

---

## 0. 为什么是「None 优化 + 原图算子」

Kotlin 侧两个会话都用 **`NO_OPT`**（`DepthCoverPlugin.kt`，用 reduced-ops so 时融合内核不存在）。
因此 PR 里跑的图是**原始 .onnx 图**，配置必须覆盖**原图**的算子集合。

而 ORT 自带的 `convert_onnx_models_to_ort` 产出的 `*.required_operators.config`
是从**优化后的 `.ort`** 推导的 —— 凡被优化器常量折叠掉的算子（原图有、优化图无）
都不会出现在配置里 → 运行时缺内核。实测 `ConstantOfShape` 在原始 migan 图出现 64 处、
优化后仅 13 处，首版配置里完全没有它。

## 1. 查找规则（最容易错的一点）

ORT `KernelRegistry` 用节点的 **SinceVersion**（算子自身版本）查找，取
「**≤ SinceVersion 的最高已注册版本**」。所以：

* **注册版本必须 ≤ 节点 SinceVersion**；
* 绝不能拿**模型的 `opset_import`** 当注册版本（migan 的 opset=17，但
  `ConstantOfShape` 节点 SinceVersion 只有 9，注册成 17 等于没注册）；
* 同一算子的多个版本必须**逐行保留**，不能合并成 `max()`。

报错文本里的数字就是 SinceVersion：
`Could not find an implementation for ConstantOfShape(9)` → 该节点 SinceVersion = 9。

## 2. 生成 / 校验算子配置

```bash
python scripts/tools/ort/gen_ops_config.py            # 只校验（对默认两份模型）
python scripts/tools/ort/gen_ops_config.py --write    # 重新生成 depth_migan_union_v3.config
```

脚本依赖 `onnx`（`pip install onnx`）。判定标准：输出 `[OK] 全部节点的 SinceVersion 都能匹配到已注册版本`。

覆盖面（v3，52 项注册）：

```
ai.onnx;1;SimplifiedLayerNormalization
ai.onnx;9;ConstantOfShape,Where
ai.onnx;11;Conv,ConvTranspose,Range,Round
ai.onnx;12;MaxPool
ai.onnx;13;Cast,Clip,Concat,Constant,DequantizeLinear,Equal,Erf,Exp,Expand,Gather,GatherND,
           Less,MatMul,NonZero,Pad,Pow,QuantizeLinear,ReduceMax,ReduceMean,ReduceMin,
           ReduceSum,Resize,Shape,Slice,Softmax,Split,Sqrt,Squeeze,Transpose,Unsqueeze
ai.onnx;14;Add,Div,Mul,Relu,Reshape,Sub
ai.onnx;15;Shape
ai.onnx;16;Identity,LeakyRelu,ScatterND,Where
com.microsoft;1;FusedConv,MatMulNBits,QLinearConv
```

## 3. 交叉编译 so

在 ORT 源码树（本机为 `E:\ort-build\onnxruntime`，对应 onnxruntime 1.30.0）执行：

```bash
<E:/ort-build>/venv/Scripts/python.exe onnxruntime/tools/ci_build/build.py \
  --android --android_abi=arm64-v8a --android_api=24 \
  --android_ndk_path C:/Android/Sdk/ndk/28.2.13676358 \
  --cmake_generator Ninja \
  --cmake_path <E:/ort-build>/venv/Scripts/cmake.exe \
  --ctest_path <E:/ort-build>/venv/Scripts/ctest.exe \
  --cmake_extra_defines CMAKE_MAKE_PROGRAM=<E:/ort-build>/venv/Scripts/ninja.exe \
  --build_dir <E:/ort-build/buildN> --config MinSizeRel \
  --build_shared_lib --skip_tests --compile_no_warning_as_error --enable_lto \
  --disable_ml_ops --use_nnapi --parallel 8 \
  --include_ops_by_config android/app/libs/ort-ops/depth_migan_union_v3.config
```

要点：

* Windows 原生构建，**必须显式给出** `--cmake_path / --ctest_path / CMAKE_MAKE_PROGRAM / --android_ndk_path`
  （build.py 自己找工具会失败）；NDK **不要**用 29.x；
* 约 25–27 分钟；产物 `<build_dir>/MinSizeRel/libonnxruntime.so`；
* 构建日志里的 `onnxruntime_REDUCED_OPS_BUILD=ON` + `MINIMAL_BUILD=OFF` 说明确实走了
  「按 config 裁剪内核注册表」这条路（可据此确认配置生效）。

## 4. 替换进 AAR

```bash
python scripts/tools/ort/repack_aar.py <build_dir>/MinSizeRel/libonnxruntime.so
```

脚本保留其余 entry 的原始 ZipInfo，只换目标 so，并在结束时回读校验 md5。

> ⚠️ **不要**用「`strings libonnxruntime.so | grep 算子名`判断内核是否被注册**：
> `MINIMAL_BUILD=OFF` 下算子 **schema 名始终编译在内**，被裁掉的只是 **kernel 注册表**。
> 新旧 so 的字符串差分同样无效（LTO 已把算子名去重，计数恒为 1）。
> **唯一权威判据是真机 `createSession`**，即日志里的 `loadInpaintModel OK`。

## 5. 验证

```bash
flutter build apk --debug --flavor depth3d --dart-define=ENABLE_DEPTH_3D=true \
  --split-per-abi --target-platform android-arm64 -t lib/private/main_private.dart
adb push build/app/outputs/flutter-apk/app-arm64-v8a-depth3d-debug.apk /data/local/tmp/x.apk
adb shell pm install -r /data/local/tmp/x.apk
adb logcat -c && adb shell monkey -p com.md3music.md3music -c android.intent.category.LAUNCHER 1
# 进播放页触发一次深度生成后核对：
adb logcat -d | grep -E "DepthCover|inpaint="
```

通过标准：

```
D DepthCover: loadInpaintModel OK                    ← 会话创建成功（缺算子会在此失败）
D DepthCover: neuralRefine OK (migan)
D DepthCover: generateDepth bg_fill OK: ... inpaint=migan   ← 不是 pushpull
```

失败会明确报出缺失算子与其 SinceVersion，据此回到第 2 步把该
`(domain, SinceVersion, Op)` 补进配置（并确认注册版本 ≤ 该 SinceVersion）。
