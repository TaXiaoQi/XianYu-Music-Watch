part of 'player_provider.dart';

extension PlayerNotifierSession on PlayerNotifier {
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
      } catch (e) {
        AppLog.warn('session', 'position save failed: $e');
      }
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
    } catch (e) {
      AppLog.warn('session', '播放会话保存失败: $e');
    }
  }

  Future<void> _restoreSession() async {
    try {
      final epoch = _playEpoch;
      String jsonStr = '';
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        jsonStr = await loadPlaybackSession(dbPath: dbPath);
      } catch (e) {
        AppLog.warn('session', '读取数据库播放会话失败: $e');
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
          } catch (e) {
            AppLog.warn('player', '恢复播放速度失败: $e');
          }
        }
        audioHandler?.syncMediaItem(
          currentItem,
          currentItem.durationMs / 1000.0,
        );
        _syncPlaybackState();
      } catch (e) {
        AppLog.warn('session', '恢复会话起播失败: $e');
      }
    } catch (e) {
      AppLog.warn('session', '恢复播放会话异常: $e');
    }
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
}
