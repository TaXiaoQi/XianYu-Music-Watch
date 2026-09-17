package com.xianyumusic.watch

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 联动模式低占用常驻前台服务：仅用一个 IMPORTANCE_LOW 无声常驻通知把进程
 * 提到前台服务级保活，让蓝牙/云中继链路在退后台后仍存活、手机播放可快速唤起。
 *
 * foregroundServiceType=connectedDevice（蓝牙联动语义，API 34+ 需配套
 * FOREGROUND_SERVICE_CONNECTED_DEVICE 权限）。进程随应用重启（联动→独立
 * 切换 restartApp 彻底重拉）直接消失，无需显式 stop。
 */
class KeepAliveService : Service() {

    companion object {
        private const val CHANNEL_ID = "link_keepalive"
        private const val CHANNEL_NAME = "设备联动常驻"
        private const val NOTIF_ID = 1001
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        // 前台服务类型需在启动早期固定（API 29+ 支持按类型声明）。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            @Suppress("DEPRECATION")
            startForeground(NOTIF_ID, notification)
        }
        // 进程被系统回收后，START_STICKY 会重建本服务（此时 Activity/Flutter
        // 均已不在、RFCOMM/云中继链路全断）：立即拉起主 Activity，让整套
        // 链路复活（Dart link_provider 冷启动自动重连手机），手机播放时才能
        // 再次唤起。正常前台启动路径 Activity 已在，hasActivity() 为 true，
        // 不会重复拉起。
        if (!WatchLinkClient.hasActivity()) {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            )
        }
        // START_STICKY：进程被系统回收后尽力重建，保住链路驻留。
        return START_STICKY
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            nm?.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    setShowBadge(false)
                    description = "保持设备联动后台连接，手机播放可快速唤起"
                },
            )
        }
        // 点击通知拉起应用主界面（回应用户操作入口）。
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_MIN)
        }
        return builder
            .setContentTitle("弦予音乐 · 设备联动已就绪")
            .setContentText("保持后台连接，手机播放可快速唤起")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(contentIntent)
            .build()
    }
}