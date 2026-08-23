package com.md3music.md3music

import org.jaudiotagger.tag.images.AndroidArtwork
import java.io.File
import java.io.IOException

/**
 * 修复版 AndroidArtwork：覆写 setImageFromData() 使其不再抛出
 * UnsupportedOperationException（Android 缺少 javax.imageio.ImageIO）。
 *
 * FlacTag.createField() 的流程：
 *   1. 调用 artwork.setImageFromData() — 原版抛异常，本覆写返回 true
 *   2. 调用 artwork.getBinaryData() — 由 setFromFile() 已正确填充
 *   3. 构造 MetadataBlockDataPicture 写入 FLAC
 *
 * 用法：用 FixedAndroidArtwork.createFromFile(file)
 *       替代 ArtworkFactory.createArtworkFromFile(file)
 */
class FixedAndroidArtwork : AndroidArtwork() {

    /**
     * 覆写关键方法：原版调用 javax.imageio.ImageIO（Android 不存在），
     * 本实现直接返回 true，因为 setFromFile() 已经通过
     * RandomAccessFile 读取了文件字节到 binaryData。
     */
    override fun setImageFromData(): Boolean {
        return binaryData != null && binaryData.isNotEmpty()
    }

    companion object {
        /**
         * 从文件创建 FixedAndroidArtwork。
         * 内部调用 AndroidArtwork.setFromFile() 读取图片字节、
         * 检测 MIME 类型、设置 pictureType。
         */
        @Throws(IOException::class)
        fun createFromFile(file: File): FixedAndroidArtwork {
            val artwork = FixedAndroidArtwork()
            artwork.setFromFile(file)
            return artwork
        }
    }
}
