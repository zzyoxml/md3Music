package com.md3music.md3music

import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.media3.session.legacy.MediaBrowserCompat
import androidx.media3.session.legacy.MediaBrowserServiceCompat
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * 车机/第三方桥接 legacy 搜索（MediaBrowserCompat.search）的进程级登记表。
 *
 * 两件事：
 * 1. **待结算的搜索回调**：legacy `Result` 允许 `detach()` 后异步 `sendResult()`，
 *    但只能结算一次（二次调用抛 IllegalStateException）。这里用一次性的
 *    [Pending.settle] 收口，并挂 8s 超时兜底——搜索要经 Dart→本地 Rust 服务往返，
 *    超时若不兜底，桥接端会永久等不到回调。
 * 2. **候选条目的 payload**：搜索结果的 `MediaItem.mediaId` 用不透明序号
 *    `md3srch:<n>` 表示，真正的 hash/albumId/albumAudioId 存在这里，供桥接端后续
 *    `playFromMediaId` 回播。用 LRU + TTL 限制常驻内存，不做持久化（进程重启后
 *    桥接端应重新搜索，届时本条目的 mediaId 会被当作失效处理）。
 *
 * 全部成员为进程级静态：会话宿主服务可能被销毁重建，但桥接端手里的 mediaId 与
 * 尚未结算的 Result 都不能丢（与 `MediaSessionService.playFromMediaIdHook` 常驻
 * 同一口径）。
 */
object BrowseSearchRegistry {

    private const val TAG = "BrowseSearch"

    /** 搜索往返超时（Dart 搜索 + 本地 Rust 服务冷启动）。 */
    private const val TIMEOUT_MS = 8_000L

    /** 候选条目上限 / 存活时间：只承载"刚搜完点一下"的场景。 */
    private const val MAX_ENTRIES = 200
    private const val ENTRY_TTL_MS = 10 * 60 * 1000L

    /** 候选条目 mediaId 前缀（不透明，桥接端只应原样回传）。 */
    const val MEDIA_ID_PREFIX = "md3srch:"

    private val nextRequestSeq = AtomicLong()
    private val nextEntrySeq = AtomicLong()
    private val mainHandler = Handler(Looper.getMainLooper())

    private val pending = ConcurrentHashMap<String, Pending>()
    private val entries = LinkedHashMap<String, Entry>(64, 0.75f, true)

    private class Entry(val payload: Map<String, Any?>, val createdAt: Long)

    /** 一次搜索请求的回调持有者：保证 `Result` 只被结算一次。 */
    private class Pending(
        val requestId: String,
        val result: MediaBrowserServiceCompat.Result<List<MediaBrowserCompat.MediaItem>>,
    ) {
        private val settled = AtomicBoolean(false)

        fun settle(items: List<MediaBrowserCompat.MediaItem>) {
            if (!settled.compareAndSet(false, true)) return
            try {
                result.sendResult(items)
            } catch (t: Throwable) {
                // 桥接端可能已断开（binder 死亡），此时 sendResult 会抛。
                Log.w(TAG, "sendSearchResult failed for $requestId", t)
            }
        }
    }

    /** 新搜索请求 id（仅进程内唯一，不需要全局唯一）。 */
    fun newRequestId(): String = "s" + nextRequestSeq.incrementAndGet()

    /**
     * 登记一次待结算的搜索并**同步 detach**：调用方（SearchProvider 实现）必须在
     * 返回前完成 detach 或 sendResult，否则基类 performSearch 会抛
     * IllegalStateException。
     */
    fun register(
        requestId: String,
        result: MediaBrowserServiceCompat.Result<List<MediaBrowserCompat.MediaItem>>,
    ) {
        val holder = Pending(requestId, result)
        pending[requestId] = holder
        try {
            result.detach()
        } catch (t: Throwable) {
            // detach 失败说明已被结算（理论上不会走到），摘掉并放弃本次请求。
            pending.remove(requestId)
            Log.w(TAG, "detach failed for $requestId", t)
            return
        }
        mainHandler.postDelayed({
            if (pending.remove(requestId) != null) {
                Log.w(TAG, "search timeout: $requestId")
                holder.settle(emptyList())
            }
        }, TIMEOUT_MS)
    }

    /** 收到 Dart 侧结果后结算；未知 requestId（已超时）静默丢弃。 */
    fun settle(requestId: String, items: List<MediaBrowserCompat.MediaItem>) {
        val holder = pending.remove(requestId) ?: run {
            Log.w(TAG, "settle for unknown request: $requestId")
            return
        }
        holder.settle(items)
    }

    /** 失败路径：与超时同义，回空列表（不能回 null，会被转成 RESULT_ERROR）。 */
    fun settleEmpty(requestId: String) = settle(requestId, emptyList())

    /** 为一条搜索结果分配不透明 mediaId，并登记回播 payload。 */
    fun putPayload(payload: Map<String, Any?>): String {
        val mediaId = MEDIA_ID_PREFIX + nextEntrySeq.incrementAndGet()
        synchronized(entries) {
            val now = System.currentTimeMillis()
            entries.entries.removeAll { now - it.value.createdAt > ENTRY_TTL_MS }
            entries[mediaId] = Entry(payload, now)
            while (entries.size > MAX_ENTRIES) {
                val oldest = entries.keys.firstOrNull() ?: break
                entries.remove(oldest)
            }
        }
        return mediaId
    }

    /** 按 mediaId 取回播 payload；过期/未知返回 null（调用方须提示重新搜索）。 */
    fun payloadOf(mediaId: String): Map<String, Any?>? {
        synchronized(entries) {
            val entry = entries[mediaId] ?: return null
            if (System.currentTimeMillis() - entry.createdAt > ENTRY_TTL_MS) {
                entries.remove(mediaId)
                return null
            }
            return entry.payload
        }
    }

    /** 会话宿主销毁时清理未结算请求（避免 Handler 持有已死服务的回调）。 */
    fun clearPending() {
        val snapshot = pending.keys.toList()
        for (id in snapshot) {
            val holder = pending.remove(id) ?: continue
            holder.settle(emptyList())
        }
    }
}
