import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/watch_fit.dart';
import '../../favorites/favorites_provider.dart';
import '../../player/player_provider.dart';
import '../../sync/playlist_source_update.dart';
import '../../sync/playlist_store.dart';
import '../common/stepped_list.dart';
import '../local/local_music_hub.dart';

class CloudPlaylistsPage extends ConsumerStatefulWidget {
  const CloudPlaylistsPage({super.key});

  @override
  ConsumerState<CloudPlaylistsPage> createState() => _CloudPlaylistsPageState();
}

class _CloudPlaylistsPageState extends ConsumerState<CloudPlaylistsPage> {
  Future<List<CloudPlaylist>>? _future;

  @override
  void initState() {
    super.initState();
    _future = CloudPlaylistStore.loadAll();
  }

  Future<void> _play(CloudPlaylist pl, int index) async {
    final items = pl.songs.map((s) => s.toQueueItem()).toList();
    if (items.isEmpty) return;
    await ref
        .read(playerProvider.notifier)
        .playQueue(items, startIndex: index);
    if (!mounted) return;
    ref.read(localHubPageProvider.notifier).state = 1;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final headerRow = const PageTitleHeader('我的歌单', showBack: true);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: FutureBuilder<List<CloudPlaylist>>(
          future: _future,
          builder: (context, snap) {
            Widget? body;
            if (snap.connectionState != ConnectionState.done) {
              body = Column(children: [
                headerRow,
                Expanded(
                  child: Center(
                    child: SizedBox(
                      width: 22 * s,
                      height: 22 * s,
                      child: CircularProgressIndicator(
                          strokeWidth: 2 * s,
                          color: const Color(0xFFFF4D6E)),
                    ),
                  ),
                ),
              ]);
            } else {
              final playlists = snap.data ?? const <CloudPlaylist>[];
              if (playlists.isEmpty) {
                body = Column(children: [
                  headerRow,
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.queue_music_rounded,
                              size: 34 * s,
                              color: Colors.white.withValues(alpha: 0.3)),
                          SizedBox(height: 8 * s),
                          Text('暂无云端歌单',
                              style: TextStyle(
                                  fontSize: 12 * s,
                                  color:
                                      Colors.white.withValues(alpha: 0.5))),
                          SizedBox(height: 4 * s),
                          Text('登录并同步后，手机/桌面端的歌单会显示在这里',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 10 * s,
                                  color: Colors.white
                                      .withValues(alpha: 0.35))),
                        ],
                      ),
                    ),
                  ),
                ]);
              } else {
                body = SteppedListView(
                  header: headerRow,
                  itemCount: playlists.length,
                  itemBuilder: (context, i) {
                    final pl = playlists[i];
                    return SteppedTile(
                      leading: SteppedLeadCircle(
                        color: const Color(0xFFFF4D6E).withValues(alpha: 0.18),
                        child: Icon(Icons.queue_music_rounded,
                            size: 22 * s, color: const Color(0xFFFF4D6E)),
                      ),
                      title: pl.name,
                      subtitle: '${pl.songs.length} 首',
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                              builder: (_) => _CloudPlaylistDetailPage(
                                    playlist: pl,
                                    onPlay: _play,
                                  )),
                        );
                        if (mounted) {
                          setState(() => _future = CloudPlaylistStore.loadAll());
                        }
                      },
                    );
                  },
                );
              }
            }
            return body;
          },
        ),
      ),
    );
  }
}

class _CloudPlaylistDetailPage extends ConsumerStatefulWidget {
  const _CloudPlaylistDetailPage({required this.playlist, this.onPlay});

  final CloudPlaylist playlist;
  final Future<void> Function(CloudPlaylist, int)? onPlay;

  @override
  ConsumerState<_CloudPlaylistDetailPage> createState() =>
      _CloudPlaylistDetailPageState();
}

class _CloudPlaylistDetailPageState
    extends ConsumerState<_CloudPlaylistDetailPage> {
  late CloudPlaylist _playlist = widget.playlist;
  bool _updating = false;

  Future<void> _updateFromSource() async {
    if (_updating) return;
    setState(() => _updating = true);
    CloudPlaylist? updated;
    try {
      updated = await updatePlaylistFromSource(context, ref, _playlist);
    } finally {
      if (mounted) setState(() => _updating = false);
    }
    if (updated != null && mounted) {
      final next = updated;
      setState(() => _playlist = next);
    }
  }

  Future<void> _save(CloudPlaylist pl) async {
    final all = await CloudPlaylistStore.loadAll();
    final i = all.indexWhere((p) => p.cloudId == pl.cloudId);
    if (i < 0) return;
    all[i] = pl;
    await CloudPlaylistStore.saveAll(all);
  }

  Future<void> _addSongs() async {
    if (!mounted) return;
    final added = await Navigator.of(context).push<List<CloudSong>>(
      MaterialPageRoute(
        builder: (_) => _AddSongsPage(
          existingPaths: _playlist.songs.map((s) => s.path).toSet(),
        ),
      ),
    );
    if (added == null || added.isEmpty || !mounted) return;
    final existing = _playlist.songs.map((s) => s.path).toSet();
    final fresh = added.where((s) => !existing.contains(s.path)).toList();
    if (fresh.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('所选歌曲已在歌单中'), duration: const Duration(seconds: 2)),
      );
      return;
    }
    final updated = _playlist.copyWith(songs: [..._playlist.songs, ...fresh]);
    setState(() => _playlist = updated);
    await _save(updated);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已添加 ${fresh.length} 首歌曲'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SteppedListView(
          header: PageTitleHeader(
            _playlist.name,
            showBack: true,
            trailing: _playlist.hasSource
                ? (_updating
                    ? Padding(
                        padding: EdgeInsets.all(14 * s),
                        child: SizedBox(
                          width: 20 * s,
                          height: 20 * s,
                          child: CircularProgressIndicator(
                            strokeWidth: 2 * s,
                            color: const Color(0xFFFF4D6E),
                          ),
                        ),
                      )
                    : IconButton(
                        padding: EdgeInsets.zero,
                        constraints: BoxConstraints(
                          minWidth: 44 * s,
                          minHeight: 44 * s,
                        ),
                        icon: Icon(Icons.sync_rounded,
                            size: 20 * s,
                            color: Colors.white.withValues(alpha: 0.85)),
                        onPressed: _updateFromSource,
                      ))
                : null,
          ),
          itemCount: _playlist.songs.length + 1,
          itemBuilder: (context, i) {
            if (i == _playlist.songs.length) {
              return SteppedTile(
                leading: SteppedLeadCircle(
                  color: const Color(0xFFFF4D6E).withValues(alpha: 0.18),
                  child: Icon(Icons.add_rounded,
                      size: 22 * s, color: const Color(0xFFFF4D6E)),
                ),
                title: '添加歌曲',
                subtitle: '从收藏中选歌到该歌单',
                onTap: _addSongs,
              );
            }
            final song = _playlist.songs[i];
            return SteppedTile(
              leading: SizedBox(
                width: 24 * s,
                child: Text(
                  '${i + 1}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15 * s,
                    fontWeight: FontWeight.w700,
                    color: i < 3
                        ? const Color(0xFFFF4D6E)
                        : Colors.white.withValues(alpha: 0.4),
                  ),
                ),
              ),
              title: song.title,
              subtitle: song.artist.isEmpty ? '未知歌手' : song.artist,
              onTap: () => widget.onPlay?.call(_playlist, i),
            );
          },
        ),
      ),
    );
  }
}

