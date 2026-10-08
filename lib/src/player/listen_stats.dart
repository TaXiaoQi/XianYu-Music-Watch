import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_provider.dart';
import '../core/application_logger.dart';
import '../i18n/i18n.dart';
import 'player_provider.dart';

/// 听歌时长 v2：事件流水 + 服务端唯一账本。
///
/// 旧协议（本地 pending + 服务端快照合并显示）已废弃：两处状态合并显示，
/// 任何一环断（弱网超时/回执缺字段）就与排行榜脱节。v2 原则：
/// 1. 客户端零账本——只产「听歌事件」流水（幂等 id + 秒数 + 发生时刻），
///    服务端 INSERT IGNORE 去重入账，重发/断网重试都不会算错账。
/// 2. 显示只读云端——登录后一律显示服务端现算快照，与排行榜同源。
///    未登录（无账本）才退回本地会话累计。

class ListenStatsState {
  /// 本地会话累计：仅未登录时用于显示；登录后以云端账本为准
  final double localTotal;
  final double localDaily;

  final int serverTotal;
  final int serverDaily;
  final int serverWeekly;

  /// 队列未入账余额（离线/弱网期间的真实播放，尚未被服务端确认）。
  /// 显示 = 快照 + 余额：离线时数字照常涨，联网回执后归零收敛。
  final int pendingTotal;
  final int pendingDaily;

  /// true = 已从云端拿到账本，显示走云端；false = 未登录/未同步，显示本地
  final bool synced;

  const ListenStatsState({
    this.localTotal = 0,
    this.localDaily = 0,
    this.serverTotal = 0,
    this.serverDaily = 0,
    this.serverWeekly = 0,
    this.pendingTotal = 0,
    this.pendingDaily = 0,
    this.synced = false,
  });

  int get displayTotal =>
      synced ? serverTotal + pendingTotal : localTotal.round();
  int get displayDaily =>
      synced ? serverDaily + pendingDaily : localDaily.round();
  int get displayWeekly => synced ? serverWeekly : 0;

  ListenStatsState copyWith({
    double? localTotal,
    double? localDaily,
    int? serverTotal,
    int? serverDaily,
    int? serverWeekly,
    int? pendingTotal,
    int? pendingDaily,
    bool? synced,
  }) => ListenStatsState(
    localTotal: localTotal ?? this.localTotal,
    localDaily: localDaily ?? this.localDaily,
    serverTotal: serverTotal ?? this.serverTotal,
    serverDaily: serverDaily ?? this.serverDaily,
    serverWeekly: serverWeekly ?? this.serverWeekly,
    pendingTotal: pendingTotal ?? this.pendingTotal,
    pendingDaily: pendingDaily ?? this.pendingDaily,
    synced: synced ?? this.synced,
  );
}

class ListenStatsNotifier extends StateNotifier<ListenStatsState> {
  ListenStatsNotifier(this._ref) : super(const ListenStatsState()) {
    _restore();
    _tickTimer = Timer.periodic(_tickInterval, (_) => _tick());
  }

  final Ref _ref;
  static const Duration _tickInterval = Duration(seconds: 15);

  // ---- 云端事件流水（v2）：60 秒聚合一个幂等事件 ----
  static const String _queueKey = 'listen_events_queue_v2';
  static const int _eventThresholdSecs = 60;
  static const int _maxEventSecs = 600;
  static const int _maxBatch = 200;
  static const int _maxQueue = 2000;

  // 快照拉取节律：复用既有 15s tick 节流（5 分钟一次），本机不播放时也能
  // 追平多端聚合值；_lastEchoAt 为最近一次成功回执时刻，播放中回执自带
  // 最新快照，50 秒内有过回执则跳过拉取
  static const int _pullIntervalSecs = 300;
  int _lastEchoAt = 0;
  int _lastPullAt = 0;

  Timer? _tickTimer;
  double _lastPos = -1;
  DateTime _lastTick = DateTime.now();
  String _dailyDate = '';
  double _eventAccum = 0;
  List<Map<String, dynamic>> _queue = [];
  bool _queueLoaded = false;
  bool _busy = false;
  bool _persistDirty = false;
  Timer? _persistTimer;

  Future<void> refresh() => _flush(force: true);

  void _rollDayIfNeeded() {
    final today = _today();
    if (_dailyDate.isEmpty) {
      _dailyDate = today;
      return;
    }
    if (_dailyDate != today) {
      _dailyDate = today;
      state = state.copyWith(localDaily: 0, serverDaily: 0);
      _schedulePersist();
    }
  }

