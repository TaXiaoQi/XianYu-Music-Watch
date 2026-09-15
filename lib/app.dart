import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/core/ambient.dart';
import 'src/core/settings.dart';
import 'src/core/watch_fit.dart';
import 'src/auth/auth_provider.dart';
import 'src/link/link_provider.dart';
import 'src/sync/sync_provider.dart';
import 'src/ui/controller/watch_controller_page.dart';
import 'src/ui/local/local_music_hub.dart';

/// 弦予腕上版入口：全屏音乐页（左侧功能列表 ↔ 中间播放 ↔ 右侧歌词横移），
/// 开屏落在播放页；设置/账号从左侧功能列表进入（插件管理并入设置）。
///
/// 联动建立（含后台通知拉起）时自动跳转播放控制页，返回后停在原处。
class XianYuWatchApp extends ConsumerStatefulWidget {
  const XianYuWatchApp({super.key});

  @override
  ConsumerState<XianYuWatchApp> createState() => _XianYuWatchAppState();
}

class _XianYuWatchAppState extends ConsumerState<XianYuWatchApp> {
  // 左缘返回条要触发 Navigator 弹栈/根路由后台驻留，而该条叠在
  // Navigator 之上（MaterialApp.builder 层），拿不到 Navigator
  // 的祖先链，只能用 GlobalKey 直取。
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

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
      navigatorKey: _navKey,
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
      // builder 包住 Navigator：所有路由（含推送页）在 ambient 下统一压暗；
      // 并在最上层叠一条左缘返回条（系统级边缘返回在本机不可靠，见
      // _EdgeBackStrip 注释）。
      builder: (context, child) => Consumer(
        builder: (context, ref, _) {
          Widget nav = child ?? const SizedBox.shrink();
          if (ref.watch(ambientModeProvider)) {
            nav = ColorFiltered(
              // 全局压暗至 60%：OLED 防烧屏 + 省电，保留最低可读性。
              colorFilter: const ColorFilter.matrix(<double>[
                0.6, 0, 0, 0, 0, //
                0, 0.6, 0, 0, 0, //
                0, 0, 0.6, 0, 0, //
                0, 0, 0, 1, 0, //
              ]),
              child: nav,
            );
          }
          return Stack(
            children: [
              Positioned.fill(child: nav),
              _EdgeBackStrip(navigatorKey: _navKey),
              const Positioned.fill(child: _PairRequestHost()),
            ],
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
    // 手表左滑返回手势（由 _EdgeBackStrip 从左缘触发）：根路由（三页横移
    // 主页）无页面可弹时退到表盘后台驻留（应用保持存活、重开秒回、播放
    // 不断），不走 Flutter 默认的 SystemNavigator.pop——那会直接 finish
    // 掉 Activity，观感即「左滑退出软件」。二级页（设置/账号等）为正常
    // 压栈路由，返回手势照常弹栈，不经此逻辑。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          const MethodChannel('xianyu/system_nav')
              .invokeMethod('moveTaskToBack')
              // 极端情况：通道失败也不能让返回彻底失效，退化为正常退出。
              .catchError((_) => SystemNavigator.pop());
        }
      },
      child: const LocalMusicHub(),
    );
  }
}

/// 左缘返回条：叠在所有路由之上（MaterialApp.builder 层）。本机
/// HarmonyOS 上系统级边缘返回手势不可触发（原生侧已排除全屏手势区，
/// 左缘窄条也不响应），返回必须自绘：仅「从左缘 26dp 内起手、向右滑」
/// 的横滑触发返回——二级页弹栈，根路由经 PopScope 后台驻留；其余横滑
/// 照常归页面（播放页翻页等）。竖滑与点按没有对应回调，手势竞技场直接
/// 放行，不影响列表滚动和左缘附近的按钮点击。
class _EdgeBackStrip extends StatefulWidget {
  const _EdgeBackStrip({required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<_EdgeBackStrip> createState() => _EdgeBackStripState();
}

class _EdgeBackStripState extends State<_EdgeBackStrip> {
  double _dx = 0;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      width: 26 * s,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => _dx = 0,
        onHorizontalDragUpdate: (d) => _dx += d.delta.dx,
        onHorizontalDragEnd: (d) {
          final velocity = d.primaryVelocity ?? 0;
          // 快甩（>300dp/s）或明确向右拖出 60dp 都算返回意图。
          final isBack = velocity > 300 || _dx >= 60 * s;
          _dx = 0;
          if (!isBack) return;
          widget.navigatorKey.currentState?.maybePop();
        },
      ),
    );
  }
}

