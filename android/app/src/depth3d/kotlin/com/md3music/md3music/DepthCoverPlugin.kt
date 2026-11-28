package com.md3music.md3music

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.FloatBuffer
import java.util.ArrayList
import java.util.HashSet
import java.util.concurrent.Executors

/**
 * Depth Anything V2 ViT-S 推理 + 封面三层切割（背景/中景/前景，带 alpha）。
 *
 * 通道名 "com.md3music.md3music/depth_cover"，方法：
 * - isModelLoaded() -> Boolean
 * - loadModel(modelPath) -> Boolean | error("LOAD_FAILED", ...)
 * - generate(sourcePath, sourceBytes?, outDir, key) -> {layers:[3 绝对路径]} | null(同 key 在途) | error(...)
 *
 * 输出文件固定为 layer0.png / layer1.png / layer2.png（与 Dart 侧 DepthCoverCache 约定一致）。
 */
object DepthCoverPlugin {
    private const val CHANNEL = "com.md3music.md3music/depth_cover"
    private const val TAG = "DepthCover"
    /**
     * 深度推理网格（同时作为背景修补掩码的分辨率）。
     *
     * 必须是 14 的倍数（ViT patch=14 对齐）。2026-09-26 由 518 降到 **378**：
     * 封面本身只有 400×400，518 属上采样、无信息增益却多约 1.7× 计算；实测
     * 378 在 Resize-Bilinear 回封面尺寸后与 518 的深度相关性 0.9945、分层 gather
     * 层一致性判据稳定（hit 99.9%），推理耗时 813ms → 377ms（**2.2×**）。
     * 代价：518 档的「脸召回」23.8%→11.0%（手掌几乎不变 63.0%→62.0%）——
     * 已由你确认接受。
     * 注意：尺寸与质量**非单调**（392 反而比 378 更差），改此值必须重跑
     * `tmp/stage1_input_size.py` 实测，禁止推断。
     */
    internal const val DEPTH_SIZE = 378

    /**
     * 背景修补掩码的膨胀半径（单位 = 深度网格像素，即 @DEPTH_SIZE）。
     *
     * 洞向外扩这么多像素，把主体过渡带（发丝 / 抗锯齿混合色）吞进洞里，
     * 让后续填充（push-pull / MI-GAN）的源只来自纯净背景；**半径越大轮廓残留越少**，
     * 代价是主体轮廓被多啃掉一圈（渲染时让出区显示修补背景的位置更靠内）。
     * 放回封面分辨率后约等于 `radius × 封面宽 / DEPTH_SIZE` 像素（400 封面 ≈ ×1.06）。
     * 2026-09-26：2 → 4（用户反馈前景边缘仍有残留未分离干净）。
     */
    private const val MASK_DILATE_RADIUS = 4
    // ImageNet 归一化常量（与 fabio-sim/Depth-Anything-ONNX infer.py 一致）
    private val MEAN = floatArrayOf(0.485f, 0.456f, 0.406f)
    private val STD = floatArrayOf(0.229f, 0.224f, 0.225f)
    // 深度带（0=远/背景, 1=近/前景），相邻带重叠 + 羽化避免硬边
    private val BANDS = arrayOf(
        floatArrayOf(0.00f, 0.40f), // layer0 背景
        floatArrayOf(0.35f, 0.70f), // layer1 中景
        floatArrayOf(0.65f, 1.00f), // layer2 前景
    )
    private const val FEATHER = 0.10f // 归一化羽化带宽

    // 模型以资产形式内置 APK（不再运行时下载）：首次 loadModel 时提取到应用目录
    private const val MODEL_ASSET = "models/depth_anything_v2_vits_q4f16.onnx"
    private const val MODEL_BYTES = 19126267L // 上游 q4f16 资产字节数，用于提取完整性校验

