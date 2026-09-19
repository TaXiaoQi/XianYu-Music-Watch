import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart' as asrv;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../auth/auth_provider.dart';
import '../effects/sound_effect_provider.dart';
import '../favorites/favorites_provider.dart';

import '../core/db_path.dart';
import '../core/settings.dart';
import '../plugin/plugin_catalog.dart';
import '../plugin/plugin_engine.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';
import '../plugin/plugin_search.dart';
import '../rust/api.dart';
import 'media_url.dart';
import 'stream_cache.dart';

class QueueItem {
  final String path;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final String? coverPath;
  final String? onlineSongJson;
  final String? coverUrl;
  final String? onlineQuality;
  final String? source;
  final String? onlineInfoJson;
  final bool fromDailyRecommend;
  const QueueItem({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    this.durationMs = 0,
    this.coverPath,
    this.onlineSongJson,
    this.coverUrl,
    this.onlineQuality,
    this.source,
    this.onlineInfoJson,
    this.fromDailyRecommend = false,
  });

  QueueItem copyWith({
    String? coverPath,
    String? coverUrl,
    String? onlineSongJson,
  }) => QueueItem(
    path: path,
    title: title,
    artist: artist,
    album: album,
    durationMs: durationMs,
    coverPath: coverPath ?? this.coverPath,
    coverUrl: coverUrl ?? this.coverUrl,
    onlineSongJson: onlineSongJson ?? this.onlineSongJson,
    onlineQuality: onlineQuality,
    source: source,
    onlineInfoJson: onlineInfoJson,
    fromDailyRecommend: fromDailyRecommend,
  );
}

class PlaybackState {
  final QueueItem? current;
  final List<QueueItem> queue;
  final int queueIndex;
  final bool isPlaying;
  final double position;
  final double duration;
  final int playMode;
  final double speed;
  final String? error;
  const PlaybackState({
    this.current,
    this.queue = const [],
    this.queueIndex = -1,
    this.isPlaying = false,
    this.position = 0,
    this.duration = 0,
    this.playMode = 0,
    this.speed = 1.0,
    this.error,
  });

  PlaybackState copyWith({
    QueueItem? current,
    List<QueueItem>? queue,
    int? queueIndex,
    bool? isPlaying,
    double? position,
    double? duration,
    int? playMode,
    double? speed,
    Object? error = _noChange,
  }) {
    return PlaybackState(
      current: current ?? this.current,
      queue: queue ?? this.queue,
      queueIndex: queueIndex ?? this.queueIndex,
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      playMode: playMode ?? this.playMode,
      speed: speed ?? this.speed,
      error: error == _noChange ? this.error : error as String?,
    );
  }
}

const Object _noChange = Object();

