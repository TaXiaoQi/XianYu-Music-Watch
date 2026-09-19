import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_provider.dart';
import '../core/db_path.dart';
import '../favorites/favorites_provider.dart';
import '../plugin/plugin_provider.dart';
import '../plugin/plugin_subscriptions.dart';
import '../plugin/plugin_sync_crypto.dart';
import '../plugin/plugin_user_vars.dart';
import '../rust/api.dart' as rust;
import 'playlist_store.dart';

class SyncState {
  final bool autoSync;
  final bool syncing;
  final DateTime? lastSyncAt;
  final String lastSummary;
  final String? error;

  const SyncState({
    this.autoSync = true,
    this.syncing = false,
    this.lastSyncAt,
    this.lastSummary = '',
    this.error,
  });

  SyncState copyWith({
    bool? autoSync,
    bool? syncing,
    DateTime? lastSyncAt,
    String? lastSummary,
    String? error,
    bool clearError = false,
  }) => SyncState(
    autoSync: autoSync ?? this.autoSync,
    syncing: syncing ?? this.syncing,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    lastSummary: lastSummary ?? this.lastSummary,
    error: clearError ? null : (error ?? this.error),
  );
}

class SyncNotifier extends StateNotifier<SyncState> {
  SyncNotifier(this._ref) : super(const SyncState()) {
    _init();
    _ref.listen<AuthState>(authProvider, (prev, next) {
      final wasIn = prev?.isLoggedIn ?? false;
      if (!wasIn && next.isLoggedIn) {
        syncOnLoginSuccess();
        _startAutoTimer();
      } else if (wasIn && !next.isLoggedIn) {
        _onLogout();
      }
    });
  }

  final Ref _ref;
  static const _autoKey = 'watch_sync_auto_v1';
  static const _loginSyncedKey = 'watch_sync_login_synced_v1';
  static const _syncedFavKey = 'watch_synced_fav_paths_v1';
  static const _cloudPluginIdsKey = 'watch_sync_cloud_plugin_ids_v1';

  bool _loginSyncInProgress = false;
  Timer? _autoTimer;

  @override
  void dispose() {
    _autoTimer?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    state = state.copyWith(autoSync: prefs.getBool(_autoKey) ?? true);
    _startAutoTimer();
  }

  Future<void> setAutoSync(bool v) async {
    state = state.copyWith(autoSync: v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoKey, v);
    _startAutoTimer();
  }

  void _startAutoTimer() {
    _autoTimer?.cancel();
    _autoTimer = null;
    if (!state.autoSync || !_ref.read(authProvider).isLoggedIn) return;
    _autoTimer = Timer.periodic(const Duration(hours: 1), (_) => _autoTick());
  }

  Future<void> _autoTick() async {
    if (state.syncing || !_ref.read(authProvider).isLoggedIn) return;
    await syncUpload();
  }

