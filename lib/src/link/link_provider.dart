import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/ambient.dart';
import 'protocol.dart';
import 'rfcomm_client.dart';

/// 链路阶段。
enum LinkPhase { disconnected, connecting, connected }

/// 手机正在播放的歌曲（now_playing 帧）。
class LinkNowPlaying {
  const LinkNowPlaying({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    this.cover,
    required this.duration,
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final String? cover;
  final double duration;

  /// 封面是否为本地文件路径（否则按 http URL 渲染）。
  bool get coverIsFile =>
      cover != null && cover!.isNotEmpty && !cover!.startsWith('http');

  static LinkNowPlaying fromPayload(Map<String, dynamic> p) => LinkNowPlaying(
        id: p['id'] as String? ?? '',
        title: p['title'] as String? ?? '',
        artist: p['artist'] as String? ?? '',
        album: p['album'] as String? ?? '',
        cover: p['cover'] as String?,
        duration: (p['duration'] as num?)?.toDouble() ?? 0,
      );
}

/// 联接状态（手表侧 UI 订阅）。
class LinkState {
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
  });

  final LinkPhase phase;
  final String phoneName;

  /// 联动开关：关闭后不再自动重连（控制页可手动断开）。
  final bool autoEnabled;

  /// 用户选择（持久化）的手机地址；null 表示尚未配对选择。
  final String? pairedAddress;
  final String? pairedName;

  final LinkNowPlaying? now;
  final bool isPlaying;
  final LinkPlayMode playMode;
  final bool liked;
  final double? volume;

  /// 显示进度（本地 1s 插值 + 手机 position 帧校正）。
  final double position;

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
  }) =>
      LinkState(
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
        volume:
            volume == _noChange ? this.volume : volume as double?,
        position: position ?? this.position,
      );
}

const Object _noChange = Object();

/// 手表端联接控制器：自动连接 + 心跳保活 + 重连退避 + 状态分发。
///
/// 保活（协议约定）：手表 3s ping，10s 无任何帧判掉线；断开后指数退避
/// 1→30s 自动重连，连接成功（收到 onConnection true）后复位退避。
class LinkController extends StateNotifier<LinkState> {
  LinkController() : super(const LinkState());

  final LinkClientChannel _channel = LinkClientChannel();
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

  /// 拉起回调：收到 now_playing 且应用在后台时触发
  ///（Kotlin 侧发 fullScreenIntent 高优先级通知拉起控制页）。
  void Function(String title, String artist)? onBackgroundNowPlaying;

  /// 环境模式（熄屏常显）探针：true 时暂停进度插值与位置帧应用，
  /// 避免常显期间每秒重绘耗电（provider 工厂注入，读 ambientModeProvider）。
  bool Function()? isAmbient;

