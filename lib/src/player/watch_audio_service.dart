import 'dart:async';

import 'package:audio_service/audio_service.dart' as asrv;

import 'player_provider.dart'
    show WatchAudioHandler, activePlayerNotifier, audioHandler;

bool _started = false;

Future<void> initWatchAudioService() {
  if (_started) return Future.value();
  _started = true;
  return asrv.AudioService.init(
    builder: () => WatchAudioHandler(),
    config: const asrv.AudioServiceConfig(
      androidNotificationChannelId: 'com.xianyumusic.watch.channel.audio',
      androidNotificationChannelName: '弦予音乐播放控制',
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
      androidNotificationIcon: 'drawable/ic_notification',
      androidNotificationClickStartsActivity: true,
    ),
  ).then(
    (h) {
      audioHandler = h;
      final notifier = activePlayerNotifier;
      if (notifier != null) h.bindNotifier(notifier);
    },
    onError: (Object e, StackTrace st) {
      _started = false;
    },
  );
}
