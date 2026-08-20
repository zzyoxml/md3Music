import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Compose 编译器插件（Kotlin 2.x 内置，版本随 Kotlin）
    id("org.jetbrains.kotlin.plugin.compose")
}

val keystoreProperties = Properties().apply {
    val f = rootProject.file("keystore.properties")
    if (f.exists()) {
        load(FileInputStream(f))
    }
}

android {
    namespace = "com.md3music.premium"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.md3music.premium"
        minSdk = flutter.minSdkVersion
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // USB 独占输出 C++ 驱动：只编译与 jniLibs 相同的 4 个 ABI
        externalNativeBuild {
            cmake {
                abiFilters("arm64-v8a", "armeabi-v7a", "x86_64", "x86")
            }
        }
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

    buildFeatures {
        // MiuixDiscoverActivity 使用 Compose + miuix 组件
        compose = true
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

    // ==================== Miuix 风格测试页（原生 Compose） ====================
    // miuix-android 0.8.8：Kotlin 2.3.20 + Compose Foundation 1.10.3 编译，
    // minCompileSdk=36，与当前工程（compileSdk 36 / Kotlin 2.3.20）完全匹配
    implementation("top.yukonga.miuix.kmp:miuix-android:0.8.8")
    // Compose 宿主（ComposeView）+ 图片加载（Coil）
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("io.coil-kt:coil-compose:2.7.0")
}

flutter {
    source = "../.."
}
