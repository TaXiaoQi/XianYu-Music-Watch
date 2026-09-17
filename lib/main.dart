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
  // 屏形探测（圆/方）须在首帧前落定：列表/页面按形状选布局，
  // 通道往返 <10ms，await 避免方表首帧闪圆屏样式。
  await WatchScreenShape.probe();
  // 启动模式决定哪些子系统初始化（联动模式不启动媒体服务/听歌统计/
  // 原生库，保续航、开机即轻量控制器；独立模式才起完整服务）。
  final appMode = await readAppMode();
  final linkMode = appMode == appModeLink;
  // 播种模式到 Notifier：运行中切换（热切）只改状态与补初始化，不重启。
  AppModeNotifier.seed(appMode);
  final container = ProviderContainer();
  if (!linkMode) {
    // rust 桥接（libxianyu_core.so，约 12MB 原生库）只被插件解析/本地
    // 扫描/独立播放侧使用；联动链路（蓝牙/云）不碰 rust，故联动跳过，
    // 白省一次映射。尽早触发（与首帧渲染并行），缩短「打开→可交互」。
    container.read(rustInitProvider);
    // 听歌时长统计（独立播放 position 增量结算 + delta 上报），常驻计时。
    container.read(listenStatsProvider);
    // 后台初始化系统 MediaSession / 媒体通知服务（独立播放灭屏/切走不被杀），
    // 不阻塞首帧；init 完成后补绑 PlayerNotifier（见 initWatchAudioService）。
    initWatchAudioService();
  }
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const XianYuWatchApp(),
    ),
  );
}
