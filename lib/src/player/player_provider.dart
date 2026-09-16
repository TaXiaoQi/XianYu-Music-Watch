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

/// 播放中的单曲信息（移动端 QueueItem 精简版：本地 + 在线插件歌所需字段）。
class QueueItem {
  final String path;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  /// 本地歌曲封面缩略图文件路径。
  final String? coverPath;
  /// 在线插件歌：歌曲 JSON（pluginId/format/source/musicInfo），非空则走插件解析直链。
  final String? onlineSongJson;
  /// 在线歌曲封面 URL。
  final String? coverUrl;
  /// 请求音质档（320k/flac 等，默认 320k）。
  final String? onlineQuality;
  /// 音源标签（wy/tx/kg 等，LX 插件歌歌词兜底用）。
  final String? source;
  /// 在线搜索元数据 JSON（LX 插件歌歌词兜底用，Rust LyricSongInfo 格式）。
  final String? onlineInfoJson;
  /// 来自每日推荐队列：播放页据此显示「不喜欢」按钮（跳过并上报负反馈）。
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

  QueueItem copyWith(
          {String? coverPath, String? coverUrl, String? onlineSongJson}) =>
      QueueItem(
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
  final int playMode; // 0 顺序(列表循环) 1 单曲循环 2 随机
  /// 倍速（独立播放；联动模式恒 1.0 不经此处）。
  final double speed;
  /// 当前播放错误信息（本地播放失败时展示）。
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
    // 留存全局引用：AudioService.init 后台异步完成，构造时 handler 可能
    // 尚未就绪导致 bindNotifier 落空，main 中 init 完成后补绑（同移动端）。
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
  /// 自然播完衔接互斥：completed 事件在起播窗口内可能重复到达，防并发 _playAt。
  bool _onTrackEndBusy = false;
  DateTime _lastPosPersist = DateTime.fromMillisecondsSinceEpoch(0);
  /// 起播流水线代际号：清空队列/删空等「重置」操作递增，_playAt 在每个
  /// await 边界后校验，不一致即放弃后续起播（防「清了还在响、队列复活」）。
  int _playEpoch = 0;
  final List<String> _shuffleHistory = [];
  final List<String> _shuffleFuture = [];

  // —— 在线失败自动换源上下文（对齐移动端口径的表端精简版）——
  /// 同曲防抖：错误事件与起播异常可能先后到达，800ms 内同曲只换源一次。
  DateTime? _lastAutoSwitchAt;
  String? _lastAutoSwitchPath;
  /// 换源上下文按歌曲（标题+歌手）隔离：已失败插件不再重试。
  String _switchCtxKey = '';
  final Set<String> _failedPluginIds = {};

  // —— 流缓存跟踪：当前直链/请求头/是否走了缓存源（错误自愈用）——
  String? _currentMediaUrl;
  Map<String, String>? _currentHeaders;
  bool _usedCacheSource = false;

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
      state = state.copyWith(duration: (d ?? Duration.zero).inMilliseconds / 1000.0);
    });
    _stateSub = _player.playerStateStream.listen((ps) {
      if (ps.playing != state.isPlaying) {
        state = state.copyWith(isPlaying: ps.playing);
        _syncPlaybackState();
      }
    });
    // 自然播完的权威信号：just_audio 在源播完时把 processingState 置为
    // completed（playing 字段不保证翻转），据此自动衔接到队列下一首。
    _procSub = _player.processingStateStream.listen((ps) {
      if (ps == ProcessingState.completed) {
        _onTrackEnd();
      }
    });
    // 播放中途错误（解码失败等）：just_audio 经 playbackEventStream 的
    // onError 上报，统一路由到错误处理，避免「播放器已死但 UI 停在播放中」。
    _errSub = _player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace st) {
        _onPlaybackError(e);
      },
    );
    // 流缓存目录注入（失败不阻塞播放器初始化，之后回退直连）。
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
    } catch (e, st) {
      debugPrint('[play] playQueue 异常: $e\n$st');
      state = state.copyWith(isPlaying: false, error: e.toString());
    }
  }

  /// 起播指定曲目；返回是否成功进入播放（失败已走换源兜底）。
  Future<bool> _playAt(int index, {double startAtSecs = 0}) async {
    if (index < 0 || index >= state.queue.length) return false;
    _playEpoch++;
    final epoch = _playEpoch;
    final item = state.queue[index];
    state = state.copyWith(
      queueIndex: index,
      current: item,
      isPlaying: false,
      position: 0,
      duration: item.durationMs / 1000.0,
      error: null,
    );
    // 切歌即更新系统媒体卡片（标题/封面先行，起播窗口内通知已就绪）。
    audioHandler?.syncMediaItem(item, item.durationMs / 1000.0);
    try {
      // 切歌即停上一首：加载窗口内不得让上一首继续出声。
      try {
        await _player.stop();
      } catch (_) {}
      if (epoch != _playEpoch) return false;
      await _loadItemSource(item);
      if (startAtSecs > 0) {
        try {
          await seek(startAtSecs);
        } catch (_) {}
      }
      await _player.setVolume(
          _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0);
      // just_audio 的 speed 是 player 级设置，切源不重置；这里兜底重申，
      // 覆盖「进程重启后 player 默认 1.0 而设置里存了倍速」的场景。
      if (state.speed != 1.0) {
        try {
          await _player.setSpeed(state.speed);
        } catch (_) {}
      }
      if (epoch != _playEpoch) return false;
      await _player.play();
      if (epoch != _playEpoch) return false;
      state = state.copyWith(isPlaying: true, error: null);
      _persistSession();
      return true;
    } catch (e) {
      if (epoch != _playEpoch) return false;
      debugPrint('[play] 起播失败 path=${item.path} error=$e');
      // 在线歌起播异常：autoswitch 时自动换源，成功即由新 _playAt 接管。
      if (item.onlineSongJson != null && item.onlineSongJson!.isNotEmpty) {
        if (await _autoSwitchSource(item, index: index)) return true;
      }
      state = state.copyWith(isPlaying: false, error: '播放失败：$e');
      _persistSession();
      return false;
    }
  }

  /// 加载曲目音源：在线插件歌走引擎解析直链，本地走文件/URI。
  Future<Duration?> _loadItemSource(QueueItem item) async {
    final json = item.onlineSongJson;
    if (json != null && json.isNotEmpty) {
      return _playPluginSong(json);
    }
    return _setLocalSource(item.path);
  }

  /// 在线插件歌：从插件引擎解析直链并播放（腕上端精简版，无换源回退）。
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
      final result =
          await engine.getMusicUrl(source, sourceKey, musicInfo, quality);
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
    // 清洗直链脏字符 + 按 CDN 域名补齐防盗链请求头（酷狗/网易云等必需）。
    final cleaned = sanitizeMediaUrl(resolved.url);
    if (cleaned.isEmpty) throw StateError('直链无效');
    final headers = normalizeMediaRequestHeaders(cleaned, resolved.headers);
    // 流缓存：预算>0 时走 LockCaching 落盘（重播同链秒开零流量），失败回退直连。
    StreamCache.instance.budgetMB =
        _ref.read(settingsProvider).valueOrNull?.streamCacheSizeMB ?? 200;
    unawaited(StreamCache.instance.settle()); // 释放上一首占用并按预算清理
    _currentMediaUrl = cleaned;
    _currentHeaders = headers;
    _usedCacheSource = false;
    final cacheSource =
        await StreamCache.instance.sourceFor(cleaned, headers: headers);
    if (cacheSource != null) {
      try {
        await _player.setAudioSource(cacheSource);
        _usedCacheSource = true;
        return null;
      } catch (_) {
        // 缓存源起播失败（半截/损坏文件）：清掉该文件后直连重试一次。
        await StreamCache.instance.evict(cleaned);
      }
    }
    await _player.setUrl(cleaned, headers: headers);
    return null;
  }

  Future<PluginSource?> _findPluginSource(
      PluginEngine engine, String pluginId) async {
    final sources = await engine.store.loadSources();
    for (final s in sources) {
      if (s.id == pluginId) return s;
    }
    return null;
  }

  static bool _isPlayableUrl(String? url) =>
      url != null && RegExp(r'^https?://').hasMatch(url);

  /// 加载本地曲目音源（content:// 树文档 URI 播放不可靠，先物化本地副本）。
  Future<Duration?> _setLocalSource(String path) async {
    if (path.startsWith('content://')) {
      return _player.setUrl(path);
    }
    return _player.setFilePath(path);
  }

  Future<void> toggle() async {
    if (state.current == null) return;
    if (state.isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
    _persistSession();
  }

  /// 系统「播放」键：仅暂停中生效。
  Future<void> resumeFromSystem() async {
    if (state.isPlaying) return;
    await toggle();
  }

  /// 系统「暂停」键：仅播放中生效。
  Future<void> pauseFromSystem() async {
    if (!state.isPlaying) return;
    await toggle();
  }

  Future<void> seek(double secs) async {
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

  Future<void> cyclePlayMode() async {
    final next = (state.playMode + 1) % 3;
    state = state.copyWith(playMode: next);
    _shuffleHistory.clear();
    _shuffleFuture.clear();
    await _ref.read(settingsProvider.notifier).setPlayMode(next);
  }

  /// 直接设置播放模式（播放页「更多」面板三选一；0 顺序 / 1 单曲 / 2 随机）。
  Future<void> setPlayMode(int mode) async {
    final m = mode.clamp(0, 2);
    if (m == state.playMode) return;
    state = state.copyWith(playMode: m);
    _shuffleHistory.clear();
    _shuffleFuture.clear();
    await _ref.read(settingsProvider.notifier).setPlayMode(m);
  }

  /// 表冠音量：写设置即联动播放引擎（volumeProvider 链，同移动端）。
  Future<void> setVolume(double v) async {
    await _ref
        .read(settingsProvider.notifier)
        .setVolume(v.clamp(0.0, 1.0));
    try {
      await _player.setVolume(
          _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0);
    } catch (_) {}
  }

  /// 倍速档位（表上低频操作，循环切换即可，同主流手表播放器）。
  static const _speedSteps = [1.0, 1.25, 1.5, 2.0, 0.75];

  /// 循环切换倍速并持久化（跨会话保留，切歌不重置）。
  Future<void> cycleSpeed() async {
    final idx = _speedSteps.indexOf(state.speed);
    final next = _speedSteps[(idx + 1) % _speedSteps.length];
    await setSpeed(next);
  }

  /// 设置播放倍速（0.5–3.0 越界截断）。
  Future<void> setSpeed(double s) async {
    final v = s.clamp(0.5, 3.0);
    state = state.copyWith(speed: v);
    try {
      await _player.setSpeed(v);
    } catch (_) {}
    _syncPlaybackState();
    await _ref.read(settingsProvider.notifier).setPlaybackSpeed(v);
  }

  Future<void> removeFromQueue(int index) async {
    final queue = [...state.queue];
    if (index < 0 || index >= queue.length) return;
    final wasCurrent = index == state.queueIndex;
    queue.removeAt(index);
    if (queue.isEmpty) {
      _playEpoch++;
      await _player.stop();
      state = const PlaybackState();
      audioHandler?.clearNowPlaying();
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

  /// 清空播放队列并停止播放。
  Future<void> clearQueue() async {
    _playEpoch++;
    try {
      await _player.stop();
    } catch (_) {}
    state = const PlaybackState();
    audioHandler?.clearNowPlaying();
  }

  /// 将队列中 [oldIndex] 的歌曲移动到 [newIndex]。
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

  /// 播放队列中指定歌曲。
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

  Future<void> _onPlaybackError(Object e) async {
    if (state.current == null) return;
    debugPrint('[play] 播放错误: $e');
    // 在线歌中途出错：缓存文件自愈 → 自动换源 → 缓存源损坏时直连兜底。
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
              _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0);
          await _player.play();
          state = state.copyWith(isPlaying: true, error: null);
          return;
        } catch (_) {}
      }
    }
    state = state.copyWith(isPlaying: false, error: '播放中断：$e');
  }

  /// 在线歌曲失败自动换源（对齐移动端口径的表端精简版）。
  /// 阶段一：同平台其他启用插件重解析同一首歌（musicInfo 直接复用，成本最低）；
  /// 阶段二：跨启用插件搜索同名歌（标题归一化相等 + 歌手有交集），
  /// 命中后以命中插件的 QueueItem 替换队列条目再起播。
  /// 返回 true 表示换源成功且已重新起播。
  Future<bool> _autoSwitchSource(QueueItem item, {required int index}) async {
    final settings = _ref.read(settingsProvider).valueOrNull;
    if ((settings?.onlineFailureBehavior ?? 'autoswitch') != 'autoswitch') {
      return false;
    }
    // 同曲防抖（移动端同款 800ms）：错误事件与起播异常可能先后到达。
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

    // —— 阶段一：同平台兄弟插件重解析（直链死链场景命中率最高）。
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
                s, sourceKey, Map<String, dynamic>.from(musicInfo), quality);
            final url = result?['url'] as String?;
            if (result == null || !_isPlayableUrl(url)) {
              _failedPluginIds.add(s.id);
              continue;
            }
            final newItem = item.copyWith(
              onlineSongJson:
                  jsonEncode({...songJson, 'pluginId': s.id}),
            );
            return await _replaceAndPlay(newItem, index);
          } catch (_) {
            _failedPluginIds.add(s.id);
          }
        }
      }
    }

    // —— 阶段二：跨插件搜索同名歌（限 3 个插件，防表端越搜越卡）。
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
                await engine.searchInPlugin(s, key, keyword, limit: 10));
          }
        } else {
          hits = await PluginCatalogService(engine, sources)
              .searchMusic(s, keyword, limit: 10);
        }
        final pick = _pickMatch(hits, item.title, item.artist);
        if (pick == null) {
          _failedPluginIds.add(s.id);
          continue;
        }
        final newItem =
            PluginSearchService(engine, sources).toQueueItem(s, pick);
        if (await _replaceAndPlay(newItem, index)) return true;
        _failedPluginIds.add(s.id);
      } catch (_) {
        _failedPluginIds.add(s.id);
      }
    }
    return false;
  }

  /// 替换队列条目并重新起播（换源成功路径）。
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

  /// 从搜索结果里挑同名歌：标题归一化相等 + 歌手有交集；
  /// 兜底放宽为标题互相包含但仍要求歌手有交集（宁停不错）。
  PluginSearchResult? _pickMatch(
      List<PluginSearchResult> hits, String title, String artist) {
    String norm(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[\s（）()【】\[\]·・\-_~～]'), '');
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

  /// 防抖持久化进度（每 5 秒一次），供重启恢复。
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

  /// 持久化播放会话（队列+模式+音量+进度），JSON 结构与移动端兼容
  /// （同 Rust savePlaybackSession，跨端数据可互读）。
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

  /// 启动时恢复上次播放会话（本地曲目预载到暂停态，点击播放续播）。
  Future<void> _restoreSession() async {
    try {
      String jsonStr = '';
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        jsonStr = await loadPlaybackSession(dbPath: dbPath);
      } catch (e) {
        debugPrint('[session] 读取播放会话失败: $e');
      }
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
        queue.add(QueueItem(
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
        ));
      }

      final curIdx = queue.indexWhere((q) => q.path == curPath);
      final currentItem = curIdx >= 0 ? queue[curIdx] : queue.first;
      // 倍速随设置跨会话恢复（设置未就绪时用默认 1.0）。
      final spd =
          _ref.read(settingsProvider).valueOrNull?.playbackSpeed ?? 1.0;
      state = PlaybackState(
        queue: queue,
        queueIndex: curIdx >= 0 ? curIdx : 0,
        current: currentItem,
        isPlaying: false,
        position: pos,
        playMode: mode,
        speed: spd,
      );
      try {
        await _loadItemSource(currentItem);
        await seek(pos);
        await _player.setVolume(
            _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0);
        if (spd != 1.0) {
          try {
            await _player.setSpeed(spd);
          } catch (_) {}
        }
        // 恢复态也挂上媒体卡片（暂停态通知，表上可一键续播）。
        audioHandler?.syncMediaItem(currentItem, currentItem.durationMs / 1000.0);
        _syncPlaybackState();
      } catch (e) {
        debugPrint('[session] 曲目预加载失败: $e');
      }
    } catch (e) {
      debugPrint('[session] 恢复播放会话异常: $e');
    }
  }

  String _titleFromPath(String p) {
    final name = p.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 同步系统媒体通知的播放状态（播放/暂停键翻转与进度 seek 时调用）。
  void _syncPlaybackState() {
    audioHandler?.syncPlaybackState(
      isPlaying: state.isPlaying,
      positionSecs: state.position,
      speed: state.speed,
    );
  }

  /// 切换当前歌收藏状态（独立模式红心；联动模式红心走手机链路，不经此处）。
  /// 返回切换后是否已收藏；无当前歌返回 null。
  Future<bool?> toggleFavorite() async {
    final item = state.current;
    if (item == null) return null;
    return _ref.read(favoritesProvider.notifier).toggle(FavoriteEntry(
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
        ));
  }

  /// 「不喜欢」日推歌：上报负反馈后跳到下一首（同移动端播放页口径）。
  /// 返回 false = 无曲目或未登录未执行（UI 据此提示）；上报失败不阻断跳歌。
  Future<bool> dislikeDaily() async {
    final item = state.current;
    if (item == null) return false;
    final ciyuanxiId =
        _ref.read(authProvider).user?.ciyuanxiId?.trim() ?? '';
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
    _player.dispose();
    super.dispose();
  }
}