  void _tick() {
    unawaited(_maybePullServerSnapshot());
    final player = _ref.read(playerProvider);
    final now = DateTime.now();
    _rollDayIfNeeded();

    double delta = 0;
    final pos = player.position;
    if (_lastPos >= 0 && pos > _lastPos) {
      final wallSec = now.difference(_lastTick).inMilliseconds / 1000.0;
      final d = pos - _lastPos;
      final speed = player.speed > 0 ? player.speed : 1.0;
      if (d <= wallSec * speed + 2) delta = d;
    }
    _lastPos = pos;
    _lastTick = now;

    if (delta <= 0) return;
    state = state.copyWith(
      localTotal: state.localTotal + delta,
      localDaily: state.localDaily + delta,
    );
    _schedulePersist();

    // 事件流水：确认真实听到的秒数，60 秒聚合一个幂等事件
    _eventAccum += delta;
    if (_eventAccum >= _eventThresholdSecs) {
      final secs = _eventAccum.floor();
      _eventAccum -= secs;
      _enqueue(secs);
    }
  }

  void _enqueue(int secs) {
    if (secs <= 0 || secs > _maxEventSecs) return;
    final r = Random();
    _queue.add({
      'id': '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
          '${r.nextInt(0x7fffffff).toRadixString(36)}',
      'secs': secs,
      'ended_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    if (_queue.length > _maxQueue) {
      _queue.removeRange(0, _queue.length - _maxQueue);
    }
    _persistQueue();
    _refreshPending();
    _scheduleFlush();
  }

  /// 重算队列未入账余额：从队列现算无增量漂移；联网回执后归零
  void _refreshPending() {
    int pendingTotal = 0;
    int pendingDaily = 0;
    final today = utc8DayKey(DateTime.now().millisecondsSinceEpoch);
    for (final e in _queue) {
      final secs = (e['secs'] as num?)?.toInt() ?? 0;
      if (secs <= 0) continue;
      pendingTotal += secs;
      final endedAt = (e['ended_at'] as num?)?.toInt() ?? 0;
      if (utc8DayKey(endedAt * 1000) == today) pendingDaily += secs;
    }
    if (pendingTotal != state.pendingTotal ||
        pendingDaily != state.pendingDaily) {
      state = state.copyWith(
        pendingTotal: pendingTotal,
        pendingDaily: pendingDaily,
      );
      _schedulePersist();
    }
  }

  String utc8DayKey(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(
      ms + 8 * 3600 * 1000,
      isUtc: true,
    );
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  void _scheduleFlush() {
    // 入队后 5 秒内上报（_busy 并发闸防抖；弱网失败原样保留队列）
    Timer(const Duration(seconds: 5), () {
      unawaited(_flush());
    });
  }

  Future<void> _flush({bool force = false}) async {
    if (_busy || !_queueLoaded) return;
    if (!_ref.read(authProvider).isLoggedIn) return;
    if (!force && _queue.isEmpty) return;
    _busy = true;
    try {
      final batch = _queue.take(_maxBatch).toList();
      final data = await _ref.read(authProvider.notifier).requestAction(
        'report_listen_events',
        {
          'ciyuanxi_id': _ref.read(authProvider).user?.ciyuanxiId ??
              _ref.read(authProvider).user?.id ??
              '',
          'batch_id': DateTime.now().microsecondsSinceEpoch.toRadixString(36),
          'events': batch,
        },
      );
      if (data['reset_at'] != null) {
        _queue.clear();
        _persistQueue();
        state = const ListenStatsState();
        _lastPos = _ref.read(playerProvider).position;
        _eventAccum = 0;
        _schedulePersist();
        return;
      }
      // 成功：删掉已发送的最老 batch.length 条（新事件在尾部不受影响）
      if (batch.length >= _queue.length) {
        _queue.clear();
      } else {
        _queue.removeRange(0, batch.length);
      }
      _persistQueue();
      _lastEchoAt = DateTime.now().millisecondsSinceEpoch;
      _refreshPending(); // 回执快照已含刚入账的秒数，余额重算后归零
      state = state.copyWith(
        serverTotal: (data['server_total_duration'] as num?)?.toInt() ?? 0,
        serverDaily: (data['server_daily_duration'] as num?)?.toInt() ?? 0,
        serverWeekly: (data['server_weekly_duration'] as num?)?.toInt() ?? 0,
        synced: true,
      );
      _schedulePersist();
    } catch (e) {
      AppLog.debug('stats', '听歌事件上报失败（队列保留，稍后重试）: $e');
    } finally {
      _busy = false;
    }
  }

  // 纯快照拉取：零上报，不产生入账。登录后显示一律走云端账本。
  Future<void> _maybePullServerSnapshot() async {
    if (_busy) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastPullAt < _pullIntervalSecs * 1000) return;
    if (!_ref.read(authProvider).isLoggedIn) return;
    if (nowMs - _lastEchoAt < 50000) return;
    _lastPullAt = nowMs;
    _busy = true;
    try {
      final data = await _ref.read(authProvider.notifier).requestAction(
        'get_listen_stats_summary',
        {
          'ciyuanxi_id': _ref.read(authProvider).user?.ciyuanxiId ??
              _ref.read(authProvider).user?.id ??
              '',
        },
      );
      if (data['reset_at'] != null) {
        _queue.clear();
        _persistQueue();
        state = const ListenStatsState();
        _lastPos = _ref.read(playerProvider).position;
        _eventAccum = 0;
        _schedulePersist();
        return;
      }
      _lastEchoAt = nowMs;
      state = state.copyWith(
        serverTotal: (data['server_total_duration'] as num?)?.toInt() ?? 0,
        serverDaily: (data['server_daily_duration'] as num?)?.toInt() ?? 0,
        serverWeekly: (data['server_weekly_duration'] as num?)?.toInt() ?? 0,
        synced: true,
      );
      _schedulePersist();
    } catch (e) {
      AppLog.debug('stats', '拉取云端听歌统计快照失败: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('listenStats');
      if (raw != null && raw.isNotEmpty) {
        final m = _decodeFlat(raw);
        final dailyDate = m['dailyDate'] as String? ?? _today();
        final stale = dailyDate != _today();
        state = ListenStatsState(
          localTotal: (m['localTotal'] as num?)?.toDouble() ?? 0,
          localDaily: stale ? 0 : (m['localDaily'] as num?)?.toDouble() ?? 0,
          serverTotal: (m['serverTotal'] as num?)?.toInt() ?? 0,
          serverDaily: stale ? 0 : (m['serverDaily'] as num?)?.toInt() ?? 0,
          serverWeekly: (m['serverWeekly'] as num?)?.toInt() ?? 0,
          synced: m['synced'] == 1,
        );
      }
      final queueRaw = prefs.getString(_queueKey);
      if (queueRaw != null && queueRaw.isNotEmpty) {
        final list = jsonDecode(queueRaw) as List? ?? const [];
        _queue = [
          for (final e in list)
            if (e is Map &&
                e['id'] is String &&
                e['secs'] is num &&
                (e['secs'] as num) > 0)
              Map<String, dynamic>.from(e),
        ];
        if (_queue.isNotEmpty) {
          _refreshPending();
          _scheduleFlush();
        }
      }
    } catch (e) {
      AppLog.debug('stats', '恢复听歌统计状态失败: $e');
    }
    _queueLoaded = true;
  }

  String _today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Map<String, Object?> _decodeFlat(String raw) {
    final out = <String, Object?>{};
    final body = raw.trim();
    if (body.length < 2 || !body.startsWith('{') || !body.endsWith('}')) {
      return out;
    }
    for (final pair in body.substring(1, body.length - 1).split(',')) {
      final idx = pair.indexOf(':');
      if (idx <= 0) continue;
      final key = pair.substring(0, idx).trim();
      final value = pair.substring(idx + 1).trim();
      if (value == 'true') {
        out[key] = 1;
      } else if (value == 'false') {
        out[key] = 0;
      } else if (value.startsWith('"') && value.endsWith('"')) {
        out[key] = value.substring(1, value.length - 1);
      } else {
        out[key] = double.tryParse(value) ?? int.tryParse(value) ?? 0;
      }
    }
    return out;
  }

  void _schedulePersist() {
    _persistDirty = true;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(seconds: 5), _persistNow);
  }

  Future<void> _persistNow() async {
    if (!_persistDirty) return;
    _persistDirty = false;
    await _persistSnapshot(state);
  }

  Future<void> _persistSnapshot(ListenStatsState s) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String q(Object v) => v.toString();
      await prefs.setString(
        'listenStats',
        '{'
            '"localTotal":${q(s.localTotal)},'
            '"localDaily":${q(s.localDaily)},'
            '"serverTotal":${q(s.serverTotal)},'
            '"serverDaily":${q(s.serverDaily)},'
            '"serverWeekly":${q(s.serverWeekly)},'
            '"synced":${s.synced ? 1 : 0},'
            '"dailyDate":"${_today()}"}',
      );
    } catch (e) {
      AppLog.warn('stats', '听歌时长本地保存失败: $e');
    }
  }

  Future<void> _persistQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_queueKey, jsonEncode(_queue));
    } catch (e) {
      AppLog.debug('stats', '写入听歌事件队列失败: $e');
    }
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _persistTimer?.cancel();
    final dirty = _persistDirty;
    _persistDirty = false;
    if (dirty) {
      unawaited(_persistSnapshot(state));
    }
    super.dispose();
  }
}

final listenStatsProvider =
    StateNotifierProvider<ListenStatsNotifier, ListenStatsState>(
      (ref) => ListenStatsNotifier(ref),
    );

String formatListenDuration(int secs) {
  if (secs < 60) return tr('{n} 秒', {'n': secs});
  final h = secs ~/ 3600;
  final m = (secs % 3600) ~/ 60;
  if (h <= 0) return tr('{n} 分钟', {'n': m});
  if (m <= 0) return tr('{n} 小时', {'n': h});
  return tr('{n} 小时 {m} 分', {'n': h, 'm': m});
}
