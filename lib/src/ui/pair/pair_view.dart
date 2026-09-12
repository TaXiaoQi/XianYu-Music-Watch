import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Column(
            children: [
              Text(
                '选择手机',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
              const SizedBox(height: 10),
              if (_loading)
                const Expanded(
                  child: Center(child: CircularProgressIndicator(strokeWidth: 3)),
                )
              else if (_needsPermission)
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.bluetooth_disabled_rounded,
                        size: 36,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                      const SizedBox(height: 10),
                      const Text('需要蓝牙权限\n以连接手机',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, height: 1.4)),
                      const SizedBox(height: 14),
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
                              fontSize: 13,
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
                              leading: const Icon(Icons.smartphone_rounded,
                                  size: 20),
                              title: Text(
                                dev.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                              subtitle: Text(
                                dev.address,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
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
