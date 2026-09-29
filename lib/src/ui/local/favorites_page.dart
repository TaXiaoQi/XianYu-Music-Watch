import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/watch_fit.dart';
import '../../favorites/favorites_provider.dart';
import '../../i18n/i18n.dart';
import '../../player/player_provider.dart';
import '../common/stepped_list.dart';
import '../home/cloud_playlists_page.dart';
import 'local_music_hub.dart';

class FavoritesPage extends ConsumerWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final favs = ref.watch(favoritesProvider).entries;
    final header = PageTitleHeader(tr('收藏'), showBack: true);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SteppedListView(
          header: header,
          itemCount: favs.isEmpty ? 1 : favs.length,
          itemBuilder: (context, i) {
            if (favs.isEmpty) {
              return SteppedPill(
                child: Padding(
                  padding: EdgeInsets.all(8 * s),
                  child: Center(
                    child: Text(
                      tr('暂无收藏，播放页点击红心即可收藏'),
                      textAlign: TextAlign.center,
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
              title: f.title,
              subtitle: f.artist.isEmpty ? tr('未知歌手') : f.artist,
              trailing: Icon(
                Icons.favorite_rounded,
                size: 18 * s,
                color: const Color(0xFFFF4D6E),
              ),
              onTap: () => _play(context, ref, favs, i),
            );
          },
        ),
      ),
    );
  }

  Future<void> _play(
    BuildContext context,
    WidgetRef ref,
    List<FavoriteEntry> favs,
    int index,
  ) async {
    final items = favs
        .map((e) => cloudSongOfFavorite(e).toQueueItem())
        .toList(growable: false);
    if (items.isEmpty) return;
    await ref.read(playerProvider.notifier).playQueue(items, startIndex: index);
    if (!context.mounted) return;
    ref.read(localHubPageProvider.notifier).state = 1;
    Navigator.of(context).pop();
  }
}