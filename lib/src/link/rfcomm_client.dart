import 'dart:async';

import 'package:flutter/services.dart';

import '../core/application_logger.dart';

class LinkConnectionEvent {
  const LinkConnectionEvent({required this.connected, required this.name});

  final bool connected;
  final String name;
}

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

class IncomingPairRequest {
  const IncomingPairRequest({required this.name, required this.address});

  final String name;
  final String address;

  static IncomingPairRequest fromMap(Object? m) {
    final map = m as Map? ?? const {};
    return IncomingPairRequest(
      name: (map['name'] as String?) ?? '',
      address: (map['address'] as String?) ?? '',
    );
  }
}

class LinkClientChannel {
  static const MethodChannel _ch = MethodChannel('xianyu/watch_link');

  final _rawCtrl = StreamController<Uint8List>.broadcast();
  final _connCtrl = StreamController<LinkConnectionEvent>.broadcast();
  final _permCtrl = StreamController<bool>.broadcast();
  final _incomingCtrl = StreamController<IncomingPairRequest>.broadcast();
  bool _bound = false;

  Stream<Uint8List> get onRaw => _rawCtrl.stream;

  Stream<LinkConnectionEvent> get onConnection => _connCtrl.stream;

  Stream<bool> get onPermission => _permCtrl.stream;

  Stream<IncomingPairRequest> get onIncomingPair => _incomingCtrl.stream;

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
        case 'onIncomingPair':
          final req = IncomingPairRequest.fromMap(call.arguments);
          if (req.address.isNotEmpty) _incomingCtrl.add(req);
      }
    });
  }

  /// ohos 是否有 SPP 原生通道（ets WatchLinkDispatcher 实现，恒 true）。
  /// Android 有 Kotlin 实现无需询问；iOS/其他平台 notImplemented → false。
  Future<bool> sppSupported() async {
    try {
      return await _ch.invokeMethod('sppSupported') == true;
    } catch (e) {
      AppLog.debug('link', 'SPP 支持探测失败（按不支持处理）: $e');
      return false;
    }
  }

  Future<List<BondedDevice>> pairedDevices() async {
    try {
      final list = await _ch.invokeMethod<List<dynamic>>('pairedDevices');
      return (list ?? const []).map(BondedDevice.fromMap).toList();
    } catch (e) {
      AppLog.warn('link', '获取已配对设备失败: $e');
      return const [];
    }
  }

  Future<void> connect(String address) async {
    try {
      await _ch.invokeMethod('connect', {'address': address});
    } catch (e) {
      AppLog.warn('link', '发起蓝牙连接失败: $e');
    }
  }

  Future<void> disconnect() async {
    try {
      await _ch.invokeMethod('disconnect');
    } catch (e) {
      AppLog.debug('link', '断开蓝牙连接失败: $e');
    }
  }

  Future<void> startServer() async {
    try {
      await _ch.invokeMethod('startServer');
    } catch (e) {
      AppLog.warn('link', '启动蓝牙监听失败: $e');
    }
  }

  Future<void> acceptPair() async {
    try {
      await _ch.invokeMethod('acceptPair');
    } catch (e) {
      AppLog.warn('link', '接受配对请求失败: $e');
    }
  }

  Future<void> rejectPair() async {
    try {
      await _ch.invokeMethod('rejectPair');
    } catch (e) {
      AppLog.warn('link', '拒绝配对请求失败: $e');
    }
  }

  Future<void> send(Uint8List bytes) async {
    try {
      await _ch.invokeMethod('send', {'bytes': bytes});
    } catch (e) {
      AppLog.warn('link', '发送蓝牙数据失败: $e');
    }
  }

  Future<bool> hasPermission() async {
    try {
      return await _ch.invokeMethod('hasPermission') == true;
    } catch (e) {
      AppLog.warn('link', '查询蓝牙权限失败: $e');
      return false;
    }
  }

  Future<void> requestPermission() async {
    try {
      await _ch.invokeMethod('requestPermission');
    } catch (e) {
      AppLog.warn('link', '请求蓝牙权限失败: $e');
    }
  }

  Future<void> notifyNowPlaying(String title, String artist) async {
    try {
      await _ch.invokeMethod('notifyNowPlaying', {
        'title': title,
        'artist': artist,
      });
    } catch (e) {
      AppLog.debug('link', '推送正在播放通知失败: $e');
    }
  }
}
