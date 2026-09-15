import 'package:wearable_rotary/wearable_rotary.dart';

/// 表冠输入量化器：统一消费 [RotaryEvent]，把高分辨率/高频原始事件折算成「格」。
///
/// 背景：三星系表冠一格产生一个 magnitude≈48-64px 的事件；部分设备（华为
/// 兼容层）一次轻刮会产生大量小幅事件——逐事件步进会「轻刮飞屏」。
/// 策略：按 magnitude 累积像素预算，每 [pxPerStep] 记一格；同时限速
/// （[minInterval] 窗口内只攒不发）。轻刮 ≈ 1 格，快转顺滑加速、单次最多 2 格。
class RotaryQuantizer {
  RotaryQuantizer({
    this.pxPerStep = 48,
    this.minInterval = const Duration(milliseconds: 70),
  });

  /// 一格对应的旋转像素预算（对齐官方 RotaryScrollController 的 50px 档距）。
  final double pxPerStep;

  /// 两次步进之间的最小间隔（限速，防高频事件连跳）。
  final Duration minInterval;

  double _acc = 0; // 带符号像素预算
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  /// 返回本次事件应步进的格数（正=顺时针，负=逆时针，0=忽略）。
  int add(RotaryEvent event) {
    final dir = event.direction == RotaryDirection.clockwise ? 1 : -1;
    // 单事件像素按官方上限 64 封顶，防尖峰；magnitude 为空（Tizen）按整格。
    final m = (event.magnitude ?? pxPerStep).clamp(0.0, 64.0).toDouble();
    if (dir * _acc < 0) _acc = 0; // 换向清账，避免旧预算反向释放
    _acc += dir * m;
    // 预算上限 3 格：事件风暴后也最多走 3 格。
    _acc = _acc.clamp(-3 * pxPerStep, 3 * pxPerStep).toDouble();
    final now = DateTime.now();
    if (now.difference(_last) < minInterval) return 0;
    _last = now;
    var steps = (_acc.abs() / pxPerStep).floor();
    if (steps < 1) return 0;
    if (steps > 2) steps = 2; // 单次最多 2 格
    _acc -= dir * steps * pxPerStep;
    return dir * steps;
  }
}
