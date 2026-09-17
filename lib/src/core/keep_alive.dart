import 'package:flutter/services.dart';

/// 联动模式低占用常驻保活：请求原生把进程提到「前台服务级」驻留
/// （Android 前台服务 + IMPORTANCE_LOW 无声通知；ohos
/// backgroundTaskManager 连续任务），使退后台后蓝牙/云中继链路仍存活、
/// 手机播放可快速唤起。失败静默，只尽力而为、不阻断启动。
///
/// 仅在联动模式运行时请求一次（幂等）；切到独立模式后不再需要，但保留已
/// 申请到的保活无碍（独立模式本身靠媒体前台服务持活）。
class LinkKeepAlive {
  static const MethodChannel _channel = MethodChannel('xianyu/keep_alive');
  static bool _started = false;

  /// 联动模式启动后调用一次。任何失败都吞掉，不影响其余启动流程。
  /// 幂等：联动首页每次重建（含热切回联动）都会触发，但只向原生申请一次。
  static Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      await _channel.invokeMethod('start');
    } catch (_) {}
  }
}