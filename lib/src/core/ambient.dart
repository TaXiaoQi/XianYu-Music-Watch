import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Wear OS 环境模式（熄屏常显）：true = 屏幕已进入 ambient，UI 需降功耗/防烧屏。
final ambientModeProvider = StateProvider<bool>((ref) => false);

/// 订阅 Kotlin AmbientLifecycleObserver 回调（MethodChannel `xianyu/ambient`）。
/// 应用启动时调用一次，ambient 进出状态同步进 [ambientModeProvider]。
void initAmbientListener(WidgetRef ref) {
  const channel = MethodChannel('xianyu/ambient');
  channel.setMethodCallHandler((call) async {
    if (call.method == 'onAmbient') {
      final entering = call.arguments is bool && (call.arguments as bool);
      ref.read(ambientModeProvider.notifier).state = entering;
    }
  });
}
