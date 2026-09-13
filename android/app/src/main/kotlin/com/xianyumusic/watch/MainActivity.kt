package com.xianyumusic.watch

import android.os.Bundle
import androidx.wear.ambient.AmbientLifecycleObserver
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var ambientChannel: MethodChannel? = null
    private var ambientObserver: AmbientLifecycleObserver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Wear OS 环境模式（熄屏常显）：进出 ambient 经 MethodChannel 通知 Dart，
        // 由 Dart 侧压暗 UI、暂停秒级进度刷新（省电 + OLED 防烧屏）。
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        WatchLinkClient.register(flutterEngine.dartExecutor.binaryMessenger, this)
        ambientChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xianyu/ambient")
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
