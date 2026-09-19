import 'package:flutter/services.dart';

class Haptics {
  Haptics._();

  static const MethodChannel _ch = MethodChannel('xianyu/haptics');

  static bool _native = true;

  static Future<void> tick() async {
    if (_native) {
      try {
        final ok = await _ch.invokeMethod<bool>('tick');
        if (ok == true) return;
        _native = false;
      } on MissingPluginException {
        _native = false;
      } catch (_) {
        _native = false;
      }
    }
    await HapticFeedback.selectionClick();
  }
}
