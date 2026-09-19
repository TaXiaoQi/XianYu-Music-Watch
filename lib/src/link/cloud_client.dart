import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'dart:io';

class CloudLinkEvent {
  const CloudLinkEvent._(this.kind, {this.peerName = ''});

  static const ready = 'ready';

  static const peerLost = 'peer_lost';

  static const replaced = 'replaced';

  static const closed = 'closed';

  final String kind;
  final String peerName;
}

class CloudLinkClient {
  WebSocket? _ws;
  StreamSubscription<dynamic>? _sub;
  bool _closed = true;
  bool _ready = false;
  Timer? _readyTimer;

  final _rawCtrl = StreamController<Uint8List>.broadcast();
  final _eventCtrl = StreamController<CloudLinkEvent>.broadcast();

  Stream<Uint8List> get onRaw => _rawCtrl.stream;

  Stream<CloudLinkEvent> get onEvent => _eventCtrl.stream;

  bool get isConnected => !_closed && _ws != null;

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
      ws.add(
        jsonEncode({'op': 'hello', 'role': 'watch', 'key': key, 'name': name}),
      );
      _ready = false;
      _readyTimer?.cancel();
      _readyTimer = Timer(const Duration(seconds: 8), () {
        if (!_closed && !_ready) close();
      });
      _sub = ws.listen(
        (data) {
          if (data is String) {
            _onText(data);
          } else if (data is List<int> && data.isNotEmpty) {
            _rawCtrl.add(data is Uint8List ? data : Uint8List.fromList(data));
          }
        },
        onError: (Object _) {
          _eventCtrl.add(const CloudLinkEvent._(CloudLinkEvent.closed));
          close();
        },
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
          _ready = true;
          _readyTimer?.cancel();
          _eventCtrl.add(
            CloudLinkEvent._(
              CloudLinkEvent.ready,
              peerName: (map['peer'] as String?) ?? '',
            ),
          );
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

  Future<void> send(Uint8List bytes) async {
    final ws = _ws;
    if (ws == null || _closed) return;
    try {
      ws.add(bytes);
    } catch (_) {}
  }

  Future<void> close() async {
    _closed = true;
    _readyTimer?.cancel();
    _readyTimer = null;
    await _sub?.cancel();
    _sub = null;
    final ws = _ws;
    _ws = null;
    try {
      await ws?.close();
    } catch (_) {}
  }
}
