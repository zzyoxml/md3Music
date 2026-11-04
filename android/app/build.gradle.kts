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

    // 产品 flavor（能力分层）:
    //   lite - 精简包（默认/对外公开）：无 3D 封面、无端侧分离 —— 不含 onnxruntime so、
    //          不含深度模型、不含 tflite 运行时、不含分离模型，Dart 侧整块功能被树摇剔除
    //   full - 全功能包：3D 深度封面（ONNX Runtime so + Depth Anything V2 模型资产）
    //          + 端侧人声/伴奏分离（MSS tflite 运行时 + 模型资产）
    //   tv   - TV 版独立包体：dpad 遥控导航 + 排除 3D/USB 独占/歌词推送
    // 三 flavor 共用同一 applicationId/签名（tv 除外，带 .tv 后缀），full 包可直接覆盖安装 lite 包。
    flavorDimensions += "feature"
    productFlavors {
        create("lite") {}
        create("full") {}
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

    // 能力源集归属（物理目录名保持 src/stemsep、src/depth3d，不随 flavor 改名）：
    //   lite - 不挂任何推理源集（无 3D、无分离）
    //   full - 同时挂 3D（src/depth3d）与端侧分离（src/stemsep）的 Kotlin + 资产
    //   tv   - 不挂（tv 盒子算力普遍不足以跑实时分离，且 tv 包一向不放推理运行时）
    // Windows 侧 CMake（windows/CMakeLists.txt）按物理路径取深度模型，故目录名不改。
    //
    // 分离模型来源：默认取仓库内已入库的 src/stemsep/assets（完整仓库）；
    // 公开树不带该资产，CI 用 -Pmd3StemModelDir=<外部目录> 在构建期注入，
    // 注入目录与仓库目录不能同时挂（同含 stem/mss-model.tflite 会触发 AGP 资源重复）。
    val stemModelDirOverride = providers.gradleProperty("md3StemModelDir").orNull
    val requireStemModel = providers.gradleProperty("md3RequireStemModel").orNull == "true"
    val stemAssetDir = if (stemModelDirOverride.isNullOrBlank()) {
        "src/stemsep/assets"
    } else {
        stemModelDirOverride.replace('\\', '/')
    }
    sourceSets {
        getByName("full") {
            java.srcDirs("src/stemsep/kotlin", "src/depth3d/kotlin")
            assets.srcDirs(stemAssetDir, "src/depth3d/assets")
        }
    }

    // full 包带分离能力，缺模型会产出「UI 有开关、点了没声」的残包：构建前就拦住。
    // 两级：
    //   1) -Pmd3RequireStemModel=true（CI 显式要求）→ 配置期直接失败，早于任何 Gradle 任务；
    //   2) 其余情况 → 挂在 assembleFull/bundleFull 上的独立校验任务。
    // 之所以默认不用配置期 throw：Gradle 配置阶段对所有变体都会执行，公开树（不带模型资产）
    // 只构建 lite 时也必须能配置成功。
    val stemModelFile = file("$stemAssetDir/stem/mss-model.tflite")
    fun checkStemModel() {
        if (!stemModelFile.isFile) {
            throw GradleException(
                "端侧分离模型缺失：$stemModelFile\n" +
                    "  a) 完整仓库：git checkout -- android/app/src/stemsep/assets 恢复已入库模型；\n" +
                    "  b) 公开树/CI：用 --android-project-arg=md3StemModelDir=<外部目录> 注入" +
                    "（目录内应有 stem/mss-model.tflite，4,902,660 B）；\n" +
                    "  c) 不需要分离能力：改用 --flavor lite。"
            )
        }
        val modelBytes = stemModelFile.length()
        if (modelBytes != 4_902_660L) {
            throw GradleException(
                "端侧分离模型字节数异常：$stemModelFile 实际 $modelBytes B，" +
                    "期望 4,902,660 B（与 TfliteMssInterpreter.MODEL_BYTES 必须一致）。"
            )
        }
    }
    if (requireStemModel) checkStemModel()
    val verifyFullStemModel by tasks.registering { doLast { checkStemModel() } }
    tasks.matching { it.name.startsWith("assembleFull") || it.name.startsWith("bundleFull") }
        .configureEach { dependsOn(verifyFullStemModel) }

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
        // TV 版 = tv flavor（true）；lite/full 为 false。
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

    // 新 API 用在低于 minSdk 的设备 = 运行时 NoSuchMethodError 必崩。issue #130 的教训：
    // Vibrator.hasAmplitudeControl() 是 API 26 方法，曾无守卫写在 MusicHapticsPlugin 的
    // 属性初始化器里，导致 Android 7.x TV 盒子（rk3128）装 .tv 包后冷启动必崩。
    // release 的 lintVital 只查 fatal severity，而 NewApi 默认为 error 不是 fatal，
    // 故被整条漏过；此处只把 NewApi 单独提为 fatal，其余既有 warning/info 不阻断。
    lint {
        abortOnError = false
        fatal += "NewApi"
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
    // 方案B阶段1：app 侧 Kotlin 引用 androidx.media3.common 类型（UnstableApi、Player 等）。
    // media3-common 为单一 maven 源（fork 同版本 1.4.1），此处显式依赖以便编译期可见
    // （fork 用 implementation 隐藏了传递依赖）。session/exoplayer 仍是 fork 本地源码，勿加 maven。
    implementation("androidx.media3:media3-common:1.4.1")
    // 2×2 封面小部件：从专辑封面位图提取主色（vibrant/dominant swatch）
    implementation("androidx.palette:palette-ktx:1.0.0")
    // 端侧人声/伴奏分离：MSS 模型走 TFLite 标准运行时（含 XNNPACK，CPU 多线程）。
    // 只给 full（lite 无分离、tv 不放推理运行时）。arm64 so ≈ 3.4MB / v7a ≈ 2.2MB。
    // 明确**不用** GPU delegate：实测该模型带 32 个 TRANSPOSE，GPU 上要额外 layout
    // 转换，性能反而倒退；旧 Java GpuDelegate 在部分驱动上直接 segfault。
    "fullImplementation"("org.tensorflow:tensorflow-lite:2.16.1")
    // 3D 深度封面：端上 Depth Anything V2 推理（ONNX Runtime Mobile）
    // 仅 full flavor 打包（lite 包不含此 so，体积 -13.2MB）
    // 自编 reduced-ops AAR：官方 libonnxruntime.so 33.0MB → 13.2MB（13,201,664 B），
    // 只编译两份深度模型实际用到的算子内核；保留 NNAPI EP 符号以匹配官方
    // libonnxruntime4j_jni.so 的符号引用（该 jni 层原样保留，勿动）；仅 arm64-v8a。
    // 算子并集 = depth 模型 ∪ MI-GAN Pipeline（52 项注册 / 9 行）；配置与重建流程见
    // android/app/libs/ort-ops/（REBUILD.md + depth_migan_union_v3.config）。
    // ⚠️ 内核裁剪后 strings/差分都判不出算子是否可用，唯一判据是真机 createSession
    //    日志（loadInpaintModel OK）。
    "fullImplementation"(files("libs/onnxruntime-android-1.30.0-custom-v8a.aar"))

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
