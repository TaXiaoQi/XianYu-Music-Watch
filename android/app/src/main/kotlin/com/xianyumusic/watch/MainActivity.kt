package com.xianyumusic.watch

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Intent
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
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
                when (call.method) {
                    "moveTaskToBack" -> {
                        runOnUiThread {
                            moveTaskToBack(true)
                            result.success(null)
                        }
                    }
                    // 联动↔独立模式切换：Dart 已落盘新模式，此处杀掉进程并由
                    // AlarmManager 150ms 后拉起启动 Intent——进程彻底重拉、
                    // 新进程按新模式初始化。等价 ohos 的 restartApp。
                    "restartApp" -> {
                        runOnUiThread {
                            val launch = packageManager.getLaunchIntentForPackage(packageName)
                            val pending = PendingIntent.getActivity(
                                this,
                                0,
                                launch,
                                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                            )
                            getSystemService(AlarmManager::class.java).set(
                                AlarmManager.RTC,
                                System.currentTimeMillis() + 150,
                                pending,
                            )
                            Process.killProcess(Process.myPid())
                            // 进程即将死亡，result 大概率送不到 Dart，无碍。
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
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
        // 触觉反馈直振：Flutter HapticFeedback.selectionClick 走
        // View.performHapticFeedback(CLOCK_TICK)，受系统「触摸时振动」开关
        // 影响，华为表兼容层上常被静默忽略（用户体感无振动）。这里用
        // Vibrator 直接打轻脉冲，不受该开关影响。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xianyu/haptics")
            .setMethodCallHandler { call, result ->
                if (call.method == "tick") {
                    runOnUiThread { result.success(hapticTick()) }
                } else {
                    result.notImplemented()
                }
            }
        // 屏形探测（圆表/方表）：官方判定 resources.configuration.isScreenRound，
        // Dart 侧据此切换圆屏阶梯列表 / 方屏全宽列表两套布局。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xianyu/screen_shape")
            .setMethodCallHandler { call, result ->
                if (call.method == "isRound") {
                    result.success(resources.configuration.isScreenRound)
                } else {
                    result.notImplemented()
                }
            }
        // 联动模式低占用常驻保活：联动进程启动时经此启动前台服务，把进程
        // 提到前台服务级驻留，退后台后蓝牙/云链路仍存活。startForegroundService
        // 可能受后台限制抛异常（SecurityException/IllegalStateException），
        // 返回 false 让 Dart 静默，不阻断联动启动。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xianyu/keep_alive")
            .setMethodCallHandler { call, result ->
                if (call.method == "start") {
                    runOnUiThread {
                        val ok = runCatching {
                            startForegroundService(Intent(this, KeepAliveService::class.java))
                            true
                        }.getOrDefault(false)
                        result.success(ok)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    /** 表冠档位/点选轻刻度（系统级轻微，类似触摸反馈，时长 ~10ms、振幅
     * ~36/255 ≈ 14%，贴近 WearOS CLOCK_TICK 的极轻单脉冲）。返回
     * false = 设备无振动器。 */
    private fun hapticTick(): Boolean {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(VIBRATOR_SERVICE) as? Vibrator
        } ?: return false
        if (!vibrator.hasVibrator()) return false
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val amplitude =
                    if (vibrator.hasAmplitudeControl()) 36 else VibrationEffect.DEFAULT_AMPLITUDE
                vibrator.vibrate(VibrationEffect.createOneShot(10, amplitude))
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(10)
            }
            true
        }.getOrDefault(false)
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
