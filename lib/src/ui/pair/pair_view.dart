import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wearable_rotary/wearable_rotary.dart';

import '../../core/watch_fit.dart';
import '../../link/link_provider.dart';
import '../../link/rfcomm_client.dart';

class PairView extends ConsumerStatefulWidget {
  const PairView({super.key});

  @override
  ConsumerState<PairView> createState() => _PairViewState();
}

class _PairViewState extends ConsumerState<PairView> {
  List<BondedDevice>? _devices;
  bool _needsPermission = false;
  bool _loading = true;

  final ScrollController _scroll = ScrollController();
  StreamSubscription<RotaryEvent>? _rotarySub;
  double _rotaryAcc = 0;

  @override
  void initState() {
    super.initState();
    _reload();
    _rotarySub = rotaryEvents.listen(_onRotary);
  }

  void _onRotary(RotaryEvent event) {
    if (!mounted || !_scroll.hasClients) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final dir = event.direction == RotaryDirection.clockwise ? 1.0 : -1.0;
    final m = (event.magnitude ?? 48).clamp(0.0, 64.0).toDouble();
    if (dir * _rotaryAcc < 0) _rotaryAcc = 0;
    _rotaryAcc += dir * m;
    final delta = _rotaryAcc * 0.6;
    _rotaryAcc = 0;
    final target = (_scroll.offset + delta)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    if ((target - _scroll.offset).abs() >= 0.5) _scroll.jumpTo(target);
  }

  @override
  void dispose() {
    _rotarySub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final controller = ref.read(linkControllerProvider.notifier);
    if (!await controller.hasBluetoothPermission()) {
      if (mounted) {
        setState(() {
          _needsPermission = true;
          _loading = false;
        });
      }
      return;
    }
    final devices = await controller.loadPairedDevices();
    if (mounted) {
      setState(() {
        _devices = devices;
        _needsPermission = false;
        _loading = false;
      });
    }
  }

  Future<void> _requestPermission() async {
    await ref.read(linkControllerProvider.notifier).requestBluetoothPermission();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 20 * s, vertical: 8 * s),
          child: Column(
            children: [
              Text(
                '选择手机',
                style: TextStyle(
                  fontSize: 16 * s,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
              SizedBox(height: 10 * s),
              if (_loading)
                Expanded(
                  child: Center(
                      child: CircularProgressIndicator(strokeWidth: 3 * s)),
                )
              else if (_needsPermission)
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.bluetooth_disabled_rounded,
                        size: 36 * s,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                      SizedBox(height: 10 * s),
                      Text('需要蓝牙权限\n以连接手机',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13 * s, height: 1.4)),
                      SizedBox(height: 14 * s),
                      FilledButton(
                        onPressed: _requestPermission,
                        child: const Text('授予权限'),
                      ),
                    ],
                  ),
                )
              else
                Expanded(
                  child: (_devices ?? const []).isEmpty
                      ? Center(
                          child: Text(
                            '暂无已配对设备\n请先在系统设置中配对手机',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13 * s,
                              height: 1.5,
                              color: Colors.white.withValues(alpha: 0.55),
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          itemCount: _devices!.length,
                          itemBuilder: (_, i) {
                            final dev = _devices![i];
                            return ListTile(
                              dense: true,
                              visualDensity: VisualDensity.compact,
                              leading: Icon(Icons.smartphone_rounded,
                                  size: 20 * s),
                              title: Text(
                                dev.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 13 * s),
                              ),
                              subtitle: Text(
                                dev.address,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10 * s,
                                  color:
                                      Colors.white.withValues(alpha: 0.4),
                                ),
                              ),
                              onTap: () {
                                ref
                                    .read(linkControllerProvider.notifier)
                                    .selectDevice(dev);
                                Navigator.of(context).popUntil((r) => r.isFirst);
                              },
                            );
                          },
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
