import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_provider.dart';
import '../core/db_path.dart';
import '../favorites/favorites_provider.dart';
import '../plugin/plugin_provider.dart';
import '../plugin/plugin_subscriptions.dart';
import '../rust/api.dart' as rust;
import 'playlist_store.dart';

/// 腕上精简云同步（登录账号后与云端互通，字段与桌面/移动端同构）：
/// - 收藏：下载合并 + 上传（merge 模式，deletePaths 跟踪本机删除）
/// - 插件：下载快照补装缺失插件（含订阅合并）+ 上传本地插件
///   （用户变量加密同步未接入腕上端，变量仍在手机/桌面端管理）
/// - 歌单：云端下载到本机（只读消费，歌单管理仍在手机/桌面端）
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
  }) =>
      SyncState(
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
    // 登录态监听：登录成功/凭证恢复 → 触发首次自动同步；登出 → 清同步标记
    // （换账号重登要重新全量同步）。syncProvider 需被提前读一次才会创建，
    // app.dart initState 里已 read。
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

  /// 定时自动同步（对齐移动端语义：仅上传，以客户端为准，不下载不弹冲突窗）。
  /// 腕上端不暴露间隔配置，固定 1 小时（与移动端默认值一致）。
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

  /// 首次登录/启动自动同步（每设备一次，失败不重试——错误在账号页可见，手动补）。
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

  /// 登出后清标记：下次登录重新全量同步 + 重置收藏删除跟踪。
  Future<void> _onLogout() async {
    _autoTimer?.cancel();
    _autoTimer = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_loginSyncedKey);
    await prefs.remove(_syncedFavKey);
    state = SyncState(autoSync: state.autoSync);
  }

  Future<Map<String, dynamic>> _action(
      String action, Map<String, dynamic> body) async {
    if (!_ref.read(authProvider).isLoggedIn) {
      throw AuthException('请先登录');
    }
    return _ref.read(authProvider.notifier).requestAction(action, body);
  }

  String? get _ciyuanxiId => _ref.read(authProvider).user?.ciyuanxiId;

  /// 通用批次执行：置同步中 → 逐项跑 → 汇总错误（单项失败不阻断后续）。
  Future<void> _runSteps(
      String doneLabel, List<(String, Future<void> Function())> steps) async {
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
    // 无论成败都写「已同步」标记：失败已在账号页同步卡展示、可手动重试；
    // 否则网络抖动一次就变成每次冷启动全量重拉（服务端日志像被同步了好几遍）。
    await prefs.setBool(_loginSyncedKey, true);
    state = state.copyWith(
      syncing: false,
      lastSyncAt: DateTime.now(),
      lastSummary: errors.isEmpty ? doneLabel : '部分完成（${errors.join('；')}）',
      error: errors.isEmpty ? null : errors.join('；'),
    );
  }

  /// 手动下载：云端 → 本机（收藏合并 + 插件补装 + 歌单只读刷新）。
  Future<void> syncDownload() => _runSteps('下载完成', [
        ('收藏下载', _syncFavoritesDownload),
        ('插件下载', _syncPluginsDownload),
        ('歌单下载', _syncPlaylistsDownload),
      ]);

  /// 手动上传：本机 → 云端（收藏 merge 上传 + 插件逐个上传；空收藏保护跳过）。
  Future<void> syncUpload() => _runSteps('上传完成', [
        ('收藏上传', _syncFavoritesUpload),
        ('插件上传', _syncPluginsUpload),
      ]);

  /// 全量同步：先下载合并、再上传（下载补齐本机后，上传才能把合并结果回写云端）。
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
    // 收敛删除：云端列表非空时，把「本机已同步跟踪、但云端已不存在」的收藏
    // 跟随移除（其他设备取消的收藏不回灌，否则下次上传会把删除撤销掉）。
    // 云端为空列表视为云端未初始化，不动本机（与移动/桌面端空列表保护一致）。
    if (favs.isNotEmpty) {
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
    }
    if (favs.isEmpty) return;
    final notifier = _ref.read(favoritesProvider.notifier);
    for (final item in favs) {
      final path = item['path'] as String? ?? '';
      if (path.isEmpty) continue;
      final musicInfo = _asMap(item['musicInfo']);
      var source = item['source'] as String?;
      var onlineInfoJson = item['onlineInfoJson'] as String?;
      // 桌面端下来的在线歌只有 musicInfo：合成 onlineInfoJson 保证可播。
      final hasMobileJson =
          (item['onlineSongJson'] as String?)?.isNotEmpty == true ||
              onlineInfoJson?.isNotEmpty == true;
      if (!hasMobileJson && musicInfo.isNotEmpty) {
        source ??= musicInfo['source'] as String? ?? _lxSourceOf(path);
        final mi = <String, dynamic>{'source': source, ...musicInfo};
        if (mi['songmid'] == null) mi['songmid'] = _lxSongmidOf(path);
        onlineInfoJson = jsonEncode(mi);
      }
      await notifier.addIfAbsent(FavoriteEntry(
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
      ));
    }
  }

  Future<void> _syncFavoritesUpload() async {
    final entries = _ref.read(favoritesProvider).entries;
    if (entries.isEmpty) return; // 空列表保护：避免清空云端收藏
    final payload = entries
        .map((e) => {
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
            })
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

  /// 与桌面端 pluginSync 一致的反转 Base64（规避 WAF 对原始 JS 的解码检测）。
  static String _encodeRevBase64(String s) =>
      String.fromCharCodes(base64Encode(utf8.encode(s)).codeUnits.reversed);

  static String _decodeRevBase64(String s) =>
      utf8.decode(base64Decode(String.fromCharCodes(s.codeUnits.reversed)));

  Future<void> _syncPluginsDownload() async {
    final data = await _action('plugin_sync_download', {
      'user_id': _ciyuanxiId,
    });
    // 云端订阅链接合并进本地（即使无插件也要合并）
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
    final cloudInstalled =
        (prefs.getStringList(_cloudPluginIdsKey) ?? []).toSet();
    // 收敛删除：云端快照已消失、且本机是之前从云端装来的插件 → 卸载
    // （跟随云端删除，防止下次上传把已删插件复活）。本机自装的插件不受影响。
    final gonePlugins =
        cloudInstalled.where((id) => !cloudIds.contains(id)).toList();
    if (gonePlugins.isNotEmpty) {
      final manager = _ref.read(pluginManagerProvider.notifier);
      for (final id in gonePlugins) {
        try {
          await manager.remove(id);
          cloudInstalled.remove(id);
        } catch (_) {
          // 单个卸载失败不阻断
        }
      }
      await prefs.setStringList(_cloudPluginIdsKey, cloudInstalled.toList());
    }
    if (items.isEmpty) return;
    final manager = _ref.read(pluginManagerProvider.notifier);
    final engine = await _ref.read(pluginEngineProvider.future);
    final existingIds =
        (await engine.store.loadSources()).map((s) => s.id).toSet();
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
        // 走 PluginManager 恢复（与上传/在线播放同一套存储，自动识别 Lx/MusicFree 格式）。
        final source = await manager.installFromScript(
          script,
          nameOverride: (item['name'] as String?)?.trim().isNotEmpty == true
              ? item['name'] as String
              : null,
          versionOverride: (item['version'] as String?)?.trim().isNotEmpty == true
              ? item['version'] as String
              : null,
          sourceUrl: (item['sourceUrl'] as String?)?.trim() ?? '',
        );
        // 云端停用的插件保持停用。
        if (item['enabled'] == false && source.enabled) {
          await manager.toggleEnabled(source.id);
        }
        installedNow.add(source.id);
      } catch (_) {
        // 单个插件恢复失败不阻断其余
      }
    }
    // 记录云端来源插件（后续下载据此跟随云端删除）。
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
    // 与移动/桌面端同语义：首个成功请求 is_first 重建云端插件集（上传端为
    // 权威副本，删除才能传播）；无插件但有订阅时用空插件做载体单独传订阅。
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
        await _action('plugin_sync_upload_one', {
          'user_id': _ciyuanxiId,
          'plugin': {
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
          },
          'is_first': first,
          'subscriptions': subs,
        });
        first = false; // 仅首个成功请求重建云端；失败则让后续请求接管重建
      } catch (_) {
        // 单个插件上传失败不阻断其余
      }
    }
  }

  // ─── 歌单（只读下载）────────────────────────────────────

  Future<void> _syncPlaylistsDownload() async {
    final data = await _action('file_sync_download', {
      'user_id': _ciyuanxiId,
    });
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
      final visible =
          songs.where((s) => s.path.isNotEmpty && !deleted.contains(s.path)).toList();
      if (visible.isEmpty) continue;
      playlists.add(CloudPlaylist(
        cloudId: (pl['cloudId'] ?? pl['id'] ?? '').toString(),
        name: (pl['name'] ?? '未命名歌单').toString(),
        songs: visible,
      ));
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

final syncProvider =
    StateNotifierProvider<SyncNotifier, SyncState>((ref) => SyncNotifier(ref));
