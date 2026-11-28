package com.md3music.md3music

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「系统 hidden 任务移除 ≠ 用户划掉后台」守卫的纯逻辑测试（SM-T870 实机取证后的回归）。
 *
 * 根因：息屏拉起锁屏歌词 → 指纹解锁 → 锁屏层 onStop 后 ~80~370ms 内主任务被
 * `remove-hidden-task` 移除，两条入口（TaskRemovalService 销毁 +
 * AudioPlaybackService.onTaskRemoved）先后触发 executeExit 自杀式退出。
 *
 * 因此窗口内必须**整段拦截、不消费**——任一条入口漏网都会退出进程。
 */
class SwipeExitPolicyLockGuardTest {

    @Test
    fun `未登记时任何时刻都不判为系统移除`() {
        assertFalse(SwipeExitPolicy.systemTaskRemovalFromLockLayer(nowElapsedMs = 1_000_000L))
    }

    @Test
    fun `窗口内多条入口全部判为系统移除且不互相消费`() {
        SwipeExitPolicy.markLockLayerEnded(nowElapsedMs = 5_000L)

        // 下界含：恰好等于登记时刻即命中；随后连续多次命中，模拟两条入口先后投递
        assertTrue(SwipeExitPolicy.systemTaskRemovalFromLockLayer(nowElapsedMs = 5_000L))
        assertTrue(SwipeExitPolicy.systemTaskRemovalFromLockLayer(nowElapsedMs = 5_150L))
        assertTrue(SwipeExitPolicy.systemTaskRemovalFromLockLayer(nowElapsedMs = 5_400L))
    }

    @Test
    fun `超过窗口则不判为系统移除`() {
        SwipeExitPolicy.markLockLayerEnded(nowElapsedMs = 9_000L)

        assertFalse(SwipeExitPolicy.systemTaskRemovalFromLockLayer(nowElapsedMs = 10_001L))
        assertFalse(SwipeExitPolicy.systemTaskRemovalFromLockLayer(nowElapsedMs = 11_100L))
    }

    @Test
    fun `窗口结束后重新登记可再次生效`() {
        SwipeExitPolicy.markLockLayerEnded(nowElapsedMs = 2_000L)
        assertFalse(SwipeExitPolicy.systemTaskRemovalFromLockLayer(nowElapsedMs = 3_101L))

        SwipeExitPolicy.markLockLayerEnded(nowElapsedMs = 20_000L)
        assertTrue(SwipeExitPolicy.systemTaskRemovalFromLockLayer(nowElapsedMs = 20_500L))
    }
}