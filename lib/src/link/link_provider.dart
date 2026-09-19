import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/ambient.dart';
import 'cloud_client.dart';
import 'protocol.dart';
import 'rfcomm_client.dart';

const String kDefaultCloudRelayUrl = 'wss://api.xianyumusic.cn/watch-relay';

enum LinkPhase { disconnected, connecting, connected }

class LinkNowPlaying {
  const LinkNowPlaying({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    this.cover,
    required this.duration,
    this.daily = false,
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final String? cover;
  final double duration;

  final bool daily;

  bool get coverIsFile =>
      cover != null && cover!.isNotEmpty && !cover!.startsWith('http');

  static LinkNowPlaying fromPayload(Map<String, dynamic> p) => LinkNowPlaying(
    id: p['id'] as String? ?? '',
    title: p['title'] as String? ?? '',
    artist: p['artist'] as String? ?? '',
    album: p['album'] as String? ?? '',
    cover: p['cover'] as String?,
    duration: (p['duration'] as num?)?.toDouble() ?? 0,
    daily: p['daily'] as bool? ?? false,
  );

  LinkNowPlaying copyWith({String? cover}) => LinkNowPlaying(
    id: id,
    title: title,
    artist: artist,
    album: album,
    cover: cover ?? this.cover,
    duration: duration,
    daily: daily,
  );
}

class LinkState {
  final LinkPhase phase;
  final String phoneName;

  final bool autoEnabled;

  final String? pairedAddress;
  final String? pairedName;

  final LinkNowPlaying? now;
  final bool isPlaying;
  final LinkPlayMode playMode;
  final bool liked;
  final double? volume;

  final double position;

  final bool viaCloud;

  final String? lyricSongId;
  final String? lyricPayload;

  final String incomingName;
  final String incomingAddress;

  const LinkState({
    this.phase = LinkPhase.disconnected,
    this.phoneName = '',
    this.autoEnabled = true,
    this.pairedAddress,
    this.pairedName,
    this.now,
    this.isPlaying = false,
    this.playMode = LinkPlayMode.order,
    this.liked = false,
    this.volume,
    this.position = 0,
    this.viaCloud = false,
    this.lyricSongId,
    this.lyricPayload,
    this.incomingName = '',
    this.incomingAddress = '',
  });

  LinkState copyWith({
    LinkPhase? phase,
    String? phoneName,
    bool? autoEnabled,
    Object? pairedAddress = _noChange,
    Object? pairedName = _noChange,
    Object? now = _noChange,
    bool? isPlaying,
    LinkPlayMode? playMode,
    bool? liked,
    Object? volume = _noChange,
    double? position,
    bool? viaCloud,
    Object? lyricSongId = _noChange,
    Object? lyricPayload = _noChange,
    String? incomingName,
    String? incomingAddress,
  }) => LinkState(
    phase: phase ?? this.phase,
    phoneName: phoneName ?? this.phoneName,
    autoEnabled: autoEnabled ?? this.autoEnabled,
    pairedAddress: pairedAddress == _noChange
        ? this.pairedAddress
        : pairedAddress as String?,
    pairedName: pairedName == _noChange
        ? this.pairedName
        : pairedName as String?,
    now: now == _noChange ? this.now : now as LinkNowPlaying?,
    isPlaying: isPlaying ?? this.isPlaying,
    playMode: playMode ?? this.playMode,
    liked: liked ?? this.liked,
    volume: volume == _noChange ? this.volume : volume as double?,
    position: position ?? this.position,
    viaCloud: viaCloud ?? this.viaCloud,
    lyricSongId: lyricSongId == _noChange
        ? this.lyricSongId
        : lyricSongId as String?,
    lyricPayload: lyricPayload == _noChange
        ? this.lyricPayload
        : lyricPayload as String?,
    incomingName: incomingName ?? this.incomingName,
    incomingAddress: incomingAddress ?? this.incomingAddress,
  );
}

const Object _noChange = Object();

class LinkController extends StateNotifier<LinkState> {
  LinkController() : super(const LinkState());

  final LinkClientChannel _channel = LinkClientChannel();
  final CloudLinkClient _cloud = CloudLinkClient();
  FrameDecoder _decoder = FrameDecoder();
  final int Function() _nextSeq = makeSeqGenerator();

  static const _heartbeatInterval = Duration(seconds: 3);
  static const _deadAfter = Duration(seconds: 10);
  static const _minBackoff = Duration(seconds: 1);
  static const _maxBackoff = Duration(seconds: 30);

  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _heartbeat;
  Timer? _interpolate;
  Timer? _reconnect;
  Duration _backoff = _minBackoff;

  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);

  bool _viaCloud = false;

  String _cloudKey = '';
  String _cloudUrl = '';

  bool _cloudTryActive = false;

  bool _disposed = false;

  final Map<String, String> _lyricCache = {};

  void Function(String title, String artist)? onBackgroundNowPlaying;

  bool Function()? isAmbient;

  Future<void> init() async {
    _channel.bind();
    onBackgroundNowPlaying = (title, artist) {
      _channel.notifyNowPlaying(title, artist);
    };
    _subs.add(_channel.onRaw.listen(_onRaw));
    _subs.add(_channel.onConnection.listen(_onConnection));
    _subs.add(_channel.onPermission.listen(_onPermission));
    _subs.add(_channel.onIncomingPair.listen(_onIncomingPair));
    _subs.add(_cloud.onRaw.listen(_onRaw));
    _subs.add(_cloud.onEvent.listen(_onCloudEvent));
    _channel.startServer();

    final prefs = await SharedPreferences.getInstance();
    final addr = prefs.getString('watch.pairedAddress');
    final name = prefs.getString('watch.pairedName');
    final auto = prefs.getBool('watch.autoEnabled') ?? true;
    _cloudKey = prefs.getString('watch.cloudKey') ?? '';
    _cloudUrl = prefs.getString('watch.cloudUrl') ?? '';
    state = state.copyWith(
      autoEnabled: auto,
      pairedAddress: addr,
      pairedName: name,
    );
    if (addr != null && auto) {
      final linkageOn = prefs.getBool('watchLinkageEnabled') ?? true;
      if (linkageOn) _attemptConnect();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    _heartbeat?.cancel();
    _interpolate?.cancel();
    _reconnect?.cancel();
    _connectWatchdog?.cancel();
    _cloud.close();
    _channel.disconnect();
    super.dispose();
  }

  // ---- 用户操作 ----

  Future<void> selectDevice(BondedDevice dev) async {
    _reconnect?.cancel();
    _backoff = _minBackoff;
    state = state.copyWith(
      pairedAddress: dev.address,
      pairedName: dev.name,
      phase: LinkPhase.connecting,
      now: null,
      isPlaying: false,
      position: 0,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('watch.pairedAddress', dev.address);
    await prefs.setString('watch.pairedName', dev.name);
    _attemptConnect();
  }

  Future<void> disconnectManually() async {
    _reconnect?.cancel();
    _stopAlive();
    _viaCloud = false;
    _cloudTryActive = false;
    state = state.copyWith(
      phase: LinkPhase.disconnected,
      now: null,
      viaCloud: false,
    );
    await _cloud.close();
    await _channel.disconnect();
  }

  Future<void> setAutoEnabled(bool v) async {
    state = state.copyWith(autoEnabled: v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('watch.autoEnabled', v);
    if (v) {
      final addr = state.pairedAddress;
      if (addr != null && state.phase == LinkPhase.disconnected) {
        _backoff = _minBackoff;
        _attemptConnect();
      } else if (_cloudKey.isNotEmpty &&
          state.phase == LinkPhase.disconnected) {
        _backoff = _minBackoff;
        _tryCloud();
      }
    } else {
      _reconnect?.cancel();
    }
  }

  // ---- 控制命令（手表 → 手机） ----

  void toggle() => _sendCmd(LinkCmdAction.toggle);
  void next() => _sendCmd(LinkCmdAction.next);
  void prev() => _sendCmd(LinkCmdAction.prev);
  void like() => _sendCmd(LinkCmdAction.like);
  void dislike() => _sendCmd(LinkCmdAction.dislike);
  void cycleMode() => _sendCmd(LinkCmdAction.mode);
  void seek(double pos) => _sendCmd(LinkCmdAction.seek, arg: {'pos': pos});

  void setVolume(double v) =>
      _sendCmd(LinkCmdAction.volume, arg: {'v': v.clamp(0.0, 1.0)});

  void retry() {
    _reconnect?.cancel();
    _backoff = _minBackoff;
    state = state.copyWith(phase: LinkPhase.disconnected);
    _attemptConnect();
  }

  Future<void> acceptIncoming() async {
    _reconnect?.cancel();
    _backoff = _minBackoff;
    final addr = state.incomingAddress;
    final name = state.incomingName;
    state = state.copyWith(
      phase: LinkPhase.connecting,
      pairedAddress: addr.isEmpty ? state.pairedAddress : addr,
      pairedName: name.isEmpty ? state.pairedName : name,
      incomingName: '',
      incomingAddress: '',
    );
    if (addr.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('watch.pairedAddress', addr);
      await prefs.setString('watch.pairedName', name);
    }
    _channel.acceptPair();
  }

  void rejectIncoming() {
    _channel.rejectPair();
    state = state.copyWith(incomingName: '', incomingAddress: '');
  }

  void _onIncomingPair(IncomingPairRequest req) {
    if (state.phase != LinkPhase.disconnected) {
      _channel.rejectPair();
      return;
    }
    state = state.copyWith(
      incomingName: req.name,
      incomingAddress: req.address,
    );
  }

  Future<List<BondedDevice>> loadPairedDevices() => _channel.pairedDevices();

  Future<bool> hasBluetoothPermission() => _channel.hasPermission();
  Future<void> requestBluetoothPermission() => _channel.requestPermission();

  void _sendCmd(String action, {Map<String, dynamic>? arg}) {
    if (state.phase != LinkPhase.connected) return;
    _send(LinkMessage.cmd(action, arg));
  }

  // ---- 连接生命周期 ----

  void _attemptConnect() {
    if (state.phase == LinkPhase.connected ||
        state.phase == LinkPhase.connecting) {
      return;
    }
    final addr = state.pairedAddress;
    if ((addr == null || addr.isEmpty)) {
      if (_cloudKey.isNotEmpty) _tryCloud();
      return;
    }
    _wasExpectingConnect = true;
    state = state.copyWith(phase: LinkPhase.connecting);
    _channel.connect(addr);
    _connectWatchdog?.cancel();
    _connectWatchdog = Timer(const Duration(seconds: 15), () {
      if (state.phase != LinkPhase.connecting || _viaCloud) return;
      _wasExpectingConnect = false;
      _channel.disconnect();
      state = state.copyWith(
        phase: LinkPhase.disconnected,
        now: null,
        isPlaying: false,
        position: 0,
      );
      if (_cloudKey.isNotEmpty) {
        _tryCloud();
      } else {
        _scheduleReconnect();
      }
    });
  }

  void _onConnection(LinkConnectionEvent evt) {
    _reconnect?.cancel();
    _connectWatchdog?.cancel();
    state = state.copyWith(incomingName: '', incomingAddress: '');
    if (evt.connected) {
      _onLinkUp(name: evt.name, viaCloud: false);
    } else {
      final wasConnected = state.phase == LinkPhase.connected;
      _stopAlive();
      state = state.copyWith(
        phase: LinkPhase.disconnected,
        now: null,
        isPlaying: false,
        position: 0,
      );
      if (wasConnected || _wasExpectingConnect) {
        if (_cloudKey.isNotEmpty) {
          _tryCloud();
        } else {
          _scheduleReconnect();
        }
      }
      _wasExpectingConnect = false;
    }
  }

  // ---- 云端兜底传输 ----

  void _tryCloud() {
    if (_cloudKey.isEmpty) return;
    if (_cloudTryActive || state.phase == LinkPhase.connected) return;
    _cloudTryActive = true;
    state = state.copyWith(phase: LinkPhase.connecting);
    _cloud.connect(
      url: _cloudUrl.isEmpty ? kDefaultCloudRelayUrl : _cloudUrl,
      key: _cloudKey,
    );
  }

  void _onCloudEvent(CloudLinkEvent evt) {
    switch (evt.kind) {
      case CloudLinkEvent.ready:
        _onLinkUp(name: evt.peerName, viaCloud: true);
      case CloudLinkEvent.peerLost:
        if (_viaCloud) _killLink(reschedule: true);
      case CloudLinkEvent.replaced:
        if (_viaCloud) _killLink(reschedule: false);
      case CloudLinkEvent.closed:
        _cloudTryActive = false;
        if (_viaCloud) {
          _killLink(reschedule: true);
        } else if (state.phase == LinkPhase.connecting) {
          _scheduleReconnect();
        }
    }
  }

  void _onLinkUp({required String name, required bool viaCloud}) {
    _cloudTryActive = false;
    _viaCloud = viaCloud;
    _decoder = FrameDecoder();
    _backoff = _minBackoff;
    _lastFrame = DateTime.now();
    state = state.copyWith(
      phase: LinkPhase.connected,
      phoneName: name,
      now: null,
      isPlaying: false,
      liked: false,
      position: 0,
      viaCloud: viaCloud,
    );
    _send(
      LinkMessage.hello(ver: kLinkProtocolVersion, role: 'watch', name: '弦予腕上'),
    );
    _startAlive();
  }

  void _killLink({required bool reschedule}) {
    _stopAlive();
    final wasCloud = _viaCloud;
    _viaCloud = false;
    _cloudTryActive = false;
    state = state.copyWith(
      phase: LinkPhase.disconnected,
      now: null,
      isPlaying: false,
      position: 0,
      viaCloud: false,
    );
    if (wasCloud) {
      _cloud.close();
    } else {
      _channel.disconnect();
    }
    if (reschedule) _scheduleReconnect();
  }

  bool _wasExpectingConnect = false;

  Timer? _connectWatchdog;

  void _scheduleReconnect() {
    if (!state.autoEnabled) return;
    if (state.pairedAddress == null && _cloudKey.isEmpty) return;
    _reconnect?.cancel();
    _reconnect = Timer(_backoff, () {
      _backoff = _backoff * 2 > _maxBackoff ? _maxBackoff : _backoff * 2;
      _attemptConnect();
    });
  }

  // ---- 保活与插值 ----

  void _startAlive() {
    _heartbeat?.cancel();
    _interpolate?.cancel();
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) {
      if (state.phase != LinkPhase.connected) return;
      _send(
        LinkMessage(LinkMsgType.ping, {
          't': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      if (DateTime.now().difference(_lastFrame) > _deadAfter) {
        if (_viaCloud) {
          _killLink(reschedule: true);
        } else {
          _wasExpectingConnect = true;
          _channel.disconnect();
        }
      }
    });
    _interpolate = Timer.periodic(const Duration(seconds: 1), (_) {
      if (state.phase != LinkPhase.connected || !state.isPlaying) return;
      if (isAmbient?.call() ?? false) return;
      final now = state.now;
      if (now == null) return;
      final p = state.position + 1;
      state = state.copyWith(position: p >= now.duration ? now.duration : p);
    });
  }

  void _stopAlive() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _interpolate?.cancel();
    _interpolate = null;
  }

  // ---- 消息入口 ----

  void _onRaw(Uint8List bytes) {
    _lastFrame = DateTime.now();
    for (final msg in _decoder.feed(bytes)) {
      _onMessage(msg);
    }
  }

  void _onMessage(LinkMessage msg) {
    switch (msg.type) {
      case LinkMsgType.state:
        state = state.copyWith(
          isPlaying: msg.payload['isPlaying'] == true,
          playMode: linkPlayModeFromString(msg.payload['playMode'] as String?),
          liked: msg.payload['liked'] == true,
          volume: (msg.payload['volume'] as num?)?.toDouble(),
        );
      case LinkMsgType.nowPlaying:
        final now = LinkNowPlaying.fromPayload(msg.payload);
        final preCover = _linkCoverPathFor(now.id);
        state = state.copyWith(
          now: preCover != null && File(preCover).existsSync()
              ? now.copyWith(cover: preCover)
              : now,
          position: 0,
        );
        final cachedLyric = _lyricCache[now.id];
        if (cachedLyric != null) {
          state = state.copyWith(
            lyricSongId: now.id,
            lyricPayload: cachedLyric,
          );
        }
        final coverData = msg.payload['coverData'] as String?;
        if (coverData != null && coverData.isNotEmpty) {
          _saveLinkCover(now.id, coverData).then((path) {
            if (_disposed || path == null || state.now?.id != now.id) return;
            state = state.copyWith(now: state.now!.copyWith(cover: path));
          });
        }
        final lifecycle =
            WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
        if (lifecycle != AppLifecycleState.resumed) {
          onBackgroundNowPlaying?.call(now.title, now.artist);
        }
      case LinkMsgType.position:
        if (isAmbient?.call() ?? false) break;
        state = state.copyWith(
          position: (msg.payload['pos'] as num?)?.toDouble() ?? 0,
        );
      case LinkMsgType.lyric:
        final lyric = msg.payload['lyric'];
        if (lyric is! Map) break;
        final id = lyric['id'] as String?;
        final payload = lyric['payload'] as String?;
        if (id == null || id.isEmpty || payload == null) break;
        state = state.copyWith(lyricSongId: id, lyricPayload: payload);
      case LinkMsgType.precache:
        final p = msg.payload['precache'];
        if (p is! Map) break;
        final pid = p['id'] as String?;
        if (pid == null || pid.isEmpty) break;
        final pcover = p['cover'] as String?;
        if (pcover != null && pcover.isNotEmpty) {
          _saveLinkCover(pid, pcover);
        }
        final plyric = p['lyric'] as String?;
        if (plyric != null && plyric.isNotEmpty) {
          if (_lyricCache.length > 8) _lyricCache.clear();
          _lyricCache[pid] = plyric;
        }
      case LinkMsgType.hello:
        break;
      case LinkMsgType.pong:
      case LinkMsgType.bye:
        break;
      case LinkMsgType.cloudBind:
        _onCloudBind(msg.payload['cloud_bind']);
      default:
        break;
    }
  }

  Future<void> _onCloudBind(Object? bind) async {
    if (bind is! Map) return;
    final key = bind['key'] as String?;
    final url = bind['url'] as String?;
    if (key == null || key.isEmpty) return;
    _cloudKey = key;
    if (url != null && url.isNotEmpty) _cloudUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('watch.cloudKey', _cloudKey);
    if (_cloudUrl.isNotEmpty) {
      await prefs.setString('watch.cloudUrl', _cloudUrl);
    }
    if (state.phase == LinkPhase.disconnected && state.autoEnabled) {
      _reconnect?.cancel();
      _backoff = _minBackoff;
      _attemptConnect();
    }
  }

  // ---- 权限 ----

  void _onPermission(bool granted) {
    if (granted &&
        state.autoEnabled &&
        state.pairedAddress != null &&
        state.phase == LinkPhase.disconnected) {
      _attemptConnect();
    }
  }

  void _send(LinkMessage msg) {
    try {
      for (final frame in encodeFrames(msg, nextSeq: _nextSeq)) {
        if (_viaCloud) {
          _cloud.send(frame);
        } else {
          _channel.send(frame);
        }
      }
    } catch (_) {}
  }

  String? _linkCoverPathFor(String songId) {
    if (songId.isEmpty) return null;
    return '${Directory.systemTemp.path}'
        '/xianyu_link_cover_${songId.hashCode.abs() % 0x7FFFFFFF}.jpg';
  }

  Future<String?> _saveLinkCover(String songId, String base64Data) async {
    try {
      final bytes = base64Decode(base64Data);
      if (bytes.isEmpty) return null;
      final f = File(_linkCoverPathFor(songId)!);
      await f.writeAsBytes(bytes, flush: true);
      try {
        final dir = Directory.systemTemp;
        final olds =
            dir
                .listSync()
                .whereType<File>()
                .where(
                  (e) =>
                      e.path.startsWith('${dir.path}/xianyu_link_cover_') &&
                      e.path != f.path,
                )
                .toList()
              ..sort(
                (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
              );
        for (var i = 2; i < olds.length; i++) {
          try {
            olds[i].deleteSync();
          } catch (_) {}
        }
      } catch (_) {}
      return f.path;
    } catch (_) {
      return null;
    }
  }
}

final linkControllerProvider = StateNotifierProvider<LinkController, LinkState>(
  (ref) {
    final controller = LinkController();
    controller.isAmbient = () => ref.read(ambientModeProvider);
    return controller;
  },
);
