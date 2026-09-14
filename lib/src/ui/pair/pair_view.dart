import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/watch_fit.dart';
import '../../link/link_provider.dart';
import '../../link/rfcomm_client.dart';

/// 设备选择页：列出系统已配对蓝牙设备，点选即连接并持久化。
/// 首次进入若无权限，先引导授予「附近设备」权限。
class PairView extends ConsumerStatefulWidget {
  const PairView({super.key});

  @override
  ConsumerState<PairView> createState() => _PairViewState();
}

class _PairViewState extends ConsumerState<PairView> {
  List<BondedDevice>? _devices;
  bool _needsPermission = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
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
    // 授予后重载；拒绝则维持提示。
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Scaffold(
      body: SafeArea(
        child: Padding(
          // 屏径等比缩放适配。
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
