import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_provider.dart';
import 'player_provider.dart';

/// 腕上端独立播放的听歌时长统计与增量上报。
///
/// 统计口径与移动端对齐：按播放进度增量结算（position 每周期真实推进的
/// 秒数），播放器死亡/卡死时 position 不动、增量恒为 0，不会虚计时长。
/// 上报走统一 delta 协议（stats_mode="delta"）：只报自上次成功上报后的
/// 增量，服务端做合计并回传账号累计/今日/本周三个真源值，多端显示一致。
class ListenStatsState {
  /// 本端本地累计（秒，独立播放），delta 基线的一部分。
  final double localTotal;

  /// 本端当日累计（秒，跨天自动归零）。
  final double localDaily;

  /// 待上报增量：累计 / 当日（上报失败保留，下轮重试）。
  final double pendingTotal;
  final double pendingDaily;

  /// 服务端账号三源值（登录态显示基准，秒）。
  final int serverTotal;
  final int serverDaily;
  final int serverWeekly;

  /// 是否已完成过一次服务端对齐（false 时卡片显示本地值）。
  final bool synced;

  const ListenStatsState({
    this.localTotal = 0,
    this.localDaily = 0,
    this.pendingTotal = 0,
    this.pendingDaily = 0,
    this.serverTotal = 0,
    this.serverDaily = 0,
    this.serverWeekly = 0,
    this.synced = false,
  });

  /// 显示值 = 服务端真源 + 本端未上报增量（多端一致且实时）。
  int get displayTotal => serverTotal + pendingTotal.round();
  int get displayDaily => serverDaily + pendingDaily.round();
  int get displayWeekly => serverWeekly + pendingDaily.round();

