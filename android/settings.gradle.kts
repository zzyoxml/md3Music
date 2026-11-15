pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // AGP 9.1.1：Flutter 3.50（stable）要求 AGP >= 9.1.1，CI 用 stable 浮动渠道会
    // 浮动升级；配合 Gradle wrapper 9.3.1 使用。
    id("com.android.application") version "9.1.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
    // Kotlin 2.x 内置的 Compose 编译器插件（版本与 Kotlin 一致）
    id("org.jetbrains.kotlin.plugin.compose") version "2.3.20" apply false
}

// SuperLyricApi / lyricon 等依赖托管在 JitPack，
// 国内镜像源（aliyun）不代理 JitPack，必须显式在 settings 中声明。
dependencyResolutionManagement {
    repositoriesMode.set(org.gradle.api.initialization.resolve.RepositoriesMode.PREFER_PROJECT)
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}

include(":app")
