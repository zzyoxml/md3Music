package com.md3music.md3music

import android.os.Bundle
import androidx.media3.session.legacy.MediaBrowserCompat
import androidx.media3.session.legacy.MediaDescriptionCompat

/**
 * MD3Music fork v40：vivo 原子随身听（vivomusicmix）的三棵列表树。
 *
 * 协议事实（真机实测 + vivo 侧反编译口径，2026-10-24）：
 * - 岛（com.vivo.musicwidgetmix）先看 metadata 里的能力位
 *   `vivomusicmix.media.metadata.support_event`：不含列表位时岛把"播放列表"按钮置灰
 *   且**连请求都不发**；声明后经 MediaBrowserServiceCompat 绑定来取列表。
 * - 三个父节点：vivomusicmix_current_list / favorite_list / local_list
 *   （对应面板"播放列表 / 收藏列表 / 下载列表"三个 tab；实际数据分别是
 *   当前队列 / 云端收藏 / 本地音乐，第二个 tab 的标签是岛侧固定文案）。
 * - 分页：请求 options 带 `vivomusicmix_key_media_page`；返回项的 description
 *   extras 带 `vivomusicmix_key_has_more` 与 `vivomusicmix_key_media_page`（下一页）。
 * - 空列表必须回一条约定 media id（否则岛一直加载并报网络错误）。
 * - 列表项 media id：`<来源>:<songId>`（songId 为 Dart 侧 Song.id，稳定键——下标进
 *   id 会随队列插删整体漂移，v39 口径已废弃）；岛按 media id 回播，经
 *   MediaSessionLegacyStub 的 playFromMediaId 钩子转发回 Dart。
 *
 * 数据来自 Dart 主动推送；快照以单个不可变对象整体替换，避免三棵树撕裂。
 */
object VivoMixLibrary {

    /** 列表来源标记（同时是 media id 前缀）。 */
    const val SOURCE_CURRENT = "queue"
    const val SOURCE_FAVORITE = "fav"
    const val SOURCE_LOCAL = "local"

    /** 三个列表父节点（vivo 约定，不可改）。 */
    const val PARENT_CURRENT = "vivomusicmix_current_list"
    const val PARENT_FAVORITE = "vivomusicmix_favorite_list"
    const val PARENT_LOCAL = "vivomusicmix_local_list"

    /** 分页协议键。 */
    const val KEY_PAGE = "vivomusicmix_key_media_page"
    const val KEY_HAS_MORE = "vivomusicmix_key_has_more"

    /** 每页条数（参照实现口径 50）。 */
    const val PAGE_SIZE = 50

    /** 空列表约定的 media id：岛读到它即停止加载（否则一直转圈并报网络错误）。 */
    const val EMPTY_MEDIA_ID = "vivomusicmix:empty"

    /** 一条列表项。songId 为 Dart 侧 Song.id（稳定寻址键）。 */
    data class Item(
        val source: String,
        val songId: String,
        val title: String,
        val artist: String,
        val album: String?,
        val artworkUri: String?,
        val durationMs: Long,
    ) {
        /**
         * v41：当前播放树的 mediaId 用 `title|artist` 口径——与岛识别"正在播放"的
         * ID（hook 补进 framework MEDIA_ID 的身份，同 lrc_change meidia_id）一致，
         * 岛靠 mediaId 相等来高亮当前项。收藏/本地树保持 `<来源>:<songId>` 稳定
         * 寻址（它们不需要高亮）。
         */
        val mediaId: String get() =
            if (source == SOURCE_CURRENT) "$title|$artist" else "$source:$songId"
    }

    /** 三棵树的不可变快照（整体替换）。 */
    data class Snapshot(
        val current: List<Item>,
        val favorites: List<Item>,
        val local: List<Item>,
    )

    @Volatile
    private var snapshot: Snapshot = Snapshot(emptyList(), emptyList(), emptyList())

    /**
     * v48：列表内容变化通知回调（宿主 MSS 注入，onDestroy 按 identity 清理）。
     * 岛订阅三棵树后内容更新必须 notifyChildrenChanged，否则一直显示订阅时刻
     * 的旧列表（melodist 参考实现同款）。不可变快照整体替换，回调只报父节点 id。
     */
    @Volatile
    var childrenChangedNotifier: ((String) -> Unit)? = null

