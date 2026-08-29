# JAudioTagger 依赖反射创建标签对象副本，必须保留所有类名和构造函数
# 否则 R8 混淆后反射调用 NoSuchMethodException: Error finding constructor to create copy
-keep class org.jaudiotagger.** { *; }
-keep class org.jaudiotagger.tag.id3.** { *; }
-keep class org.jaudiotagger.tag.flac.** { *; }
-keep class org.jaudiotagger.tag.mp4.** { *; }
-keep class org.jaudiotagger.tag.vorbiscomment.** { *; }
-keep class org.jaudiotagger.audio.** { *; }
-keep class org.jaudiotagger.tag.datatype.** { *; }
-keep class org.jaudiotagger.tag.reference.** { *; }
-keep class org.jaudiotagger.tag.images.** { *; }
-keep class org.jaudiotagger.tag.lyrics.** { *; }
-keep class org.jaudiotagger.tag.id3.framebody.** { *; }
-keep class org.jaudiotagger.tag.id3.valuepair.** { *; }

# ── SuperLyricApi（R8 必须保留所有 API 类，避免 Binder/AIDL 反射失败） ──
-keep class com.hchen.superlyricapi.* {*;}

# ├── USB 独占输出（JNI 外部方法 + fork 桥接接口，R8 必须保留方法名） ──
-keepclasseswithmembernames class com.md3music.md3music.UsbAudioStream {
    native <methods>;
}
-keep class com.md3music.md3music.UsbAudioAdapter { *; }
-keep class com.ryanheise.just_audio.UsbAudioSinkController { *; }
-keep class com.ryanheise.just_audio.UsbAudioSink { *; }

# ── Miuix 组件（Compose Multiplatform，无自带 consumer rules，R8 需保留类结构） ──
-keep class top.yukonga.miuix.** { *; }
# Proguard rules specific to the core module.

# Constructors accessed via reflection in DefaultRenderersFactory
-dontnote androidx.media3.decoder.vp9.LibvpxVideoRenderer
-keepclassmembers class androidx.media3.decoder.vp9.LibvpxVideoRenderer {
  <init>(long, android.os.Handler, androidx.media3.exoplayer.video.VideoRendererEventListener, int);
}
-dontnote androidx.media3.decoder.av1.Libgav1VideoRenderer
-keepclassmembers class androidx.media3.decoder.av1.Libgav1VideoRenderer {
  <init>(long, android.os.Handler, androidx.media3.exoplayer.video.VideoRendererEventListener, int);
}
-dontnote androidx.media3.decoder.ffmpeg.ExperimentalFfmpegVideoRenderer
-keepclassmembers class androidx.media3.decoder.ffmpeg.ExperimentalFfmpegVideoRenderer {
  <init>(long, android.os.Handler, androidx.media3.exoplayer.video.VideoRendererEventListener, int);
}
-dontnote androidx.media3.decoder.opus.LibopusAudioRenderer
-keepclassmembers class androidx.media3.decoder.opus.LibopusAudioRenderer {
  <init>(android.os.Handler, androidx.media3.exoplayer.audio.AudioRendererEventListener, androidx.media3.exoplayer.audio.AudioSink);
}
-dontnote androidx.media3.decoder.flac.LibflacAudioRenderer
-keepclassmembers class androidx.media3.decoder.flac.LibflacAudioRenderer {
  <init>(android.os.Handler, androidx.media3.exoplayer.audio.AudioRendererEventListener, androidx.media3.exoplayer.audio.AudioSink);
}
-dontnote androidx.media3.decoder.ffmpeg.FfmpegAudioRenderer
-keepclassmembers class androidx.media3.decoder.ffmpeg.FfmpegAudioRenderer {
  <init>(android.os.Handler, androidx.media3.exoplayer.audio.AudioRendererEventListener, androidx.media3.exoplayer.audio.AudioSink);
}
-dontnote androidx.media3.decoder.midi.MidiRenderer
-keepclassmembers class androidx.media3.decoder.midi.MidiRenderer {
  <init>(android.content.Context);
}

# Constructors accessed via reflection in DefaultDownloaderFactory
-dontnote androidx.media3.exoplayer.dash.offline.DashDownloader
-keepclassmembers class androidx.media3.exoplayer.dash.offline.DashDownloader {
  <init>(androidx.media3.common.MediaItem, androidx.media3.datasource.cache.CacheDataSource$Factory, java.util.concurrent.Executor);
}
-dontnote androidx.media3.exoplayer.hls.offline.HlsDownloader
-keepclassmembers class androidx.media3.exoplayer.hls.offline.HlsDownloader {
  <init>(androidx.media3.common.MediaItem, androidx.media3.datasource.cache.CacheDataSource$Factory, java.util.concurrent.Executor);
}
-dontnote androidx.media3.exoplayer.smoothstreaming.offline.SsDownloader
-keepclassmembers class androidx.media3.exoplayer.smoothstreaming.offline.SsDownloader {
  <init>(androidx.media3.common.MediaItem, androidx.media3.datasource.cache.CacheDataSource$Factory, java.util.concurrent.Executor);
}

# Constructors accessed via reflection in DefaultMediaSourceFactory
-dontnote androidx.media3.exoplayer.dash.DashMediaSource$Factory
-keepclasseswithmembers class androidx.media3.exoplayer.dash.DashMediaSource$Factory {
  <init>(androidx.media3.datasource.DataSource$Factory);
}
-dontnote androidx.media3.exoplayer.hls.HlsMediaSource$Factory
-keepclasseswithmembers class androidx.media3.exoplayer.hls.HlsMediaSource$Factory {
  <init>(androidx.media3.datasource.DataSource$Factory);
}
-dontnote androidx.media3.exoplayer.smoothstreaming.SsMediaSource$Factory
-keepclasseswithmembers class androidx.media3.exoplayer.smoothstreaming.SsMediaSource$Factory {
  <init>(androidx.media3.datasource.DataSource$Factory);
}
-dontnote androidx.media3.exoplayer.rtsp.RtspMediaSource$Factory
-keepclasseswithmembers class androidx.media3.exoplayer.rtsp.RtspMediaSource$Factory {
  <init>();
}

# Constructors and methods accessed via reflection in CompositingVideoSinkProvider
-dontnote androidx.media3.effect.PreviewingSingleInputVideoGraph$Factory
-keepclasseswithmembers class androidx.media3.effect.PreviewingSingleInputVideoGraph$Factory {
  <init>(androidx.media3.common.VideoFrameProcessor$Factory);
}
-dontnote androidx.media3.effect.DefaultVideoFrameProcessor$Factory$Builder
-keepclasseswithmembers class androidx.media3.effect.DefaultVideoFrameProcessor$Factory$Builder {
  androidx.media3.effect.DefaultVideoFrameProcessor$Factory build();
}
