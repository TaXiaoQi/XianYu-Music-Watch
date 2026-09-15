package com.xianyumusic.watch

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 腕上端手表联动 RFCOMM 传输层（手表端 = 客户端 + 反向服务端）。
 *
 * 职责边界：Kotlin 只做蓝牙 SPP 字节管道（connect / accept / 读写 / 断连感知），
 * 帧编解码、CRC、分片重组、心跳（3s ping / 10s 无帧判死）、重连指数退避
 * 与协议语义全部在 Dart 侧 `lib/src/link/`（与手机端同一份协议实现）。
 *
 * 连接模型：单手机场景，connect(address) 异步发起一次连接（成败经
 * onConnection 回传），断开后由 Dart 决策退避重连；disconnect 关闭套接字
 * 并中断连接线程，幂等可重入。
 *
 * 反向配对（手机端发起）：startServer 监听同一 SPP UUID，手机作为客户端
 * 连入后先挂起（pending）并回调 onIncomingPair，由 Dart 弹「允许/拒绝」
 * 确认后 acceptPair 采纳（走与 connect 成功相同的 onConnection 流程）或
 * rejectPair 拒绝。已连接/已有待确认时新入连接直接关闭。
 */
object WatchLinkClient {
    const val CHANNEL = "xianyu/watch_link"

    // 与 lib/src/link/protocol.dart 的 kWatchLinkServiceUuid 严格一致（手机端 accept）。
    private val SERVICE_UUID: UUID = UUID.fromString("f7a24b6c-9d3e-4f8a-b1c2-2e5d8a7f6b3a")

    private const val READ_BUFFER = 4096
    private const val PERMISSION_REQUEST_CODE = 4301

    private var channel: MethodChannel? = null
    private var activity: android.app.Activity? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var socket: BluetoothSocket? = null
    private var out: OutputStream? = null
    private val writeLock = Any()

    /** connect 进行中标志（防止并发连接线程叠加）。 */
    private val connecting = AtomicBoolean(false)

    /** 反向配对服务端（手机端主动发起时手表侧 accept）。 */
    private var serverSocket: BluetoothServerSocket? = null
    private val serverRunning = AtomicBoolean(false)

    /** 手机端发起、等待手表确认的入站连接。 */
    private var pending: BluetoothSocket? = null

