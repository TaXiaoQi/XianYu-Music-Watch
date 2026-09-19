import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_provider.dart';
import 'player_provider.dart';

class ListenStatsState {
  final double localTotal;

  final double localDaily;

  final double pendingTotal;
  final double pendingDaily;

  final int serverTotal;
  final int serverDaily;
  final int serverWeekly;

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
  }) => ListenStatsState(
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
  static const double _flushThreshold = 60;

  Timer? _tickTimer;
  double _lastPos = -1;
  DateTime _lastTick = DateTime.now();
  String _dailyDate = '';
  bool _reportBusy = false;
  bool _persistDirty = false;
  Timer? _persistTimer;

  Future<void> refresh() => _flush();

  void _tick() {
    final player = _ref.read(playerProvider);
    final now = DateTime.now();
    _rollDayIfNeeded(now);

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

  Future<void> _flush() async {
    if (_reportBusy) return;
    final pendingTotal = state.pendingTotal;
    final pendingDaily = state.pendingDaily;
    if (pendingTotal < 1 && pendingDaily < 1) return;
    if (!_ref.read(authProvider).isLoggedIn) return;
    _reportBusy = true;
    try {
      final data = await _ref
          .read(authProvider.notifier)
          .requestAction('report_listen_stats', {
            'stats_mode': 'delta',
            'delta_duration': pendingTotal.round(),
            'delta_daily_duration': pendingDaily.round(),
          });
      if (data['reset_at'] != null) {
        _dailyDate = _today();
        state = const ListenStatsState(localDaily: 0);
        _lastPos = _ref.read(playerProvider).position;
        _reportBusy = false;
        _schedulePersist();
        return;
      }
      state = state.copyWith(
        pendingTotal: (state.pendingTotal - pendingTotal)
            .clamp(0.0, double.infinity)
            .toDouble(),
        pendingDaily: (state.pendingDaily - pendingDaily)
            .clamp(0.0, double.infinity)
            .toDouble(),
        serverTotal: (data['server_total_duration'] as num?)?.toInt() ?? 0,
        serverDaily: (data['server_daily_duration'] as num?)?.toInt() ?? 0,
        serverWeekly: (data['server_weekly_duration'] as num?)?.toInt() ?? 0,
        synced: true,
      );
      _schedulePersist();
    } catch (_) {
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
    await _persistSnapshot(state, _dailyDate);
  }

  Future<void> _persistSnapshot(ListenStatsState s, String date) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String q(Object v) => v.toString();
      await prefs.setString(
        'listenStats',
        '{'
            '"localTotal":${q(s.localTotal)},'
            '"localDaily":${q(s.localDaily)},'
            '"pendingTotal":${q(s.pendingTotal)},'
            '"pendingDaily":${q(s.pendingDaily)},'
            '"serverTotal":${q(s.serverTotal)},'
            '"serverDaily":${q(s.serverDaily)},'
            '"serverWeekly":${q(s.serverWeekly)},'
            '"synced":${s.synced ? 1 : 0},'
            '"dailyDate":"$date"}',
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _persistTimer?.cancel();
    final dirty = _persistDirty;
    _persistDirty = false;
    if (dirty) {
      unawaited(_persistSnapshot(state, _dailyDate));
    }
    super.dispose();
  }
}

final listenStatsProvider =
    StateNotifierProvider<ListenStatsNotifier, ListenStatsState>(
      (ref) => ListenStatsNotifier(ref),
    );

String formatListenDuration(int secs) {
  if (secs < 60) return '$secs 秒';
  final h = secs ~/ 3600;
  final m = (secs % 3600) ~/ 60;
  if (h <= 0) return '$m 分钟';
  if (m <= 0) return '$h 小时';
  return '$h 小时 $m 分';
}
