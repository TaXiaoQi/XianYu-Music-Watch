import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 根路由系统返回承接：非最左页先翻回上一页（补回被系统抢走的「往右滑回
/// 功能区」），仅最左页才退后台驻留（应用保持存活、重开秒回、会话不断），
/// 绝不退出。
///
/// 背景：鸿蒙侧 back 链路为 系统手势/返回键 → Index.onBackPress（ability 级
/// onBackPressed 兜底）→ popRoute；安卓版由左缘条 maybePop 走同一条路——
/// 两端的根路由返回都收口在此。此前鸿蒙上根路由直接退后台（turn-0
/// 「右滑退出软件」），根因是 PopScope 一律 moveTaskToBack，这里改成先翻页。
///
/// [pageCtrl] 传主页 PageController：滚动中或 600ms 内刚翻过页时忽略本次
/// 返回——「手势与触摸并存」机型上触摸横滑刚翻完页、系统返回又随即提交，
/// 不忽略会「翻页后又立刻退后台」的双重响应。
class RootBackScope extends StatefulWidget {
  const RootBackScope({super.key, required this.child, this.pageCtrl});

  final Widget child;

  /// 主页 PageController；null = 无横移页（返回一律退后台）。
  final PageController? pageCtrl;

  @override
  State<RootBackScope> createState() => _RootBackScopeState();
}

class _RootBackScopeState extends State<RootBackScope> {
  /// 最近一次翻页时刻：控制器跨过档距中线（page 取整变化）即刷新，
  /// 触摸翻页与程序翻页一并覆盖。
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
      // 触摸横滑正在进行/刚完成翻页：本次返回已被触摸消化，忽略。
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
    // 最左页再返回：退后台驻留，绝不退出（失败静默留在前台）。
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
