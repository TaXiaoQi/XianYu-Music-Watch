import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart' as asrv;
import 'package:audio_session/audio_session.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app.dart';
import '../auth/auth_provider.dart';
import '../effects/sound_effect_provider.dart';
import '../favorites/favorites_provider.dart';
import '../i18n/i18n.dart';

import '../core/db_path.dart';
import '../core/application_logger.dart';
import '../core/settings.dart';
import '../plugin/plugin_catalog.dart';
import '../plugin/plugin_engine.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';
import '../plugin/plugin_search.dart';
import '../rust/api.dart';
import '../sync/playlist_store.dart';
import 'media_url.dart';
import 'online_quality_probe.dart';
import 'stream_cache.dart';

part 'player_provider.queue.dart';
part 'player_provider.session.dart';
part 'player_provider.audio_chain.dart';
part 'player_provider.quality.dart';
part 'player_provider.online.dart';
part 'player_provider.source.dart';
part 'player_provider.types.dart';
part 'player_provider.media_handler.dart';

class PlayerNotifier extends StateNotifier<PlaybackState>
    with WidgetsBindingObserver {
  PlayerNotifier(this._ref) : super(const PlaybackState()) {
    WidgetsBinding.instance.addObserver(this);
    activePlayerNotifier = this;
    audioHandler?.bindNotifier(this);
    _init();
  }

  final Ref _ref;
  // handleInterruptions 关掉 just_audio 内置打断处理：它只会暂停 ExoPlayer，
  // 管不到 DSP 管线；打断响应统一由 _init 里的 interruptionEventStream 接管。
  final AudioPlayer _player = AudioPlayer(handleInterruptions: false);

  /// part 拆分专用：riverpod StateController 同款回收（勿在类外使用）
  @override
  PlaybackState get state => super.state;
  @override
  set state(PlaybackState value) => super.state = value;

  final Random _rand = Random();
  StreamSubscription<Duration?>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<dynamic>? _stateSub;
  StreamSubscription<ProcessingState>? _procSub;
  StreamSubscription<dynamic>? _errSub;
  StreamSubscription<dynamic>? _interruptionSub;
  bool _interruptedByInterruption = false;
  bool _onTrackEndBusy = false;
  DateTime _lastPosPersist = DateTime.fromMillisecondsSinceEpoch(0);
  int _playEpoch = 0;

  bool _switchingSource = false;
  final List<String> _shuffleHistory = [];
  final List<String> _shuffleFuture = [];

  DateTime? _lastAutoSwitchAt;
  String? _lastAutoSwitchPath;
  String _switchCtxKey = '';
  final Set<String> _failedPluginIds = {};
  int _skipDepth = 0;

  String? _currentMediaUrl;
  Map<String, String>? _currentHeaders;
  bool _usedCacheSource = false;

  bool _dspAvailable = kDspPipelineSupported;
  bool _dspSkipNextStart = false;
  bool _dspActive = false;
  Timer? _dspTimer;
  Timer? _sfxSyncTimer;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _persistSession();
    }
  }

  Future<void> _init() async {
    _initAudioFocus();
    _posSub = _player.positionStream.listen((pos) {
      final secs = pos.inMilliseconds / 1000.0;
      state = state.copyWith(position: secs);
      _persistPositionDebounced();
    });
    _durSub = _player.durationStream.listen((d) {
      state = state.copyWith(
        duration: (d ?? Duration.zero).inMilliseconds / 1000.0,
      );
    });
    _stateSub = _player.playerStateStream.listen((ps) {
      if (ps.playing != state.isPlaying) {
        state = state.copyWith(isPlaying: ps.playing);
        _syncPlaybackState();
      }
    });
    _procSub = _player.processingStateStream.listen((ps) {
      if (ps == ProcessingState.completed) {
        _onTrackEnd();
      }
    });
    _errSub = _player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace st) {
        _onPlaybackError(e);
      },
    );
    _ref.listen(soundEffectProvider.select((s) => s.settings), (_, s) {
      _applyEffectSpeedPitch(s);
      _syncDspEffects(s);
    });
    unawaited(() async {
      try {
        final tmp = await getTemporaryDirectory();
        StreamCache.instance.rootDir = tmp.path;
      } catch (e) {
        AppLog.debug('cache', '初始化流缓存目录失败: $e');
      }
    }());
    await _restoreSession();
  }

  /// 会话级在线音质覆盖（播放中切换音质用），持续到用户再改；null = 跟随设置
  String? _sessionQualityOverride;

  /// 当前活跃探测的歌曲键：切歌时失效旧 probe，避免注册表无限膨胀
  String? _activeProbeKey;
  final Map<String, int> _qualitySizeByUrl = {};
  final Set<String> _prewarmKeys = {};

  Future<bool> _playAt(int index, {double startAtSecs = 0}) async {
    if (index < 0 || index >= state.queue.length) return false;
    _playEpoch++;
    final epoch = _playEpoch;
    _switchingSource = true;
    final item = state.queue[index];
    // 切歌时失效旧歌的探测缓存（同曲重播保留，供音质菜单续用）
    final prevCurrent = state.current;
    if (_activeProbeKey != null &&
        (prevCurrent == null || prevCurrent.path != item.path)) {
      onlineQualityProbeRegistry.invalidate(_activeProbeKey!);
      _activeProbeKey = null;
    }
    state = state.copyWith(
      queueIndex: index,
      current: item,
      isPlaying: false,
      position: 0,
      duration: item.durationMs / 1000.0,
      error: null,
    );
    audioHandler?.syncMediaItem(item, item.durationMs / 1000.0);
    try {
      try {
        await _player.stop();
      } catch (e) {
        AppLog.warn('player', '播放器停止失败: $e');
      }
      if (epoch != _playEpoch) return false;
      if (_isDspEligible(item) &&
          await _tryStartDspPipeline(item.path, startAtSecs: startAtSecs)) {
        if (epoch != _playEpoch) return false;
        _skipDepth = 0;
        state = state.copyWith(isPlaying: true, error: null);
        _syncPlaybackState();
        _persistSession();
        return true;
      }
      await _loadItemSource(item);
      if (startAtSecs > 0) {
        try {
          await seek(startAtSecs);
        } catch (e) {
          AppLog.warn('player', '恢复播放进度失败: $e');
        }
      }
      await _player.setVolume(
        _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0,
      );
      if (state.speed != 1.0) {
        try {
          await _player.setSpeed(state.speed);
        } catch (e) {
          AppLog.warn('player', '设置播放速度失败: $e');
        }
      }
      if (epoch != _playEpoch) return false;
      _switchingSource = false;
      await _player.play();
      if (epoch != _playEpoch) return false;
      _skipDepth = 0;
      state = state.copyWith(isPlaying: true, error: null);
      _persistSession();
      return true;
    } catch (e) {
      if (epoch != _playEpoch) return false;
      if (item.onlineSongJson != null && item.onlineSongJson!.isNotEmpty) {
        if (await _autoSwitchSource(item, index: index)) return true;
        final behavior =
            _ref.read(settingsProvider).valueOrNull?.onlineFailureBehavior;
        if (behavior == 'skip' && _skipDepth < state.queue.length) {
          _skipDepth++;
          final next = _pickNextIndex();
          if (next >= 0 && next != index) return _playAt(next);
          _skipDepth = 0;
        }
      }
      state = state.copyWith(isPlaying: false, error: '播放失败：$e');
      _persistSession();
      return false;
    } finally {
      if (epoch == _playEpoch) _switchingSource = false;
    }
  }

  Future<Duration?> _loadItemSource(QueueItem item) async {
    final json = item.onlineSongJson;
    if (json != null && json.isNotEmpty) {
      return _playOnline(item, json);
    }
    return _setLocalSource(item.path);
  }

  /// 在线起播（探测体系版，与移动端 _playOnline 同构）：startBest 沿
  /// 候选链解析直链（并发 3 槽 + 蝰蛇流过滤 + 实际档位归一），命中后沿用
  /// StreamCache 缓存伺服链起播；解析全败抛错走 _autoSwitchSource 换源。
  Future<Duration?> _playOnline(QueueItem item, String json) async {
    final songJson = jsonDecode(json) as Map<String, dynamic>;
    final pluginId = songJson['pluginId'] as String? ?? '';
    if (pluginId.isEmpty) throw StateError('插件信息缺失');
    final s0 = _ref.read(settingsProvider).valueOrNull;
    final preferred = _sessionQualityOverride ??
        s0?.onlineQuality ??
        item.onlineQuality ??
        '320k';
    // 腕上端无降级方向设置，固定向下降级链（对齐移动端默认 lower）
    final candidates = _qualityCandidates(preferred);
    AppLog.info('play', '[playOnline] ${item.title} pluginId=$pluginId '
        'format=${songJson['format']} preferred=$preferred '
        'candidates=$candidates');

    final key = _songProbeKey(songJson, item);
    final probe = onlineQualityProbeRegistry.ensure(
        key, _buildResolveCallback(songJson, item));
    _activeProbeKey = key;

    final start = await probe
        .startBest(preferred, candidates)
        .timeout(const Duration(seconds: 45), onTimeout: () => null);
    if (start == null) {
      final reason = probe.lastFailureReason;
      throw StateError(
          reason == null ? '无法获取播放链接' : _shortResolveReason(reason));
    }
    AppLog.info('play',
        '[playOnline] startBest q=${start.quality} '
        'available=${probe.availableQualities} probing=${probe.probing}');
    state = state.copyWith(currentQuality: start.quality);
    _refreshQualityMenuState(probe);
    unawaited(_prewarmOnlineSizes(item));

    final cleaned = sanitizeMediaUrl(start.url);
    if (cleaned.isEmpty) throw StateError('直链无效');
    final headers = normalizeMediaRequestHeaders(cleaned, start.headers);
    _currentMediaUrl = cleaned;
    _currentHeaders = headers;
    _usedCacheSource = false;
    // 加密流（ekey/cek）走下载解密临时文件路径，不经流缓存伺服（与移动端
    // _startEncryptedFile 同构）：Rust 侧下载+解密落盘后直接 setFilePath，
    // seek/volume/play 由 _playAt 统一接续。
    if ((start.ekey != null && start.ekey!.isNotEmpty) ||
        (start.cek != null && start.cek!.isNotEmpty)) {
      final plainPath = await _decryptUrlToTemp(cleaned, headers,
          ekey: start.ekey, cek: start.cek);
      await _player.setFilePath(plainPath);
      AppLog.info('play',
          '[playOnline] 加密流解密起播 q=${start.quality} '
          'isCenc=${start.ekey == null}');
      return null;
    }
    StreamCache.instance.budgetMB =
        _ref.read(settingsProvider).valueOrNull?.streamCacheSizeMB ?? 200;
    unawaited(StreamCache.instance.settle());
    final cacheSource = await StreamCache.instance.sourceFor(
      cleaned,
      headers: headers,
    );
    if (cacheSource != null) {
      try {
        await _player.setAudioSource(cacheSource);
        _usedCacheSource = true;
        return null;
      } catch (_) {
        await StreamCache.instance.evict(cleaned);
      }
    }
    await _player.setUrl(cleaned, headers: headers);
    return null;
  }

  static const int _decryptCacheMax = 8;
  final Map<String, String> _decryptPathCache = {};

  static int? _parseQualitySize(dynamic size) {
    if (size is num) return size > 0 ? size.toInt() : null;
    if (size is! String) return null;
    final s = size.trim().toLowerCase();
    if (s.isEmpty ||
        s == '0' ||
        s == '未知' ||
        s == 'unknown' ||
        s == '--' ||
        s == '-') {
      return null;
    }
    final m = RegExp(r'^([\d.]+)\s*([kmgt]?b?)$').firstMatch(s);
    if (m == null) return null;
    final v = double.tryParse(m.group(1)!);
    if (v == null || v <= 0) return null;
    final unit = m.group(2)!;
    final mult = switch (unit) {
      'k' || 'kb' => 1024.0,
      'm' || 'mb' => 1024.0 * 1024,
      'g' || 'gb' => 1024.0 * 1024 * 1024,
      't' || 'tb' => 1024.0 * 1024 * 1024 * 1024,
      _ => 1.0,
    };
    return (v * mult).round();
  }

  /// 候选降级链：preferred 本档 + 沿梯子向下展开（腕上端固定 lower）。
  static List<String> _qualityCandidates(String preferred) {
    final result = <String>[];
    if (kQualityLadder.contains(preferred)) result.add(preferred);
    final idx = kQualityLadder.indexOf(preferred);
    if (idx != -1) {
      for (var i = idx - 1; i >= 0; i--) {
        result.add(kQualityLadder[i]);
      }
    }
    if (result.isEmpty) result.add(kQualityLadder.first);
    return result;
  }

  static bool _isPlayableUrl(String? url) =>
      url != null && RegExp(r'^https?://').hasMatch(url);

  Future<void> toggle() async {
    if (state.current == null) return;
    if (_dspActive) {
      if (state.isPlaying) {
        await pauseUsbExclusive();
        state = state.copyWith(isPlaying: false);
      } else {
        await resumeUsbExclusive();
        state = state.copyWith(isPlaying: true);
      }
      _syncPlaybackState();
      _persistSession();
      return;
    }
    if (state.isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
    _persistSession();
  }

  Future<void> resumeFromSystem() async {
    if (state.isPlaying) return;
    await toggle();
  }

  /// 音频焦点：声明音乐媒体会话并监听打断。被其他应用占用输出时暂停当前
  /// 出声主体（DSP 管线必须走 Pause 命令，_player 只控制 ExoPlayer）。
  void _initAudioFocus() {
    AudioSession.instance.then((session) async {
      try {
        await session.configure(const AudioSessionConfiguration.music());
      } catch (e) {
        AppLog.warn('audio_session', 'configure failed: $e');
      }
      _interruptionSub = session.interruptionEventStream.listen((event) async {
        if (!event.begin) {
          // 临时打断（来电/导航语音）结束：仅当打断期间暂停过且设置允许时
          // 自动恢复。永久焦点丢失（type=unknown）不会有结束事件。
          if (_interruptedByInterruption) {
            _interruptedByInterruption = false;
            final auto = _ref.read(settingsProvider).valueOrNull
                    ?.autoResumeAfterInterruption ??
                true;
            if (auto && !state.isPlaying && state.current != null) {
              await _resumeAfterInterruption();
            }
          }
          return;
        }
        if (event.type == AudioInterruptionType.duck) return;
        if (state.isPlaying) {
          _interruptedByInterruption = true;
          await _pauseForInterruption();
        }
      });
    });
  }

  Future<void> _pauseForInterruption() async {
    try {
      if (_dspActive) {
        await pauseUsbExclusive();
        state = state.copyWith(isPlaying: false);
        _syncPlaybackState();
      } else {
        await _player.pause();
      }
    } catch (e) {
      AppLog.warn('playgate', 'interruption pause failed: $e');
    }
    _persistSession();
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      _notifyInterrupted();
    }
  }

  Future<void> _resumeAfterInterruption() async {
    try {
      if (_dspActive) {
        await resumeUsbExclusive();
        state = state.copyWith(isPlaying: true);
        _syncPlaybackState();
      } else {
        await _player.play();
      }
    } catch (e) {
      AppLog.warn('playgate', 'interruption resume failed: $e');
      return;
    }
    _persistSession();
  }

  void _notifyInterrupted() {
    final ctx = appNavKey.currentState?.context;
    if (ctx == null || !ctx.mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      content: Text(tr('音频输出被其他应用占用，已暂停')),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> pauseFromSystem() async {
    if (!state.isPlaying) return;
    await toggle();
  }

  Future<void> seek(double secs) async {
    if (_dspActive) {
      try {
        await seekUsbExclusive(timeSecs: secs, isPlaying: state.isPlaying);
      } catch (e) {
        AppLog.warn('player', 'USB 独占跳转失败: $e');
      }
      state = state.copyWith(position: secs);
      _syncPlaybackState();
      return;
    }
    await _player.seek(Duration(milliseconds: (secs * 1000).round()));
    state = state.copyWith(position: secs);
    _syncPlaybackState();
  }

  Future<void> next() async {
    final i = _pickNextIndex();
    if (i >= 0) await _playAt(i);
  }

  Future<void> previous() async {
    if (state.position > 3) {
      await seek(0);
      return;
    }
    final n = state.queue.length;
    if (n == 0) return;
    if (state.playMode == 2) {
      final i = _randomPrevIndex();
      if (i >= 0) await _playAt(i);
      return;
    }
    final i = state.queueIndex <= 0 ? n - 1 : state.queueIndex - 1;
    await _playAt(i);
  }

  Future<void> setPlayMode(int mode) async {
    final m = mode.clamp(0, 2);
    if (m == state.playMode) return;
    state = state.copyWith(playMode: m);
    _shuffleHistory.clear();
    _shuffleFuture.clear();
    await _ref.read(settingsProvider.notifier).setPlayMode(m);
  }

  Future<void> setVolume(double v) async {
    final vol = v.clamp(0.0, 1.0);
    await _ref.read(settingsProvider.notifier).setVolume(vol);
    if (_dspActive) {
      try {
        await setUsbExclusiveVolume(volume: vol);
      } catch (e) {
        AppLog.warn('player', '独占音量下发失败: $e');
      }
      return;
    }
    try {
      await _player.setVolume(
        _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0,
      );
    } catch (e) {
      AppLog.warn('player', '音量设置失败: $e');
    }
  }

  Future<void> setSpeed(double s) async {
    final v = s.clamp(0.5, 3.0);
    state = state.copyWith(speed: v);
    try {
      await _player.setSpeed(v);
    } catch (e) {
      AppLog.warn('player', '设置播放速度失败: $e');
    }
    if (_dspActive) {
      _syncDspEffects(_ref.read(soundEffectProvider).settings);
    }
    _syncPlaybackState();
    await _ref.read(settingsProvider.notifier).setPlaybackSpeed(v);
  }

  Future<void> _onTrackEnd() async {
    if (_onTrackEndBusy) return;
    _onTrackEndBusy = true;
    try {
      if (state.playMode == 1) {
        await seek(0);
        await _player.play();
        return;
      }
      final next = _pickNextIndex();
      if (next < 0) {
        await _player.pause();
        if (state.current != null) await seek(0);
        return;
      }
      await _playAt(next);
    } finally {
      _onTrackEndBusy = false;
    }
  }

  Future<void> _onPlaybackError(Object e) async {
    if (_switchingSource) return;
    if (state.current == null) return;
    final item = state.current!;
    if (item.onlineSongJson != null && item.onlineSongJson!.isNotEmpty) {
      final url = _currentMediaUrl;
      if (_usedCacheSource && url != null) {
        await StreamCache.instance.evict(url);
      }
      if (await _autoSwitchSource(item, index: state.queueIndex)) return;
      final behavior =
          _ref.read(settingsProvider).valueOrNull?.onlineFailureBehavior;
      if (behavior == 'skip' && _skipDepth < state.queue.length) {
        _skipDepth++;
        final next = _pickNextIndex();
        if (next >= 0 && next != state.queueIndex) {
          await _playAt(next);
          return;
        }
        _skipDepth = 0;
      }
      if (_usedCacheSource && url != null) {
        try {
          await _player.stop();
          await _player.setUrl(url, headers: _currentHeaders ?? const {});
          await _player.setVolume(
            _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0,
          );
          await _player.play();
          state = state.copyWith(isPlaying: true, error: null);
          return;
        } catch (e) {
          AppLog.warn('player', '缓存源重试起播失败: $e');
        }
      }
    }
    state = state.copyWith(isPlaying: false, error: '播放中断：$e');
  }

  Future<bool?> toggleFavorite() async {
    final item = state.current;
    if (item == null) return null;
    return _ref
        .read(favoritesProvider.notifier)
        .toggle(
          FavoriteEntry(
            path: item.path,
            title: item.title,
            artist: item.artist,
            album: item.album,
            durationMs: item.durationMs,
            coverPath: item.coverPath,
            coverUrl: item.coverUrl,
            onlineSongJson: item.onlineSongJson,
            onlineQuality: item.onlineQuality,
            source: item.source,
            onlineInfoJson: item.onlineInfoJson,
            addedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
  }

  Future<bool> dislikeDaily() async {
    final item = state.current;
    if (item == null) return false;
    final ciyuanxiId = _ref.read(authProvider).user?.ciyuanxiId?.trim() ?? '';
    if (ciyuanxiId.isEmpty) return false;
    try {
      await _ref.read(authProvider.notifier).requestAction(
        'report_daily_dislike',
        {
          'ciyuanxi_id': ciyuanxiId,
          'song_name': item.title,
          'singer': item.artist,
        },
      );
    } catch (e) {
      AppLog.warn('play', '上报不喜欢的歌失败: $e');
    }
    await next();
    return true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _procSub?.cancel();
    _errSub?.cancel();
    _interruptionSub?.cancel();
    _stopDspPolling();
    _sfxSyncTimer?.cancel();
    unawaited(_stopDsp());
    _player.dispose();
    super.dispose();
  }
}

final volumeProvider = Provider<double>((ref) {
  return ref.watch(settingsProvider.select((s) => s.valueOrNull?.volume)) ??
      1.0;
});

final playerProvider = StateNotifierProvider<PlayerNotifier, PlaybackState>(
  (ref) => PlayerNotifier(ref),
);

WatchAudioHandler? audioHandler;
PlayerNotifier? activePlayerNotifier;
