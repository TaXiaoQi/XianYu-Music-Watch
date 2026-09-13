package com.xianyumusic.watch

import android.os.Bundle
import android.view.WindowManager
import androidx.wear.ambient.AmbientLifecycleObserver
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// 继承 AudioServiceActivity（FlutterActivity 子类）：audio_service 后台媒体
// 前台服务的原生要求，否则媒体通知初始化报 IllegalStateException。
class MainActivity : AudioServiceActivity() {

    private var ambientChannel: MethodChannel? = null
    private var ambientObserver: AmbientLifecycleObserver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Wear OS 环境模式（熄屏常显）：进出 ambient 经 MethodChannel 通知 Dart，
        // 由 Dart 侧压暗 UI、暂停秒级进度刷新（省电 + OLED 防烧屏）。
        // 仅在有 wearable 共享库的设备（真手表）注册；无 GMS 手机上该库缺失，
        // AmbientLifecycleObserver 构造即抛异常，须先探测再注册。
        if (hasWearableSharedLibrary()) {
            ambientObserver = AmbientLifecycleObserver(
                this,
                object : AmbientLifecycleObserver.AmbientLifecycleCallback {
                    override fun onEnterAmbient(ambientDetails: AmbientLifecycleObserver.AmbientDetails) {
                        emitAmbient(true)
                    }

                    override fun onExitAmbient() {
                        emitAmbient(false)
                    }

                    override fun onUpdateAmbient() {
                        // 常显周期刷新：本应用无秒级动画需求，保持静态显示最省电
                    }
                },
            )
            lifecycle.addObserver(ambientObserver!!)
        }
    }

    private fun hasWearableSharedLibrary(): Boolean =
        runCatching {
            packageManager.getSharedLibraries(0)
                ?.any { it.name == "com.google.android.wearable" } == true
        }.getOrDefault(false)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        WatchLinkClient.register(flutterEngine.dartExecutor.binaryMessenger, this)
        ambientChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xianyu/ambient")
        // 屏幕常亮开关（设置-播放）：FLAG_KEEP_SCREEN_ON 仅作用于本窗口。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xianyu/keep_screen")
            .setMethodCallHandler { call, result ->
                if (call.method == "set") {
                    val enable = call.argument<Boolean>("enable") ?: true
                    runOnUiThread {
                        if (enable) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        WatchLinkClient.onPermissionResult(requestCode, grantResults)
    }

    private fun emitAmbient(entering: Boolean) {
        runOnUiThread {
            runCatching { ambientChannel?.invokeMethod("onAmbient", entering) }
        }
    }
}
