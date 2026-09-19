import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final ambientModeProvider = StateProvider<bool>((ref) => false);

void initAmbientListener(WidgetRef ref) {
  const channel = MethodChannel('xianyu/ambient');
  channel.setMethodCallHandler((call) async {
    if (call.method == 'onAmbient') {
      final entering = call.arguments is bool && (call.arguments as bool);
      ref.read(ambientModeProvider.notifier).state = entering;
    }
  });
}
