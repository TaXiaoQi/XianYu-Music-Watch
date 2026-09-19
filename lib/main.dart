import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'src/core/app_mode.dart';
import 'src/core/rust_init.dart';
import 'src/core/watch_fit.dart';
import 'src/player/listen_stats.dart';
import 'src/player/watch_audio_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await WatchScreenShape.probe();
  final appMode = await readAppMode();
  final linkMode = appMode == appModeLink;
  AppModeNotifier.seed(appMode);
  final container = ProviderContainer();
  if (!linkMode) {
    container.read(rustInitProvider);
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
