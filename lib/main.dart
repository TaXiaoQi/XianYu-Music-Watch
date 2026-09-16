import 'dart:async';

import 'package:audio_service/audio_service.dart' as asrv;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'src/core/rust_init.dart';
import 'src/core/watch_fit.dart';
import 'src/player/listen_stats.dart';
import 'src/player/player_provider.dart'
    show WatchAudioHandler, activePlayerNotifier, audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 屏形探测（圆/方）须在首帧前落定：列表/页面按形状选布局，
  // 通道往返 <10ms，await 避免方表首帧闪圆屏样式。
  await WatchScreenShape.probe();
  final container = ProviderContainer();
  // 尽早触发 rust 初始化（与首帧渲染并行），缩短「打开→可交互」的等待。
  container.read(rustInitProvider);
  // 听歌时长统计（独立播放 position 增量结算 + delta 上报），常驻计时。
  container.read(listenStatsProvider);
  // 后台初始化系统 MediaSession / 媒体通知服务（独立播放灭屏/切走不被杀），
  // 不阻塞首帧；init 完成后补绑 PlayerNotifier（见 _initAudioService）。
  _initAudioService();
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const XianYuWatchApp(),
    ),
  );
}

/// 初始化 audio_service：表上媒体通知 + 前台媒体服务。
///
/// init 是后台异步，PlayerNotifier 构造时 [audioHandler] 可能仍为 null
/// 导致 bindNotifier 落空，完成后在此补绑（同移动端模式）。
void _initAudioService() {
  unawaited(
    asrv.AudioService.init(
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
      debugPrint('[audio_service] 初始化完成');
    }, onError: (Object e, StackTrace st) {
      debugPrint('[audio_service] 初始化失败: $e\n$st');
    }),
  );
}
