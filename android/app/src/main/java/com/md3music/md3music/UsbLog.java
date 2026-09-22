package com.md3music.md3music;

import android.util.Log;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.text.SimpleDateFormat;
import java.util.ArrayDeque;
import java.util.Date;
import java.util.Locale;

/**
 * USB 独占链路内部日志系统（用户无法抓 logcat 时的导出通道）。
 *
 * 双通道设计：
 * - 内存环形缓冲：app 模块（UsbAudioDevice/UsbAudioStream/UsbAudioPlugin）的
 *   Log.i/w/e 经本类双写，logcat 行为不变；
 * - logcat 自读导出：应用可读取自身 uid 的 logcat 缓冲（logcat -d 按 tag 过滤），
 *   覆盖 just_audio 模块（UsbAudioSinkCtrl/UsbStreamingThread）与
 *   native（UsbAudioOutput，含数据供给节奏/SUBMITURB 错误）的全部输出。
 *
 * 导出：exportAll() 合并两路，由设置页「导出诊断日志」打包进 usb.log。
 */
public final class UsbLog {

    private static final int CAPACITY = 800;
    private static final ArrayDeque<String> lines = new ArrayDeque<>(CAPACITY);
    private static final SimpleDateFormat fmt = new SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US);

    private UsbLog() {}

    public static void i(String tag, String msg) {
        append('I', tag, msg);
        Log.i(tag, msg);
    }

    public static void w(String tag, String msg) {
        append('W', tag, msg);
        Log.w(tag, msg);
    }

    public static void e(String tag, String msg) {
        append('E', tag, msg);
        Log.e(tag, msg);
    }

    public static void e(String tag, String msg, Throwable tr) {
        append('E', tag, tr != null ? msg + ": " + tr.getMessage() : msg);
        Log.e(tag, msg, tr);
    }

    /**
     * 桥接入口：只进内存环形缓冲，不写 logcat。
     * 用于 just_audio 模块的日志桥接（源头已写过 logcat，避免同条日志在
     * 诊断导出的 logcat 段出现两次）。
     */
    public static void bridge(char level, String tag, String msg) {
        append(level, tag, msg);
    }

    private static synchronized void append(char level, String tag, String msg) {
        if (lines.size() >= CAPACITY) {
            lines.pollFirst();
        }
        lines.addLast(fmt.format(new Date()) + " " + level + "/" + tag + ": " + msg);
    }

    /** 导出内存环形缓冲（最旧在前）。 */
    public static synchronized String dump() {
        StringBuilder sb = new StringBuilder(lines.size() * 96);
        for (String line : lines) {
            sb.append(line).append('\n');
        }
        return sb.toString();
    }

    /**
     * 读取本应用 logcat 缓冲中 USB 链路相关日志。
     * 应用可读取自身 uid 写入的日志缓冲（无需 READ_LOGS 权限），
     * 覆盖 just_audio 模块与 native（__android_log_print）的输出。
     */
    public static String readLogcat() {
        try {
            Process p = Runtime.getRuntime().exec(new String[]{
                    "logcat", "-d", "-v", "time",
                    "UsbAudioDevice:V", "UsbAudioPlugin:V", "UsbAudioOutput:V",
                    "UsbAudioSinkCtrl:V", "UsbStreamingThread:V",
                    // media3 链路（P0-4/P0-5 观测）：渲染器调度、render 循环分支、
                    // codec 生命周期与「输入缓冲容量/KEY_MAX_INPUT_SIZE」修复判据
                    "ExoPlayerImplInternal:V", "MediaCodecRenderer:V",
                    "MediaCodecAudioRenderer:V",
                    // 32bit FLAC 定位（2026-09-14）：libFLAC 原生错误分布在两个 tag ——
                    // flac_jni（JNI 层）与 FLACParser（解析器逐帧错误/CRC 校验失败）；
                    // UsbDiag 是 fork 的渲染器/扩展状态打点
                    "flac_jni:V", "FLACParser:V", "UsbDiag:V", "*:S"});
            BufferedReader reader =
                    new BufferedReader(new InputStreamReader(p.getInputStream(), "UTF-8"));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) {
                sb.append(line).append('\n');
            }
            reader.close();
            p.waitFor();
            return sb.toString();
        } catch (Throwable t) {
            return "";
        }
    }

    /** 导出全部：内存环形缓冲（app 侧）+ logcat 过滤段（just_audio 模块与 native）。 */
    public static String exportAll() {
        return "── 内存环形日志（app 侧） ──\n"
                + dump()
                + "\n── logcat（USB 链路过滤，含 just_audio 模块与 native 传输层） ──\n"
                + readLogcat();
    }
}
