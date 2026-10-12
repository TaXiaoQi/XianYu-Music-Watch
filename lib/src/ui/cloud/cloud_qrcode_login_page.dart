import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../cloud/cloud_credentials_store.dart';
import '../../cloud/cloud_provider.dart';
import '../../cloud/cloud_registry.dart';
import '../../cloud/cloud_types.dart';
import '../../core/application_logger.dart';
import '../../core/watch_fit.dart';
import '../../i18n/i18n.dart';

/// 扫码登录页（qrCode 范式，手表居中布局）。
///
/// createQrLogin 拿二维码内容渲染，2s 轮询 pollQrLogin；
/// 抛 CloudException（过期/已取消）时停止轮询并提供刷新入口。
class CloudQrcodeLoginPage extends ConsumerStatefulWidget {
  const CloudQrcodeLoginPage({super.key, required this.providerId});

  final String providerId;

  @override
  ConsumerState<CloudQrcodeLoginPage> createState() =>
      _CloudQrcodeLoginPageState();
}

class _CloudQrcodeLoginPageState extends ConsumerState<CloudQrcodeLoginPage> {
  late final CloudProvider _provider;
  CloudQrLoginSession? _session;
  Timer? _timer;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _provider = cloudProviderById(widget.providerId)!;
    _create();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _create() async {
    _timer?.cancel();
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await _provider.createQrLogin();
      if (!mounted) return;
      setState(() {
        _session = s;
        _loading = false;
      });
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    } catch (e) {
      AppLog.warn('cloud', '${_provider.id} 二维码获取失败: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is CloudException ? e.message : tr('二维码获取失败');
      });
    }
  }

  Future<void> _poll() async {
    final s = _session;
    if (s == null || _saving || _timer == null) return;
    try {
      final account = await _provider.pollQrLogin(s);
      if (account == null || !mounted) return;
      _timer?.cancel();
      setState(() => _saving = true);
      await CloudCredentialsStore.instance.saveAccount(account);
      if (!mounted) return;
      _toast(tr('绑定成功'));
      Navigator.of(context).pop();
    } on CloudException catch (e) {
      _timer?.cancel();
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      // 网络抖动等瞬时错误：保持轮询。
      AppLog.debug('cloud', '${_provider.id} 扫码轮询异常: $e');
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(horizontal: 18 * s),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      tr('使用{name}App 扫码登录', {'name': _provider.displayName}),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13 * s,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                    SizedBox(height: 12 * s),
                    _buildQr(s),
                    SizedBox(height: 12 * s),
                    if (_error != null) ...[
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11.5 * s,
                          color: const Color(0xFFFF6B81),
                        ),
                      ),
                      SizedBox(height: 8 * s),
                      TextButton(
                        onPressed: _create,
                        style: TextButton.styleFrom(
                          padding:
                              EdgeInsets.symmetric(horizontal: 14 * s),
                          minimumSize: Size(0, 32 * s),
                        ),
                        child: Text(
                          tr('刷新二维码'),
                          style: TextStyle(
                            fontSize: 12.5 * s,
                            color: const Color(0xFFFF8FA3),
                          ),
                        ),
                      ),
                    ] else
                      Text(
                        _loading ? tr('正在获取二维码...') : tr('扫码后确认登录'),
                        style: TextStyle(
                          fontSize: 11 * s,
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (_saving)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black38,
                child: Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5 * s,
                    color: const Color(0xFFFF4D6E),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildQr(double s) {
    if (_loading) {
      return SizedBox(
        width: 132 * s,
        height: 132 * s,
        child: Center(
          child: CircularProgressIndicator(
            strokeWidth: 2.5 * s,
            color: const Color(0xFFFF4D6E),
          ),
        ),
      );
    }
    final session = _session;
    if (session == null) {
      return SizedBox(
        width: 132 * s,
        height: 132 * s,
        child: Center(
          child: Text(
            _error ?? tr('二维码获取失败'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5 * s,
              color: const Color(0xFFFF6B81),
            ),
          ),
        ),
      );
    }
    // 服务方直接下发二维码图片（百度）：直接展示，无需本地渲染。
    final img = session.qrImageUrl;
    if (img != null && img.isNotEmpty) {
      return Container(
        padding: EdgeInsets.all(8 * s),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10 * s),
        ),
        child: Image.network(
          img,
          width: 116 * s,
          height: 116 * s,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => Icon(
            Icons.qr_code_2,
            size: 40 * s,
            color: Colors.black26,
          ),
        ),
      );
    }
    return Container(
      padding: EdgeInsets.all(8 * s),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10 * s),
      ),
      child: QrImageView(
        data: session.qrContent,
        version: QrVersions.auto,
        size: 116 * s,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
        backgroundColor: Colors.white,
      ),
    );
  }
}
