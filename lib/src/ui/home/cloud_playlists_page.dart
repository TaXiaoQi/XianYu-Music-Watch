import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/watch_fit.dart';
import '../../player/player_provider.dart';
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
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => _CloudPlaylistDetailPage(
                                  playlist: pl,
                                  onPlay: _play,
                                )),
                      ),
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

class _CloudPlaylistDetailPage extends StatelessWidget {
  const _CloudPlaylistDetailPage({required this.playlist, this.onPlay});

  final CloudPlaylist playlist;
  final Future<void> Function(CloudPlaylist, int)? onPlay;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SteppedListView(
          header: PageTitleHeader(playlist.name, showBack: true),
          itemCount: playlist.songs.length,
        itemBuilder: (context, i) {
          final song = playlist.songs[i];
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
            onTap: () => onPlay?.call(playlist, i),
          );
        },
        ),
      ),
    );
  }
}