  /// 初始化（main 启动时调用一次）。
  Future<void> init() async {
    _channel.bind();
    onBackgroundNowPlaying = (title, artist) {
      _channel.notifyNowPlaying(title, artist);
    };
    _subs.add(_channel.onRaw.listen(_onRaw));
    _subs.add(_channel.onConnection.listen(_onConnection));
    _subs.add(_channel.onPermission.listen(_onPermission));

    final prefs = await SharedPreferences.getInstance();
    final addr = prefs.getString('watch.pairedAddress');
    final name = prefs.getString('watch.pairedName');
    final auto = prefs.getBool('watch.autoEnabled') ?? true;
    state = state.copyWith(
      autoEnabled: auto,
      pairedAddress: addr,
      pairedName: name,
    );
    if (addr != null && auto) {
      _attemptConnect();
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _heartbeat?.cancel();
    _interpolate?.cancel();
    _reconnect?.cancel();
    _channel.disconnect();
    super.dispose();
  }

  // ---- 用户操作 ----

  /// 选择手机并连接（持久化地址，之后自动重连）。
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

  /// 手动断开：停止自动重连（保留配对地址）。
  Future<void> disconnectManually() async {
    _reconnect?.cancel();
    _stopAlive();
    state = state.copyWith(phase: LinkPhase.disconnected, now: null);
    await _channel.disconnect();
  }

  /// 联动开关。
  Future<void> setAutoEnabled(bool v) async {
    state = state.copyWith(autoEnabled: v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('watch.autoEnabled', v);
    if (v) {
      final addr = state.pairedAddress;
      if (addr != null && state.phase == LinkPhase.disconnected) {
        _backoff = _minBackoff;
        _attemptConnect();
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
  void cycleMode() => _sendCmd(LinkCmdAction.mode);
  void seek(double pos) =>
      _sendCmd(LinkCmdAction.seek, arg: {'pos': pos});

  /// 表冠调音量（0..1，UI 侧节流后调用）。
  void setVolume(double v) =>
      _sendCmd(LinkCmdAction.volume, arg: {'v': v.clamp(0.0, 1.0)});

  /// 手动重试连接（退避复位）。
  void retry() {
    _reconnect?.cancel();
    _backoff = _minBackoff;
    state = state.copyWith(phase: LinkPhase.disconnected);
    _attemptConnect();
  }

  /// 已配对设备列表（设备选择页用）。
  Future<List<BondedDevice>> loadPairedDevices() =>
      _channel.pairedDevices();

  /// 蓝牙权限状态与申请（设备选择页用）。
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
    if (addr == null || addr.isEmpty) return;
    _wasExpectingConnect = true;
    state = state.copyWith(phase: LinkPhase.connecting);
    _channel.connect(addr);
  }

  void _onConnection(LinkConnectionEvent evt) {
    _reconnect?.cancel();
    if (evt.connected) {
      _decoder = FrameDecoder();
      _backoff = _minBackoff;
      _lastFrame = DateTime.now();
      state = state.copyWith(
        phase: LinkPhase.connected,
        phoneName: evt.name,
        now: null,
        isPlaying: false,
        liked: false,
        position: 0,
      );
      _send(LinkMessage.hello(
        ver: kLinkProtocolVersion,
        role: 'watch',
        name: '弦予腕上',
      ));
      _startAlive();
    } else {
      // 连接失败/断开：视阶段决定是否自动重连。
      final wasConnected = state.phase == LinkPhase.connected;
      _stopAlive();
      state = state.copyWith(
        phase: LinkPhase.disconnected,
        now: null,
        isPlaying: false,
        position: 0,
      );
      if (wasConnected || _wasExpectingConnect) _scheduleReconnect();
      _wasExpectingConnect = false;
    }
  }

  /// connect 发起后到结果回传前的窗口标记（失败也退避重试）。
  bool _wasExpectingConnect = false;

  void _scheduleReconnect() {
    if (!state.autoEnabled || state.pairedAddress == null) return;
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
      _send(LinkMessage(LinkMsgType.ping, {'t': DateTime.now().millisecondsSinceEpoch}));
      if (DateTime.now().difference(_lastFrame) > _deadAfter) {
        // 10s 无帧判死：主动断开，onConnection(false) 将触发退避重连。
        _wasExpectingConnect = true;
        _channel.disconnect();
      }
    });
    _interpolate = Timer.periodic(const Duration(seconds: 1), (_) {
      if (state.phase != LinkPhase.connected || !state.isPlaying) return;
      if (isAmbient?.call() ?? false) return; // 环境模式：暂停刷新省电
      final now = state.now;
      if (now == null) return;
      final p = state.position + 1;
      state = state.copyWith(
        position: p >= now.duration ? now.duration : p,
      );
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
        state = state.copyWith(now: now, position: 0);
        // 高德腕上式拉起：手机开播而手表在后台 → fullScreenIntent。
        final lifecycle =
            WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
        if (lifecycle != AppLifecycleState.resumed) {
          onBackgroundNowPlaying?.call(now.title, now.artist);
        }
      case LinkMsgType.position:
        if (isAmbient?.call() ?? false) break; // 环境模式：不应用，保持静态帧
        state = state.copyWith(
          position: (msg.payload['pos'] as num?)?.toDouble() ?? 0,
        );
      case LinkMsgType.hello:
        // 手机侧 hello（握手回应），phoneName 以 onConnection 事件为准。
        break;
      case LinkMsgType.pong:
      case LinkMsgType.bye:
        break;
      default:
        break;
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
        _channel.send(frame);
      }
    } catch (_) {
      // 发送失败静默：断连由读线程统一上报。
    }
  }
}

/// 联接控制器 provider（main 启动时 init）。
final linkControllerProvider =
    StateNotifierProvider<LinkController, LinkState>((ref) {
  final controller = LinkController();
  // 注入环境模式探针：ambient 下暂停秒级进度刷新（省电 + 防烧屏）。
  controller.isAmbient = () => ref.read(ambientModeProvider);
  return controller;
});
