import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../favorites/favorites_provider.dart';
import '../../lyrics/lyric_model.dart';
import '../../lyrics/lyrics_repository.dart';
import '../../player/player_provider.dart';
import '../home/cloud_playlists_page.dart';
import '../player/play_page_body.dart';
import '../player/lyrics_view.dart';
import '../player/page_dots.dart';
import '../player/player_source.dart';
import '../account/account_view.dart';
import '../home/daily_recommend_page.dart';
import '../online/plugin_manage_page.dart';
import '../online/search_page.dart';
import '../online/toplist_page.dart';
import '../settings/settings_view.dart';
import 'local_library_view.dart';

/// 音乐 tab 当前页（0 选择 / 1 播放 / 2 歌词）。
/// 开屏默认 1：打开 App 直接落在播放页（网易云手表式）。
/// 歌曲列表点歌后置 1 再返回，实现「点歌自动进播放页」。
final localHubPageProvider = StateProvider<int>((ref) => 1);

/// 本地当前曲歌词行（自动跟随 playerProvider 当前曲目变化）。
final _localLyricsProvider = FutureProvider.autoDispose<List<LyricLine>>(
  (ref) async {
    final cur = ref.watch(playerProvider).current;
    if (cur == null) return const [];
    return ref.watch(lyricsRepositoryProvider).fetchLyrics(cur);
  },
);

/// 音乐 tab 主壳（网易云手表版形态）：选择页 ↔ 播放页 ↔ 歌词页
/// 三页左右横移 + 底部圆点指示；无复杂转场。
class LocalMusicHub extends ConsumerStatefulWidget {
  const LocalMusicHub({super.key});

  @override
  ConsumerState<LocalMusicHub> createState() => _LocalMusicHubState();
}

class _LocalMusicHubState extends ConsumerState<LocalMusicHub> {
  // 开屏默认落在播放页（provider 初始 1，与此保持一致）。
  final PageController _pageCtrl = PageController(initialPage: 1);
  int _page = 1;

  @override
  void initState() {
    super.initState();
    // 歌曲列表点歌 → 跳播放页。
    ref.listenManual(localHubPageProvider, (prev, next) {
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
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          PageView(
            controller: _pageCtrl,
            onPageChanged: (i) => setState(() => _page = i),
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
            child: Center(
              child: PageDots(count: 3, current: _page),
            ),
          ),
        ],
      ),
    );
  }
}

/// 选择页：音乐源入口（网易云样式：彩色圆形图标 + 文字 + 箭头）。
class _SourcePickerPage extends ConsumerWidget {
  const _SourcePickerPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _entry(
                  context: context,
                  color: const Color(0xFFE8A33D),
                  icon: Icons.account_circle_rounded,
                  label: '账号',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const AccountView()),
                  ),
                ),
                const SizedBox(height: 8),
                _entry(
                  context: context,
                  color: const Color(0xFFE8694D),
                  icon: Icons.recommend_rounded,
                  label: '每日推荐',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const DailyRecommendPage()),
                  ),
                ),
                const SizedBox(height: 8),
                _entry(
                  context: context,
                  color: const Color(0xFFD94A8C),
                  icon: Icons.queue_music_rounded,
                  label: '我的歌单',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const CloudPlaylistsPage()),
                  ),
                ),
                const SizedBox(height: 8),
                _entry(
                  context: context,
                  color: const Color(0xFF4A90D9),
                  icon: Icons.leaderboard_rounded,
                  label: '音源榜单',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const TopListPage()),
                  ),
                ),
                const SizedBox(height: 8),
                _entry(
                  context: context,
                  color: const Color(0xFFFF4D6E),
                  icon: Icons.library_music_rounded,
                  label: '本地音乐',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const LocalLibraryView()),
                  ),
                ),
                const SizedBox(height: 8),
                _entry(
                  context: context,
                  color: const Color(0xFF4A90D9),
                  icon: Icons.travel_explore_rounded,
                  label: '在线搜索',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const OnlineSearchPage()),
                  ),
                ),
                const SizedBox(height: 8),
                _entry(
                  context: context,
                  color: const Color(0xFF9B6BD9),
                  icon: Icons.extension_rounded,
                  label: '插件管理',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const PluginManagePage()),
                  ),
                ),
                const SizedBox(height: 8),
                _entry(
                  context: context,
                  color: const Color(0xFF5FA97C),
                  icon: Icons.settings_rounded,
                  label: '设置',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const SettingsView()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _entry({
    required BuildContext context,
    required Color color,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(28),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Icon(icon, size: 20, color: Colors.white),
            ),
            const SizedBox(width: 14),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 110),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right_rounded,
              size: 22,
              color: Colors.white.withValues(alpha: 0.38),
            ),
          ],
        ),
      ),
    );
  }
}

/// 本地播放页：通用 PlayPageBody（本地数据源，表冠调本地音量）。
class _LocalPlayPage extends ConsumerWidget {
  const _LocalPlayPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(playerProvider);
    final vol = ref.watch(volumeProvider);
    // watch 收藏态：红心键显隐与实心/描边随点随变（无当前歌时 liked=null 隐藏键）。
    final cur = st.current;
    final liked =
        cur == null ? null : ref.watch(favoritesProvider).contains(cur.path);
    return PlayPageBody(
      sourceBuilder: () => LocalPlayerSource(
        st,
        ref.read(playerProvider.notifier),
        vol,
        liked,
      ),
      emptyText: '还没有在播的歌',
      emptyActionLabel: '去选歌',
      onEmptyAction: () => ref.read(localHubPageProvider.notifier).state = 0,
    );
  }
}

/// 本地歌词页。
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
    );
  }
}