class PlayerNotifier extends StateNotifier<PlaybackState>
    with WidgetsBindingObserver {
  PlayerNotifier(this._ref) : super(const PlaybackState()) {
    WidgetsBinding.instance.addObserver(this);
    activePlayerNotifier = this;
    audioHandler?.bindNotifier(this);
    _init();
  }

  final Ref _ref;
  final AudioPlayer _player = AudioPlayer();
  final Random _rand = Random();
  StreamSubscription<Duration?>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<dynamic>? _stateSub;
  StreamSubscription<ProcessingState>? _procSub;
  StreamSubscription<dynamic>? _errSub;
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

  String? _currentMediaUrl;
  Map<String, String>? _currentHeaders;
  bool _usedCacheSource = false;

  bool _dspAvailable = kDspPipelineSupported;
  bool _dspSkipNextStart = false;
  bool _dspActive = false;
  Timer? _dspTimer;
  Timer? _sfxSyncTimer;

  bool _isDspEligible(QueueItem item) =>
      (item.onlineSongJson == null || item.onlineSongJson!.isEmpty) &&
      !item.path.startsWith('content://');

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _persistSession();
    }
  }

  Future<void> _init() async {
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
      } catch (_) {}
    }());
    await _restoreSession();
  }

  Future<void> playQueue(List<QueueItem> items, {int startIndex = 0}) async {
    if (items.isEmpty) return;
    _shuffleHistory.clear();
    _shuffleFuture.clear();
    state = state.copyWith(
      queue: items,
      queueIndex: startIndex,
      current: items[startIndex],
    );
    try {
      await _playAt(startIndex);
    } catch (e) {
      state = state.copyWith(isPlaying: false, error: e.toString());
    }
  }

  Future<bool> _playAt(int index, {double startAtSecs = 0}) async {
    if (index < 0 || index >= state.queue.length) return false;
    _playEpoch++;
    final epoch = _playEpoch;
    _switchingSource = true;
    final item = state.queue[index];
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
      } catch (_) {}
      if (epoch != _playEpoch) return false;
      if (_isDspEligible(item) &&
          await _tryStartDspPipeline(item.path, startAtSecs: startAtSecs)) {
        if (epoch != _playEpoch) return false;
        state = state.copyWith(isPlaying: true, error: null);
        _syncPlaybackState();
        _persistSession();
        return true;
      }
      await _loadItemSource(item);
      if (startAtSecs > 0) {
        try {
          await seek(startAtSecs);
        } catch (_) {}
      }
      await _player.setVolume(
        _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0,
      );
      if (state.speed != 1.0) {
        try {
          await _player.setSpeed(state.speed);
        } catch (_) {}
      }
      if (epoch != _playEpoch) return false;
      _switchingSource = false;
      await _player.play();
      if (epoch != _playEpoch) return false;
      state = state.copyWith(isPlaying: true, error: null);
      _persistSession();
      return true;
    } catch (e) {
      if (epoch != _playEpoch) return false;
      if (item.onlineSongJson != null && item.onlineSongJson!.isNotEmpty) {
        if (await _autoSwitchSource(item, index: index)) return true;
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
      return _playPluginSong(json);
    }
    return _setLocalSource(item.path);
  }

  Future<Duration?> _playPluginSong(String json) async {
    final songJson = jsonDecode(json) as Map<String, dynamic>;
    final pluginId = songJson['pluginId'] as String? ?? '';
    final format = songJson['format'] as String? ?? 'lx';
    final sourceKey = songJson['source'] as String? ?? '';
    final musicInfo = songJson['musicInfo'] as Map<String, dynamic>? ?? {};
    if (pluginId.isEmpty) throw StateError('插件信息缺失');
    final engine = await _ref.read(pluginEngineProvider.future);
    final source = await _findPluginSource(engine, pluginId);
    if (source == null) throw StateError('插件未安装');
    final quality =
        _ref.read(settingsProvider).valueOrNull?.onlineQuality ?? '320k';

    ResolvedMediaUrl? resolved;
    if (format == 'musicfree') {
      resolved = await engine.getMusicFreeUrl(
        source,
        musicInfo,
        preferred: quality,
        fallback: 'pause',
      );
    } else {
      final result = await engine.getMusicUrl(
        source,
        sourceKey,
        musicInfo,
        quality,
      );
      final url = result?['url'] as String?;
      if (result != null && _isPlayableUrl(url)) {
        final h = result['headers'];
        resolved = ResolvedMediaUrl(
          url: url!,
          headers: h is Map ? h.cast<String, String>() : null,
          quality: quality,
        );
      }
    }
    if (resolved == null) throw StateError('直链解析失败');
    final cleaned = sanitizeMediaUrl(resolved.url);
    if (cleaned.isEmpty) throw StateError('直链无效');
    final headers = normalizeMediaRequestHeaders(cleaned, resolved.headers);
    StreamCache.instance.budgetMB =
        _ref.read(settingsProvider).valueOrNull?.streamCacheSizeMB ?? 200;
    unawaited(StreamCache.instance.settle());
    _currentMediaUrl = cleaned;
    _currentHeaders = headers;
    _usedCacheSource = false;
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

  Future<PluginSource?> _findPluginSource(
    PluginEngine engine,
    String pluginId,
  ) async {
    final sources = await engine.store.loadSources();
    for (final s in sources) {
      if (s.id == pluginId) return s;
    }
    return null;
  }

  static bool _isPlayableUrl(String? url) =>
      url != null && RegExp(r'^https?://').hasMatch(url);

  Future<Duration?> _setLocalSource(String path) async {
    if (path.startsWith('content://')) {
      return _player.setUrl(path);
    }
    return _player.setFilePath(path);
  }

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

  Future<void> pauseFromSystem() async {
    if (!state.isPlaying) return;
    await toggle();
  }

  Future<void> seek(double secs) async {
    if (_dspActive) {
      try {
        await seekUsbExclusive(timeSecs: secs, isPlaying: state.isPlaying);
      } catch (_) {}
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
      } catch (_) {}
      return;
    }
    try {
      await _player.setVolume(
        _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0,
      );
    } catch (_) {}
  }

  Future<void> setSpeed(double s) async {
    final v = s.clamp(0.5, 3.0);
    state = state.copyWith(speed: v);
    try {
      await _player.setSpeed(v);
    } catch (_) {}
    if (_dspActive) {
      _syncDspEffects(_ref.read(soundEffectProvider).settings);
    }
    _syncPlaybackState();
    await _ref.read(settingsProvider.notifier).setPlaybackSpeed(v);
  }

  Future<void> removeFromQueue(int index) async {
    final queue = [...state.queue];
    if (index < 0 || index >= queue.length) return;
    final wasCurrent = index == state.queueIndex;
    queue.removeAt(index);
    if (queue.isEmpty) {
      await clearQueue();
      return;
    }
    var newIndex = state.queueIndex;
    if (index < state.queueIndex) {
      newIndex = state.queueIndex - 1;
    } else if (index == state.queueIndex) {
      newIndex = index.clamp(0, queue.length - 1);
    }
    if (wasCurrent) {
      await _playAt(newIndex);
    } else {
      state = state.copyWith(queue: queue, queueIndex: newIndex);
    }
  }

  Future<void> clearQueue() async {
    _playEpoch++;
    await _stopDsp();
    try {
      await _player.stop();
    } catch (_) {}
    state = const PlaybackState();
    audioHandler?.clearNowPlaying();
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= state.queue.length) return;
    if (newIndex < 0 || newIndex >= state.queue.length) return;
    final queue = [...state.queue];
    final item = queue.removeAt(oldIndex);
    queue.insert(newIndex, item);
    var qi = state.queueIndex;
    if (oldIndex == qi) {
      qi = newIndex;
    } else if (oldIndex < qi && newIndex >= qi) {
      qi--;
    } else if (oldIndex > qi && newIndex <= qi) {
      qi++;
    }
    state = state.copyWith(queue: queue, queueIndex: qi);
  }

  Future<void> playQueueItem(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    await _playAt(index);
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

  Future<bool> _tryStartDspPipeline(
    String path, {
    required double startAtSecs,
  }) async {
    if (!_dspAvailable) return false;
    if (_dspSkipNextStart) {
      _dspSkipNextStart = false;
      return false;
    }
    try {
      final sfx = _ref.read(soundEffectProvider).settings;
      final vol = _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0;
      await startUsbExclusivePlayback(
        path: path,
        deviceId: -1,
        volume: vol,
        startTimeSecs: startAtSecs,
        isPlaying: true,
        volumeBalanceGain: 1.0,
        equalizerSettingsJson: jsonEncode(sfx.toEqualizerRustJson()),
        soundEffectSettingsJson: jsonEncode(sfx.toRustJson()),
        bitPerfect: false,
        dsdNativePassthrough: false,
        sharedMode: true,
      );
      _dspActive = true;
      _startDspPolling();
      return true;
    } catch (e) {
      _dspActive = false;
      if (e.toString().contains('libaaudio')) {
        _dspAvailable = false;
      }
      return false;
    }
  }

  Future<void> _stopDsp() async {
    _stopDspPolling();
    try {
      await stopUsbExclusivePlayback();
    } catch (_) {}
    _dspActive = false;
  }

  void _startDspPolling() {
    _stopDspPolling();
    _dspTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _pollDsp(),
    );
  }

  void _stopDspPolling() {
    _dspTimer?.cancel();
    _dspTimer = null;
  }

  Future<void> _pollDsp() async {
    if (!_dspActive) return;
    try {
      final pos = await getUsbExclusivePositionSecs();
      state = state.copyWith(position: pos);
      _persistPositionDebounced();
      final infoStr = await getUsbExclusiveDeviceInfo();
      final info = jsonDecode(infoStr) as Map<String, dynamic>;
      final engineDur = (info['durationSecs'] as num?)?.toDouble() ?? 0.0;
      if (engineDur > 0) {
        state = state.copyWith(duration: engineDur);
      }
      final dur = state.duration;
      if (info['active'] != true) {
        if (dur > 0 && pos >= dur - 0.3) {
          await _onDspTrackEnd();
        } else {
          await _onDspDisconnect();
        }
        return;
      }
      if (dur > 0 && pos >= dur - 0.3) {
        await _onDspTrackEnd();
      }
    } catch (_) {}
  }

  Future<void> _onDspDisconnect() async {
    await _stopDsp();
    _dspSkipNextStart = true;
    state = state.copyWith(isPlaying: false);
    await _playAt(state.queueIndex);
  }

  Future<void> _onDspTrackEnd() async {
    await _stopDsp();
    if (state.playMode == 1) {
      await _playAt(state.queueIndex);
      return;
    }
    final next = _pickNextIndex();
    if (next < 0) {
      state = state.copyWith(isPlaying: false, position: 0);
      _syncPlaybackState();
      return;
    }
    await _playAt(next);
  }

  void _syncDspEffects(SoundEffectSettings s) {
    if (!_dspActive) return;
    _sfxSyncTimer?.cancel();
    _sfxSyncTimer = Timer(const Duration(milliseconds: 50), () async {
      try {
        await setUsbExclusiveEqualizer(
          settingsJson: jsonEncode(s.toEqualizerRustJson()),
        );
        final json = s.toRustJson();
        final rate = s.playbackRate.clamp(50.0, 200.0) * state.speed;
        json['playbackRate'] = rate.clamp(50.0, 200.0);
        await setUsbExclusiveSoundEffect(settingsJson: jsonEncode(json));
      } catch (_) {}
    });
  }

  Future<void> _applyEffectSpeedPitch(SoundEffectSettings s) async {
    if (_dspActive) return;
    try {
      final rate = s.playbackRate.clamp(50.0, 200.0) / 100.0;
      await _player.setSpeed(rate);
      if (s.preservesPitch) {
        await _player.setPitch(1.0);
      } else {
        await _player.setPitch(s.pitchShift.clamp(50.0, 200.0) / 100.0);
      }
    } catch (_) {}
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
        } catch (_) {}
      }
    }
    state = state.copyWith(isPlaying: false, error: '播放中断：$e');
  }

  Future<bool> _autoSwitchSource(QueueItem item, {required int index}) async {
    final settings = _ref.read(settingsProvider).valueOrNull;
    if ((settings?.onlineFailureBehavior ?? 'autoswitch') != 'autoswitch') {
      return false;
    }
    final now = DateTime.now();
    if (_lastAutoSwitchPath == item.path &&
        _lastAutoSwitchAt != null &&
        now.difference(_lastAutoSwitchAt!) <
            const Duration(milliseconds: 800)) {
      return false;
    }
    _lastAutoSwitchAt = now;
    _lastAutoSwitchPath = item.path;

    final ctxKey = '${item.title}|${item.artist}';
    if (_switchCtxKey != ctxKey) {
      _switchCtxKey = ctxKey;
      _failedPluginIds.clear();
    }
    if (item.title.trim().isEmpty || index < 0) return false;

    Map<String, dynamic> songJson;
    try {
      songJson = jsonDecode(item.onlineSongJson!) as Map<String, dynamic>;
    } catch (_) {
      return false;
    }
    final failedId = songJson['pluginId'] as String? ?? '';
    if (failedId.isNotEmpty) _failedPluginIds.add(failedId);

    PluginEngine engine;
    List<PluginSource> sources;
    try {
      engine = await _ref.read(pluginEngineProvider.future);
      sources = await engine.store.loadSources();
    } catch (_) {
      return false;
    }
    final enabled = sources.where((s) => s.enabled).toList();
    final quality = settings?.onlineQuality ?? '320k';

    if (songJson['format'] != 'musicfree') {
      final sourceKey = songJson['source'] as String? ?? '';
      final musicInfo = songJson['musicInfo'];
      if (sourceKey.isNotEmpty && musicInfo is Map && musicInfo.isNotEmpty) {
        for (final s in enabled) {
          if (_failedPluginIds.contains(s.id)) continue;
          if (s.format != PluginFormat.lx) continue;
          if (!s.sources.contains(sourceKey)) continue;
          try {
            final result = await engine.getMusicUrl(
              s,
              sourceKey,
              Map<String, dynamic>.from(musicInfo),
              quality,
            );
            final url = result?['url'] as String?;
            if (result == null || !_isPlayableUrl(url)) {
              _failedPluginIds.add(s.id);
              continue;
            }
            final newItem = item.copyWith(
              onlineSongJson: jsonEncode({...songJson, 'pluginId': s.id}),
            );
            return await _replaceAndPlay(newItem, index);
          } catch (_) {
            _failedPluginIds.add(s.id);
          }
        }
      }
    }

    final keyword = '${item.title} ${item.artist}'.trim();
    var tried = 0;
    for (final s in enabled) {
      if (_failedPluginIds.contains(s.id)) continue;
      if (tried >= 3) break;
      tried++;
      try {
        List<PluginSearchResult> hits;
        if (s.format == PluginFormat.lx) {
          final keys = s.sources.isEmpty ? <String>['default'] : s.sources;
          hits = [];
          for (final key in keys) {
            hits.addAll(
              await engine.searchInPlugin(s, key, keyword, limit: 10),
            );
          }
        } else {
          hits = await PluginCatalogService(
            engine,
            sources,
          ).searchMusic(s, keyword, limit: 10);
        }
        final pick = _pickMatch(hits, item.title, item.artist);
        if (pick == null) {
          _failedPluginIds.add(s.id);
          continue;
        }
        final newItem = PluginSearchService(
          engine,
          sources,
        ).toQueueItem(s, pick);
        if (await _replaceAndPlay(newItem, index)) return true;
        _failedPluginIds.add(s.id);
      } catch (_) {
        _failedPluginIds.add(s.id);
      }
    }
    return false;
  }

  Future<bool> _replaceAndPlay(QueueItem newItem, int index) async {
    if (index < 0 || index >= state.queue.length) return false;
    final queue = [...state.queue];
    queue[index] = newItem;
    state = state.copyWith(queue: queue, current: newItem);
    try {
      return await _playAt(index);
    } catch (_) {
      return false;
    }
  }

  PluginSearchResult? _pickMatch(
    List<PluginSearchResult> hits,
    String title,
    String artist,
  ) {
    String norm(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'[\s（）()【】\[\]·・\-_~～]'), '');
    final t = norm(title);
    if (t.isEmpty) return null;
    Set<String> artistSet(String raw) => raw
        .split(RegExp(r'[/、,，&]'))
        .map(norm)
        .where((a) => a.isNotEmpty)
        .toSet();
    final artists = artistSet(artist);
    for (final h in hits) {
      if (norm(h.name) != t) continue;
      if (artists.isEmpty ||
          artistSet(h.singer).intersection(artists).isNotEmpty) {
        return h;
      }
    }
    for (final h in hits) {
      final hn = norm(h.name);
      if ((hn.contains(t) || t.contains(hn)) &&
          artistSet(h.singer).intersection(artists).isNotEmpty) {
        return h;
      }
    }
    return null;
  }

  int _pickNextIndex() {
    final n = state.queue.length;
    if (n == 0) return -1;
    if (state.playMode == 2) {
      return _randomNextIndex();
    }
    if (state.queueIndex < 0) return 0;
    return (state.queueIndex + 1) % n;
  }

  int _randomNextIndex() {
    if (_shuffleFuture.isNotEmpty) {
      final path = _shuffleFuture.removeLast();
      final i = state.queue.indexWhere((q) => q.path == path);
      if (i >= 0) return i;
    }
    if (state.current != null) {
      _shuffleHistory.add(state.current!.path);
      if (_shuffleHistory.length > 256) _shuffleHistory.removeAt(0);
    }
    return _randomDistinctIndex();
  }

  int _randomPrevIndex() {
    if (_shuffleHistory.isNotEmpty) {
      final path = _shuffleHistory.removeLast();
      if (state.current != null) _shuffleFuture.add(state.current!.path);
      final i = state.queue.indexWhere((q) => q.path == path);
      if (i >= 0) return i;
    }
    return _randomDistinctIndex();
  }

  int _randomDistinctIndex() {
    final n = state.queue.length;
    if (n <= 1) return 0;
    final cur = state.current?.path;
    final candidates = <int>[];
    for (var i = 0; i < n; i++) {
      if (state.queue[i].path != cur) candidates.add(i);
    }
    if (candidates.isEmpty) return 0;
    return candidates[_rand.nextInt(candidates.length)];
  }

  void _persistPositionDebounced() {
    final current = state.current;
    if (current == null) return;
    final now = DateTime.now();
    if (now.difference(_lastPosPersist).inSeconds < 5) return;
    _lastPosPersist = now;
    Future(() async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        await updatePlaybackPosition(
          dbPath: dbPath,
          positionSecs: state.position,
          isPlaying: state.isPlaying,
        );
      } catch (_) {}
    });
  }

  Future<void> _persistSession() async {
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final settings = _ref.read(settingsProvider).valueOrNull;
      final item = state.current;
      if (item == null || state.queue.isEmpty) return;

      final queueSongMeta = <String, dynamic>{};
      for (final q in state.queue) {
        queueSongMeta[q.path] = {
          'path': q.path,
          'title': q.title,
          'artist': q.artist,
          'album': q.album,
          'durationMs': q.durationMs,
          'coverPath': q.coverPath,
          'coverUrl': q.coverUrl,
          'onlineSongJson': q.onlineSongJson,
          'onlineQuality': q.onlineQuality,
          'source': q.source,
          'onlineInfoJson': q.onlineInfoJson,
        };
      }

      final sessionJson = jsonEncode({
        'currentSongPath': item.path,
        'playQueuePaths': state.queue.map((q) => q.path).toList(),
        'sourceSongPaths': state.queue.map((q) => q.path).toList(),
        'playMode': state.playMode,
        'volume': (settings?.volume ?? 1.0) * 100.0,
        'currentPositionSecs': state.position,
        'isPlaying': state.isPlaying,
        'sessionQualityOverride': null,
        'queueSongMeta': queueSongMeta,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
      await savePlaybackSession(dbPath: dbPath, sessionJson: sessionJson);
    } catch (_) {}
  }

  Future<void> _restoreSession() async {
    try {
      final epoch = _playEpoch;
      String jsonStr = '';
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        jsonStr = await loadPlaybackSession(dbPath: dbPath);
      } catch (_) {}
      if (jsonStr.isEmpty || jsonStr == 'null') return;

      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final curPath = data['currentSongPath'] as String? ?? '';
      final rawQueue = data['playQueuePaths'] as List? ?? [];
      final rawMeta = data['queueSongMeta'] as Map? ?? {};
      final mode = (data['playMode'] as num?)?.toInt() ?? 0;
      final pos = (data['currentPositionSecs'] as num?)?.toDouble() ?? 0;

      if (rawQueue.isEmpty || curPath.isEmpty) return;

      final queue = <QueueItem>[];
      for (final p in rawQueue) {
        final pathStr = p as String;
        final meta = rawMeta[pathStr] as Map<String, dynamic>?;
        queue.add(
          QueueItem(
            path: pathStr,
            title: meta?['title'] as String? ?? _titleFromPath(pathStr),
            artist: meta?['artist'] as String? ?? '',
            album: meta?['album'] as String? ?? '',
            durationMs: (meta?['durationMs'] as num?)?.toInt() ?? 0,
            coverPath: meta?['coverPath'] as String?,
            coverUrl: meta?['coverUrl'] as String?,
            onlineSongJson: meta?['onlineSongJson'] as String?,
            onlineQuality: meta?['onlineQuality'] as String?,
            source: meta?['source'] as String?,
            onlineInfoJson: meta?['onlineInfoJson'] as String?,
          ),
        );
      }

      final curIdx = queue.indexWhere((q) => q.path == curPath);
      final currentItem = curIdx >= 0 ? queue[curIdx] : queue.first;
      final spd = _ref.read(settingsProvider).valueOrNull?.playbackSpeed ?? 1.0;
      if (_playEpoch != epoch) return;
      state = PlaybackState(
        queue: queue,
        queueIndex: curIdx >= 0 ? curIdx : 0,
        current: currentItem,
        isPlaying: false,
        position: pos,
        playMode: mode,
        speed: spd,
      );
      if (_playEpoch != epoch) return;
      try {
        await _loadItemSource(currentItem);
        if (_playEpoch != epoch) return;
        await seek(pos);
        await _player.setVolume(
          _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0,
        );
        if (spd != 1.0) {
          try {
            await _player.setSpeed(spd);
          } catch (_) {}
        }
        audioHandler?.syncMediaItem(
          currentItem,
          currentItem.durationMs / 1000.0,
        );
        _syncPlaybackState();
      } catch (_) {}
    } catch (_) {}
  }

  String _titleFromPath(String p) {
    final name = p.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  void _syncPlaybackState() {
    audioHandler?.syncPlaybackState(
      isPlaying: state.isPlaying,
      positionSecs: state.position,
      speed: state.speed,
    );
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
    } catch (_) {}
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

class WatchAudioHandler extends asrv.BaseAudioHandler with asrv.SeekHandler {
  PlayerNotifier? _notifier;

  void bindNotifier(PlayerNotifier notifier) {
    _notifier = notifier;
  }

  void syncMediaItem(QueueItem item, double durationSecs) {
    mediaItem.add(
      asrv.MediaItem(
        id: item.path,
        album: item.album.isEmpty ? '弦予音乐' : item.album,
        title: item.title,
        artist: item.artist.isEmpty ? '未知歌手' : item.artist,
        duration: durationSecs > 0
            ? Duration(milliseconds: (durationSecs * 1000).round())
            : null,
        artUri: _artUriFor(item),
      ),
    );
  }

  Uri? _artUriFor(QueueItem item) {
    final local = item.coverPath;
    if (local != null &&
        local.isNotEmpty &&
        !local.startsWith('http') &&
        File(local).existsSync()) {
      return Uri.file(local);
    }
    final url = item.coverUrl;
    if (url != null && url.isNotEmpty) return Uri.tryParse(url);
    return null;
  }

  void syncPlaybackState({
    required bool isPlaying,
    required double positionSecs,
    double speed = 1.0,
  }) {
    playbackState.add(
      asrv.PlaybackState(
        controls: [
          asrv.MediaControl.skipToPrevious,
          if (isPlaying) asrv.MediaControl.pause else asrv.MediaControl.play,
          asrv.MediaControl.skipToNext,
        ],
        systemActions: const {
          asrv.MediaAction.seek,
          asrv.MediaAction.seekForward,
          asrv.MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: asrv.AudioProcessingState.ready,
        playing: isPlaying,
        updatePosition: Duration(milliseconds: (positionSecs * 1000).round()),
        bufferedPosition: Duration(milliseconds: (positionSecs * 1000).round()),
        speed: speed,
      ),
    );
  }

  void clearNowPlaying() {
    mediaItem.add(null);
    playbackState.add(asrv.PlaybackState());
    stop();
  }

  @override
  Future<void> play() => _notifier?.resumeFromSystem() ?? Future.value();

  @override
  Future<void> pause() => _notifier?.pauseFromSystem() ?? Future.value();

  @override
  Future<void> skipToNext() => _notifier?.next() ?? Future.value();

  @override
  Future<void> skipToPrevious() => _notifier?.previous() ?? Future.value();

  @override
  Future<void> seek(Duration position) =>
      _notifier?.seek(position.inMilliseconds / 1000.0) ?? Future.value();
}
