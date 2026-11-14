package com.md3music.md3music

import android.app.Service
import android.content.Intent
import android.os.IBinder

/**
 * 独立任务移除监听服务。
 *
 * Manifest 中 stopWithTask=true：用户从最近任务划掉应用时，由系统直接停止本服务，
 * 不依赖各 ROM 是否及时投递 onTaskRemoved。本服务没有任何业务 stopSelf/stopService
 * 路径，因此 onDestroy 不会与正常暂停、关闭通知等操作混淆。
 */
class TaskRemovalService : Service() {

    override fun onCreate() {
        super.onCreate()
        RingLog.i("SwipeExit", "stopWithTask service started")
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_NOT_STICKY

    override fun onDestroy() {
        val shouldExit = SwipeExitPolicy.shouldSwipeExit(applicationContext)
        RingLog.i("SwipeExit", "stopWithTask onDestroy entered, shouldExit=$shouldExit")
        super.onDestroy()
        if (shouldExit) {
            SwipeExitPolicy.executeExit(applicationContext)
        }
    }
}