/// 音量（与设置联动，同移动端：写设置即全链路生效）。
final volumeProvider = Provider<double>((ref) {
  return ref.watch(settingsProvider.select((s) => s.valueOrNull?.volume)) ?? 1.0;
});

final playerProvider = StateNotifierProvider<PlayerNotifier, PlaybackState>(
  (ref) => PlayerNotifier(ref),
);

/// 全局 AudioService 处理器（main 中后台 init 完成后赋值）与最近创建的
/// 播放控制器（init 晚于 PlayerNotifier 构造时补绑用，同移动端模式）。
WatchAudioHandler? audioHandler;
PlayerNotifier? activePlayerNotifier;

/// 系统媒体通知（MediaSession）与 Flutter 播放状态的双向桥梁
///（腕上精简版：上一首/播放暂停/下一首 + 进度 seek，无收藏/模式自定义键）。
class WatchAudioHandler extends asrv.BaseAudioHandler with asrv.SeekHandler {
  PlayerNotifier? _notifier;

  void bindNotifier(PlayerNotifier notifier) {
    _notifier = notifier;
  }

  /// 广播当前歌的系统媒体卡片（标题/歌手/专辑/封面/时长）。
  void syncMediaItem(QueueItem item, double durationSecs) {
    mediaItem.add(asrv.MediaItem(
      id: item.path,
      album: item.album.isEmpty ? '弦予音乐' : item.album,
      title: item.title,
      artist: item.artist.isEmpty ? '未知歌手' : item.artist,
      // 时长无效时不下发 0：0 会被部分系统判定无效元数据，卡片不显示。
      duration: durationSecs > 0
          ? Duration(milliseconds: (durationSecs * 1000).round())
          : null,
      artUri: _artUriFor(item),
    ));
  }

  /// 通知卡片封面：本地缩略图优先（表上加载网络图慢且费电），无则退网络 URL。
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

  /// 广播系统播放状态（上一首/播放暂停/下一首三键 + 进度 seek）。
  void syncPlaybackState({
    required bool isPlaying,
    required double positionSecs,
    double speed = 1.0,
  }) {
    playbackState.add(asrv.PlaybackState(
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
    ));
  }

  /// 队列清空/停止：撤掉媒体通知并退出前台服务。
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