  ListenStatsState copyWith({
    double? localTotal,
    double? localDaily,
    double? pendingTotal,
    double? pendingDaily,
    int? serverTotal,
    int? serverDaily,
    int? serverWeekly,
    bool? synced,
  }) =>
      ListenStatsState(
        localTotal: localTotal ?? this.localTotal,
        localDaily: localDaily ?? this.localDaily,
        pendingTotal: pendingTotal ?? this.pendingTotal,
        pendingDaily: pendingDaily ?? this.pendingDaily,
        serverTotal: serverTotal ?? this.serverTotal,
        serverDaily: serverDaily ?? this.serverDaily,
        serverWeekly: serverWeekly ?? this.serverWeekly,
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
  /// 待上报增量达到该阈值才发起网络请求，表端省电省流量。
  static const double _flushThreshold = 60;

  Timer? _tickTimer;
  double _lastPos = -1;
  DateTime _lastTick = DateTime.now();
  String _dailyDate = '';
  bool _reportBusy = false;
  bool _persistDirty = false;
  Timer? _persistTimer;

  /// 账号页打开时主动对齐一次（零增量也回传服务端现值）。
  Future<void> refresh() => _flush(force: true);

  void _tick() {
    final player = _ref.read(playerProvider);
    final now = DateTime.now();
    _rollDayIfNeeded(now);

    double delta = 0;
    final pos = player.position;
    if (_lastPos >= 0 && pos > _lastPos) {
      final wallSec =
          now.difference(_lastTick).inMilliseconds / 1000.0;
      final d = pos - _lastPos;
      // 超出墙钟的跳变（seek）不计，倒退（切歌归零）不计。
      if (d <= wallSec + 2) delta = d;
    }
    _lastPos = pos;
    _lastTick = now;

    if (delta <= 0) return;
    state = state.copyWith(
      localTotal: state.localTotal + delta,
      localDaily: state.localDaily + delta,
      pendingTotal: state.pendingTotal + delta,
      pendingDaily: state.pendingDaily + delta,
    );
    _schedulePersist();
    if (state.pendingTotal >= _flushThreshold) {
      _flush();
    }
  }

  void _rollDayIfNeeded(DateTime now) {
    final today =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    if (_dailyDate.isEmpty) {
      _dailyDate = today;
      return;
    }
    if (_dailyDate != today) {
      _dailyDate = today;
      state = state.copyWith(localDaily: 0, pendingDaily: 0);
      _schedulePersist();
    }
  }

  Future<void> _flush({bool force = false}) async {
    if (_reportBusy) return;
    final pendingTotal = state.pendingTotal;
    final pendingDaily = state.pendingDaily;
    if (pendingTotal < 1 && pendingDaily < 1) return;
    if (!_ref.read(authProvider).isLoggedIn) return;
    _reportBusy = true;
    try {
      final data = await _ref.read(authProvider.notifier).requestAction(
        'report_listen_stats',
        {
          'stats_mode': 'delta',
          'delta_duration': pendingTotal.round(),
          'delta_daily_duration': pendingDaily.round(),
        },
      );
      if (data['reset_at'] != null) {
        // 服务端重置：本地统计与基线全部清零，从零重新累计。
        _dailyDate = _today();
        state = const ListenStatsState(localDaily: 0);
        _lastPos = _ref.read(playerProvider).position;
        _reportBusy = false;
        _schedulePersist();
        return;
      }
      state = state.copyWith(
        pendingTotal: 0,
        pendingDaily: 0,
        serverTotal: (data['server_total_duration'] as num?)?.toInt() ?? 0,
        serverDaily: (data['server_daily_duration'] as num?)?.toInt() ?? 0,
        serverWeekly: (data['server_weekly_duration'] as num?)?.toInt() ?? 0,
        synced: true,
      );
      _schedulePersist();
    } catch (_) {
      // 失败保留 pending，下轮阈值或 force 重试。
    } finally {
      _reportBusy = false;
    }
  }

  String _today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('listenStats');
      if (raw == null || raw.isEmpty) {
        _dailyDate = _today();
        return;
      }
      // 手写轻量解析，避免引入依赖：键值均为简单类型。
      final m = _decodeFlat(raw);
      _dailyDate = m['dailyDate'] as String? ?? _today();
      final today = _today();
      final stale = _dailyDate != today;
      state = ListenStatsState(
        localTotal: (m['localTotal'] as num?)?.toDouble() ?? 0,
        localDaily: stale ? 0 : (m['localDaily'] as num?)?.toDouble() ?? 0,
        pendingTotal: (m['pendingTotal'] as num?)?.toDouble() ?? 0,
        pendingDaily: stale ? 0 : (m['pendingDaily'] as num?)?.toDouble() ?? 0,
        serverTotal: (m['serverTotal'] as num?)?.toInt() ?? 0,
        serverDaily: stale ? 0 : (m['serverDaily'] as num?)?.toInt() ?? 0,
        serverWeekly: (m['serverWeekly'] as num?)?.toInt() ?? 0,
        synced: m['synced'] == 1,
      );
      if (stale) _schedulePersist();
    } catch (_) {
      _dailyDate = _today();
    }
  }

  /// 平铺 JSON（数字/字符串/布尔），与存储格式一一对应。
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
    try {
      final prefs = await SharedPreferences.getInstance();
      String q(Object v) => v.toString();
      await prefs.setString(
        'listenStats',
        '{'
        '"localTotal":${q(state.localTotal)},'
        '"localDaily":${q(state.localDaily)},'
        '"pendingTotal":${q(state.pendingTotal)},'
        '"pendingDaily":${q(state.pendingDaily)},'
        '"serverTotal":${q(state.serverTotal)},'
        '"serverDaily":${q(state.serverDaily)},'
        '"serverWeekly":${q(state.serverWeekly)},'
        '"synced":${state.synced ? 1 : 0},'
        '"dailyDate":"$_dailyDate"}',
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _persistTimer?.cancel();
    _persistNow();
    super.dispose();
  }
}

final listenStatsProvider =
    StateNotifierProvider<ListenStatsNotifier, ListenStatsState>(
  (ref) => ListenStatsNotifier(ref),
);

/// 秒数 → 紧凑中文时长（账号页显示用）。
String formatListenDuration(int secs) {
  if (secs < 60) return '$secs 秒';
  final h = secs ~/ 3600;
  final m = (secs % 3600) ~/ 60;
  if (h <= 0) return '$m 分钟';
  if (m <= 0) return '$h 小时';
  return '$h 小时 $m 分';
}
