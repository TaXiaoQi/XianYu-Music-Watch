import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../core/db_path.dart';
import '../core/settings.dart';
import '../rust/api.dart';

/// 播放中的单曲信息（移动端 QueueItem 精简版：仅本地播放所需字段）。
class QueueItem {
  final String path;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  /// 本地歌曲封面缩略图文件路径。
  final String? coverPath;
  const QueueItem({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    this.durationMs = 0,
    this.coverPath,
  });

  QueueItem copyWith({String? coverPath}) => QueueItem(
        path: path,
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs,
        coverPath: coverPath ?? this.coverPath,
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
      error: error == _noChange ? this.error : error as String?,
    );
  }
}

const Object _noChange = Object();

class PlayerNotifier extends StateNotifier<PlaybackState>
    with WidgetsBindingObserver {
  PlayerNotifier(this._ref) : super(const PlaybackState()) {
    WidgetsBinding.instance.addObserver(this);
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

  Future<void> _playAt(int index, {double startAtSecs = 0}) async {
    if (index < 0 || index >= state.queue.length) return;
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
    try {
      // 切歌即停上一首：加载窗口内不得让上一首继续出声。
      try {
        await _player.stop();
      } catch (_) {}
      if (epoch != _playEpoch) return;
      await _setLocalSource(item.path);
      if (startAtSecs > 0) {
        try {
          await seek(startAtSecs);
        } catch (_) {}
      }
      await _player.setVolume(
          _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0);
      if (epoch != _playEpoch) return;
      await _player.play();
      if (epoch != _playEpoch) return;
      state = state.copyWith(isPlaying: true, error: null);
    } catch (e) {
      if (epoch != _playEpoch) return;
      state = state.copyWith(isPlaying: false, error: '播放失败：$e');
      debugPrint('[play] 本地播放失败 path=${item.path} error=$e');
    }
    _persistSession();
  }

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

  Future<void> removeFromQueue(int index) async {
    final queue = [...state.queue];
    if (index < 0 || index >= queue.length) return;
    final wasCurrent = index == state.queueIndex;
    queue.removeAt(index);
    if (queue.isEmpty) {
      _playEpoch++;
      await _player.stop();
      state = const PlaybackState();
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
    state = state.copyWith(isPlaying: false, error: '播放中断：$e');
    debugPrint('[play] 播放错误: $e');
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
        ));
      }

      final curIdx = queue.indexWhere((q) => q.path == curPath);
      final currentItem = curIdx >= 0 ? queue[curIdx] : queue.first;
      state = PlaybackState(
        queue: queue,
        queueIndex: curIdx >= 0 ? curIdx : 0,
        current: currentItem,
        isPlaying: false,
        position: pos,
        playMode: mode,
      );
      try {
        await _player.setFilePath(currentItem.path);
        await seek(pos);
        await _player.setVolume(
            _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0);
      } catch (e) {
        debugPrint('[session] 本地曲目预加载失败: $e');
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
