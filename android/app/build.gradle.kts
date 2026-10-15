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

    // 产品 flavor（3D 深度封面）:
    //   standard - 不含 3D 封面：无 onnxruntime so、无深度模型资产，体积最小
    //   depth3d  - 3D 全量包：内置 ONNX Runtime so + Depth Anything V2 模型资产
    //   tv       - TV 版独立包体：dpad 遥控导航 + 排除 3D/USB 独占/歌词推送
    // 两 flavor 共用同一 applicationId/签名，depth3d 包可直接覆盖安装 standard 包。
    flavorDimensions += "feature"
    productFlavors {
        create("standard") {}
        create("depth3d") {}
        // TV 版独立包体：dpad 遥控导航 + 排除 3D/USB 独占/歌词推送。
        // 后缀与手机版并存互不覆盖（TV 设备上只装 TV 版）。
        create("tv") {
            dimension = "feature"
            applicationIdSuffix = ".tv"
            buildConfigField("boolean", "FEATURE_TV", "true")
            // 不编译 USB 独占输出 C++ 驱动（TV 包内无 libusb_audio_driver.so）
            externalNativeBuild {
                cmake {
                    arguments += listOf("-DUSB_DRIVER=OFF")
                }
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // TV flavor 用 BuildConfig.FEATURE_TV 门控 USB 独占/Direct PCM 原生插件注册。
    // AGP 9 默认不生成 BuildConfig，必须显式开启。
    buildFeatures {
        buildConfig = true
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
        // TV 版 = tv flavor（true）；standard/depth3d 为 false。
        buildConfigField("boolean", "FEATURE_TV", "false")
        // 渲染引擎 manifest 静态开关，默认 Impeller（true）。Flutter 3.44 只认
        // manifest 静态值；构建 Skia 版用 -Pmd3EnableImpeller=false
        // （见 scripts/tasks/android_skia.ps1）。仅此一处、无 flavor，产物名不含引擎标识。
        manifestPlaceholders["enableImpeller"] = providers.gradleProperty("md3EnableImpeller").getOrElse("true")
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

    // MD3Music fork: JVM 单元测试里 android.util.Log 等框架桩默认会抛
    // "Method i in android.util.Log not mocked"。DirectPcmController 等 fork 侧的
    // 状态类在测试中需要走 setEnabled（内部会打日志），故开启返回默认值。
    testOptions {
        unitTests.isReturnDefaultValues = true
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
    // 2×2 封面小部件：从专辑封面位图提取主色（vibrant/dominant swatch）
    implementation("androidx.palette:palette-ktx:1.0.0")
    // 3D 深度封面：端上 Depth Anything V2 推理（ONNX Runtime Mobile）
    // 仅 depth3d flavor 打包（standard 包不含此 so，体积 -13.2MB）
    // 自编 reduced-ops AAR：官方 libonnxruntime.so 33.0MB → 13.2MB（13,201,664 B），
    // 只编译两份深度模型实际用到的算子内核；保留 NNAPI EP 符号以匹配官方
    // libonnxruntime4j_jni.so 的符号引用（该 jni 层原样保留，勿动）；仅 arm64-v8a。
    // 算子并集 = depth 模型 ∪ MI-GAN Pipeline（52 项注册 / 9 行）；配置与重建流程见
    // android/app/libs/ort-ops/（REBUILD.md + depth_migan_union_v3.config）。
    // ⚠️ 内核裁剪后 strings/差分都判不出算子是否可用，唯一判据是真机 createSession
    //    日志（loadInpaintModel OK）。
    "depth3dImplementation"(files("libs/onnxruntime-android-1.30.0-custom-v8a.aar"))

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
