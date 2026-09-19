import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/watch_fit.dart';
import '../../link/link_provider.dart';
import '../../link/rfcomm_client.dart';
import '../common/stepped_list.dart';

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
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 8 * s),
          child: _loading
              ? Center(child: CircularProgressIndicator(strokeWidth: 3 * s))
              : _needsPermission
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.bluetooth_disabled_rounded,
                      size: 36 * s,
                      color: Colors.white.withValues(alpha: 0.4),
                    ),
                    SizedBox(height: 10 * s),
                    Text(
                      '需要蓝牙权限\n以连接手机',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13 * s, height: 1.4),
                    ),
                    SizedBox(height: 14 * s),
                    FilledButton(
                      onPressed: _requestPermission,
                      child: const Text('授予权限'),
                    ),
                  ],
                )
              : (_devices ?? const []).isEmpty
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
              : SteppedListView(
                  itemCount: _devices!.length,
                  header: const PageTitleHeader('选择手机'),
                  itemBuilder: (context, i) {
                    final dev = _devices![i];
                    return SteppedTile(
                      leading: SteppedLeadCircle(
                        color: const Color(0xFF3D7BFD),
                        child: Icon(
                          Icons.smartphone_rounded,
                          size: 20 * s,
                          color: Colors.white,
                        ),
                      ),
                      title: dev.name,
                      subtitle: dev.address,
                      onTap: () {
                        ref
                            .read(linkControllerProvider.notifier)
                            .selectDevice(dev);
                        Navigator.of(
                          context,
                        ).popUntil((r) => r.isFirst);
                      },
                    );
                  },
                ),
        ),
      ),
    );
  }
}
