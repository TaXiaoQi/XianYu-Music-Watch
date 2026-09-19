import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

extension WatchFitContext on BuildContext {
  double watchScale() =>
      (MediaQuery.of(this).size.shortestSide / 200).clamp(0.85, 1.30);
}

class WatchScreenShape {
  static const _ch = MethodChannel('xianyu/screen_shape');

  static bool isRound = true;

  static Future<void> probe() async {
    try {
      final r = await _ch.invokeMethod<bool>('isRound');
      if (r != null) isRound = r;
    } catch (_) {
    }
    if (!isRound) {
      final views = WidgetsBinding.instance.platformDispatcher.views;
      if (views.isNotEmpty) {
        final s = views.first.physicalSize;
        if (s.width > 0 && s.height > 0 &&
            ((s.width / s.height) - 1).abs() < 0.08) {
          isRound = true;
        }
      }
    }
  }
}

extension WatchShapeContext on BuildContext {
  bool get isRoundWatch => WatchScreenShape.isRound;
}
