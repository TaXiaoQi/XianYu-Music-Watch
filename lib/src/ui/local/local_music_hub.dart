import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../favorites/favorites_provider.dart';
import '../../lyrics/lyric_model.dart';
import '../../lyrics/lyrics_repository.dart';
import '../../player/player_provider.dart';
import '../common/stepped_list.dart';
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
    // 只盯封面字段：播放进度逐秒刷新 playerProvider，若整层 watch 会
    // 连带重建 CoverBackdrop——ImageFilter 实例每次都变，触发全屏模糊
    // 重栅格化（表上是明显的周期性卡顿）。
    final coverPath =
        ref.watch(playerProvider.select((s) => s.current?.coverPath));
    final coverUrl =
        ref.watch(playerProvider.select((s) => s.current?.coverUrl));
    return Scaffold(
      body: Stack(
        children: [
          // 全屏封面模糊背景（网易云手表版）：三页共享一层，横移时背景不动。
          Positioned.fill(
            child: CoverBackdrop(
              cover: CoverRef(filePath: coverPath, url: coverUrl),
            ),
          ),
          PageView(
            controller: _pageCtrl,
            onPageChanged: (i) {
              setState(() => _page = i);
              // 回写 provider：表冠门禁（选择页/播放页守卫）都读它，
              // 只 setState 不回写会让门禁永远停在初始页。
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
/// 支持表冠滚动列表（每档约一个条目 + 档位振动）。
class _SourcePickerPage extends ConsumerStatefulWidget {
  const _SourcePickerPage();

  @override
  ConsumerState<_SourcePickerPage> createState() => _SourcePickerPageState();
}

class _SourcePickerPageState extends ConsumerState<_SourcePickerPage> {
  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    // 对齐移动端：无任何已启用音源插件时隐藏 每日推荐/音源榜单。
    final hasPlugins =
        ref.watch(pluginManagerProvider).sources.any((p) => p.enabled);
    final specs = <(Color, IconData, String, VoidCallback)>[
      (
        const Color(0xFFE8A33D),
        Icons.account_circle_rounded,
        '账号',
        () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AccountView()),
            ),
      ),
      if (hasPlugins) ...[
        (
          const Color(0xFFE8694D),
          Icons.recommend_rounded,
          '每日推荐',
          () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                    builder: (_) => const DailyRecommendPage()),
              ),
        ),
        (
          const Color(0xFF4A90D9),
          Icons.leaderboard_rounded,
          '音源榜单',
          () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const TopListPage()),
              ),
        ),
      ],
      (
        const Color(0xFF4A90D9),
        Icons.travel_explore_rounded,
        '搜索',
        () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const OnlineSearchPage()),
            ),
      ),
      (
        const Color(0xFFFF4D6E),
        Icons.library_music_rounded,
        '本地音乐',
        () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const LocalLibraryView()),
            ),
      ),
      (
        const Color(0xFFD94A8C),
        Icons.queue_music_rounded,
        '我的歌单',
        () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const CloudPlaylistsPage()),
            ),
      ),
      (
        const Color(0xFF5FA97C),
        Icons.settings_rounded,
        '设置',
        () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsView()),
            ),
      ),
    ];
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: SteppedListView(
          itemCount: specs.length,
          // 本页在 PageView 中：表冠是全局流，仅第 0 页且无上层推送页时
          // 才归本页，否则隐藏页会误滚动误振动。
          rotaryGuard: () => ref.read(localHubPageProvider) == 0,
          itemBuilder: (context, i) {
            final (color, icon, label, onTap) = specs[i];
            return SteppedTile(
              leading: SteppedLeadCircle(
                color: color,
                child: Icon(icon, size: 22 * s, color: Colors.white),
              ),
              title: label,
              trailing: Icon(
                Icons.chevron_right_rounded,
                size: 22 * s,
                color: Colors.white.withValues(alpha: 0.38),
              ),
              onTap: onTap,
            );
          },
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
      // 表冠门禁：仅播放页是 PageView 当前页时才调音量。
      rotaryGuard: () => ref.read(localHubPageProvider) == 1,
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