  Future<void> syncOnLoginSuccess() async {
    if (!state.autoSync || _loginSyncInProgress) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_loginSyncedKey) == true) {
      return;
    }
    _loginSyncInProgress = true;
    try {
      await syncAll();
    } finally {
      _loginSyncInProgress = false;
    }
  }

  Future<void> _onLogout() async {
    _autoTimer?.cancel();
    _autoTimer = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_loginSyncedKey);
    await prefs.remove(_syncedFavKey);
    state = SyncState(autoSync: state.autoSync);
  }

  Future<Map<String, dynamic>> _action(
    String action,
    Map<String, dynamic> body,
  ) async {
    if (!_ref.read(authProvider).isLoggedIn) {
      throw AuthException('请先登录');
    }
    return _ref.read(authProvider.notifier).requestAction(action, body);
  }

  String? get _ciyuanxiId => _ref.read(authProvider).user?.ciyuanxiId;

  Future<void> _runSteps(
    String doneLabel,
    List<(String, Future<void> Function())> steps,
  ) async {
    if (state.syncing) return;
    state = state.copyWith(syncing: true, clearError: true);
    final errors = <String>[];
    for (final (label, run) in steps) {
      try {
        await run();
      } catch (e) {
        errors.add('$label：${e is AuthException ? e.message : e}');
      }
    }
    final prefs = await SharedPreferences.getInstance();
    if (errors.isEmpty) {
      await prefs.setBool(_loginSyncedKey, true);
    }
    state = state.copyWith(
      syncing: false,
      lastSyncAt: DateTime.now(),
      lastSummary: errors.isEmpty ? doneLabel : '部分完成（${errors.join('；')}）',
      error: errors.isEmpty ? null : errors.join('；'),
    );
  }

  Future<void> syncDownload() => _runSteps('下载完成', [
    ('收藏下载', _syncFavoritesDownload),
    ('插件下载', _syncPluginsDownload),
    ('歌单下载', _syncPlaylistsDownload),
  ]);

  Future<void> syncUpload() => _runSteps('上传完成', [
    ('收藏上传', _syncFavoritesUpload),
    ('插件上传', _syncPluginsUpload),
  ]);

  Future<void> syncAll() => _runSteps('全量同步完成', [
    ('收藏下载', _syncFavoritesDownload),
    ('插件下载', _syncPluginsDownload),
    ('歌单下载', _syncPlaylistsDownload),
    ('收藏上传', _syncFavoritesUpload),
    ('插件上传', _syncPluginsUpload),
  ]);

  // ─── 收藏 ───────────────────────────────────────────────

  Future<void> _syncFavoritesDownload() async {
    final data = await _action('favorites_sync_download', {
      'user_id': _ciyuanxiId,
    });
    final favs = ((data['favorites'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final cloudPaths = favs
        .map((e) => (e['path'] as String?) ?? '')
        .where((p) => p.isNotEmpty)
        .toSet();
    final prefs = await SharedPreferences.getInstance();
    final tracked = (prefs.getStringList(_syncedFavKey) ?? []).toSet();
    final gone = tracked.where((p) => !cloudPaths.contains(p)).toList();
    if (gone.isNotEmpty) {
      await _ref.read(favoritesProvider.notifier).removeByPaths(gone);
      tracked.removeAll(gone);
      await prefs.setStringList(_syncedFavKey, tracked.toList());
    }
    if (favs.isEmpty) return;
    final notifier = _ref.read(favoritesProvider.notifier);
    for (final item in favs) {
      final path = item['path'] as String? ?? '';
      if (path.isEmpty) continue;
      final musicInfo = _asMap(item['musicInfo']);
      var source = item['source'] as String?;
      var onlineInfoJson = item['onlineInfoJson'] as String?;
      final hasMobileJson =
          (item['onlineSongJson'] as String?)?.isNotEmpty == true ||
          onlineInfoJson?.isNotEmpty == true;
      if (!hasMobileJson && musicInfo.isNotEmpty) {
        source ??= musicInfo['source'] as String? ?? _lxSourceOf(path);
        final mi = <String, dynamic>{'source': source, ...musicInfo};
        if (mi['songmid'] == null) mi['songmid'] = _lxSongmidOf(path);
        onlineInfoJson = jsonEncode(mi);
      }
      await notifier.addIfAbsent(
        FavoriteEntry(
          path: path,
          title: (item['title'] ?? item['name'] ?? path.split('/').last)
              .toString(),
          artist: (item['artist'] ?? '').toString(),
          album: (item['album'] ?? '').toString(),
          durationMs: (item['duration'] as num?)?.toInt() ?? 0,
          coverUrl: (item['coverUrl'] as String?)?.isNotEmpty == true
              ? item['coverUrl'] as String?
              : _httpCover(musicInfo['img']),
          source: source,
          onlineSongJson: item['onlineSongJson'] as String?,
          onlineQuality: item['onlineQuality'] as String?,
          onlineInfoJson: onlineInfoJson,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
  }

  Future<void> _syncFavoritesUpload() async {
    final entries = _ref.read(favoritesProvider).entries;
    if (entries.isEmpty) return;
    final payload = entries
        .map(
          (e) => {
            'title': e.title,
            'name': e.title,
            'path': e.path,
            'artist': e.artist,
            'album': e.album,
            'duration': e.durationMs,
            'coverUrl': e.coverUrl,
            'source': e.source,
            'onlineSongJson': e.onlineSongJson,
            'onlineQuality': e.onlineQuality,
            'onlineInfoJson': e.onlineInfoJson,
          },
        )
        .toList();
    final prefs = await SharedPreferences.getInstance();
    final currentPaths = entries.map((e) => e.path).toSet();
    final deletePaths = (prefs.getStringList(_syncedFavKey) ?? [])
        .where((p) => !currentPaths.contains(p))
        .toList();
    await _action('favorites_sync_upload', {
      'user_id': _ciyuanxiId,
      'favorites': payload,
      if (deletePaths.isNotEmpty) 'delete_paths': deletePaths,
      'merge': true,
    });
    await prefs.setStringList(_syncedFavKey, currentPaths.toList());
  }

  // ─── 插件 ───────────────────────────────────────────────

  static String _encodeRevBase64(String s) =>
      String.fromCharCodes(base64Encode(utf8.encode(s)).codeUnits.reversed);

  static String _decodeRevBase64(String s) =>
      utf8.decode(base64Decode(String.fromCharCodes(s.codeUnits.reversed)));

  Future<void> _syncPluginsDownload() async {
    final data = await _action('plugin_sync_download', {
      'user_id': _ciyuanxiId,
    });
    final cloudSubs = ((data['subscriptions'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    if (cloudSubs.isNotEmpty) {
      await _ref
          .read(pluginSubscriptionsProvider.notifier)
          .mergeFromCloud(cloudSubs);
    }
    final items = ((data['plugins'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final cloudIds = items
        .map((e) => ((e['id'] as String?) ?? '').trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    final prefs = await SharedPreferences.getInstance();
    final cloudInstalled = (prefs.getStringList(_cloudPluginIdsKey) ?? [])
        .toSet();
    final gonePlugins = cloudInstalled
        .where((id) => !cloudIds.contains(id))
        .toList();
    if (gonePlugins.isNotEmpty) {
      final manager = _ref.read(pluginManagerProvider.notifier);
      for (final id in gonePlugins) {
        try {
          await manager.remove(id);
          cloudInstalled.remove(id);
        } catch (_) {}
      }
      await prefs.setStringList(_cloudPluginIdsKey, cloudInstalled.toList());
    }
    if (items.isEmpty) return;
    final manager = _ref.read(pluginManagerProvider.notifier);
    final engine = await _ref.read(pluginEngineProvider.future);
    final existingIds = (await engine.store.loadSources())
        .map((s) => s.id)
        .toSet();
    final installedNow = <String>{};
    for (final item in items) {
      final cloudId = (item['id'] as String?)?.trim() ?? '';
      if (cloudId.isEmpty || existingIds.contains(cloudId)) continue;
      var script = (item['script'] as String?) ?? '';
      if (item['scriptEncoded'] == true && script.isNotEmpty) {
        try {
          script = _decodeRevBase64(script);
        } catch (_) {
          continue;
        }
      }
      if (script.trim().isEmpty) continue;
      try {
        final source = await manager.installFromScript(
          script,
          nameOverride: (item['name'] as String?)?.trim().isNotEmpty == true
              ? item['name'] as String
              : null,
          versionOverride:
              (item['version'] as String?)?.trim().isNotEmpty == true
              ? item['version'] as String
              : null,
          sourceUrl: (item['sourceUrl'] as String?)?.trim() ?? '',
        );
        if (item['enabled'] == false && source.enabled) {
          await manager.toggleEnabled(source.id);
        }
        // 用户变量解密恢复（与桌面/移动同步协议一致）
        final encBlock = item['userVariablesEncrypted'];
        if (encBlock is Map) {
          final ciyuanxiId = _ciyuanxiId;
          if (ciyuanxiId != null && ciyuanxiId.isNotEmpty) {
            final values = PluginUserVarCrypto.decrypt(
                ciyuanxiId, encBlock.cast<String, dynamic>());
            if (values != null && values.isNotEmpty) {
              await _ref
                  .read(pluginUserVarValuesProvider.notifier)
                  .save(source.id, values);
            }
          }
        }
        installedNow.add(source.id);
      } catch (_) {}
    }
    if (installedNow.isNotEmpty) {
      final all = {...cloudInstalled, ...installedNow}.toList();
      await prefs.setStringList(_cloudPluginIdsKey, all);
    }
  }

  Future<void> _syncPluginsUpload() async {
    final engine = await _ref.read(pluginEngineProvider.future);
    final sources = await engine.store.loadSources();
    final dir = await _ref.read(appDataDirProvider.future);
    final subs = _ref
        .read(pluginSubscriptionsProvider)
        .map((s) => s.toJson())
        .toList();
    if (sources.isEmpty) {
      if (subs.isEmpty) return;
      await _action('plugin_sync_upload_one', {
        'user_id': _ciyuanxiId,
        'plugin': <String, dynamic>{},
        'is_first': true,
        'subscriptions': subs,
      });
      return;
    }
    var first = true;
    for (final p in sources) {
      try {
        final scriptPath = '$dir/plugins/${p.id}.js';
        final script = await rust.readPluginFile(path: scriptPath);
        if (script.trim().isEmpty) continue;
        final plugin = <String, dynamic>{
          'id': p.id,
          'name': p.name,
          'version': p.version,
          'author': p.author,
          'description': p.description,
          'enabled': p.enabled,
          'sources': p.sources,
          'filePath': scriptPath,
          'sourceUrl': p.sourceUrl,
          'script': _encodeRevBase64(script),
          'scriptEncoded': true,
        };
        // 用户变量加密上传（与桌面/移动同步协议一致）
        final ciyuanxiId = _ciyuanxiId;
        if (ciyuanxiId != null && ciyuanxiId.isNotEmpty) {
          final userVars =
              await _ref.read(pluginUserVarValuesProvider.notifier).valuesOf(p.id);
          if (userVars.isNotEmpty) {
            final block = PluginUserVarCrypto.encrypt(ciyuanxiId, userVars);
            if (block != null) plugin['userVariablesEncrypted'] = block;
          }
        }
        await _action('plugin_sync_upload_one', {
          'user_id': _ciyuanxiId,
          'plugin': plugin,
          'is_first': first,
          'subscriptions': subs,
        });
        first = false;
      } catch (_) {}
    }
  }

  // ─── 歌单（只读下载）────────────────────────────────────

  Future<void> _syncPlaylistsDownload() async {
    final data = await _action('file_sync_download', {'user_id': _ciyuanxiId});
    final cloud = ((data['playlists'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final playlists = <CloudPlaylist>[];
    for (final pl in cloud) {
      final songs = ((pl['songs'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => CloudSong.fromJson(e.cast<String, dynamic>()))
          .toList();
      final deleted = ((pl['deletedSongPaths'] as List?) ?? const [])
          .whereType<String>()
          .toSet();
      final visible = songs
          .where((s) => s.path.isNotEmpty && !deleted.contains(s.path))
          .toList();
      if (visible.isEmpty) continue;
      final raw = pl['sourceRaw'];
      playlists.add(
        CloudPlaylist(
          cloudId: (pl['cloudId'] ?? pl['id'] ?? '').toString(),
          name: (pl['name'] ?? '未命名歌单').toString(),
          songs: visible,
          sourcePluginId: (pl['sourcePluginId'] as String?)?.isNotEmpty == true
              ? pl['sourcePluginId'] as String
              : null,
          sourceUrl: (pl['sourceUrl'] as String?)?.isNotEmpty == true
              ? pl['sourceUrl'] as String
              : null,
          sourceRaw: raw is Map ? raw.cast<String, dynamic>() : null,
        ),
      );
    }
    await CloudPlaylistStore.saveAll(playlists);
  }
}

// ─── 共享小工具 ───────────────────────────────────────────

Map<String, dynamic> _asMap(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : const {};

String? _httpCover(Object? v) {
  final s = v?.toString() ?? '';
  return s.startsWith('http://') || s.startsWith('https://') ? s : null;
}

String? _lxSourceOf(String path) {
  if (!path.startsWith('lx://')) return null;
  final rest = path.substring('lx://'.length);
  final slash = rest.indexOf('/');
  return slash <= 0 ? null : rest.substring(0, slash);
}

String? _lxSongmidOf(String path) {
  if (!path.startsWith('lx://')) return null;
  final rest = path.substring('lx://'.length);
  final slash = rest.indexOf('/');
  return slash < 0 ? null : rest.substring(slash + 1);
}

final syncProvider = StateNotifierProvider<SyncNotifier, SyncState>(
  (ref) => SyncNotifier(ref),
);
