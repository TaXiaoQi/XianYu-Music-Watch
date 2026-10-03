part of 'player_provider.dart';

extension PlayerNotifierSourceSwitch on PlayerNotifier {
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
    final quality = _preferredOnlineQuality;

    if (!isMfFormatValue(songJson['format'] as String?)) {
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
            if (result == null || !PlayerNotifier._isPlayableUrl(url)) {
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
}
