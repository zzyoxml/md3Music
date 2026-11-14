package com.ryanheise.just_audio;

import static org.junit.Assert.assertTrue;
import static org.junit.Assert.assertEquals;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.List;
import org.junit.Test;

/**
 * fork 内 media3 源码的**结构断言**。
 *
 * <p>为什么用源码断言而不是运行时测试：{@code DefaultAudioSink} 依赖 208 处
 * Android API（AudioTrack/AudioTimestamp 等），在 JVM 单测里无法实例化，而
 * 它恰恰是本次 bug 的所在位置。
 *
 * <p>锁死的行为：{@code DefaultAudioSink.flush()} 必须调用
 * {@code audioProcessingPipeline.flush()}。
 *
 * <p>上游 media3 只在 {@code reset()} 里调 {@code pipeline.reset()}（由
 * onDisabled 触发，即切歌/换源），{@code flush()}（由 onPositionReset 触发，
 * 即 **seek**）**从不通知处理器链**。后果是拖进度条时
 * {@code StemSeparateProcessor.onFlush()} 不被调用 → 端侧分离保留 seek 之前的
 * 旧音频与 28 路流式状态 → 新位置音频接在旧内容后面推理 → 实测表现为
 * 「拖动进度后分离失效/串音」。
 */
public class DefaultAudioSinkSourceTest {

  /** 从测试工作目录向上找到 fork 的 media3 源码。 */
  private static File media3Source() {
    File dir = new File(System.getProperty("user.dir"));
    for (int i = 0; i < 6 && dir != null; i++) {
      File candidate =
          new File(dir,
              "third_party/just_audio/android/src/main/java/androidx/media3/exoplayer/audio"
                  + "/DefaultAudioSink.java");
      if (candidate.isFile()) {
        return candidate;
      }
      File direct =
          new File(dir,
              "src/main/java/androidx/media3/exoplayer/audio/DefaultAudioSink.java");
      if (direct.isFile()) {
        return direct;
      }
      dir = dir.getParentFile();
    }
    return null;
  }

  @Test
  public void sinkFlushNotifiesAudioProcessingPipeline() throws IOException {
    File src = media3Source();
    assertTrue("找不到 DefaultAudioSink.java，源码断言失效", src != null);

    List<String> lines = Files.readAllLines(src.toPath(), StandardCharsets.UTF_8);

    // 定位 flush() 方法体范围（按大括号配对）
    int start = -1;
    for (int i = 0; i < lines.size(); i++) {
      if (lines.get(i).trim().startsWith("public void flush()")) {
        start = i;
        break;
      }
    }
    assertTrue("DefaultAudioSink 里找不到 flush()", start >= 0);

    int depth = 0;
    boolean opened = false;
    int end = -1;
    for (int i = start; i < lines.size(); i++) {
      String line = lines.get(i);
      if (line.contains("{")) {
        depth += count(line, '{');
        opened = true;
      } else if (opened) {
        depth += count(line, '{');
      }
      if (opened) {
        depth -= count(line, '}');
        if (depth <= 0) {
          end = i;
          break;
        }
      }
    }
    assertTrue("flush() 方法体范围解析失败", end > start);

    StringBuilder body = new StringBuilder();
    for (int i = start; i <= end; i++) {
      body.append(lines.get(i)).append('\n');
    }

    // 核心断言：在 flush() 方法体**内**、且**不是注释行**处，必须出现该调用。
    //
    // 不能只在整个文件里搜字符串 —— setupAudioProcessors() 本来就有一次
    // audioProcessingPipeline.flush()（约第 871 行），纯文本匹配会让断言永远
    // 通过、完全失去意义（实测：把真实调用删掉后旧断言仍然通过）。必须限定
    // 在 flush() 方法体内并剔除注释（注释里也写了该调用的说明文字）。
    boolean found = false;
    for (int i = start + 1; i <= end; i++) {
      String code = lines.get(i).trim();
      if (code.startsWith("//") || code.startsWith("*") || code.startsWith("/*")) {
        continue;
      }
      if (code.contains("audioProcessingPipeline.flush()")) {
        found = true;
        break;
      }
    }
    assertTrue(
        "DefaultAudioSink.flush() 必须在方法体内真正调用 "
            + "audioProcessingPipeline.flush()（不含注释），否则 seek 时处理器链"
            + "收不到通知，端侧分离会残留 seek 之前的音频并产生串音。当前方法体:",
        found);
  }
  @Test
  public void sinkResetStillResetsPipeline() {
    // 对照护栏：reset() 路径（切歌/换源）本来就有 pipeline.reset()，不能被改掉。
    File src = media3Source();
    assertTrue(src != null);
    try {
      String content = new String(Files.readAllBytes(src.toPath()), StandardCharsets.UTF_8);
      assertTrue("reset() 必须仍调用 audioProcessingPipeline.reset()",
          content.contains("audioProcessingPipeline.reset()"));
    } catch (IOException e) {
      throw new AssertionError("读取 DefaultAudioSink.java 失败: " + e.getMessage());
    }
  }

  private static int count(String s, char c) {
    int n = 0;
    for (int i = 0; i < s.length(); i++) {
      if (s.charAt(i) == c) n++;
    }
    return n;
  }
}
