import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class RootBackScope extends StatefulWidget {
  const RootBackScope({super.key, required this.child, this.pageCtrl});

  final Widget child;

  final PageController? pageCtrl;

  @override
  State<RootBackScope> createState() => _RootBackScopeState();
}

class _RootBackScopeState extends State<RootBackScope> {
  DateTime _lastPageChange = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastPage = -1;

  @override
  void initState() {
    super.initState();
    widget.pageCtrl?.addListener(_onTick);
  }

  @override
  void didUpdateWidget(covariant RootBackScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageCtrl != widget.pageCtrl) {
      oldWidget.pageCtrl?.removeListener(_onTick);
      widget.pageCtrl?.addListener(_onTick);
    }
  }

  @override
  void dispose() {
    widget.pageCtrl?.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    final p = widget.pageCtrl?.page?.round();
    if (p != null && p != _lastPage) {
      _lastPage = p;
      _lastPageChange = DateTime.now();
    }
  }

  void _handleBack() {
    final c = widget.pageCtrl;
    if (c != null) {
      final busy = (c.hasClients && c.position.isScrollingNotifier.value) ||
          DateTime.now().difference(_lastPageChange) <
              const Duration(milliseconds: 600);
      if (busy) return;
      final p = c.page?.round() ?? 0;
      if (p > 0) {
        c.animateToPage(
          p - 1,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
        return;
      }
    }
    const MethodChannel('xianyu/system_nav')
        .invokeMethod('moveTaskToBack')
        .catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: widget.child,
    );
  }
}

/// 全局返回节流：一次返回手势可能产生两次返回信号（系统返回键/侧滑手势
/// 与自绘左缘返回条并存，返回键也可能抖动重复派发），而 Navigator 的
/// maybePop 对「上一次 pop 过渡结束后才到达的第二次请求」会继续弹掉当前
/// 层之下的路由，表现为多级页返回时跳层。这里把系统级返回弹栈收口为
/// 窗口期内最多一次；悬浮返回钮等页面内的显式点击不在此列。
const Duration _kBackThrottleWindow = Duration(milliseconds: 400);

DateTime _lastBackPopAt = DateTime.fromMillisecondsSinceEpoch(0);

/// 系统级返回信号到达时调用。返回 true 表示本次信号落在上一次返回弹栈
/// 的节流窗内，应整条吞掉（弹栈已由上一次信号完成）；返回 false 表示
/// 本次信号有效（时刻已记录），调用方继续执行弹栈。
bool consumeBackSignal() {
  final now = DateTime.now();
  if (now.difference(_lastBackPopAt) < _kBackThrottleWindow) {
    return true;
  }
  _lastBackPopAt = now;
  return false;
}
