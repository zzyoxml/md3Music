package com.md3music.md3music

import android.content.Context
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import io.flutter.embedding.android.FlutterView

/**
 * tv: IME 会话代理视图（TV 构建专用）。
 *
 * ## 为什么需要
 *
 * 部分 Android TV（`config_preventImeStartupUnlessTextEditor=true`，如 Chromecast with
 * Google TV、部分 Philips/TCL）拒绝给「不自报为文本编辑器」的视图绑定输入法会话。
 * `FlutterView` 从不 override `onCheckIsTextEditor()` → IMMS 返回 NO_EDITOR →
 * 会话绑定失败（logcat：`Ignoring onBind: cur seq=-1`），遥控器方向键一个都到不了
 * 软键盘，用户无法选字（Flutter issue #177360）。
 *
 * 本组件复刻引擎侧正解（PR #193074 正文的 app 侧等价形态，Plezy 生产在用）：
 * 一个 **1×1 可聚焦子 View**，在 Dart 控制下自报 `onCheckIsTextEditor==true`、
 * 把输入连接**委托**给 `FlutterView`、并对 `checkInputConnectionProxy(flutterView)`
 * 返回 true。会话绑定修好后，系统 `ImeInputStage`（早于 FlutterView 所在的
 * ViewPostIme）就会把方向键/OK 直接投给系统 IME，遥控器可以在软键盘上选字。
 *
 * ## 激活语义
 *
 * 只有 Dart 报「主焦点在可编辑控件」(kTextInputFocused) 时才 [imeActive]=true 并
 * 抢焦点；失焦立即清焦点并转 GONE。恒开会让 IME 误判整窗都在文本编辑，
 * 破坏 back / 媒体键语义。
 */
class TvImeProxyView(context: Context) : View(context) {

    /** 对 FlutterView 的引用（MainActivity 注入）。 */
    lateinit var flutterViewRef: FlutterView

    /** Dart 侧信号：是否正在输入。写入后由 MainActivity 同步可见性与焦点。 */
    @Volatile
    var imeActive: Boolean = false

    init {
        // 必须可获焦：IMMS 的「是否文本编辑器」判定问的是持焦视图。
        isFocusable = true
        isFocusableInTouchMode = true
        // 视觉不可见但参与布局（1×1），不要用 GONE——GONE 视图拿不到焦点。
        alpha = 0f
    }

    /**
     * 系统询问「是否为文本编辑器」。设备正是靠这个回调决定是否绑定 IME 会话。
     * 与引擎侧 `FlutterView.isTextEditor()` 同口径：有文本客户端才报 true。
     */
    override fun onCheckIsTextEditor(): Boolean =
        imeActive && flutterViewRef.isAttachedToFlutterEngine()

    /**
     * 创建输入法连接：**委托**给 FlutterView，让 IME 直接与 Flutter 的
     * TextInputPlugin 对话（EditorInfo 由 FlutterView 填充）。
     */
    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? =
        if (imeActive && flutterViewRef.isAttachedToFlutterEngine()) {
            flutterViewRef.onCreateInputConnection(outAttrs)
        } else {
            null
        }

    /**
     * 代理检查：FlutterView 的输入连接由本 View 代理时返回 true。
     * 这是让 IME 接受「非持焦视图提供的连接」的关键契约。
     */
    override fun checkInputConnectionProxy(child: View?): Boolean =
        child === flutterViewRef

    /** 不消费点击（本 View 只是语义代理，无交互）。 */
    override fun performClick(): Boolean = false
}
