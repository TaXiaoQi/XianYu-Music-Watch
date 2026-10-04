import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'src/core/app_mode.dart';
import 'src/core/rust_init.dart';
import 'src/core/settings.dart';
import 'src/core/watch_fit.dart';
import 'src/player/listen_stats.dart';
import 'src/player/watch_audio_service.dart';
import 'src/plugin/fallback_modules/sync.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await WatchScreenShape.probe();
  final appMode = await readAppMode();
  final linkMode = appMode == appModeLink;
  AppModeNotifier.seed(appMode);
  final container = ProviderContainer();
  if (!linkMode) {
    container.read(rustInitProvider);
    // Rust 就绪后挂载兜底模块同步（验签/load 依赖桥）
    container.listen(rustInitProvider, (prev, next) {
      if (next.hasValue) initFallbackModuleSync(container);
    });
    // 兜底模块配置快照变化推送（500ms 防抖）
    container.listen(settingsProvider, (prev, next) {
      if (next.hasValue) scheduleFallbackModuleConfigPush(container);
    });
    container.read(listenStatsProvider);
    initWatchAudioService();
  }
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const XianYuWatchApp(),
    ),
  );
}
