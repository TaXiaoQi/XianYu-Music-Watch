import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/core/ambient.dart';
import 'src/core/app_mode.dart';
import 'src/core/keep_alive.dart' show LinkKeepAlive;
import 'src/core/settings.dart';
import 'src/core/watch_fit.dart';
import 'src/i18n/i18n.dart';
import 'src/auth/auth_provider.dart';
import 'src/link/link_provider.dart';
import 'src/sync/sync_provider.dart';
import 'src/ui/common/root_back_scope.dart';
import 'src/ui/local/local_music_hub.dart';
import 'src/ui/link/linkage_home.dart';
import 'src/update/app_update.dart';

class XianYuWatchApp extends ConsumerStatefulWidget {
  const XianYuWatchApp({super.key});

  @override
  ConsumerState<XianYuWatchApp> createState() => _XianYuWatchAppState();
}

/// 全局导航 key：供无 BuildContext 的服务层（播放器打断提示等）弹 UI。
final appNavKey = GlobalKey<NavigatorState>();

class _XianYuWatchAppState extends ConsumerState<XianYuWatchApp>
    with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navKey = appNavKey;
  ProviderSubscription<String>? _modeSub;
  ProviderSubscription<AsyncValue<AppSettings>>? _settingsSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _modeSub = ref.listenManual(appModeProvider, (prev, next) {
      if (prev != null && prev != next) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _navKey.currentState?.popUntil((route) => route.isFirst);
        });
      }
    });
    Future.microtask(() {
      ref.read(syncProvider.notifier);
      ref.read(linkControllerProvider.notifier).init();
      ref.read(authProvider.notifier).init();
    });
    _startupUpdateCheck();
    initAmbientListener(ref);
    _settingsSub = ref.listenManual(settingsProvider, (prev, next) {
      _applyKeepScreenOn(next.valueOrNull?.keepScreenOn ?? true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _modeSub?.close();
    _settingsSub?.close();
    super.dispose();
  }

  /// 回到前台立刻重查联动链路：手机端每次启动都会重连（云端中继无条件
  /// 建链），手表端却只在冷启动与断连事件时才刷新，导致手机回来了而手表
  /// 状态纹丝不动。这里补上「回前台即重查」。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    ref.read(linkControllerProvider.notifier).refreshOnResume();
  }

  /// 系统返回节流收口：Android 返回键/手势与鸿蒙 popRoute 最终都经
  /// WidgetsBinding.handlePopRoute 依次派发给各 observer 的 didPopRoute，
  /// 本 observer 注册先于 WidgetsApp。在此吞掉节流窗内的重复返回信号，
  /// 未节流的返回 false 交回 WidgetsApp 走原有 maybePop 弹栈（含根路由
  /// RootBackScope 的退后台/翻页），既有行为不变。不收口时，第二次返回
  /// 信号若落在上一次 pop 过渡结束之后，会把当前层之下的路由也弹掉（跳层）。
  @override
  Future<bool> didPopRoute() async => consumeBackSignal();

  /// 启动后静默拉取服务端下发的最新版本，有新版且在当天未提示过则弹出整页更新页。
  Future<void> _startupUpdateCheck() async {
    await Future<void>.delayed(const Duration(seconds: 3));
    final latest = await ref.read(authProvider.notifier).fetchServerUpdate();
    if (latest == null || !hasNewVersion(latest)) return;
    if (!await claimUpdatePrompt()) return;
    final ctx = _navKey.currentState?.context;
    if (ctx == null || !ctx.mounted) return;
    await showUpdatePage(ctx, latest,
        onUpdate: () => toastUpdateOnPhone(ctx));
  }

  static Future<void> _applyKeepScreenOn(bool enable) {
    return const MethodChannel(
      'xianyu/keep_screen',
    ).invokeMethod('set', {'enable': enable}).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final language =
        ref.watch(settingsProvider.select((s) => s.valueOrNull?.language)) ??
            'system';
    I18n.setMode(_i18nModeFor(language));
    return MaterialApp(
      key: ValueKey('app-${I18n.mode.name}'),
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
      builder: (context, child) => Consumer(
        builder: (context, ref, _) {
          Widget nav = child ?? const SizedBox.shrink();
          if (ref.watch(ambientModeProvider)) {
            nav = ColorFiltered(
              colorFilter: const ColorFilter.matrix(<double>[
                0.6,
                0,
                0,
                0,
                0,
                0,
                0.6,
                0,
                0,
                0,
                0,
                0,
                0.6,
                0,
                0,
                0,
                0,
                0,
                1,
                0,
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
      home: Consumer(
        builder: (context, ref, _) {
          final mode = ref.watch(appModeProvider);
          if (mode == appModeLink) LinkKeepAlive.start();
          return mode == appModeLink
              ? const LinkageHome()
              : const LocalMusicHub();
        },
      ),
    );
  }

  I18nMode _i18nModeFor(String lang) => switch (lang) {
        'zhCN' => I18nMode.zhCn,
        'zhTW' => I18nMode.zhTw,
        'en' => I18nMode.en,
        _ => _modeForSystemLocale(),
      };

  /// 繁体命中链：zh-Hant（无地区码）/ zh-TW / zh-HK / zh-MO，与移动端一致。
  I18nMode _modeForSystemLocale() {
    final locales = WidgetsBinding.instance.platformDispatcher.locales;
    if (locales.isEmpty) return I18nMode.zhCn;
    final first = locales.first;
    switch (first.languageCode) {
      case 'en':
        return I18nMode.en;
      case 'zh':
        final cc = first.countryCode;
        if (first.scriptCode == 'Hant' ||
            cc == 'TW' ||
            cc == 'HK' ||
            cc == 'MO') {
          return I18nMode.zhTw;
        }
        return I18nMode.zhCn;
    }
    return I18nMode.zhCn;
  }
}

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
          final isBack = velocity > 300 || _dx >= 60 * s;
          _dx = 0;
          if (!isBack) return;
          // 本条与系统返回是并存的兜底通道：固件把一次侧滑同时派发给
          // 系统返回与 Flutter 触摸流时，这里再 maybePop 会连弹两层（跳层）。
          // 与 didPopRoute 共用同一节流窗，保证一次返回手势至多弹一层。
          if (consumeBackSignal()) return;
          widget.navigatorKey.currentState?.maybePop();
        },
      ),
    );
  }
}

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
      linkControllerProvider.select((st) => st.incomingName),
    );
    if (name.isEmpty) return const SizedBox.shrink();
    final vh = MediaQuery.of(context).size.height;
    return Container(
      color: const Color(0xFF0C0C0F),
      child: NotificationListener<ScrollEndNotification>(
        onNotification: (n) {
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
            constraints: BoxConstraints(minHeight: vh - 28 * s),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.watch_rounded,
                    size: 44 * s,
                    color: const Color(0xFF4A90D9),
                  ),
                  SizedBox(height: 12 * s),
                  Text(
                    tr('配对请求'),
                    style: TextStyle(
                      fontSize: 18 * s,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 8 * s),
                  Text(
                    tr('「{name}」请求连接腕上弦予', {
                      'name': name.isEmpty ? tr('手机') : name,
                    }),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13 * s,
                      height: 1.35,
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
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
                            horizontal: 18 * s,
                            vertical: 5 * s,
                          ),
                          minimumSize: Size(0, 36 * s),
                          textStyle: TextStyle(fontSize: 13.5 * s),
                        ),
                        child: Text(tr('允许')),
                      ),
                      SizedBox(width: 12 * s),
                      OutlinedButton(
                        onPressed: () => ref
                            .read(linkControllerProvider.notifier)
                            .rejectIncoming(),
                        style: OutlinedButton.styleFrom(
                          padding: EdgeInsets.symmetric(
                            horizontal: 18 * s,
                            vertical: 5 * s,
                          ),
                          minimumSize: Size(0, 36 * s),
                          textStyle: TextStyle(fontSize: 13.5 * s),
                        ),
                        child: Text(tr('拒绝')),
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
