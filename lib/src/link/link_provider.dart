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

/// 云端中继默认地址（服务端 `/watch-relay`，可用手机下发的 url 覆盖）。
const String kDefaultCloudRelayUrl = 'wss://api.xianyumusic.cn/watch-relay';

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
    this.daily = false,
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final String? cover;
  final double duration;

  /// 是否来自日推队列（播放页据此显示「不喜欢」按钮）。
  final bool daily;

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

/// 联接状态（手表侧 UI 订阅）。
class LinkState {
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

  /// 当前链路是否走云端中继（false = 蓝牙 RFCOMM）。
  final bool viaCloud;

  /// 手机推送的当前歌歌词（结构化 payload JSON）及其歌曲 id。
  /// id 与 now.id 不一致表示歌词尚未到达/已过期，歌词页显示占位。
  final String? lyricSongId;
  final String? lyricPayload;

  /// 手机端主动发起、待手表确认的配对请求（非空时 UI 弹确认框）。
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

/// 手表端联接控制器：自动连接 + 心跳保活 + 重连退避 + 状态分发。
///
/// 保活（协议约定）：手表 3s ping，10s 无任何帧判掉线；断开后指数退避
/// 1→30s 自动重连，连接成功（收到 onConnection true）后复位退避。
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

  /// 当前链路是否走云端中继（false = 蓝牙 RFCOMM）。
  bool _viaCloud = false;

  /// 云端绑定凭据（手机经 `cloud_bind` 帧下发，持久化）。
  String _cloudKey = '';
  String _cloudUrl = '';

  /// 云连接尝试进行中（防重入）。
  bool _cloudTryActive = false;

  /// 手机预载的歌词缓存（id → payload）：precache 帧先到，切歌 now_playing
  /// 到达时立即命中，免等手机重发。上限防膨胀。
  final Map<String, String> _lyricCache = {};

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
    _subs.add(_channel.onIncomingPair.listen(_onIncomingPair));
    _subs.add(_cloud.onRaw.listen(_onRaw));
    _subs.add(_cloud.onEvent.listen(_onCloudEvent));
    // 反向配对服务端：手机可主动发起连接，手表端弹确认。
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
      // 设置-手机联动总开关：关闭时不自动连接（手动重连仍可用）。
      final linkageOn = prefs.getBool('watchLinkageEnabled') ?? true;
      if (linkageOn) _attemptConnect();
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
    _cloud.close();
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

  /// 采纳手机端发起的配对请求（确认弹窗「允许」）：把手机地址持久化为
  /// 配对设备——否则进程重启（手动打开/被杀复活/切模式重启）后回到未
  /// 配对态，必须重新配对。写入完成后再 accept，连接建立时已落盘。
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

  /// 拒绝手机端发起的配对请求（确认弹窗「拒绝」）。
  void rejectIncoming() {
    _channel.rejectPair();
    state = state.copyWith(incomingName: '', incomingAddress: '');
  }

