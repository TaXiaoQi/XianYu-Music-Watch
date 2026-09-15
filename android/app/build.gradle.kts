import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名：读取 android/key.properties（已 gitignore，含随机密码）。
// 缺失时回退 debug 签名，保证开发/CI 环境 `flutter run --release` 仍可构建。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.xianyumusic.watch"
    // 36：shared_preferences_android/wearable_rotary 要求的最低编译 SDK。
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.xianyumusic.watch"
        // Wear OS 2.1+（API 28）起，兼容无 GMS 国表（OPPO/小米 Wear OS）
        minSdk = 28
        targetSdk = 34
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // ABI 打包策略（disable-abi-filtering=true 会拦掉 Flutter 插件的自动过滤，这里自己读）：
        // - `--target-platform android-arm64` → 仅 arm64（v8 包）
        // - `--target-platform android-arm`   → 仅 armv7（v7 包，32 位国表如华为 GLL-AL00）
        // - 不传 → 双 ABI 全量包；flutter run 按设备 ABI 自动传，无需关心。
        val tpAbis = (project.findProperty("target-platform") as String?)
            ?.split(',')
            ?.mapNotNull { tp ->
                when (tp.trim()) {
                    "android-arm64" -> "arm64-v8a"
                    "android-arm" -> "armeabi-v7a"
                    else -> null
                }
            }
            ?.toSet()
            ?: emptySet()
        ndk {
            abiFilters += if (tpAbis.isNotEmpty()) tpAbis else setOf("arm64-v8a", "armeabi-v7a")
        }
    }

    // 安装包压缩：.so 在 APK 内 deflate（安装时解压到本地），体积约省 40%。
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String? ?: ""
            keyPassword = keystoreProperties["keyPassword"] as String? ?: ""
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String? ?: ""
        }
    }

    buildTypes {
        debug {
            // debug 包名加 .debug 后缀：与正式版（com.xianyumusic.watch）共存，
            // flutter run 不再顶掉正式安装包（与移动端同款做法）
            applicationIdSuffix = ".debug"
            // debug 显示名加「·测试」后缀，多任务/桌面与正式版一眼区分
            manifestPlaceholders["appLabel"] = "腕上弦予·测试"
        }
        release {
            manifestPlaceholders["appLabel"] = "腕上弦予"
            // key.properties 存在时用专用 release 密钥签名，缺失时回退 debug 签名
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Wear OS 环境模式（AmbientLifecycleObserver，MainActivity 使用）。
    implementation("androidx.wear:wear:1.3.0")
}

// 禁用 lint 关键检查 task（避免构建时从 dl.google.com 下载 lint 依赖超时）
tasks.configureEach {
    if (name.startsWith("lintVital")) {
        enabled = false
    }
}

// Rust 自动编译钩子：flutter run / flutter build apk 时自动检测并编译
// Rust（绑定 + .so，见 scripts/gradle-rust-hook.ps1）。与移动端同款脚本。
// 工程内已有 libxianyu_core.so 时钩子自动跳过编译（检测产物新旧），
// 如需完全跳过设置 XIANMU_SKIP_RUST=1。
val isWindows = System.getProperty("os.name").lowercase().contains("windows")
tasks.register("rustHook") {
    doLast {
        val hookCmd = if (isWindows) {
            listOf(
                "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                "-File", rootProject.projectDir.resolve("../scripts/gradle-rust-hook.ps1").absolutePath,
            )
        } else {
            listOf(
                "bash", rootProject.projectDir.resolve("../scripts/gradle-rust-hook.sh").absolutePath,
            )
        }
        val proc = ProcessBuilder(hookCmd).apply {
            directory(projectDir)
            inheritIO()
        }.start()
        val code = proc.waitFor()
        if (code != 0) {
            val flMode = if (gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }) {
                "release"
            } else {
                "debug"
            }
            if (code == 3 && flMode == "release") {
                logger.lifecycle("[rustHook] 正式包：Rust 绑定已重新生成，随本次构建直接生效")
            } else {
                throw GradleException(
                    "Rust 钩子退出码 $code：若上方提示 API 绑定已更新，重新运行一次 flutter run / flutter build 即可",
                )
            }
        }
    }
}
tasks.matching { it.name == "preBuild" }.configureEach {
    dependsOn("rustHook")
}

// 正式包自动归档：assembleRelease 完成后把 release APK（arm64+armv7 双 ABI）
// 复制到 releases/android/弦予音乐v<版本>-Watch-<架构>.apk（预发布版本名自带
// -betaN 后缀），让裸 `flutter build apk --release` 一条命令出正式包并归档
// （与移动端同款钩子）。
tasks.register("archiveReleaseApk") {
    group = "build"
    doLast {
        val apk = layout.buildDirectory.file("outputs/flutter-apk/app-release.apk").get().asFile
        if (!apk.exists()) return@doLast
        val version = runCatching { flutter.versionName }.getOrDefault("0.0.0")
        val projectRoot = rootProject.projectDir.parentFile
        val releasesAndroidDir = File(File(projectRoot, "releases"), "android")
        releasesAndroidDir.mkdirs()
        // 架构后缀：XIANMU_RUST_ABI（包装函数写入）v7→arm32 / v8→arm64；
        // 未设时 rust 与 Flutter 目标均为双 ABI 全编 → -arm32-arm64。
        // 与移动端 -Mobile-arm64、鸿蒙 -Mobile-arm64/-x86 命名体系对齐。
        val arch = when (System.getenv("XIANMU_RUST_ABI")) {
            "v7" -> "arm32"
            "v8" -> "arm64"
            else -> "arm32-arm64"
        }
        val dest = File(releasesAndroidDir, "弦予音乐v$version-Watch-$arch.apk")
        apk.copyTo(dest, overwrite = true)
        logger.lifecycle("已归档正式安装包: ${dest.absolutePath} (${"%.1f".format(dest.length() / 1024.0 / 1024.0)} MB)")
    }
}
tasks.matching { it.name == "assembleRelease" }.configureEach {
    finalizedBy("archiveReleaseApk")
}
