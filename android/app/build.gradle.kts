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
        // 谷歌 Data Layer 未接入（国内两端均无 GMS，零覆盖），无需与手机端同包名；
        // 加 .app 后缀与手机端 com.xianyumusic.app 品牌对齐
        applicationId = "com.xianyumusic.watch.app"
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

    // 渠道维度：prod 正式包 / beta 测试包。加 flavor 后构建需显式指定：
    // `flutter build apk --release --flavor prod|beta`（flutter run 同理）。
    // 注意 flavor 不能叫 test*（AGP 保留前缀，构建直接报错），故用 beta。
    flavorDimensions += "channel"
    productFlavors {
        create("prod") {
            dimension = "channel"
            // 正式包：包名/应用名与历史版本完全一致（原 release buildType 的
            // appLabel 移到此处，flavor 级占位符不会被更高优先级覆盖）
            manifestPlaceholders["appLabel"] = "腕上弦予"
        }
        create("beta") {
            dimension = "channel"
            // 测试包：包名加 .test 后缀、版本名加 -test 后缀、应用名加「·测试」，
            // 与正式包并存安装互不覆盖（与 debug 后缀方案同款做法）
            applicationIdSuffix = ".test"
            versionNameSuffix = "-test"
            manifestPlaceholders["appLabel"] = "腕上弦予·测试"
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
            // debug 包名加 .debug 后缀：与正式版（com.xianyumusic.watch.app）共存，
            // flutter run 不再顶掉正式安装包（与移动端同款做法）
            applicationIdSuffix = ".debug"
            // debug 显示名加「·测试」后缀，多任务/桌面与正式版一眼区分
            // （buildType 级占位符优先级高于 flavor，debug 两种 flavor 均显示·测试）
            manifestPlaceholders["appLabel"] = "腕上弦予·测试"
        }
        release {
            // 应用名占位符已移至 prod/test flavor（buildType 级会覆盖 flavor 级，
            // 留在这里会让测试包也显示正式名）；签名配置保持不变
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

// 正式/测试包自动归档：assemble{Prod,Beta}Release 完成后把对应 release APK
// （arm64+armv7 双 ABI）复制到 releases/android/（预发布版本名自带 -betaN 后缀），
// 让 `flutter build apk --release --flavor prod|beta` 一条命令出包并归档：
// - prod：腕上弦予v<版本>-Watch-<架构>.apk（与历史命名一致）
// - beta：腕上弦予v<版本>-Watch-test-<架构>.apk（归档名沿用 -test，与正式包区分）
// （与移动端同款钩子）
tasks.register("archiveReleaseApk") {
    group = "build"
    doLast {
        // flavor 从本次命令行任务名推断（rustHook 同款思路）；直接执行本任务时默认 prod
        val taskNames = gradle.startParameter.taskNames
        val flavor = if (taskNames.any { it.contains("BetaRelease", ignoreCase = true) }) {
            "beta"
        } else {
            "prod"
        }
        val apk = layout.buildDirectory
            .file("outputs/flutter-apk/app-$flavor-release.apk").get().asFile
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
        // 归档名沿用 -test 标记（与包名 .test 后缀、版本 -test 后缀一致）
        val flavorTag = if (flavor == "beta") "-test" else ""
        val dest = File(releasesAndroidDir, "腕上弦予v$version-Watch$flavorTag-$arch.apk")
        apk.copyTo(dest, overwrite = true)
        logger.lifecycle("已归档${if (flavor == "beta") "测试" else "正式"}安装包: ${dest.absolutePath} (${"%.1f".format(dest.length() / 1024.0 / 1024.0)} MB)")
        // 混淆符号归档（gen_snapshot --save-debugging-info=app.symbols 落项目根，
        // 供 flutter symbolize -d app.symbols 还原混淆堆栈；与移动端同款）
        val sym = File(projectRoot, "app.symbols")
        if (sym.exists()) {
            val symDir = File(File(projectRoot, "releases"), "symbols/$version")
            symDir.mkdirs()
            sym.copyTo(File(symDir, "app.symbols"), overwrite = true)
            sym.delete()
            logger.lifecycle("已归档混淆符号: ${symDir.absolutePath}")
        }
    }
}
tasks.matching { it.name == "assembleProdRelease" || it.name == "assembleBetaRelease" }
    .configureEach {
        finalizedBy("archiveReleaseApk")
    }