    /** Dart 推送到达时整体替换，并通知已订阅的岛端刷新。 */
    fun replace(currentItems: List<Item>, favoriteItems: List<Item>, localItems: List<Item>) {
        snapshot = Snapshot(currentItems, favoriteItems, localItems)
        val notifier = childrenChangedNotifier ?: return
        for (parent in listOf(PARENT_CURRENT, PARENT_FAVORITE, PARENT_LOCAL)) {
            try {
                notifier(parent)
            } catch (_: Exception) {
                // 通知失败不影响快照本身；岛端下次订阅自然拿到新内容。
            }
        }
    }

    fun currentList(): List<Item> = snapshot.current
    fun favoritesList(): List<Item> = snapshot.favorites
    fun localList(): List<Item> = snapshot.local

    /** 按 media id 反查（点播回放用）。 */
    fun find(mediaId: String?): Item? {
        if (mediaId.isNullOrEmpty()) return null
        val s = snapshot
        return s.current.firstOrNull { it.mediaId == mediaId }
            ?: s.favorites.firstOrNull { it.mediaId == mediaId }
            ?: s.local.firstOrNull { it.mediaId == mediaId }
    }

    private fun listOf(parentId: String?): List<Item>? =
        when (parentId) {
            PARENT_CURRENT -> snapshot.current
            PARENT_FAVORITE -> snapshot.favorites
            PARENT_LOCAL -> snapshot.local
            else -> null
        }

    /**
     * 构造一页 children。所有异常路径（未知父节点/越界/空树）一律回哨兵项，
     * 保证岛侧"停止加载"而不是转圈。
     */
    fun buildChildren(
        parentId: String?,
        options: Bundle?,
    ): List<MediaBrowserCompat.MediaItem> {
        val items = listOf(parentId)
        if (items == null || items.isEmpty()) return listOf(emptyItem())
        // 页号防御：岛端把页号写成 Long 时 getInt 会静默回默认值，这里按 Number 兜取；
        // 负数/溢出一律压回 0，from 用 Long 计算避免 page*PAGE_SIZE 溢出。
        val pageRaw = (options?.get(KEY_PAGE)) as? Number
        val page = (pageRaw?.toInt() ?: 0).coerceAtLeast(0)
        val from = page.toLong() * PAGE_SIZE
        if (from >= items.size) return listOf(emptyItem())
        val to = minOf(from + PAGE_SIZE, items.size.toLong()).toInt()
        val hasMore = to < items.size
        val out = ArrayList<MediaBrowserCompat.MediaItem>()
        for (i in from.toInt() until to) {
            val item = items[i]
            val extras = Bundle().apply {
                putBoolean(KEY_HAS_MORE, hasMore)
                putInt(KEY_PAGE, page + 1)
            }
            val description = MediaDescriptionCompat.Builder()
                .setMediaId(item.mediaId)
                .setTitle(item.title)
                .setSubtitle(item.artist)
                .setDescription(item.album)
                .setExtras(extras)
                .build()
            // FLAG_PLAYABLE：叶子必须可播，否则按 flags 判定可点性的浏览器会忽略该行。
            out.add(MediaBrowserCompat.MediaItem(description, MediaBrowserCompat.MediaItem.FLAG_PLAYABLE))
        }
        return out
    }

    /**
     * 空列表哨兵项。subtitle 必须给非空真实文案：未设置渲染成字面 "null"（v41
     * 真机实测"空null"；LastWave 同结论，他们对每项都 `subtitle ?: ""`），
     * 空串也渲染成"空"字（v46 真机实测"暂无歌曲"下显示"空"）。
     */
    private fun emptyItem(): MediaBrowserCompat.MediaItem {
        val extras = Bundle().apply {
            putBoolean(KEY_HAS_MORE, false)
            putInt(KEY_PAGE, 0)
        }
        val description = MediaDescriptionCompat.Builder()
            .setMediaId(EMPTY_MEDIA_ID)
            .setTitle("暂无歌曲")
            .setSubtitle("播放后自动同步")
            .setExtras(extras)
            .build()
        return MediaBrowserCompat.MediaItem(description, 0)
    }
}
