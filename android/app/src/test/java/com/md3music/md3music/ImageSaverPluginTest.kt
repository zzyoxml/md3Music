package com.md3music.md3music

import org.junit.Assert.assertEquals
import org.junit.Test

/** 图片保存插件里两个纯函数：文件名净化与同名去重。 */
class ImageSaverPluginTest {

    @Test
    fun `净化掉路径分隔符与控制字符`() {
        assertEquals("a_b.jpg", ImageSaverPlugin.sanitizeFileName("a/b.jpg"))
        assertEquals("a_..b.png", ImageSaverPlugin.sanitizeFileName("a\\..b.png"))
        assertEquals("ab_c.jpg", ImageSaverPlugin.sanitizeFileName("ab\tc.jpg"))
    }

    @Test
    fun `首尾下划线点与空格被裁掉`() {
        assertEquals("photo.jpg", ImageSaverPlugin.sanitizeFileName(".._photo.jpg__"))
    }

    @Test
    fun `空名或全是非法字符回退为 image jpg`() {
        assertEquals("image.jpg", ImageSaverPlugin.sanitizeFileName(""))
        assertEquals("image.jpg", ImageSaverPlugin.sanitizeFileName("///"))
    }

    @Test
    fun `超长名截断但保留扩展名`() {
        val long = "x".repeat(200) + ".jpeg"
        val out = ImageSaverPlugin.sanitizeFileName(long)
        assertEquals(60, out.length)
        assertEquals(".jpeg", out.substring(out.lastIndexOf('.')))
    }

    @Test
    fun `同名时追加递增序号`() {
        val taken = mutableSetOf("a.jpg", "a-2.jpg", "a-3.jpg")
        assertEquals(
            "a-4.jpg",
            ImageSaverPlugin.dedupeFileName("a.jpg") { taken.contains(it) },
        )
    }

    @Test
    fun `无扩展名时也按整体名去重`() {
        val taken = mutableSetOf("a", "a-2")
        assertEquals("a-3", ImageSaverPlugin.dedupeFileName("a") { taken.contains(it) })
    }

    @Test
    fun `不同名原样返回`() {
        assertEquals("b.jpg", ImageSaverPlugin.dedupeFileName("b.jpg") { false })
    }
}
