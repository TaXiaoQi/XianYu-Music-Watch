import 'package:flutter/services.dart';

/// 联动模式低占用常驻保活：请求原生把进程提到「前台服务级」驻留
/// （Android 前台服务 + IMPORTANCE_LOW 无声通知；ohos
/// backgroundTaskManager 连续任务），使退后台后蓝牙/云中继链路仍存活、
/// 手机播放可快速唤起。失败静默，只尽力而为、不阻断启动。
///
/// 仅在联动模式进程启动时调用一次；切独立模式走原生 restartApp，整个
/// 进程被重拉，保活随之消失，无需显式停止。
class LinkKeepAlive {
  static const MethodChannel _channel = MethodChannel('xianyu/keep_alive');

  /// 联动模式启动后调用一次。任何失败都吞掉，不影响其余启动流程。
  static Future<void> start() async {
    try {
      await _channel.invokeMethod('start');
    } catch (_) {}
  }
}