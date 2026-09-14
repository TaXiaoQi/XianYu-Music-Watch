import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/watch_fit.dart';
import '../../player/player_provider.dart';
import '../../sync/playlist_store.dart';
import '../local/local_music_hub.dart';

/// 我的歌单（云端同步下载，只读消费）：歌单列表 → 歌曲列表，
/// 点任意一首整单入队并回播放页。
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
    // 网易云式：点歌后回 hub 播放页。
    ref.read(localHubPageProvider.notifier).state = 1;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale(); // 屏径等比缩放
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('我的歌单', style: TextStyle(fontSize: 15 * s)),
        centerTitle: true,
      ),
      body: FutureBuilder<List<CloudPlaylist>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return Center(
              child: SizedBox(
                width: 22 * s,
                height: 22 * s,
                child: CircularProgressIndicator(
                    strokeWidth: 2 * s, color: const Color(0xFFFF4D6E)),
              ),
            );
          }
          final playlists = snap.data ?? const <CloudPlaylist>[];
          if (playlists.isEmpty) {
            return Center(
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
                          color: Colors.white.withValues(alpha: 0.5))),
                  SizedBox(height: 4 * s),
                  Text('登录并同步后，手机/桌面端的歌单会显示在这里',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 10 * s,
                          color: Colors.white.withValues(alpha: 0.35))),
                ],
              ),
            );
          }
          return ListView.builder(
            padding: EdgeInsets.symmetric(vertical: 6 * s),
            itemCount: playlists.length,
            itemBuilder: (context, i) {
              final pl = playlists[i];
              return ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 17 * s,
                  backgroundColor: const Color(0xFFFF4D6E)
                      .withValues(alpha: 0.18),
                  child: Icon(Icons.queue_music_rounded,
                      size: 18 * s, color: const Color(0xFFFF4D6E)),
                ),
                title: Text(
                  pl.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13 * s, fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  '${pl.songs.length} 首',
                  style: TextStyle(
                      fontSize: 11 * s,
                      color: Colors.white.withValues(alpha: 0.45)),
                ),
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
        },
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
    final s = context.watchScale(); // 屏径等比缩放
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14 * s)),
        centerTitle: true,
      ),
      body: ListView.builder(
        padding: EdgeInsets.symmetric(vertical: 6 * s),
        itemCount: playlist.songs.length,
        itemBuilder: (context, i) {
          // 局部变量改名为 song，避免遮蔽缩放系数 s。
          final song = playlist.songs[i];
          return ListTile(
            dense: true,
            leading: Text(
              '${i + 1}',
              style: TextStyle(
                fontSize: 12 * s,
                fontWeight: FontWeight.w700,
                color: i < 3
                    ? const Color(0xFFFF4D6E)
                    : Colors.white.withValues(alpha: 0.4),
              ),
            ),
            title: Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13 * s),
            ),
            subtitle: Text(
              song.artist.isEmpty ? '未知歌手' : song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11 * s, color: Colors.white.withValues(alpha: 0.45)),
            ),
            onTap: () => onPlay?.call(playlist, i),
          );
        },
      ),
    );
  }
}
