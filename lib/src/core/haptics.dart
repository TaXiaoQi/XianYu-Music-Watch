import 'package:flutter/services.dart';

/// 触觉反馈统一封装。
///
/// 背景：`HapticFeedback.selectionClick` 走 `View.performHapticFeedback
/// (CLOCK_TICK)`，受系统「触摸时振动」开关影响——华为表兼容层上常被静默
/// 忽略，用户体感「没有振动反馈」。这里优先经 `xianyu/haptics` 通道用
/// Vibrator 直接打轻脉冲（不受该开关影响，需 manifest VIBRATE 权限）；
/// 原生不可用（通道缺失/无振动器）时回退 Flutter HapticFeedback。
class Haptics {
  Haptics._();

  static const MethodChannel _ch = MethodChannel('xianyu/haptics');

  /// 原生通道可用性（失败一次即降级，避免每次调用都白等一次 miss）。
  static bool _native = true;

  /// 表冠档位/点选确认的轻刻度脉冲（原生约 18ms 直振）。
  static Future<void> tick() async {
    if (_native) {
      try {
        final ok = await _ch.invokeMethod<bool>('tick');
        if (ok == true) return;
        _native = false; // 设备无振动器等：之后走 Flutter 回退
      } on MissingPluginException {
        _native = false;
      } catch (_) {
        _native = false;
      }
    }
    await HapticFeedback.selectionClick();
  }
}
