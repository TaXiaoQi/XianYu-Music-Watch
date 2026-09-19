import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/i18n.dart';
import '../plugin/plugin_catalog.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';
import '../ui/common/full_dialog.dart';
import 'playlist_store.dart';

/// 从源端（插件歌单）更新歌单：
/// 1. 用导入时记录的来源重新拉取源端歌曲；
/// 2. 与本地对比得出新增 / 移除；
/// 3. 有移除时全屏弹窗让用户选择「仅添加」或「完全同步」；
///    手动添加的歌曲（addedInApp）不参与删除。
/// 返回更新后的歌单；无变化或中断时返回 null。
Future<CloudPlaylist?> updatePlaylistFromSource(
  BuildContext context,
  WidgetRef ref,
  CloudPlaylist playlist,
) async {
  final sources = ref.read(pluginManagerProvider).sources;
  final pluginId = playlist.sourcePluginId ?? '';
  final source = sources
      .where((s) => s.id == pluginId && s.enabled)
      .firstOrNull;
  if (source == null) {
    _toast(context, tr('音源插件未安装或未启用，无法更新'));
    return null;
  }

  List<CloudSong> sourceSongs;
  try {
    sourceSongs = await _fetchSourceSongs(ref, source, playlist);
  } catch (e) {
    if (context.mounted) _toast(context, tr('获取源歌单失败：{e}', {'e': e}));
    return null;
  }
  if (sourceSongs.isEmpty) {
    if (context.mounted) _toast(context, tr('源端歌单为空或获取失败'));
    return null;
  }

  final sourceKeys = sourceSongs.map((s) => s.path).toSet();
  final localKeys = playlist.songs.map((s) => s.path).toSet();
  final addCount =
      sourceSongs.where((s) => !localKeys.contains(s.path)).length;
  final removeCount = playlist.songs
      .where((s) => !s.addedInApp && !sourceKeys.contains(s.path))
      .length;
  if (addCount == 0 && removeCount == 0) {
    if (context.mounted) _toast(context, tr('已是最新，与源端一致'));
    return null;
  }

  var fullSync = false;
  if (removeCount > 0) {
    if (!context.mounted) return null;
    final mode = await _showSyncModeDialog(context, addCount, removeCount);
    if (mode == null || !context.mounted) return null;
    fullSync = mode == 'full';
  }

  final updated = await _applySourceSync(
    playlist,
    sourceSongs: sourceSongs,
    fullSync: fullSync,
  );
  if (context.mounted) {
    _toast(
      context,
      fullSync
          ? tr('已完全同步：新增 {n} 首，移除 {m} 首', {'n': addCount, 'm': removeCount})
          : tr('已新增 {n} 首歌曲', {'n': addCount}),
    );
  }
  return updated;
}

Future<List<CloudSong>> _fetchSourceSongs(
  WidgetRef ref,
  PluginSource source,
  CloudPlaylist playlist,
) async {
  final engine = await ref.read(pluginEngineProvider.future);
  final catalog = PluginCatalogService(
    engine,
    ref.read(pluginManagerProvider).sources,
  );

  final results = <PluginSearchResult>[];
  final raw = playlist.sourceRaw;
  if (raw != null && raw.isNotEmpty) {
    final seen = <String>{};
    var page = 1;
    var maxPageSize = 0;
    final total = (raw['trackCount'] as num?)?.toInt() ?? 0;
    while (page <= 50) {
      final result =
          await catalog.getMusicSheetInfoWithEnd(source, raw, page: page);
      if (result.songs.isEmpty) break;
      final fresh = result.songs.where((r) {
        final key = '${r.songmid}|${r.name}|${r.singer}';
        return seen.add(key);
      }).toList();
      if (fresh.isEmpty) break;
      results.addAll(fresh);
      if (result.isEnd == true) break;
      if (total > 0 && results.length >= total) break;
      if (result.songs.length > maxPageSize) maxPageSize = result.songs.length;
      if (result.songs.length < maxPageSize) break;
      page++;
    }
  }
  if (results.isEmpty) {
    final url = playlist.sourceUrl;
    if (url != null && url.isNotEmpty) {
      results.addAll(await catalog.importMusicSheet(source, url));
    }
  }
  return results.map((r) => _cloudSongOf(source, r)).toList();
}

CloudSong _cloudSongOf(PluginSource source, PluginSearchResult r) => CloudSong(
      path: 'plugin://${source.id}/${r.songmid}',
      title: r.name,
      artist: r.singer,
      album: r.albumName,
      durationSec: parseIntervalMs(r.interval) ~/ 1000,
      coverUrl: r.img,
      pluginId: source.id,
      source: r.source,
      format: source.format.value,
      musicInfo: r.toJson(),
    );

/// 与移动端 applySourceSync 相同的合并逻辑，落到本地云端歌单快照
Future<CloudPlaylist> _applySourceSync(
  CloudPlaylist playlist, {
  required List<CloudSong> sourceSongs,
  required bool fullSync,
}) async {
  final localKeys = playlist.songs.map((s) => s.path).toSet();
  final additions =
      sourceSongs.where((s) => !localKeys.contains(s.path)).toList();
  var nextSongs = [...playlist.songs, ...additions];
  if (fullSync) {
    final sourceKeys = sourceSongs.map((s) => s.path).toSet();
    nextSongs = playlist.songs
        .where((s) => s.addedInApp || sourceKeys.contains(s.path))
        .toList();
    final keptKeys = nextSongs.map((s) => s.path).toSet();
    nextSongs = [
      ...nextSongs,
      ...sourceSongs.where((s) => !keptKeys.contains(s.path)),
    ];
  }
  final updated = playlist.copyWith(songs: nextSongs);
  final all = await CloudPlaylistStore.loadAll();
  final index = all.indexWhere((p) => p.cloudId == playlist.cloudId);
  if (index >= 0) {
    all[index] = updated;
    await CloudPlaylistStore.saveAll(all);
  }
  return updated;
}

/// 同步模式选择，腕上端使用全屏弹窗
Future<String?> _showSyncModeDialog(
  BuildContext context,
  int addCount,
  int removeCount,
) {
  return showFullPicker<String>(
    context,
    title: tr('检测到源端歌单更新'),
    options: [
      ('add', tr('仅添加 {n} 首新歌', {'n': addCount})),
      ('full', tr('完全同步（移除 {m} 首）', {'m': removeCount})),
    ],
  );
}

void _toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
  );
}
