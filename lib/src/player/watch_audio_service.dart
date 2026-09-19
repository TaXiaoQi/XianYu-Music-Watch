import 'dart:async';

import 'package:audio_service/audio_service.dart' as asrv;

import 'player_provider.dart'
    show WatchAudioHandler, activePlayerNotifier, audioHandler;

bool _started = false;

/// 初始化 audio_service（幂等）：表上媒体通知 + 前台媒体服务。
///
/// init 是后台异步，PlayerNotifier 构造时 [audioHandler] 可能仍为 null
/// 导致 bindNotifier 落空，完成后在此补绑（同移动端模式）。幂等由
/// [_started] 保证：冷启动独立模式（main gate）与联动→独立热切换共用，
/// 避免重复 init 造成二次通知通道/绑定。
Future<void> initWatchAudioService() {
  if (_started) return Future.value();
  _started = true;
  return asrv.AudioService.init(
    builder: () => WatchAudioHandler(),
    config: const asrv.AudioServiceConfig(
      androidNotificationChannelId: 'com.xianyumusic.watch.channel.audio',
      androidNotificationChannelName: '弦予音乐播放控制',
      // 暂停不撤通知（表上随时一键续播）、暂停不退前台：持久媒体卡片。
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: false,
      androidNotificationIcon: 'drawable/ic_notification',
      androidNotificationClickStartsActivity: true,
    ),
  ).then((h) {
    audioHandler = h;
    final notifier = activePlayerNotifier;
    if (notifier != null) h.bindNotifier(notifier);
    // 初始化失败不重抛：调用方均为 fire-and-forget，吞掉异常避免未处理错误。
  }, onError: (Object e, StackTrace st) {});
}