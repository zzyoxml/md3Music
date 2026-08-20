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
-keepclasseswithmembernames class com.md3music.premium.UsbAudioStream {
    native <methods>;
}
-keep class com.md3music.premium.UsbAudioAdapter { *; }
-keep class com.ryanheise.just_audio.UsbAudioSinkController { *; }
-keep class com.ryanheise.just_audio.UsbAudioSink { *; }

# ── Miuix 组件（Compose Multiplatform，无自带 consumer rules，R8 需保留类结构） ──
-keep class top.yukonga.miuix.** { *; }