/// 把收藏条目还原成可播放的 CloudSong（标记为腕上手动添加）
CloudSong _cloudSongOfFavorite(FavoriteEntry e) {
  String? pluginId, source, format;
  Map<String, dynamic> musicInfo = const {};
  final json = e.onlineSongJson;
  if (json != null && json.isNotEmpty) {
    try {
      final m = jsonDecode(json);
      if (m is Map) {
        final map = m.cast<String, dynamic>();
        pluginId = map['pluginId'] as String?;
        source = map['source'] as String?;
        format = map['format'] as String?;
        final mi = map['musicInfo'];
        if (mi is Map) musicInfo = mi.cast<String, dynamic>();
      }
    } catch (_) {}
  }
  return CloudSong(
    path: e.path,
    title: e.title,
    artist: e.artist,
    album: e.album,
    durationSec: e.durationMs ~/ 1000,
    coverUrl: e.coverUrl ?? e.coverPath,
    pluginId: pluginId ?? '',
    source: source ?? e.source ?? '',
    format: format ?? '',
    musicInfo: musicInfo,
    addedInApp: true,
  );
}

class _AddSongsPage extends ConsumerStatefulWidget {
  const _AddSongsPage({required this.existingPaths});

  final Set<String> existingPaths;

  @override
  ConsumerState<_AddSongsPage> createState() => _AddSongsPageState();
}

class _AddSongsPageState extends ConsumerState<_AddSongsPage> {
  final _selected = <String>{};

  List<FavoriteEntry> get _candidates {
    final favs = ref.watch(favoritesProvider).entries;
    return favs
        .where((e) => e.path.isNotEmpty && !widget.existingPaths.contains(e.path))
        .toList();
  }

  void _confirm(BuildContext context, double s) {
    final favs = _candidates;
    final byPath = {for (final e in favs) e.path: e};
    final songs = _selected
        .where(byPath.containsKey)
        .map((p) => _cloudSongOfFavorite(byPath[p]!))
        .toList();
    Navigator.of(context).pop(songs);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final favs = _candidates;
    final count = _selected.length;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SteppedListView(
          header: PageTitleHeader(
            '添加歌曲',
            showBack: true,
            trailing: TextButton(
              onPressed: count > 0 ? () => _confirm(context, s) : null,
              child: Text(
                count > 0 ? '添加($count)' : '添加',
                style: TextStyle(
                  fontSize: 13 * s,
                  fontWeight: FontWeight.w600,
                  color: count > 0
                      ? const Color(0xFFFF4D6E)
                      : Colors.white.withValues(alpha: 0.35),
                ),
              ),
            ),
          ),
          itemCount: favs.isEmpty ? 1 : favs.length,
          itemBuilder: (context, i) {
            if (favs.isEmpty) {
              return SteppedPill(
                child: Padding(
                  padding: EdgeInsets.all(8 * s),
                  child: Center(
                    child: Text(
                      '还没有可添加的收藏歌曲',
                      style: TextStyle(
                        fontSize: 10 * s,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ),
              );
            }
            final f = favs[i];
            final sel = _selected.contains(f.path);
            return SteppedTile(
              leading: SteppedLeadCircle(
                color: sel
                    ? const Color(0xFFFF4D6E).withValues(alpha: 0.18)
                    : Colors.white.withValues(alpha: 0.10),
                child: Icon(
                  sel ? Icons.check_rounded : Icons.music_note_rounded,
                  size: 22 * s,
                  color: sel
                      ? const Color(0xFFFF4D6E)
                      : Colors.white.withValues(alpha: 0.5),
                ),
              ),
              title: f.title,
              subtitle: f.artist.isEmpty ? '未知歌手' : f.artist,
              onTap: () => setState(() {
                if (!_selected.add(f.path)) _selected.remove(f.path);
              }),
            );
          },
        ),
      ),
    );
  }
}