    // 神经修补（Phase B）：官方 MI-GAN-512-Places2 Pipeline ONNX（INT8 静态量化，
    // tmp/migan_quantize.py 产出；MIT License, Picsart AI Research）。
    // 签名：image [1,3,H,W] uint8 NCHW + mask [1,1,H,W] uint8 NCHW（255=known 0=hole），
    // 输出 [1,3,H,W] uint8（内部已 crop/resize/blending，支持任意分辨率输入）。
    // 注意：喂图必须 NCHW 平面布局、掩码必须二值，两者搞错都会出彩色噪声/镶边。
    private const val INPAINT_ASSET = "models/migan512_pipeline_int8.onnx"
    private const val INPAINT_BYTES = 10885440L // INT8 量化产物解压后字节数（提取完整性校验）

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var session: OrtSession? = null
    // 神经修补会话（懒加载，进程内一次；与 depth 会话共用 OrtEnvironment）
    private var inpaintSession: OrtSession? = null
    private var env: OrtEnvironment? = null
    private val inFlight = HashSet<String>()
    private var hostActivity: Activity? = null

    fun register(activity: Activity, messenger: BinaryMessenger) {
        hostActivity = activity
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isModelLoaded" -> result.success(session != null)
                "isInpaintModelLoaded" -> result.success(inpaintSession != null)
                "loadInpaintModel" -> {
                    // 神经修补会话：显式 modelPath（测试/调试）或自动从 APK 资产提取。
                    // 失败不阻塞主流程（Dart 侧 catch 后走纯 Phase A 行为）。
                    val explicitPath = call.argument<String>("modelPath")
                    executor.execute {
                        var extracted: File? = null
                        try {
                            val e = env ?: OrtEnvironment.getEnvironment().also { env = it }
                            val path = explicitPath
                                ?: extractInpaintAsset(hostActivity!!).also { extracted = File(it) }
                            inpaintSession?.close()
                            // NO_OPT 同 depth 会话：reduced-ops so 缺融合内核
                            inpaintSession = e.createSession(
                                File(path).readBytes(),
                                OrtSession.SessionOptions().apply {
                                    setIntraOpNumThreads(4)
                                    setOptimizationLevel(
                                        OrtSession.SessionOptions.OptLevel.NO_OPT,
                                    )
                                },
                            )
                            Log.d(TAG, "loadInpaintModel OK")
                            mainHandler.post { result.success(true) }
                        } catch (e: Exception) {
                            if (explicitPath == null) extracted?.delete()
                            Log.e(TAG, "loadInpaintModel FAILED", e)
                            mainHandler.post { result.error("LOAD_FAILED", e.message, null) }
                        }
                    }
                }
                "loadModel" -> {
                    // 优先用显式 modelPath（测试/调试）；缺省从 APK 资产提取到应用目录后加载
                    val explicitPath = call.argument<String>("modelPath")
                    val assetPath = call.argument<String>("modelAsset") ?: MODEL_ASSET
                    Log.d(TAG, "loadModel begin: explicit=$explicitPath asset=$assetPath")
                    executor.execute {
                        var extracted: File? = null
                        try {
                            env = OrtEnvironment.getEnvironment()
                            session?.close()
                            val path = explicitPath
                                ?: extractModelAsset(hostActivity!!, assetPath).also { extracted = File(it) }
                            session = env!!.createSession(
                                File(path).readBytes(),
                                OrtSession.SessionOptions().apply {
                                setIntraOpNumThreads(4)
                                // 关键：禁用运行时图优化。reduced-ops 裁剪的 so 只含
                                // 模型原始算子内核；若开启优化（默认 ALL），运行时融合会
                                // 生成 BiasGelu/FusedConv 等 contrib 节点 → Kernel not found。
                                // 代价：失去融合优化；换取裁剪确定性（缺内核类失败彻底消失），
                                // 且 fp16/fp32 两种导入模型（同图同算子）均可加载。
                                setOptimizationLevel(
                                    OrtSession.SessionOptions.OptLevel.NO_OPT,
                                )
                            },
                            )
                            Log.d(TAG, "loadModel OK")
                            mainHandler.post { result.success(true) }
                        } catch (e: Exception) {
                            // 提取产物损坏时删除半成品，允许下次重试
                            if (explicitPath == null) extracted?.delete()
                            Log.e(TAG, "loadModel FAILED", e)
                            mainHandler.post { result.error("LOAD_FAILED", e.message, null) }
                        }
                    }
                }
                "generate" -> {
                    val sourcePath = call.argument<String>("sourcePath")!!
                    val sourceBytes = call.argument<ByteArray>("sourceBytes")
                    val outDir = call.argument<String>("outDir")!!
                    val key = call.argument<String>("key")!!
                    val s = session
                    if (s == null) {
                        result.error("MODEL_NOT_LOADED", "call loadModel first", null)
                        return@setMethodCallHandler
                    }
                    // 单飞行守卫：记账语义为「已成功完成」；在途直接返回 null，失败路径会移除以便重试
                    if (!inFlight.add(key)) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            Log.d(TAG, "generate begin: key=$key src=$sourcePath exists=${File(sourcePath).exists()} outDir=$outDir")
                            val paths = generate(s, sourcePath, sourceBytes, outDir, key)
                            Log.d(TAG, "generate OK: $paths")
                            mainHandler.post { result.success(paths) }
                        } catch (e: Exception) {
                            Log.e(TAG, "generate FAILED", e)
                            mainHandler.post { result.error("GENERATE_FAILED", e.message, null) }
                        } finally {
                            inFlight.remove(key)
                        }
                    }
                }
                "generateDepth" -> {
                    val sourcePath = call.argument<String>("sourcePath")!!
                    val outDir = call.argument<String>("outDir")!!
                    val key = call.argument<String>("key")!!
                    val s = session
                    if (s == null) {
                        result.error("MODEL_NOT_LOADED", "call loadModel first", null)
                        return@setMethodCallHandler
                    }
                    if (!inFlight.add(key)) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        try {
                            Log.d(TAG, "generateDepth begin: key=$key src=$sourcePath")
                            val src = BitmapFactory.decodeFile(sourcePath)
                                ?: throw IllegalStateException("cannot decode cover")
                            val norm = normalize(infer(s, src))
                            val std = depthStd(norm)
                            // --- 背景修补（push-pull + 深度保边平滑）：洞区被填充，
                            // 供 shader 遮挡失配回退采样（消除轮廓拉伸伪影） ---
                            val w = src.width
                            val h = src.height
                            val inpaint = inpaintBackground(src, norm)
                            // --- 神经细化（Phase B，可选）：MI-GAN pipeline 会话就绪时
                            // 对洞区二次填充（结构化纹理），失败保底 push-pull 结果。
                            // 开关由 Dart 侧控制（未开启时不加载会话，直接跳过） ---
                            val usedNeural = inpaintSession?.let { s2 ->
                                val e2 = env ?: OrtEnvironment.getEnvironment()
                                neuralRefine(src, inpaint.mask518, inpaint.filled, w, h, s2, e2)
                            } == true
                            src.recycle()
                            val bgFill = Bitmap.createBitmap(inpaint.filled, w, h, Bitmap.Config.ARGB_8888)
                            val bgF = File(outDir).apply { mkdirs() }.let { File(it, "bg_fill.png") }
                            FileOutputStream(bgF).use { bgFill.compress(Bitmap.CompressFormat.PNG, 100, it) }
                            bgFill.recycle()
                            Log.d(TAG, "generateDepth bg_fill OK: ${bgF.absolutePath} inpaint=${if (usedNeural) "migan" else "pushpull"}")
                            // 灰度 8-bit PNG（ShengChao DepthEngine.swift:111-132 同构）：
                            // 用 ARGB 位图承载灰度（R=G=B=gray, A=255），避免 ALPHA_8 无法 compress
                            val size = DEPTH_SIZE
                            val pixels = IntArray(size * size)
                            for (i in pixels.indices) {
                                val g = (norm[i] * 255f).toInt().coerceIn(0, 255)
                                pixels[i] = 0xFF000000.toInt() or (g shl 16) or (g shl 8) or g
                            }
                            val gray = Bitmap.createBitmap(pixels, size, size, Bitmap.Config.ARGB_8888)
                            val out = File(outDir).apply { mkdirs() }
                            val f = File(out, "depth.png")
                            FileOutputStream(f).use { gray.compress(Bitmap.CompressFormat.PNG, 100, it) }
                            gray.recycle()
                            Log.d(TAG, "generateDepth OK: ${f.absolutePath} std=$std")
                            mainHandler.post {
                                result.success(
                                    mapOf(
                                        "depth" to f.absolutePath,
                                        "depthStd" to std,
                                        "bgFill" to bgF.absolutePath,
                                        "inpaint" to if (usedNeural) "migan" else "pushpull",
                                    ),
                                )
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "generateDepth FAILED", e)
                            mainHandler.post { result.error("GENERATE_FAILED", e.message, null) }
                        } finally {
                            inFlight.remove(key)
                        }
                    }
                }
                // 原生 Toast：3D 封面降级提示（Dart 侧无法可靠弹出系统 toast）
                "showToast" -> {
                    val msg = call.argument<String>("message") ?: ""
                    mainHandler.post {
                        try {
                            Toast.makeText(hostActivity, msg, Toast.LENGTH_LONG).show()
                        } catch (t: Throwable) {
                            Log.w(TAG, "showToast failed: $t")
                        }
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 从 APK 资产提取模型到应用目录（`files/depth_model/<文件名>`）。
     * 已存在且字节数匹配则直接复用；提取先写 .part 再 rename（原子落盘），
     * 大小不符视为损坏并抛错（调用方负责删除半成品以便重试）。
     */
    private fun extractModelAsset(activity: Activity, assetPath: String): String {
        val target = File(activity.filesDir, "depth_model/${assetPath.substringAfterLast('/')}")
        if (target.exists() && target.length() == MODEL_BYTES) {
            return target.absolutePath
        }
        // 关键：全新安装时 files/depth_model/ 目录不存在，直接写 .part 会抛
        // FileNotFoundException(ENOENT)，导致内置模型提取永久失败（3D 封面无法触发）。
        // 必须与下方 generate/generateDepth 的输出目录处理保持一致。
        val parent = target.parentFile
        if (parent != null && !parent.exists() && !parent.mkdirs()) {
            throw IllegalStateException("mkdirs failed: ${parent.absolutePath}")
        }
        val part = File(target.parentFile, "${target.name}.part")
        activity.assets.open(assetPath).use { input ->
            FileOutputStream(part).use { output -> input.copyTo(output, 1 shl 20) }
        }
        if (part.length() != MODEL_BYTES) {
            val actual = part.length()
            part.delete()
            throw IllegalStateException("asset extract size mismatch: expect=$MODEL_BYTES actual=$actual")
        }
        if (target.exists()) target.delete()
        if (!part.renameTo(target)) {
            throw IllegalStateException("rename failed: ${part.absolutePath}")
        }
        Log.d(TAG, "extractModelAsset OK: ${target.absolutePath}")
        return target.absolutePath
    }

    /** 神经修补模型资产提取（与 [extractModelAsset] 同构：.part + 大小校验 + 原子 rename）。 */
    private fun extractInpaintAsset(activity: Activity): String {
        val target = File(activity.filesDir, "depth_model/${INPAINT_ASSET.substringAfterLast('/')}")
        if (target.exists() && target.length() == INPAINT_BYTES) {
            return target.absolutePath
        }
        val parent = target.parentFile
        if (parent != null && !parent.exists() && !parent.mkdirs()) {
            throw IllegalStateException("mkdirs failed: ${parent.absolutePath}")
        }
        val part = File(target.parentFile, "${target.name}.part")
        activity.assets.open(INPAINT_ASSET).use { input ->
            FileOutputStream(part).use { output -> input.copyTo(output, 1 shl 20) }
        }
        if (part.length() != INPAINT_BYTES) {
            val actual = part.length()
            part.delete()
            throw IllegalStateException("inpaint asset size mismatch: expect=$INPAINT_BYTES actual=$actual")
        }
        if (target.exists()) target.delete()
        if (!part.renameTo(target)) {
            throw IllegalStateException("rename failed: ${part.absolutePath}")
        }
        Log.d(TAG, "extractInpaintAsset OK: ${target.absolutePath}")
        return target.absolutePath
    }

    private fun generate(
        session: OrtSession,
        sourcePath: String,
        sourceBytes: ByteArray?,
        outDir: String,
        key: String,
    ): Map<String, Any> {
        val src = BitmapFactory.decodeFile(sourcePath)
            ?: (if (sourceBytes != null) BitmapFactory.decodeByteArray(sourceBytes, 0, sourceBytes.size) else null)
            ?: throw IllegalStateException("cannot decode cover")
        val out = File(outDir).apply { mkdirs() }

        // 1) 推理 + min-max 归一化到 0..1（值越大越近）
        val norm = normalize(infer(session, src))

        // 2) 背景修补：layer0 从修补像素切割（主体被抠走处已填充，不再有透明洞）
        val result = inpaintBackground(src, norm)
        val bgBitmap = Bitmap.createBitmap(
            result.filled,
            src.width,
            src.height,
            Bitmap.Config.ARGB_8888,
        )

        // 3) 深度带切割：layer0=远(背景) layer2=近(前景)，平滑羽化避免硬边
        val paths = ArrayList<String>(3)
        for ((li, band) in BANDS.withIndex()) {
            val layer = splitLayer(if (li == 0) bgBitmap else src, norm, band[0], band[1])
            val f = File(out, "layer$li.png") // 修正：固定文件名 layer{i}.png
            FileOutputStream(f).use { layer.compress(Bitmap.CompressFormat.PNG, 100, it) }
            paths.add(f.absolutePath)
            layer.recycle()
        }
        bgBitmap.recycle()
        src.recycle()
        return mapOf("layers" to paths)
    }

    /** 修补结果：filled=原图分辨率修补像素；mask518=膨胀后的前景掩码（1=洞，供神经细化复用）。 */
    private data class InpaintResult(val filled: IntArray, val mask518: FloatArray)

    /**
     * 背景修补管线（generate/generateDepth 共用）：
     * 原图灰度引导的 joint bilateral 深度平滑 → 前景掩码（膨胀 + 双线性放大到
     * 原图分辨率）→ push-pull 金字塔填充。
     */
    private fun inpaintBackground(src: Bitmap, norm: FloatArray): InpaintResult {
        // 引导图：原图灰度下采样到深度网格（亮度差约束滤波权重，主体边缘不跨边模糊）
        val guide = FloatArray(DEPTH_SIZE * DEPTH_SIZE)
        val small = Bitmap.createScaledBitmap(src, DEPTH_SIZE, DEPTH_SIZE, true)
        val sPix = IntArray(DEPTH_SIZE * DEPTH_SIZE)
        small.getPixels(sPix, 0, DEPTH_SIZE, 0, 0, DEPTH_SIZE, DEPTH_SIZE)
        small.recycle()
        for (i in sPix.indices) {
            val p = sPix[i]
            guide[i] = (0.299f * ((p shr 16) and 0xFF) +
                0.587f * ((p shr 8) and 0xFF) +
                0.114f * (p and 0xFF)) / 255f
        }
        val smoothDepth = InpaintTools.jointBilateralSmooth(norm, guide)
        val w = src.width
        val h = src.height
        val srcPix = IntArray(w * h)
        src.getPixels(srcPix, 0, w, 0, 0, w, h)
        // 掩码膨胀：洞向外扩 MASK_DILATE_RADIUS 像素（@DEPTH_SIZE 网格），把主体过渡带
        // （发丝/抗锯齿混合色）吞进洞里，填充源只来自纯净背景——消除轮廓污染环
        val mask518 = InpaintTools.dilateHole(InpaintTools.fgMask(smoothDepth), radius = MASK_DILATE_RADIUS)
        val maskFull = FloatArray(w * h)
        // 双线性放大（替代最近邻，消除掩码锯齿边）
        for (y in 0 until h) {
            val fy = (y + 0.5f) * DEPTH_SIZE / h - 0.5f
            for (x in 0 until w) {
                val fx = (x + 0.5f) * DEPTH_SIZE / w - 0.5f
                maskFull[y * w + x] = sampleMaskBilinear(mask518, fx, fy)
            }
        }
        return InpaintResult(PullPushFiller.fill(srcPix, w, h, maskFull), mask518)
    }

    /**
     * 神经细化（Phase B）：官方 MI-GAN Pipeline（内部自带 mask 周围 crop / 512
     * 缩放 / 归一化 / blending），Kotlin 只喂 uint8 NCHW 原图 + uint8 掩码，
     * 输出与输入同分辨率且非洞区像素与原图完全一致（桌面验证洞外差异=0），
     * 故直接整体覆盖 filled。
     * 返回 true=已覆盖；任何异常=false（保底 push-pull 结果）。
     * 注意：pipeline 掩码协议 255=known、0=hole，与 fgMask 相反，此处已反转。
     */
    private fun neuralRefine(
        src: Bitmap,
        mask518: FloatArray,
        filled: IntArray,
        w: Int,
        h: Int,
        session: OrtSession,
        env: OrtEnvironment,
    ): Boolean {
        return try {
            // 1) 膨胀掩码 → 反转 → uint8（双线性上采样与 push-pull 同一几何）。
            //    ⚠ 官方要求掩码必须是二值（"must be binary"）：连续值会让 pipeline
            //    的 crop/blending 逻辑在过渡带产生彩色镶边（桌面实测边界带误差
            //    二值 11.98 → 软边 60.45，彩度偏差 3.77 → 10.39），故此处硬阈值化。
            val maskU8 = ByteArray(w * h)
            for (y in 0 until h) {
                val fy = (y + 0.5f) * DEPTH_SIZE / h - 0.5f
                for (x in 0 until w) {
                    val fx = (x + 0.5f) * DEPTH_SIZE / w - 0.5f
                    val hole = sampleMaskBilinear(mask518, fx, fy)
                    maskU8[y * w + x] = if (hole >= 0.5f) 0.toByte() else 255.toByte()
                }
            }
            // 2) 原图 uint8 RGB —— 必须按 NCHW 平面布局（R 平面→G 平面→B 平面），
            //    与签名 [1,3,H,W] 一致。此前误用 packed RGB（交错）导致整个洞区
            //    输出为色块噪声（设备 bg_fill 取证确认），桌面验证用 transpose(2,0,1)
            //    所以未暴露。
            val rgb = ByteArray(w * h * 3)
            val pix = IntArray(w * h)
            src.getPixels(pix, 0, w, 0, 0, w, h)
            val plane = w * h
            for (i in pix.indices) {
                val p = pix[i]
                rgb[i] = ((p shr 16) and 0xFF).toByte()              // R 平面
                rgb[plane + i] = ((p shr 8) and 0xFF).toByte()       // G 平面
                rgb[2 * plane + i] = (p and 0xFF).toByte()           // B 平面
            }
            // 3) 按张量维度识别 image/mask 输入名（image: dim1==3；mask: dim1==1）
            var imgName: String? = null
            var mskName: String? = null
            for ((name, info) in session.inputInfo) {
                val ti = info.info as? ai.onnxruntime.TensorInfo ?: continue
                val dims = ti.shape ?: continue
                if (dims.size >= 2 && dims[1] == 3L) imgName = name else mskName = name
            }
            if (imgName == null || mskName == null) {
                throw IllegalStateException("unexpected inpaint model inputs")
            }
            // 4) 推理（uint8 NCHW）
            OnnxTensor.createTensor(
                env,
                java.nio.ByteBuffer.wrap(rgb),
                longArrayOf(1, 3, h.toLong(), w.toLong()),
                ai.onnxruntime.OnnxJavaType.UINT8,
            ).use { ti ->
                OnnxTensor.createTensor(
                    env,
                    java.nio.ByteBuffer.wrap(maskU8),
                    longArrayOf(1, 1, h.toLong(), w.toLong()),
                    ai.onnxruntime.OnnxJavaType.UINT8,
                ).use { tm ->
                    session.run(mapOf(imgName to ti, mskName to tm)).use { out ->
                        val t = out[0] as OnnxTensor
                        val bb = t.byteBuffer
                            ?: throw IllegalStateException("no byte buffer on output")
                        // 输出 [1,3,H,W] uint8（NCHW）；非洞区与原图一致，直接覆盖
                        for (i in 0 until w * h) {
                            val r = bb.get(i).toInt() and 0xFF
                            val g = bb.get(w * h + i).toInt() and 0xFF
                            val b = bb.get(2 * w * h + i).toInt() and 0xFF
                            filled[i] = 0xFF000000.toInt() or (r shl 16) or (g shl 8) or b
                        }
                    }
                }
            }
            Log.d(TAG, "neuralRefine OK (migan)")
            true
        } catch (e: Exception) {
            Log.w(TAG, "neuralRefine failed, keep push-pull result", e)
            false
        }
    }

    /** 518 网格掩码的双线性采样（半像素中心对齐）。 */
    private fun sampleMaskBilinear(mask: FloatArray, fx: Float, fy: Float): Float {
        val x0 = fx.toInt().coerceIn(0, DEPTH_SIZE - 1)
        val y0 = fy.toInt().coerceIn(0, DEPTH_SIZE - 1)
        val x1 = (x0 + 1).coerceAtMost(DEPTH_SIZE - 1)
        val y1 = (y0 + 1).coerceAtMost(DEPTH_SIZE - 1)
        val tx = (fx - x0).coerceIn(0f, 1f)
        val ty = (fy - y0).coerceIn(0f, 1f)
        val a = mask[y0 * DEPTH_SIZE + x0] * (1 - tx) + mask[y0 * DEPTH_SIZE + x1] * tx
        val b = mask[y1 * DEPTH_SIZE + x0] * (1 - tx) + mask[y1 * DEPTH_SIZE + x1] * tx
        return a * (1 - ty) + b * ty
    }

    /** min-max 归一化到 0..1（值越大越近）。 */
    private fun normalize(depth: FloatArray): FloatArray {
        var min = Float.MAX_VALUE
        var max = -Float.MAX_VALUE
        for (v in depth) {
            if (v < min) min = v
            if (v > max) max = v
        }
        val range = (max - min).coerceAtLeast(1e-6f)
        return FloatArray(depth.size) { (depth[it] - min) / range }
    }

    /** 深度图标准差（stride 采样，ShengChao computeDepthStd 同款）。 */
    private fun depthStd(norm: FloatArray): Float {
        var sum = 0f
        var sumSq = 0f
        var n = 0f
        var i = 0
        while (i < norm.size) {
            val v = norm[i]
            sum += v
            sumSq += v * v
            n += 1f
            i += 4
        }
        if (n == 0f) return 0.18f
        val mean = sum / n
        val variance = (sumSq / n - mean * mean).coerceAtLeast(0f)
        return kotlin.math.sqrt(variance)
    }

    /**
     * 深度在 [lo,hi] 带内的像素保留，带外按 [FEATHER] 线性羽化为透明。
     * 输出保持封面原分辨率；norm 为推理分辨率(DEPTH_SIZE x DEPTH_SIZE)的摊平结果，
     * 按 (x,y) 遍历 src 时把坐标最近邻映射回深度网格取深度。
     */
    private fun splitLayer(src: Bitmap, norm: FloatArray, lo: Float, hi: Float): Bitmap {
        val w = src.width
        val h = src.height
        val pixels = IntArray(w * h)
        src.getPixels(pixels, 0, w, 0, 0, w, h)
        for (y in 0 until h) {
            for (x in 0 until w) {
                val i = y * w + x
                val dx = (x * DEPTH_SIZE / w).coerceAtMost(DEPTH_SIZE - 1)
                val dy = (y * DEPTH_SIZE / h).coerceAtMost(DEPTH_SIZE - 1)
                val d = norm[dy * DEPTH_SIZE + dx]
                val a = when {
                    d < lo - FEATHER || d > hi + FEATHER -> 0f
                    d < lo -> (d - (lo - FEATHER)) / FEATHER
                    d > hi -> ((hi + FEATHER) - d) / FEATHER
                    else -> 1f
                }
                if (a <= 0f) {
                    pixels[i] = Color.TRANSPARENT
                } else if (a < 1f) {
                    pixels[i] = (pixels[i] and 0x00FFFFFF) or ((a * 255f).toInt() shl 24)
                }
            }
        }
        return Bitmap.createBitmap(pixels, w, h, Bitmap.Config.ARGB_8888)
    }

    private fun infer(session: OrtSession, src: Bitmap): FloatArray {
        val scaled = Bitmap.createScaledBitmap(src, DEPTH_SIZE, DEPTH_SIZE, true)
        try {
            val pixels = IntArray(DEPTH_SIZE * DEPTH_SIZE)
            scaled.getPixels(pixels, 0, DEPTH_SIZE, 0, 0, DEPTH_SIZE, DEPTH_SIZE)
            // NCHW float 输入
            val data = FloatArray(3 * DEPTH_SIZE * DEPTH_SIZE)
            for (c in 0..2) {
                val plane = c * DEPTH_SIZE * DEPTH_SIZE
                for (i in pixels.indices) {
                    val px = pixels[i]
                    val v = when (c) {
                        0 -> (px shr 16 and 0xFF) / 255f
                        1 -> (px shr 8 and 0xFF) / 255f
                        else -> (px and 0xFF) / 255f
                    }
                    data[plane + i] = (v - MEAN[c]) / STD[c]
                }
            }
            val shape = longArrayOf(1, 3, DEPTH_SIZE.toLong(), DEPTH_SIZE.toLong())
            val e = env ?: OrtEnvironment.getEnvironment().also { env = it }
            val inputName = session.inputNames.first() // 运行时取输入名
            OnnxTensor.createTensor(e, FloatBuffer.wrap(data), shape).use { tensor ->
                session.run(mapOf(inputName to tensor)).use { out ->
                    val outTensor = out[0] as OnnxTensor
                    // 运行时读取真实输出形状，数据摊平为 FloatArray（兼容 (1,1,H,W) 与 (1,H,W)）
                    val realShape = outTensor.info.shape
                    Log.d("DepthCover", "output shape=${realShape.contentToString()}")
                    val fb = outTensor.floatBuffer
                    val flat = FloatArray(fb.remaining())
                    fb.get(flat)
                    return flat
                }
            }
            throw IllegalStateException("unreachable")
        } finally {
            scaled.recycle()
        }
    }
}
