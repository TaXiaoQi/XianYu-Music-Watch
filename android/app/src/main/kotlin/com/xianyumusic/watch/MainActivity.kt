package com.xianyumusic.watch

import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.view.MotionEvent
import android.view.WindowManager
import android.view.ViewTreeObserver
import androidx.wear.ambient.AmbientLifecycleObserver
import com.ryanheise.audioservice.AudioServiceActivity
import com.samsung.wearable_rotary.WearableRotaryPlugin
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
        excludeEdgeBackGesture()
    }

    /**
     * 排除系统边缘返回手势区（API 29+）：表屏太小，页面横滑几乎必然从边缘
     * 起手，会被边缘返回手势抢走直接退出应用（表现即「左滑退出软件」）。
     * 参考网易云手表版：排除几乎全屏，仅保留左侧 20dp 窄条给系统返回——
     * 根路由返回经 PopScope 走 moveTaskToBack 后台驻留，二级页照常弹栈。
     * 系统对单边手势排除有 200dp 高度上限，表屏超出部分（底部极窄区）仍可能
     * 触发返回，可接受。
     */
    private fun excludeEdgeBackGesture() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val decor = window.decorView
        val applyExclusion = Runnable {
            val strip = (resources.displayMetrics.density * 20).toInt()
            decor.setSystemGestureExclusionRects(
                listOf(
                    Rect(
                        strip,
                        0,
                        decor.width.coerceAtLeast(strip + 1),
                        decor.height.coerceAtLeast(1),
                    ),
                ),
            )
        }
        decor.viewTreeObserver.addOnGlobalLayoutListener(
            ViewTreeObserver.OnGlobalLayoutListener { applyExclusion.run() },
        )
        decor.post(applyExclusion)
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
        // 系统返回（手表左滑手势）：根路由无页面可弹时退到表盘后台驻留，
        // 不走 Flutter 默认 SystemNavigator.pop 的 finish()（那会真·退出应用，
        // 重开要冷启动）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xianyu/system_nav")
            .setMethodCallHandler { call, result ->
                if (call.method == "moveTaskToBack") {
                    runOnUiThread {
                        moveTaskToBack(true)
                        result.success(null)
                    }
                } else {
                    result.notImplemented()
                }
            }
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

    /**
     * 表冠旋转事件转发：wearable_rotary 插件不会自己挂监听，要求宿主
     * Activity 重写 dispatchGenericMotionEvent 手动喂给它（SOURCE_ROTARY_
     * ENCODER 的 ACTION_SCROLL 才会被消费）。不转发 = 表冠事件永远进不了
     * Flutter（列表滚不动、播放页调不了音量）。
     */
    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean =
        if (WearableRotaryPlugin.onGenericMotionEvent(event)) {
            true
        } else {
            super.dispatchGenericMotionEvent(event)
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
