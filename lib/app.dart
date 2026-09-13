import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/link/link_provider.dart';
import 'src/ui/controller/watch_controller_page.dart';
import 'src/ui/local/local_library_view.dart';
import 'src/ui/pair/pair_view.dart';

/// 弦予腕上版入口：联接状态即路由 + 独立本地库双模式。
///
/// - 手机控制 tab：已连接 → 联接控制页；连接中 → 手机名 + 取消；
///   未连接 → 无配对选设备 / 已配对给重连/换设备
/// - 本地音乐 tab：断连独立播放本地音乐（P2）
/// 两个模式可共存：正在控制手机时也可切到本地库浏览。
class XianYuWatchApp extends ConsumerStatefulWidget {
  const XianYuWatchApp({super.key});

  @override
  ConsumerState<XianYuWatchApp> createState() => _XianYuWatchAppState();
}

class _XianYuWatchAppState extends ConsumerState<XianYuWatchApp> {
  @override
  void initState() {
    super.initState();
    // 链路初始化（读配对地址 → 自动连接 / 退避重连 / 心跳）。
    Future.microtask(() => ref.read(linkControllerProvider.notifier).init());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '弦予腕上',
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
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final link = ref.watch(linkControllerProvider);
    Widget controllerTab;
    switch (link.phase) {
      case LinkPhase.connected:
        controllerTab = const WatchControllerPage();
      case LinkPhase.connecting:
        controllerTab = const _ConnectingView();
      case LinkPhase.disconnected:
        controllerTab = link.pairedAddress == null
            ? const PairView()
            : const _DisconnectedView();
    }

    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          controllerTab,
          const LocalLibraryView(),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _tabBtn(
              icon: Icons.smartphone_rounded,
              label: '控制',
              selected: _tab == 0,
              onTap: () => setState(() => _tab = 0),
            ),
            const SizedBox(width: 28),
            _tabBtn(
              icon: Icons.library_music_rounded,
              label: '本地',
              selected: _tab == 1,
              onTap: () => setState(() => _tab = 1),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabBtn({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final color = selected
        ? const Color(0xFFFF4D6E)
        : Colors.white.withValues(alpha: 0.45);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            Text(
              label,
              style: TextStyle(fontSize: 10, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// 连接中：展示目标手机名。
class _ConnectingView extends ConsumerWidget {
  const _ConnectingView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(linkControllerProvider);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(strokeWidth: 3),
          const SizedBox(height: 16),
          Text(
            '正在连接\n${link.pairedName ?? ''}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, height: 1.4),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () =>
                ref.read(linkControllerProvider.notifier).disconnectManually(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }
}

/// 已配对但断连：重连 / 更换设备。
class _DisconnectedView extends ConsumerWidget {
  const _DisconnectedView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(linkControllerProvider);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.watch_off_rounded,
            size: 40,
            color: Colors.white.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          Text(
            '未连接手机\n${link.pairedName ?? ''}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              height: 1.4,
              color: Colors.white.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: () => ref.read(linkControllerProvider.notifier).retry(),
            child: const Text('重新连接'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const PairView()),
            ),
            child: const Text('更换设备'),
          ),
        ],
      ),
    );
  }
}
