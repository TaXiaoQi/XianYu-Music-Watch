import 'dart:async';

import 'package:flutter/services.dart';

/// 连接事件（Kotlin 侧 onConnection 回传）。
class LinkConnectionEvent {
  const LinkConnectionEvent({required this.connected, required this.name});

  final bool connected;
  final String name;
}

/// 已配对蓝牙设备。
class BondedDevice {
  const BondedDevice({required this.address, required this.name});

  final String address;
  final String name;

  static BondedDevice fromMap(Object? m) {
    final map = m as Map;
    return BondedDevice(
      address: map['address'] as String? ?? '',
      name: map['name'] as String? ?? '',
    );
  }
}

/// 手表端联动 MethodChannel 封装（对应 Kotlin `WatchLinkClient.kt`）。
///
/// Kotlin 只做 RFCOMM 字节管道：connect/读写/断连感知；帧编解码、心跳
/// （3s ping）、无帧判死（10s）与重连指数退避在 [link_provider.dart]。
class LinkClientChannel {
  static const MethodChannel _ch = MethodChannel('xianyu/watch_link');

  final _rawCtrl = StreamController<Uint8List>.broadcast();
  final _connCtrl = StreamController<LinkConnectionEvent>.broadcast();
  final _permCtrl = StreamController<bool>.broadcast();
  bool _bound = false;

  /// 收到的原始字节流（帧解码由上层 FrameDecoder 完成）。
  Stream<Uint8List> get onRaw => _rawCtrl.stream;

  /// 连接建立/断开。
  Stream<LinkConnectionEvent> get onConnection => _connCtrl.stream;

  /// 运行时权限请求结果（Android 12+ BLUETOOTH_CONNECT）。
  Stream<bool> get onPermission => _permCtrl.stream;

  /// 注册 Kotlin→Dart 回调 handler（幂等）。
  void bind() {
    if (_bound) return;
    _bound = true;
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onRaw':
          final bytes = call.arguments as Uint8List?;
          if (bytes != null && bytes.isNotEmpty) _rawCtrl.add(bytes);
        case 'onConnection':
          final args = call.arguments as Map?;
          _connCtrl.add(LinkConnectionEvent(
            connected: args?['connected'] == true,
            name: (args?['name'] as String?) ?? '',
          ));
        case 'onPermission':
          _permCtrl.add(call.arguments == true);
      }
    });
  }

  /// 已配对设备列表。
  Future<List<BondedDevice>> pairedDevices() async {
    try {
      final list = await _ch.invokeMethod<List<dynamic>>('pairedDevices');
      return (list ?? const []).map(BondedDevice.fromMap).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 连接指定地址（异步发起，成败经 [onConnection] 回传）。
  Future<void> connect(String address) async {
    try {
      await _ch.invokeMethod('connect', {'address': address});
    } catch (_) {}
  }

  /// 断开连接（幂等）。
  Future<void> disconnect() async {
    try {
      await _ch.invokeMethod('disconnect');
    } catch (_) {}
  }

  /// 发送原始帧字节。
  Future<void> send(Uint8List bytes) async {
    try {
      await _ch.invokeMethod('send', {'bytes': bytes});
    } catch (_) {}
  }

  /// 蓝牙运行时权限是否已授予。
  Future<bool> hasPermission() async {
    try {
      return await _ch.invokeMethod('hasPermission') == true;
    } catch (_) {
      return false;
    }
  }

  /// 发起权限请求，结果经 [onPermission] 回传。
  Future<void> requestPermission() async {
    try {
      await _ch.invokeMethod('requestPermission');
    } catch (_) {}
  }

  /// 后台拉起：发 fullScreenIntent 高优先级通知（应用前台时 Kotlin 侧自动跳过）。
  Future<void> notifyNowPlaying(String title, String artist) async {
    try {
      await _ch.invokeMethod('notifyNowPlaying', {
        'title': title,
        'artist': artist,
      });
    } catch (_) {}
  }
}