/// 手机端发起的配对确认（叠在全部路由之上）：有请求时显示完整确认页
/// （非浮卡，圆屏弧缘不再裁切内容）。内容垂直居中、上下留白填充；设备名
/// 超长换行使内容超屏时可滚动，滚动结束吸附到最近端（头部/按钮完整可见），
/// 不超屏时始终居中。允许 → 采纳连接（后续自动进控制页）；拒绝 → 关闭并回绝。
class _PairRequestHost extends ConsumerStatefulWidget {
  const _PairRequestHost();

  @override
  ConsumerState<_PairRequestHost> createState() => _PairRequestHostState();
}

class _PairRequestHostState extends ConsumerState<_PairRequestHost> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final name = ref.watch(
        linkControllerProvider.select((st) => st.incomingName));
    if (name.isEmpty) return const SizedBox.shrink();
    final vh = MediaQuery.of(context).size.height;
    return Container(
      color: const Color(0xFF0C0C0F),
      child: NotificationListener<ScrollEndNotification>(
        onNotification: (n) {
          // 滚动结束吸附：内容超屏时对齐最近端（头部或按钮完整可见），
          // 不停在半截；不超屏时本就居中，无需处理。
          final m = n.metrics;
          if (!m.hasContentDimensions || m.maxScrollExtent <= 0) return false;
          final target =
              (m.pixels / m.maxScrollExtent).round() * m.maxScrollExtent;
          if ((target - m.pixels).abs() > 0.5) {
            _scroll.animateTo(
              target,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
            );
          }
          return false;
        },
        child: SingleChildScrollView(
          controller: _scroll,
          padding: EdgeInsets.symmetric(horizontal: 30 * s, vertical: 14 * s),
          child: ConstrainedBox(
            // 最小高度撑满视口（扣除自身纵向 padding）：内容少时垂直
            // 居中，上下留白填充；内容多时自然撑开、可滚动。
            constraints: BoxConstraints(minHeight: vh - 28 * s),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.watch_rounded,
                      size: 44 * s, color: const Color(0xFF4A90D9)),
                  SizedBox(height: 12 * s),
                  Text('配对请求',
                      style: TextStyle(
                          fontSize: 18 * s, fontWeight: FontWeight.bold)),
                  SizedBox(height: 8 * s),
                  Text(
                    '「${name.isEmpty ? '手机' : name}」请求连接腕上弦予',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13 * s,
                        height: 1.35,
                        color: Colors.white.withValues(alpha: 0.6)),
                  ),
                  SizedBox(height: 20 * s),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton(
                        onPressed: () => ref
                            .read(linkControllerProvider.notifier)
                            .acceptIncoming(),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFFF4D6E),
                          padding: EdgeInsets.symmetric(
                              horizontal: 18 * s, vertical: 5 * s),
                          minimumSize: Size(0, 36 * s),
                          textStyle: TextStyle(fontSize: 13.5 * s),
                        ),
                        child: const Text('允许'),
                      ),
                      SizedBox(width: 12 * s),
                      OutlinedButton(
                        onPressed: () => ref
                            .read(linkControllerProvider.notifier)
                            .rejectIncoming(),
                        style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.symmetric(
                              horizontal: 18 * s, vertical: 5 * s),
                          minimumSize: Size(0, 36 * s),
                          textStyle: TextStyle(fontSize: 13.5 * s),
                        ),
                        child: const Text('拒绝'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
