import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../favorites/favorites_provider.dart';
import '../../i18n/i18n.dart';
import '../../lyrics/lyric_model.dart';
import '../../lyrics/lyrics_repository.dart';
import '../../player/player_provider.dart';
import '../common/stepped_list.dart';
import '../common/root_back_scope.dart';
import '../home/cloud_playlists_page.dart';
import '../../core/watch_fit.dart';
import '../player/play_page_body.dart';
import '../player/cover_backdrop.dart';
import '../player/lyrics_view.dart';
import '../player/page_dots.dart';
import '../player/player_source.dart';
import '../account/account_view.dart';
import '../home/daily_recommend_page.dart';
import '../../plugin/plugin_provider.dart';
import '../online/search_page.dart';
import '../online/toplist_page.dart';
import '../link/link_page.dart';
import '../settings/settings_view.dart';
import 'local_library_view.dart';
import 'favorites_page.dart';

final localHubPageProvider = StateProvider<int>((ref) => 1);

final _localLyricsProvider = FutureProvider.autoDispose<List<LyricLine>>((
  ref,
) async {
  final cur = ref.watch(playerProvider).current;
  if (cur == null) return const [];
  return ref.watch(lyricsRepositoryProvider).fetchLyrics(cur);
});

class LocalMusicHub extends ConsumerStatefulWidget {
  const LocalMusicHub({super.key});

  @override
  ConsumerState<LocalMusicHub> createState() => _LocalMusicHubState();
}

class _LocalMusicHubState extends ConsumerState<LocalMusicHub> {
  final PageController _pageCtrl = PageController(initialPage: 1);
  int _page = 1;
  ProviderSubscription<int>? _pageSub;

  @override
  void initState() {
    super.initState();
    _pageSub = ref.listenManual(localHubPageProvider, (prev, next) {
      if (!mounted || next == _page) return;
      _pageCtrl.animateToPage(
        next,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _pageSub?.close();
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coverPath = ref.watch(
      playerProvider.select((s) => s.current?.coverPath),
    );
    final coverUrl = ref.watch(
      playerProvider.select((s) => s.current?.coverUrl),
    );
    return RootBackScope(
      pageCtrl: _pageCtrl,
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: CoverBackdrop(
                cover: CoverRef(filePath: coverPath, url: coverUrl),
              ),
            ),
            PageView(
              controller: _pageCtrl,
              onPageChanged: (i) {
                setState(() => _page = i);
                ref.read(localHubPageProvider.notifier).state = i;
              },
              children: [
                const _SourcePickerPage(),
                const _LocalPlayPage(),
                const _LocalLyricsPage(),
              ],
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 10,
              child: Center(child: PageDots(count: 3, current: _page)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourcePickerPage extends ConsumerStatefulWidget {
  const _SourcePickerPage();

  @override
  ConsumerState<_SourcePickerPage> createState() => _SourcePickerPageState();
}

class _SourcePickerPageState extends ConsumerState<_SourcePickerPage> {
  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final hasPlugins = ref
        .watch(pluginManagerProvider)
        .sources
        .any((p) => p.enabled);
    final specs = <(Color, IconData, String, VoidCallback)>[
      (
        const Color(0xFFFF4D6E),
        Icons.library_music_rounded,
        tr('本地音乐'),
        () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const LocalLibraryView()),
        ),
      ),
      (
        const Color(0xFFFF4D6E),
        Icons.favorite_rounded,
        tr('收藏'),
        () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const FavoritesPage()),
        ),
      ),
      (
        const Color(0xFFD94A8C),
        Icons.queue_music_rounded,
        tr('歌单'),
        () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const CloudPlaylistsPage()),
        ),
      ),
      (
        const Color(0xFFE8A33D),
        Icons.account_circle_rounded,
        tr('账号'),
        () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const AccountView())),
      ),
      if (hasPlugins) ...[
        (
          const Color(0xFFE8694D),
          Icons.recommend_rounded,
          tr('每日推荐'),
          () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DailyRecommendPage()),
          ),
        ),
        (
          const Color(0xFF4A90D9),
          Icons.leaderboard_rounded,
          tr('音源榜单'),
          () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const TopListPage())),
        ),
      ],
      (
        const Color(0xFF4A90D9),
        Icons.travel_explore_rounded,
        tr('搜索'),
        () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const OnlineSearchPage()),
        ),
      ),
      (
        const Color(0xFF5FA97C),
        Icons.settings_rounded,
        tr('设置'),
        () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const SettingsView())),
      ),
    ];
    // 功能条统一配色：深灰实底胶囊 + 白字 + 彩色圆标（kSteppedTileBg）
    const tileFg = Color(0xFFFFFFFF);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: SteppedListView(
          itemCount: specs.length + 1,
          header: PageTitleHeader(tr('功能')),
          rotaryGuard: () => ref.read(localHubPageProvider) == 0,
          itemBuilder: (context, i) {
            if (i == 0) {
              return const LinkEntryTile(
                titleColor: tileFg,
                subtitleColor: Colors.white70,
                backgroundColor: kSteppedTileBg,
              );
            }
            final (color, icon, label, onTap) = specs[i - 1];
            return SteppedTile(
              leading: SteppedLeadCircle(
                color: color,
                child: Icon(icon, size: 22 * s, color: Colors.white),
              ),
              title: label,
              titleColor: tileFg,
              trailing: Icon(
                Icons.chevron_right_rounded,
                size: 22 * s,
                color: tileFg.withValues(alpha: 0.35),
              ),
              onTap: onTap,
              backgroundColor: kSteppedTileBg,
            );
          },
        ),
      ),
    );
  }
}

class _LocalPlayPage extends ConsumerWidget {
  const _LocalPlayPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(playerProvider);
    final vol = ref.watch(volumeProvider);
    final cur = st.current;
    final liked = cur == null
        ? null
        : ref.watch(favoritesProvider).contains(cur.path);
    return PlayPageBody(
      sourceBuilder: () =>
          LocalPlayerSource(st, ref.read(playerProvider.notifier), vol, liked),
      emptyText: tr('还没有在播的歌'),
      emptyActionLabel: tr('无音乐，去选歌'),
      onEmptyAction: () => ref.read(localHubPageProvider.notifier).state = 0,
      rotaryGuard: () => ref.read(localHubPageProvider) == 1,
    );
  }
}

class _LocalLyricsPage extends ConsumerWidget {
  const _LocalLyricsPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(playerProvider);
    final lyricsAsync = ref.watch(_localLyricsProvider);
    final lines = lyricsAsync.valueOrNull ?? const <LyricLine>[];
    return LyricsView(
      lines: lines,
      position: st.position,
      isPlaying: st.isPlaying,
      onSeek: (secs) => ref.read(playerProvider.notifier).seek(secs),
      rotaryGuard: () => ref.read(localHubPageProvider) == 2,
    );
  }
}
