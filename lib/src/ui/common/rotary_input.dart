import 'package:wearable_rotary/wearable_rotary.dart';

class RotaryQuantizer {
  RotaryQuantizer({
    this.pxPerStep = 48,
    this.minInterval = const Duration(milliseconds: 70),
  });

  final double pxPerStep;

  final Duration minInterval;

  double _acc = 0;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  int add(RotaryEvent event) {
    final dir = event.direction == RotaryDirection.clockwise ? 1 : -1;
    final m = (event.magnitude ?? pxPerStep).clamp(0.0, 64.0).toDouble();
    if (dir * _acc < 0) _acc = 0;
    _acc += dir * m;
    _acc = _acc.clamp(-3 * pxPerStep, 3 * pxPerStep).toDouble();
    final now = DateTime.now();
    if (now.difference(_last) < minInterval) return 0;
    _last = now;
    var steps = (_acc.abs() / pxPerStep).floor();
    if (steps < 1) return 0;
    if (steps > 2) steps = 2;
    _acc -= dir * steps * pxPerStep;
    return dir * steps;
  }
}
