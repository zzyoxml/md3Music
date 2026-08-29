group = "com.ryanheise.just_audio"
version = "1.0"
val args = listOf("-Xlint:deprecation", "-Xlint:unchecked")

buildscript {
    // Uncomment when moving to Kotlin
    // val kotlinVersion = "2.3.20"
    val agpVersion = "9.0.1"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:$agpVersion")
        // Uncomment when moving to Kotlin
        // classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

tasks.withType<JavaCompile>().configureEach {
    options.compilerArgs.addAll(args)
}

// Uncomment when moving to Kotlin
// val agpMajor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.substringBefore('.').toInt()
// if (agpMajor < 9) {
//    apply(plugin = "org.jetbrains.kotlin.android")
// }

android {
    namespace = "com.ryanheise.just_audio"
    compileSdk = 35

    defaultConfig {
        minSdk = 16
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Uncomment when moving to Kotlin
    // sourceSets {
    //     getByName("main") {
    //         java.srcDirs("src/main/kotlin")
    //     }
    //     getByName("test") {
    //         java.srcDirs("src/test/kotlin")
    //     }
    // }

    lint {
        disable += listOf("AndroidGradlePluginVersion", "InvalidPackage", "GradleDependency", "NewerVersionAvailable")
    }
}

dependencies {
    val exoplayerVersion = "1.4.1"
    // MD3Music fork: media3-exoplayer 已改为本地源码（src/main/java/androidx/media3/exoplayer/**），
    // 原因：在 AudioFocusManager 暴露原始焦点事件（setAudioFocusEventListener）供 Dart 三模式决策。
    // 因此不再引入 maven 的 media3-exoplayer（避免重复类）；dash/hls/smoothstreaming 保持 maven，
    // 但需排除其传递依赖的 exoplayer（本地源码提供）。
    fun excludeLocalExoplayer(module: String) {
        implementation("androidx.media3:$module:$exoplayerVersion") {
            exclude(group = "androidx.media3", module = "media3-exoplayer")
        }
    }
    // 本地源码版 exoplayer 依赖的其余 media3 模块（common/container/datasource/decoder/extractor）由 maven 提供
    implementation("androidx.media3:media3-common:$exoplayerVersion")
    implementation("androidx.media3:media3-container:$exoplayerVersion")
    implementation("androidx.media3:media3-database:$exoplayerVersion")
    implementation("androidx.media3:media3-datasource:$exoplayerVersion")
    implementation("androidx.media3:media3-decoder:$exoplayerVersion")
    implementation("androidx.media3:media3-extractor:$exoplayerVersion")
    // 本地 exoplayer 源码所需的注解依赖（原 maven media3-exoplayer 自带传递依赖）
    compileOnly("com.google.errorprone:error_prone_annotations:2.28.0")
    compileOnly("org.checkerframework:checker-qual:3.43.0")
    // MD3Music fork: AudioFocusRequestCompat（自动携带 ACCEPTS_DUCKING，焦点事件可达）
    implementation("androidx.media:media:1.7.0")
    // MD3Music fork: media3-session 已本地化（src/main/java/androidx/media3/session/**），
    // 用于创建 MediaSession 关联 ExoPlayer，使小米等系统识别播放器、不再自动 duck。
    // 不引入 maven media3-session（本地源码编译提供，避免重复类）。
    excludeLocalExoplayer("media3-exoplayer-dash")
    excludeLocalExoplayer("media3-exoplayer-hls")
    excludeLocalExoplayer("media3-exoplayer-smoothstreaming")
}
