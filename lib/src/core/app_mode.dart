import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../player/listen_stats.dart';
import '../player/player_provider.dart' show audioHandler;
import '../player/watch_audio_service.dart';
import 'rust_init.dart';

const appModeKey = 'appMode';
const appModeLink = 'link';
const appModeStandalone = 'standalone';

Future<String> readAppMode() async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getString(appModeKey) ?? appModeLink) == appModeStandalone
      ? appModeStandalone
      : appModeLink;
}

Future<void> writeAppMode(String mode) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(appModeKey, mode);
}

class AppModeNotifier extends Notifier<String> {
  static String _seeded = appModeLink;

  static void seed(String mode) => _seeded = mode;

  @override
  String build() => _seeded;

  bool get isLink => state == appModeLink;
  bool get isStandalone => state == appModeStandalone;

  Future<void> change(String mode) async {
    if (mode != appModeLink && mode != appModeStandalone) return;
    if (mode == state) return;
    state = mode;
    unawaited(writeAppMode(mode).catchError((_) {}));
    if (mode == appModeStandalone) {
      ref.read(rustInitProvider);
      ref.read(listenStatsProvider);
      initWatchAudioService();
    } else {
      try {
        await audioHandler?.pause();
      } catch (_) {}
    }
  }
}

final appModeProvider = NotifierProvider<AppModeNotifier, String>(
  AppModeNotifier.new,
);