import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/settings.dart';
import '../favorites/favorites_provider.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';
import '../sync/playlist_store.dart';

const _kBackupSchema = 'xianyu-music.app-backup';
const _kBackupVersion = 2;

/// 与移动端备份一致的平台标记/设置槽位。
const kBackupPlatformWatch = 'watch';

/// 腕上端备份导出服务，产出与移动端兼容的 `xianyu-music.app-backup` v2 结构，
/// 方便在手机端保存后仍可被手机端导入。
class WatchBackupService {
  const WatchBackupService(this._ref);

  final Ref _ref;

  Future<String> exportJson() async {
    // 收藏
    final favorites = _ref
        .read(favoritesProvider)
        .entries
        .map((e) => e.toJson())
        .toList();

    // 歌单（云端歌单存储）
    final playlists = <Map<String, dynamic>>[];
    for (final p in await CloudPlaylistStore.loadAll()) {
      playlists.add({
        'name': p.name,
        'songs': p.songs.map((e) => e.toJson()).toList(),
        if (p.sourcePluginId != null)
          'sourcePluginId': p.sourcePluginId,
        if (p.sourceUrl != null) 'sourceUrl': p.sourceUrl,
        if (p.sourceRaw != null) 'sourceRaw': p.sourceRaw,
      });
    }

    // 插件（非内置）
    final plugins = <Map<String, dynamic>>[];
    try {
      final engine = await _ref.read(pluginEngineProvider.future);
      final sources = await engine.store.loadSources();
      for (final source in sources) {
        if (source.isBuiltin) continue;
        final script = await engine.store.readScript(source.id);
        if (script == null || script.isEmpty) continue;
        plugins.add({'source': source.toJson(), 'script': script});
      }
    } catch (_) {}

    // 设置写入 watch 槽位，移动端/桌面端预留空位互不影响。
    final settings = _ref.read(settingsProvider).valueOrNull;

    final backup = {
      'schema': _kBackupSchema,
      'version': _kBackupVersion,
      'createdAt': DateTime.now().toIso8601String(),
      'platform': kBackupPlatformWatch,
      'data': <String, dynamic>{
        'playlists': playlists,
        'favorites': favorites,
        'favoriteCollections': <Map<String, dynamic>>[],
        'plugins': plugins,
        // 腕上端无独立的历史播放列表，预留空以兼容迁移端。
        'recentHistory': <Map<String, dynamic>>[],
        // 设置按端分槽：本端只写自己的槽位。
        'settings': {
          'desktop': null,
          'mobile': null,
          kBackupPlatformWatch:
              settings != null ? _settingsToJson(settings) : null,
        },
      },
    };
    return const JsonEncoder.withIndent('  ').convert(backup);
  }

  /// 从备份 JSON 恢复腕上端本机数据（收藏/歌单/插件 + watch 槽位设置）。
  /// 返回各分类写入数量。仅写本端（watch）设置槽位，不影响 mobile/desktop。
  Future<Map<String, int>> importJson(String json) async {
    final dynamic data;
    try {
      data = jsonDecode(json);
    } catch (_) {
      throw FormatException('文件不是有效的 JSON 格式');
    }
    if (data is! Map || data['schema'] != _kBackupSchema) {
      throw FormatException('无法识别的备份格式');
    }
    final inner = data['data'];
    if (inner is! Map) {
      throw FormatException('备份文件数据结构无效');
    }
    final map = inner.cast<String, dynamic>();

    var favorites = 0;
    var playlists = 0;
    var plugins = 0;
    var settingsApplied = 0;

    // 收藏：按 path 去重合并，不覆盖本端已有收藏。
    final favManager = _ref.read(favoritesProvider.notifier);
    for (final raw in (map['favorites'] as List? ?? [])) {
      if (raw is! Map) continue;
      try {
        final e = FavoriteEntry.fromJson(raw.cast<String, dynamic>());
        if (e.path.isNotEmpty && await favManager.addIfAbsent(e)) {
          favorites++;
        }
      } catch (_) {}
    }

    // 歌单：按歌单名去重合并。
    final incoming = <CloudPlaylist>[];
    for (final raw in (map['playlists'] as List? ?? [])) {
      if (raw is! Map) continue;
      final pl = CloudPlaylist.fromJson(raw.cast<String, dynamic>());
      if (pl.songs.isNotEmpty) incoming.add(pl);
    }
    if (incoming.isNotEmpty) {
      final existing = await CloudPlaylistStore.loadAll();
      final knownNames = existing.map((p) => p.name).toSet();
      for (final pl in incoming) {
        if (knownNames.contains(pl.name)) continue;
        existing.add(pl);
        knownNames.add(pl.name);
        playlists++;
      }
      await CloudPlaylistStore.saveAll(existing);
    }

    // 插件：脚本相同则跳过，缺失则安装。
    try {
      final manager = _ref.read(pluginManagerProvider.notifier);
      for (final raw in (map['plugins'] as List? ?? [])) {
        if (raw is! Map) continue;
        final entry = raw.cast<String, dynamic>();
        final script = entry['script'] as String? ?? '';
        final sourceRaw = entry['source'];
        if (script.trim().isEmpty || sourceRaw is! Map) continue;
        try {
          final source = PluginSource.fromJson(sourceRaw.cast<String, dynamic>());
          await manager.installFromScript(
            script,
            nameOverride: source.name.isNotEmpty ? source.name : null,
            versionOverride: source.version.isNotEmpty ? source.version : null,
          );
          plugins++;
        } catch (_) {}
      }
    } catch (_) {}

    // 设置：写入 watch 槽位。
    final settings = map['settings'];
    if (settings is Map) {
      final slot = settings[kBackupPlatformWatch];
      if (slot is Map) {
        try {
          final current = _ref.read(settingsProvider).valueOrNull;
          if (current != null) {
            final restored =
                _settingsFromJson(current, slot.cast<String, dynamic>());
            await _ref.read(settingsProvider.notifier).saveAll(restored);
            settingsApplied = 1;
          }
        } catch (_) {}
      }
    }

    return {
      'favorites': favorites,
      'playlists': playlists,
      'plugins': plugins,
      'settings': settingsApplied,
    };
  }

