import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/core/ambient.dart';
import 'src/core/settings.dart';
import 'src/auth/auth_provider.dart';
import 'src/link/link_provider.dart';
import 'src/sync/sync_provider.dart';
import 'src/ui/controller/watch_controller_page.dart';
import 'src/ui/local/local_music_hub.dart';

/// 弦予腕上版入口：全屏音乐页（左侧功能列表 ↔ 中间播放 ↔ 右侧歌词横移），
/// 开屏落在播放页；设置/账号/插件管理从左侧功能列表进入。
///
/// 联动建立（含后台通知拉起）时自动跳转播放控制页，返回后停在原处。
class XianYuWatchApp extends ConsumerStatefulWidget {
  const XianYuWatchApp({super.key});

  @override
  ConsumerState<XianYuWatchApp> createState() => _XianYuWatchAppState();
}

class _XianYuWatchAppState extends ConsumerState<XianYuWatchApp> {
  @override
  void initState() {
    super.initState();
    // 链路初始化（读配对地址 → 自动连接 / 退避重连 / 心跳）+ 账号凭证恢复。
    Future.microtask(() {
      // 先创建 SyncNotifier 注册登录态监听：登录/凭证恢复后自动触发首次云同步。
      ref.read(syncProvider.notifier);
      ref.read(linkControllerProvider.notifier).init();
      ref.read(authProvider.notifier).init();
    });
    // Wear OS 环境模式监听（进出 ambient 压暗 UI + 暂停刷新）。
    initAmbientListener(ref);
    // 屏幕常亮设置应用（设置-播放，原生 FLAG_KEEP_SCREEN_ON）。
    ref.listenManual(settingsProvider, (prev, next) {
      _applyKeepScreenOn(next.valueOrNull?.keepScreenOn ?? true);
    });
  }

  static Future<void> _applyKeepScreenOn(bool enable) {
    return const MethodChannel('xianyu/keep_screen')
        .invokeMethod('set', {'enable': enable})
        .catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // 多任务卡片标题取 MaterialApp.title（覆盖 manifest label），debug 带·测试。
      title: kDebugMode ? '腕上弦予·测试' : '腕上弦予',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF4D6E),
          secondary: Color(0xFFFF8FA3),
          surface: Colors.black,
        ),
      ),
      // builder 包住 Navigator：所有路由（含推送页）在 ambient 下统一压暗。
      builder: (context, child) => Consumer(
        builder: (context, ref, _) {
          if (!ref.watch(ambientModeProvider)) {
            return child ?? const SizedBox.shrink();
          }
          return ColorFiltered(
            // 全局压暗至 60%：OLED 防烧屏 + 省电，保留最低可读性。
            colorFilter: const ColorFilter.matrix(<double>[
              0.6, 0, 0, 0, 0, //
              0, 0.6, 0, 0, 0, //
              0, 0, 0.6, 0, 0, //
              0, 0, 0, 1, 0, //
            ]),
            child: child ?? const SizedBox.shrink(),
          );
        },
      ),
      home: const LinkHome(),
    );
  }
}

class LinkHome extends ConsumerStatefulWidget {
  const LinkHome({super.key});

  @override
  ConsumerState<LinkHome> createState() => _LinkHomeState();
}

class _LinkHomeState extends ConsumerState<LinkHome> {
  bool _pushingController = false;

  @override
  void initState() {
    super.initState();
    // 联动建立（含冷启动自动连接、后台通知拉起）→ 自动进入播放控制页。
    ref.listenManual(linkControllerProvider, (prev, next) {
      if (_pushingController || !mounted) return;
      if (next.phase != LinkPhase.connected) return;
      if (prev?.phase == LinkPhase.connected) return;
      _pushingController = true;
      Navigator.of(context)
          .push(
        MaterialPageRoute<void>(builder: (_) => const WatchControllerPage()),
      )
          .whenComplete(() => _pushingController = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 全屏音乐页（功能列表 ↔ 播放 ↔ 歌词三页横移），
    // 设置/账号/插件管理等入口都在左侧功能列表里。
    return const LocalMusicHub();
  }
}
