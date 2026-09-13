import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'dart:io';

/// 云端兜底链路事件。
class CloudLinkEvent {
  const CloudLinkEvent._(this.kind, {this.peerName = ''});

  /// 与手机配对成功（对端已在线）。
  static const ready = 'ready';

  /// 手机端离线（底层连接仍可用，等待手机重连）。
  static const peerLost = 'peer_lost';

  /// 本连接被同 key 的新连接替换（服务端踢旧留新）。
  static const replaced = 'replaced';

  /// 底层连接断开（网络故障/服务端不可达）。
  static const closed = 'closed';

  final String kind;
  final String peerName;
}

/// 手表端云端中继客户端（对应服务端 `/watch-relay`，role=watch）。
///
/// 传输语义与 RFCOMM 完全一致：XYW1 帧字节原样走 WS Binary；
/// WS Text 仅承载链路控制（hello/ready/peer_lost/replaced）。
/// 心跳沿用上层 [LinkController] 的 3s ping（兼作 NAT 保活）。
class CloudLinkClient {
  WebSocket? _ws;
  StreamSubscription<dynamic>? _sub;
  bool _closed = true;

  final _rawCtrl = StreamController<Uint8List>.broadcast();
  final _eventCtrl = StreamController<CloudLinkEvent>.broadcast();

  /// 收到的 XYW1 帧字节流（帧解码由上层 FrameDecoder 完成）。
  Stream<Uint8List> get onRaw => _rawCtrl.stream;

  /// 链路事件。
  Stream<CloudLinkEvent> get onEvent => _eventCtrl.stream;

  bool get isConnected => !_closed && _ws != null;

  /// 连接中继服务（role=watch）。成败经 [onEvent] 回传。
  Future<void> connect({
    required String url,
    required String key,
    String name = '弦予腕上',
  }) async {
    await close();
    _closed = false;
    try {
      final ws = await WebSocket.connect(url).timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw TimeoutException('relay connect timeout'),
          );
      _ws = ws;
      // 握手：首条 Text hello。
      ws.add(jsonEncode({
        'op': 'hello',
        'role': 'watch',
        'key': key,
        'name': name,
      }));
      _sub = ws.listen(
        (data) {
          if (data is String) {
            _onText(data);
          } else if (data is List<int> && data.isNotEmpty) {
            _rawCtrl.add(data is Uint8List ? data : Uint8List.fromList(data));
          }
        },
        onError: (_) => close(),
        onDone: () {
          _eventCtrl.add(const CloudLinkEvent._(CloudLinkEvent.closed));
          close();
        },
        cancelOnError: true,
      );
    } catch (_) {
      _eventCtrl.add(const CloudLinkEvent._(CloudLinkEvent.closed));
      _closed = true;
      _ws = null;
    }
  }

  void _onText(String text) {
    try {
      final map = jsonDecode(text) as Map<String, dynamic>;
      switch (map['op']) {
        case 'ready':
          _eventCtrl.add(CloudLinkEvent._(
            CloudLinkEvent.ready,
            peerName: (map['peer'] as String?) ?? '',
          ));
        case 'peer_lost':
          _eventCtrl.add(const CloudLinkEvent._(CloudLinkEvent.peerLost));
        case 'replaced':
          _eventCtrl.add(const CloudLinkEvent._(CloudLinkEvent.replaced));
          close();
        default:
          break;
      }
    } catch (_) {}
  }

  /// 发送 XYW1 帧字节（WS Binary）。
  Future<void> send(Uint8List bytes) async {
    final ws = _ws;
    if (ws == null || _closed) return;
    try {
      ws.add(bytes);
    } catch (_) {}
  }

  /// 关闭连接（幂等）。
  Future<void> close() async {
    _closed = true;
    await _sub?.cancel();
    _sub = null;
    final ws = _ws;
    _ws = null;
    try {
      await ws?.close();
    } catch (_) {}
  }
}