  /// 手机端主动连入（反向配对）：忙时静默拒绝，空闲时弹确认。
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
    if ((addr == null || addr.isEmpty)) {
      // 无蓝牙配对但有云端凭据：直接走云。
      if (_cloudKey.isNotEmpty) _tryCloud();
      return;
    }
    _wasExpectingConnect = true;
    state = state.copyWith(phase: LinkPhase.connecting);
    _channel.connect(addr);
  }

  void _onConnection(LinkConnectionEvent evt) {
    _reconnect?.cancel();
    // 任何连接结果到达，未决的配对弹窗即失效（可能已被 accept 采纳）。
    state = state.copyWith(incomingName: '', incomingAddress: '');
    if (evt.connected) {
      _decoder = FrameDecoder();
      _viaCloud = false;
      _backoff = _minBackoff;
      _lastFrame = DateTime.now();
      state = state.copyWith(
        phase: LinkPhase.connected,
        phoneName: evt.name,
        now: null,
        isPlaying: false,
        liked: false,
        position: 0,
        viaCloud: false,
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
      if (wasConnected || _wasExpectingConnect) {
        // 云端兜底：蓝牙不可达时立即尝试云（凭据在手），不再等满退避；
        // 云也失败则并入原退避循环（下轮先蓝牙后云）。
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

  /// 发起云中继连接（角色 watch，凭据 device_key）。
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
        _onCloudUp(evt.peerName);
      case CloudLinkEvent.peerLost:
        // 手机端离线：链路死亡，走统一拆除 + 退避重连。
        if (_viaCloud) _killLink(reschedule: true);
      case CloudLinkEvent.replaced:
        // 同 key 被新连接替换：静默让位，不重连（避免与新连接互踢）。
        if (_viaCloud) _killLink(reschedule: false);
      case CloudLinkEvent.closed:
        _cloudTryActive = false;
        if (_viaCloud) {
          _killLink(reschedule: true);
        } else if (state.phase == LinkPhase.connecting) {
          // 云连接尝试失败：并入退避循环（下轮先蓝牙）。
          _scheduleReconnect();
        }
    }
  }

  void _onCloudUp(String name) {
    _cloudTryActive = false;
    _viaCloud = true;
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
      viaCloud: true,
    );
    _send(LinkMessage.hello(
      ver: kLinkProtocolVersion,
      role: 'watch',
      name: '弦予腕上',
    ));
    _startAlive();
  }

  /// 统一链路拆除：断开当前传输（按 [_viaCloud] 分派）、复位状态、按需重连。
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
        // 10s 无帧判死：主动断开，onConnection(false)/cloud closed 将触发退避重连。
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
        // 预载封面命中：手机起播时提前推过的封面已在本机（precache 落盘
        // 同一命名），直接挂文件路径——免等 coverData 重传，更免在线歌
        // 手表二次拉 URL（联动切歌几秒丢封面的主因）。
        final preCover = _linkCoverPathFor(now.id);
        state = state.copyWith(
          now: preCover != null && File(preCover).existsSync()
              ? now.copyWith(cover: preCover)
              : now,
          position: 0,
        );
        // 预载歌词命中：歌词立刻可用；手机随后重发的同内容 lyric 帧幂等。
        final cachedLyric = _lyricCache[now.id];
        if (cachedLyric != null) {
          state = state.copyWith(lyricSongId: now.id, lyricPayload: cachedLyric);
        }
        // 手机端本地歌封面（base64 JPEG）：落盘后挂到 now 上，背景/小封面复用
        // 文件路径链路。序号守卫防异步写盘期间切歌导致错挂。
        final coverData = msg.payload['coverData'] as String?;
        if (coverData != null && coverData.isNotEmpty) {
          _saveLinkCover(now.id, coverData).then((path) {
            if (path == null || state.now?.id != now.id) return;
            state = state.copyWith(now: state.now!.copyWith(cover: path));
          });
        }
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
      case LinkMsgType.lyric:
        final lyric = msg.payload['lyric'];
        if (lyric is! Map) break;
        final id = lyric['id'] as String?;
        final payload = lyric['payload'] as String?;
        if (id == null || id.isEmpty || payload == null) break;
        state = state.copyWith(lyricSongId: id, lyricPayload: payload);
      case LinkMsgType.precache:
        // 下一首预载：封面按 id 落盘（与 now_playing coverData 同一命名，
        // 切歌时命中）、歌词进缓存；静默接收，不影响当前 UI 状态。
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
        // 手机侧 hello（握手回应），phoneName 以 onConnection 事件为准。
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

  /// 手机下发的云端兜底绑定：持久化凭据；未连接时立即尝试建链。
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
    // 蓝牙已连着则暂不动；断连状态下立即用新凭据建链。
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
    } catch (_) {
      // 发送失败静默：断连由读线程统一上报。
    }
  }

  /// 联动封面落盘路径（与 [_saveLinkCover] 同一命名；预载命中检查用）。
  String? _linkCoverPathFor(String songId) {
    if (songId.isEmpty) return null;
    return '${Directory.systemTemp.path}'
        '/xianyu_link_cover_${songId.hashCode.abs() % 0x7FFFFFFF}.jpg';
  }

  /// 联动封面落盘：按歌曲 id 命名（FileImage/背景模糊按路径缓存，同名覆盖
  /// 会切歌不刷新），保留最新 3 张，其余清理防堆积。
  Future<String?> _saveLinkCover(String songId, String base64Data) async {
    try {
      final bytes = base64Decode(base64Data);
      if (bytes.isEmpty) return null;
      final f = File(_linkCoverPathFor(songId)!);
      await f.writeAsBytes(bytes, flush: true);
      // 清理旧封面（保留当前 + 最新 2 张）。
      try {
        final dir = Directory.systemTemp;
        final olds = dir
            .listSync()
            .whereType<File>()
            .where((e) =>
                e.path.startsWith('${dir.path}/xianyu_link_cover_') &&
                e.path != f.path)
            .toList()
          ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
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

/// 联接控制器 provider（main 启动时 init）。
final linkControllerProvider =
    StateNotifierProvider<LinkController, LinkState>((ref) {
  final controller = LinkController();
  // 注入环境模式探针：ambient 下暂停秒级进度刷新（省电 + 防烧屏）。
  controller.isAmbient = () => ref.read(ambientModeProvider);
  return controller;
});