  Map<String, dynamic> _settingsToJson(AppSettings s) => {
        'volume': s.volume,
        'playMode': s.playMode,
        'playbackSpeed': s.playbackSpeed,
        'keepScreenOn': s.keepScreenOn,
        'libraryMinDurationSeconds': s.libraryMinDurationSeconds,
        'scanFormats': s.scanFormats,
        'watchLinkageEnabled': s.watchLinkageEnabled,
        'onlineQuality': s.onlineQuality,
        'showLyricsTranslation': s.showLyricsTranslation,
        'lyricFontSize': s.lyricFontSize,
        'lyricOffsetMs': s.lyricOffsetMs,
        'onlineFailureBehavior': s.onlineFailureBehavior,
        'streamCacheSizeMB': s.streamCacheSizeMB,
      };

  AppSettings _settingsFromJson(AppSettings fallback, Map<String, dynamic> j) {
    int? asInt(String k) => j[k] is num ? (j[k] as num).toInt() : null;
    bool? asBool(String k) => j[k] is bool ? j[k] as bool : null;
    double? asDouble(String k) => j[k] is num ? (j[k] as num).toDouble() : null;
    String? asStr(String k) => j[k] is String ? j[k] as String : null;
    return fallback.copyWith(
      volume: asDouble('volume'),
      playMode: asInt('playMode'),
      playbackSpeed: asDouble('playbackSpeed'),
      keepScreenOn: asBool('keepScreenOn'),
      libraryMinDurationSeconds: asInt('libraryMinDurationSeconds'),
      scanFormats: j['scanFormats'] is List
          ? (j['scanFormats'] as List).cast<String>()
          : null,
      watchLinkageEnabled: asBool('watchLinkageEnabled'),
      onlineQuality: asStr('onlineQuality'),
      showLyricsTranslation: asBool('showLyricsTranslation'),
      lyricFontSize: asInt('lyricFontSize'),
      lyricOffsetMs: asInt('lyricOffsetMs'),
      onlineFailureBehavior: asStr('onlineFailureBehavior'),
      streamCacheSizeMB: asInt('streamCacheSizeMB'),
    );
  }
}

/// 生成带时间戳的备份文件名，与移动端同一命名风格。
String watchBackupFileName() {
  final now = DateTime.now();
  final m = now.month.toString().padLeft(2, '0');
  final d = now.day.toString().padLeft(2, '0');
  return 'xianyu-backup-${now.year}-$m-$d.json';
}

/// 将备份 JSON 写入腕上端应用文档目录，返回完整路径；失败抛出异常。
Future<String> writeWatchBackupFileLocal(String json) async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/xianyu_watch_backups/${watchBackupFileName()}');
  await file.writeAsString(json, flush: true);
  return file.path;
}

/// 读取腕上端文档目录下最新的备份文件内容；不存在则返回 null。
Future<String?> readLatestLocalBackupFile() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/xianyu_watch_backups');
    if (!folder.existsSync()) return null;
    final files = folder
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    if (files.isEmpty) return null;
    return await files.first.readAsString();
  } catch (_) {
    return null;
  }
}

final watchBackupProvider = Provider<WatchBackupService>(
  (ref) => WatchBackupService(ref),
);