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
import android.view.ViewConfiguration
import android.view.WindowManager
import android.view.ViewTreeObserver
import androidx.wear.ambient.AmbientLifecycleObserver
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

// 继承 AudioServiceActivity（FlutterActivity 子类）：audio_service 后台媒体
// 前台服务的原生要求，否则媒体通知初始化报 IllegalStateException。
class MainActivity : AudioServiceActivity() {

    private var ambientChannel: MethodChannel? = null
    private var ambientObserver: AmbientLifecycleObserver? = null
    private var rotarySink: EventChannel.EventSink? = null

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

    /**
     * 圆/方屏判定：以官方 isScreenRound 为主，再按整屏宽高比近似方形兜底 ——
     * 判据对齐鸿蒙端 display 宽高比 <10%（近似方形）即圆屏。部分 WearOS 圆表
     * 的 configuration.isScreenRound 会误报 false，用整屏宽高比补齐后，
     * 安卓端阶梯列表样式与鸿蒙端一致。
     */
    private fun isRoundScreen(): Boolean {
        if (resources.configuration.isScreenRound) return true
        val real = android.graphics.Point()
        @Suppress("DEPRECATION")
        windowManager.defaultDisplay.getRealSize(real)
        if (real.x <= 0 || real.y <= 0) return resources.configuration.isScreenRound
        val w = real.x.toFloat()
        val h = real.y.toFloat()
        return Math.abs(w - h) / Math.max(w, h) < 0.10f
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        WatchLinkClient.register(flutterEngine.dartExecutor.binaryMessenger, this)
        // 表冠旋转输入：Dart 侧 third_party/wearable_rotary 统一监听
        // "xianyu/rotary" EventChannel（鸿蒙 EntryAbility.ets 亦注册同名通道），
        // 这里注册 Android 端实现，把 Wear OS rotary 事件以「一格像素增量」
        // 转发过去。见 dispatchGenericMotionEvent。
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "xianyu/rotary")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    rotarySink = events
                }

                override fun onCancel(arguments: Any?) {
                    rotarySink = null
                }
            })
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
                    result.success(isRoundScreen())
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
     * 表冠旋转事件原生转发：SOURCE_ROTARY_ENCODER 的 ACTION_SCROLL 即表冠
     * 滚动，取轴值增量 × 系统纵向滚动系数（px/档，≈48）经 "xianyu/rotary"
     * EventChannel 发给 Dart。注意 ACTION_SCROLL 的轴值语义是「档位数」
     * （一格 ≈ ±1.0）而非像素，与上游 Samsung 插件
     * getScaledVerticalScrollFactor 同为档位→像素换算；漏乘此系数时一格
     * 只值 1px，Dart 端按一格 48px 消费等效无响应。
     * 与鸿蒙端 EntryAbility 转发 onDigitalCrown 走同一通道/同一协议，
     * Dart 侧 third_party/wearable_rotary 无需感知平台差异。
     * 不再反射 Samsung WearableRotaryPlugin：本地 shim 依赖态下该类不存在，
     * 反射必然失败（即此前 Android 表冠断链的根因）。
     */
    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        if (rotarySink != null && event.action == MotionEvent.ACTION_SCROLL) {
            // Wear OS 表冠滚动轴随厂商/系统版本走 AXIS_VSCROLL /
            // AXIS_HSCROLL / AXIS_SCROLL 之一，逐轴取首个非零值即可，避免
            // 引入 RotaryEncoder 依赖。取负号以符合「顺→正向滚动」。
            var delta = -event.getAxisValue(MotionEvent.AXIS_VSCROLL)
            if (delta == 0f) delta = -event.getAxisValue(MotionEvent.AXIS_HSCROLL)
            if (delta == 0f) delta = -event.getAxisValue(MotionEvent.AXIS_SCROLL)
            if (delta != 0f) {
                val px = delta * scrollFactorPx
                val sink = rotarySink
                runOnUiThread { runCatching { sink?.success(px) } }
                return true
            }
        }
        return super.dispatchGenericMotionEvent(event)
    }

    /** 档位→像素换算系数：系统纵向滚动一格的像素数（minSdk 28 ≥ API 26，
     * 可直接用 ViewConfiguration API，等价上游插件的 compat 版本）。 */
    private val scrollFactorPx: Float by lazy {
        ViewConfiguration.get(this).scaledVerticalScrollFactor
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
