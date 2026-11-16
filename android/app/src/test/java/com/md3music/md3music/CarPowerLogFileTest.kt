package com.md3music.md3music

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/**
 * [CarPowerLogFile] 纯核心（renderLine / appendToFile）的 JVM 单测。
 * 不依赖 Android：目录由测试注入临时目录。
 */
class CarPowerLogFileTest {

    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun renderLineFormatsWithTrailingNewline() {
        val line = CarPowerLogFile.renderLine("11-05 19:31:53.702", "hello")
        assertEquals("[11-05 19:31:53.702] hello\n", line)
    }

    @Test
    fun appendCreatesFileAndKeepsOrder() {
        val dir = tmp.newFolder("diagnostic_logs")
        CarPowerLogFile.appendToFile(dir, "one\n")
        CarPowerLogFile.appendToFile(dir, "two\n")
        val text = File(dir, "car_power.log").readText()
        assertEquals("one\ntwo\n", text)
    }

    @Test
    fun appendCreatesMissingDirectory() {
        val dir = File(tmp.root, "not/yet/created")
        CarPowerLogFile.appendToFile(dir, "x\n")
        assertTrue(File(dir, "car_power.log").exists())
    }

    @Test
    fun appendTruncatesWhenOverCap() {
        val dir = tmp.newFolder("big")
        val file = File(dir, "car_power.log")
        // 预置超过上限（64KB）的内容，尾部特征明显
        file.writeText("H".repeat(70 * 1024) + "TAIL_MARKER\n")
        CarPowerLogFile.appendToFile(dir, "new-line\n")
        val text = file.readText()
        assertTrue("滚动后必须保留最近的尾部证据", text.contains("TAIL_MARKER"))
        assertTrue(text.endsWith("new-line\n"))
        // 截半后 + 新行必然小于原文件 + 新行
        assertTrue(text.length < 70 * 1024 + 20)
    }
}
