import 'package:flutter/services.dart';

class LinkKeepAlive {
  static const MethodChannel _channel = MethodChannel('xianyu/keep_alive');
  static bool _started = false;

  static Future<void> start() async {
    if (_started) return;
    try {
      await _channel.invokeMethod('start');
      _started = true;
    } catch (_) {}
  }
}