    fun register(messenger: BinaryMessenger, activity: android.app.Activity) {
        this.activity = activity
        channel = MethodChannel(messenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "pairedDevices" -> result.success(pairedDevices())
                    "connect" -> {
                        val address = call.argument<String>("address") ?: ""
                        connect(address)
                        result.success(null)
                    }
                    "disconnect" -> {
                        disconnect()
                        result.success(null)
                    }
                    "send" -> {
                        val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
                        send(bytes)
                        result.success(null)
                    }
                    "startServer" -> {
                        startServer()
                        result.success(null)
                    }
                    "acceptPair" -> {
                        acceptPair()
                        result.success(null)
                    }
                    "rejectPair" -> {
                        rejectPair()
                        result.success(null)
                    }
                    "hasPermission" -> result.success(hasPermission())
                    "requestPermission" -> {
                        requestPermission()
                        result.success(null)
                    }
                    "notifyNowPlaying" -> {
                        val title = call.argument<String>("title") ?: ""
                        val artist = call.argument<String>("artist") ?: ""
                        notifyNowPlaying(title, artist)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /** 蓝牙运行时权限是否已授予（Android 12+ 需 BLUETOOTH_CONNECT；旧版清单声明即有）。 */
    fun hasPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val ctx = activity ?: return false
        return ContextCompat.checkSelfPermission(ctx, Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED
    }

    /** 发起运行时权限请求（BLUETOOTH_CONNECT；Android 13+ 附带 POST_NOTIFICATIONS）。 */
    fun requestPermission() {
        val act = activity ?: return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            emitPermission(true)
            return
        }
        if (hasPermission()) {
            emitPermission(true)
            return
        }
        val perms = mutableListOf(Manifest.permission.BLUETOOTH_CONNECT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            perms.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        act.requestPermissions(perms.toTypedArray(), PERMISSION_REQUEST_CODE)
    }

    /** MainActivity.onRequestPermissionsResult 转发进来。 */
    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PERMISSION_REQUEST_CODE) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        emitPermission(granted)
    }

    private fun emitPermission(granted: Boolean) {
        mainHandler.post {
            runCatching { channel?.invokeMethod("onPermission", granted) }
        }
    }

    /**
     * 高德腕上式拉起：手机开播且手表在后台时，发 fullScreenIntent 高优先级
     * 通知（规避 Wear OS 3+ 后台启动限制），点击直进控制页。应用在前台
     * （窗口持有焦点）时静默跳过，由 UI 直接切页。
     */
    fun notifyNowPlaying(title: String, artist: String) {
        val act = activity ?: return
        if (act.hasWindowFocus()) return
        try {
            val nm = act.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channelId = "watch_nowplaying"
            nm.createNotificationChannel(
                NotificationChannel(
                    channelId, "手机正在播放", NotificationManager.IMPORTANCE_HIGH,
                ).apply { setShowBadge(false) },
            )
            val fullScreen = PendingIntent.getActivity(
                act, 0,
                Intent(act, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val notif = Notification.Builder(act, channelId)
                .setContentTitle(title.ifEmpty { "手机正在播放" })
                .setContentText(artist)
                .setSmallIcon(act.applicationInfo.icon)
                .setContentIntent(fullScreen)
                .setFullScreenIntent(fullScreen, true)
                .setCategory(Notification.CATEGORY_TRANSPORT)
                .setAutoCancel(true)
                .build()
            nm.notify(NOW_PLAYING_NOTIFICATION_ID, notif)
        } catch (_: Exception) {
        }
    }

    private const val NOW_PLAYING_NOTIFICATION_ID = 1001

    private fun adapter(): BluetoothAdapter? {
        val ctx = activity ?: return null
        val manager = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        return manager?.adapter
    }

    /** 已配对设备列表 [{address, name}]（无权限/无适配器返回空）。 */
    private fun pairedDevices(): List<Map<String, String>> {
        val adapter = adapter() ?: return emptyList()
        if (!hasPermission()) return emptyList()
        return try {
            adapter.bondedDevices.map { dev ->
                mapOf(
                    "address" to dev.address,
                    "name" to (try { dev.name ?: dev.address } catch (_: Exception) { dev.address }),
                )
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    /** 连接指定地址（异步，单飞）。成败与断连均经 onConnection 回传。 */
    fun connect(address: String) {
        if (address.isEmpty()) return
        if (!connecting.compareAndSet(false, true)) return
        if (!hasPermission()) {
            connecting.set(false)
            return
        }
        val adapter = adapter()
        if (adapter == null || !adapter.isEnabled) {
            connecting.set(false)
            emitConnection(false, "")
            return
        }
        Thread {
            var sock: BluetoothSocket? = null
            try {
                val dev = adapter.getRemoteDevice(address)
                runCatching { adapter.cancelDiscovery() }
                sock = dev.createRfcommSocketToServiceRecord(SERVICE_UUID)
                synchronized(writeLock) { socket = sock }
                sock.connect() // 阻塞直至建立或抛 IOException
                synchronized(writeLock) {
                    out = sock.outputStream
                }
                connecting.set(false)
                val name = try { dev.name ?: address } catch (_: Exception) { address }
                emitConnection(true, name)
                readLoop(sock)
            } catch (_: Exception) {
                connecting.set(false)
                runCatching { sock?.close() }
                synchronized(writeLock) {
                    if (socket === sock) {
                        socket = null
                        out = null
                    }
                }
                emitConnection(false, "")
            }
        }.apply { setName("xy-watch-connect") }.start()
    }

    /** 断开连接（幂等）。不发 onConnection：Dart 侧主动断开自知状态。 */
    @Synchronized
    fun disconnect() {
        val sock = synchronized(writeLock) {
            val s = socket
            socket = null
            out = null
            s
        }
        runCatching { sock?.close() } // 关闭会使阻塞中的 connect()/read() 抛异常退出
    }

    /**
     * 启动反向配对服务端（幂等）：监听同一 SPP UUID，手机作为客户端连入时
     * 挂起等待手表确认。应用存活期间常开（Dart init 调一次）。
     */
    @Synchronized
    fun startServer() {
        if (serverRunning.get()) return
        val adapter = adapter() ?: return
        if (!hasPermission()) return
        val server = try {
            adapter.listenUsingRfcommWithServiceRecord("XianYuWatchLink", SERVICE_UUID)
        } catch (_: Exception) {
            return
        }
        serverSocket = server
        serverRunning.set(true)
        Thread {
            while (serverRunning.get()) {
                val sock = try {
                    server.accept()
                } catch (_: IOException) {
                    break // socket 被关闭
                }
                if (!serverRunning.get()) {
                    runCatching { sock.close() }
                    break
                }
                onIncoming(sock)
            }
        }.apply { setName("xy-watch-accept") }.start()
    }

    /** 处理手机端主动连入：已连接/已有待确认时直接关闭，否则挂起并请求确认。 */
    private fun onIncoming(sock: BluetoothSocket) {
        synchronized(writeLock) {
            if (socket != null || pending != null) {
                runCatching { sock.close() }
                return
            }
            pending = sock
        }
        val name = try { sock.remoteDevice.name ?: "手机" } catch (_: Exception) { "手机" }
        val address = try { sock.remoteDevice.address ?: "" } catch (_: Exception) { "" }
        mainHandler.post {
            runCatching {
                channel?.invokeMethod("onIncomingPair", mapOf("name" to name, "address" to address))
            }
        }
    }

    /** 采纳挂起的入站连接（手表确认允许）：与 connect 成功同流程。 */
    fun acceptPair() {
        val sock = synchronized(writeLock) {
            val s = pending
            pending = null
            s
        } ?: return
        val name = try { sock.remoteDevice.name ?: "手机" } catch (_: Exception) { "手机" }
        synchronized(writeLock) {
            socket = sock
            out = try { sock.outputStream } catch (_: Exception) { null }
        }
        emitConnection(true, name)
        Thread { readLoop(sock) }.apply { setName("xy-watch-read-accepted") }.start()
    }

    /** 拒绝挂起的入站连接（手表确认拒绝）。 */
    fun rejectPair() {
        val sock = synchronized(writeLock) {
            val s = pending
            pending = null
            s
        }
        runCatching { sock?.close() }
    }

    /** 读取循环：断连时统一上报 onConnection(false)（Dart 据此退避重连）。 */
    private fun readLoop(sock: BluetoothSocket) {
        val buf = ByteArray(READ_BUFFER)
        try {
            val ins: InputStream = sock.inputStream
            while (true) {
                val n = ins.read(buf)
                if (n < 0) break
                if (n > 0) {
                    val chunk = buf.copyOf(n)
                    mainHandler.post {
                        runCatching { channel?.invokeMethod("onRaw", chunk) }
                    }
                }
            }
        } catch (_: Exception) {
            // 读异常 = 连接断开
        } finally {
            val wasCurrent = synchronized(writeLock) { socket === sock }
            runCatching { sock.close() }
            if (wasCurrent) {
                synchronized(writeLock) {
                    if (socket === sock) {
                        socket = null
                        out = null
                    }
                }
                emitConnection(false, "")
            }
        }
    }

    /** 发送原始字节（帧由 Dart 层编码；写失败静默，断连由读线程统一上报）。 */
    fun send(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        val stream = synchronized(writeLock) { out } ?: return
        try {
            synchronized(writeLock) { stream.write(bytes); stream.flush() }
        } catch (_: Exception) {
        }
    }

    private fun emitConnection(connected: Boolean, name: String) {
        mainHandler.post {
            runCatching {
                channel?.invokeMethod("onConnection", mapOf("connected" to connected, "name" to name))
            }
        }
    }
}
