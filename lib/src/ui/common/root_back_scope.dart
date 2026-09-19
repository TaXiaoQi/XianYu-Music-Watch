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
