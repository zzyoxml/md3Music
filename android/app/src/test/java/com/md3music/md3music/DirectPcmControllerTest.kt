package com.md3music.md3music

import com.ryanheise.just_audio.DirectPcmController
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「系统 Direct PCM」开关状态机（fork 侧 `DirectPcmController`）的单元测试。
 *
 * 覆盖的是**决定实际输出行为的那几个判定**（float 强制 / 低延迟 / unity 音量 / 效果链旁路），
 * 它们分别被 `DefaultAudioSink.floatOutputRequested()`、`createAudioTrackV29`、
 * 缓冲尺寸分支与 `OutputModeCoordinator` 读取；判定错误会直接导致 bit-perfect 失效
 * 或误伤 USB 独占，故在此钉住。
 *
 * 依赖 `android/app/build.gradle.kts` 的 `testOptions.unitTests.isReturnDefaultValues`，
 * 否则 `setEnabled` 内部的 `android.util.Log` 会在 JVM 测试里抛未 mock 异常。
 */
class DirectPcmControllerTest {

    private val allFeatureKeys = listOf(
        DirectPcmController.KEY_HIGH_PRECISION,
        DirectPcmController.KEY_DSP_BYPASS,
        DirectPcmController.KEY_UNITY_VOLUME,
        DirectPcmController.KEY_LOW_LATENCY,
        DirectPcmController.KEY_EXACT_ROUTE,
        DirectPcmController.KEY_NATIVE_RATE,
        DirectPcmController.KEY_RATE_ALIGNMENT,
    )

    @After
    fun tearDown() {
        // 静态状态：逐项复位，避免用例间串味
        DirectPcmController.setEnabled(false)
        allFeatureKeys.forEach { DirectPcmController.setFeature(it, false) }
    }

    @Test
    fun `默认全部子开关为关`() {
        allFeatureKeys.forEach { key ->
            assertFalse(key, DirectPcmController.isFeatureEnabled(key))
        }
        assertFalse(DirectPcmController.isEnabled())
    }

    @Test
    fun `子开关在总开关关闭时一律不生效`() {
        allFeatureKeys.forEach { DirectPcmController.setFeature(it, true) }
        // 总开关关着时，即使子开关全开，行为判定也必须全为 false
        assertFalse(DirectPcmController.isHighPrecisionOutputEnabled())
        assertFalse(DirectPcmController.isLowLatencyEnabled())
        assertFalse(DirectPcmController.isDspBypassEnabled())
        assertFalse(DirectPcmController.isUnityVolumeEnabled())
    }

    @Test
    fun `总开关打开后子开关按值生效`() {
        DirectPcmController.setFeature(DirectPcmController.KEY_HIGH_PRECISION, true)
        DirectPcmController.setFeature(DirectPcmController.KEY_LOW_LATENCY, true)
        DirectPcmController.setEnabled(true)

        assertTrue(DirectPcmController.isHighPrecisionOutputEnabled())
        assertTrue(DirectPcmController.isLowLatencyEnabled())
        // 未打开的两项仍为 false
        assertFalse(DirectPcmController.isDspBypassEnabled())
        assertFalse(DirectPcmController.isUnityVolumeEnabled())
    }

    @Test
    fun `未知子开关被忽略且不影响已知项`() {
        DirectPcmController.setFeature("settings_direct_pcm_not_exist", true)
        assertFalse(DirectPcmController.isFeatureEnabled("settings_direct_pcm_not_exist"))

        DirectPcmController.setFeature(DirectPcmController.KEY_HIGH_PRECISION, true)
        DirectPcmController.setEnabled(true)
        assertTrue(DirectPcmController.isHighPrecisionOutputEnabled())
    }

    @Test
    fun `状态快照包含全部子开关且总开关状态可读`() {
        DirectPcmController.setFeature(DirectPcmController.KEY_LOW_LATENCY, true)
        DirectPcmController.setEnabled(true)

        val status = DirectPcmController.getStatus()
        assertTrue(status["enabled"] as Boolean)

        // 状态里带出的 features 必须是全量键集（UI 逐项渲染依赖它），
        // 少一个键就会有一个子开关在设置页显示不出状态
        @Suppress("UNCHECKED_CAST")
        val features = status["features"] as Map<String, Boolean>
        allFeatureKeys.forEach { key ->
            assertTrue("状态缺少子开关 $key", features.containsKey(key))
        }
        assertTrue(features[DirectPcmController.KEY_LOW_LATENCY] == true)

        DirectPcmController.setEnabled(false)
        assertFalse(DirectPcmController.getStatus()["enabled"] as Boolean)
    }

    @Test
    fun `状态快照在无法确认原生率时明确标记为未知而非默认 bit perfect`() {
        DirectPcmController.setEnabled(true)
        val status = DirectPcmController.getStatus()
        // JVM 测试环境没有 AudioManager，原生率必然拿不到
        assertFalse("nativeRateKnown 必须为 false", status["nativeRateKnown"] as Boolean)
        assertFalse("拿不到原生率时不得声称 bit-perfect", status["bitPerfect"] as Boolean)
        assertTrue("必须给出原因", (status["bitPerfectReason"] as? String)?.isNotEmpty() == true)
    }
}
