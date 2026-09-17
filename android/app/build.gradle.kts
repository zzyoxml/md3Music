import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties().apply {
    val f = rootProject.file("keystore.properties")
    if (f.exists()) {
        load(FileInputStream(f))
    }
}

android {
    namespace = "com.md3music.md3music"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }


    defaultConfig {
        // CI 的原子随身听兼容包只覆盖 applicationId；namespace、Kotlin 包路径和
        // MethodChannel 名保持不变，避免复制或改写原生代码。
        applicationId = providers.gradleProperty("md3ApplicationId")
            .getOrElse("com.md3music.md3music")
        minSdk = flutter.minSdkVersion
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 渲染引擎固定为 skia（EnableImpeller=false，兼容优先）。Flutter 3.44 只认
        // manifest 静态值。仅此一处、无 flavor：保证 split-per-abi 产物名不含引擎标识。
        manifestPlaceholders["enableImpeller"] = "false"
        // USB 独占输出 C++ 驱动：只编译与 jniLibs 相同的 4 个 ABI
        externalNativeBuild {
            cmake {
                abiFilters("arm64-v8a", "armeabi-v7a", "x86_64", "x86")
            }
        }
    }

    // 2026-09-12：加入 libflacJNI.so（P0-5 flac 扩展）后 native libs 被改为 Stored
    // （APK 153.6→191.2MB）。显式恢复未压缩打包默认（extractNativeLibs=false，
    // 直接从 APK 页对齐加载，安装包最小、加载最快）。
    packaging {
        jniLibs.useLegacyPackaging = false
    }

    signingConfigs {
        create("release") {
            if (keystoreProperties.isNotEmpty()) {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Use the persistent release signing config (if keystore.properties exists)
            // Falls back to debug signing when keystore.properties is missing (CI / first build)
            signingConfig = if (keystoreProperties.isNotEmpty()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        debug {
            // Disable symbol stripping for Gradle 9.x compatibility
            ndk {
                debugSymbolLevel = "none"
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.media:media:1.6.0")
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("io.github.proify.lyricon:provider:0.1.70")
    implementation("io.github.proify.lyricon.lyric:model:0.1.70")
    // SuperLyricApi：基于 Binder 的系统级实时歌词 API（jnitpack，settings.gradle.kts 已声明）
    implementation("com.github.HChenX:SuperLyricApi:3.4")
    // JAudioTagger 社区分叉（支持 MP3/FLAC/Ogg/M4A 等格式的 ID3v2 / VorbisComment 标签读写，
    // 用于在下载完成后向音频文件嵌入标题/艺术家/专辑/封面/歌词）。
    // JitPack 上 AdrienPoupa 分叉仅有 2.2.3（无 2.2.5）。
    implementation("com.github.AdrienPoupa:jaudiotagger:2.2.3")
    // 方案B阶段1：app 侧 Kotlin 引用 androidx.media3.common 类型（UnstableApi、Player 等）。
    // media3-common 为单一 maven 源（fork 同版本 1.4.1），此处显式依赖以便编译期可见
    // （fork 用 implementation 隐藏了传递依赖）。session/exoplayer 仍是 fork 本地源码，勿加 maven。
    implementation("androidx.media3:media3-common:1.4.1")

    // USB 独占数据路径（UsbDither / UsbAudioStream.writeRaw）的 JVM 单元测试
    testImplementation("junit:junit:4.13.2")
}

// MD3Music fork: 全局强制 media3 版本与本地 just_audio fork 的 exoplayer 源码一致（1.4.1）。
// video_player 等库声明更高版本（1.9.2），若不强制会出现重复类（本地源码 vs maven 1.9.2）。
// media3-exoplayer 的 maven 版本全局排除——由 just_audio fork 内的本地源码提供。
configurations.all {
    exclude(group = "androidx.media3", module = "media3-exoplayer")
    resolutionStrategy {
        force(
            "androidx.media3:media3-common:1.4.1",
            "androidx.media3:media3-container:1.4.1",
            "androidx.media3:media3-database:1.4.1",
            "androidx.media3:media3-datasource:1.4.1",
            "androidx.media3:media3-decoder:1.4.1",
            "androidx.media3:media3-exoplayer-dash:1.4.1",
            "androidx.media3:media3-exoplayer-hls:1.4.1",
            "androidx.media3:media3-exoplayer-rtsp:1.4.1",
            "androidx.media3:media3-exoplayer-smoothstreaming:1.4.1",
            "androidx.media3:media3-extractor:1.4.1"
        )
    }
}

flutter {
    source = "../.."
}
