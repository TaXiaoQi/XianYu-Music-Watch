import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wearable_rotary/wearable_rotary.dart';

import '../../favorites/favorites_provider.dart';
import '../../lyrics/lyric_model.dart';
import '../../lyrics/lyrics_repository.dart';
import '../../player/player_provider.dart';
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
    final st = ref.watch(playerProvider);
    return Scaffold(
      body: Stack(
        children: [
          // 全屏封面模糊背景（网易云手表版）：三页共享一层，横移时背景不动。
          Positioned.fill(
            child: CoverBackdrop(
              cover: CoverRef(
                filePath: st.current?.coverPath,
                url: st.current?.coverUrl,
              ),
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
  final ScrollController _scroll = ScrollController();
  StreamSubscription<RotaryEvent>? _rotarySub;

  @override
  void initState() {
    super.initState();
    _rotarySub = rotaryEvents.listen(_onRotary);
  }

  @override
  void dispose() {
    _rotarySub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onRotary(RotaryEvent event) {
    if (!mounted || !_scroll.hasClients) return;
    // 表冠是全局流：仅本页为当前页（PageView 第 0 页 + 无上层推送页）
    // 时响应，否则转表冠会滚动这份隐藏列表并误振。
    if (ref.read(localHubPageProvider) != 0) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final s = context.watchScale();
    final pitch = 64 * s; // 一档 = 一个条目，与列表阶梯节距一致
    final dir = event.direction == RotaryDirection.clockwise ? 1 : -1;
    final target = (_scroll.offset + dir * pitch)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
    );
    HapticFeedback.selectionClick(); // 表冠档位振动反馈
  }

  @override
  Widget build(BuildContext context) {
    // 透明：透出宿主层的全屏封面模糊背景；尺寸随屏径等比缩放。
    final s = context.watchScale();
    final pitch = 64 * s; // 阶梯节距：一个条目占一档
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 首尾留白：顶部/底部各补 (视口高-节距)/2，让第一项和
            // 最后一项都能精确停在屏幕正中（maxScroll 恰为 (n-1)*节距）。
            final spacer =
                ((constraints.maxHeight - pitch) / 2).clamp(0.0, double.infinity);
            return AnimatedBuilder(
              animation: _scroll,
              builder: (context, _) {
                // 居中锚点：屏幕正中是「当前项」。距锚点越远条目越小
                // （1.0 → 相邻 0.775 → 0.55 封底），上收/下收对称，
                // 形成网易云手表式「中间大、上下逐级缩小」的纵深列表。
                final offset = _scroll.hasClients ? _scroll.offset : 0.0;
                final anchor = offset + constraints.maxHeight / 2;
                return ListView.builder(
                  controller: _scroll,
                  itemExtent: pitch,
                  padding: EdgeInsets.symmetric(vertical: spacer),
                  itemCount: specs.length,
                  itemBuilder: (context, i) {
                    final distance =
                        ((i + 0.5) * pitch + spacer - anchor).abs() / pitch;
                    final scale = (1.0 - distance * 0.225).clamp(0.55, 1.0);
                    final alpha = 0.45 + 0.55 * ((scale - 0.55) / 0.45);
                    final (color, icon, label, onTap) = specs[i];
                    return Center(
                      child: Opacity(
                        opacity: alpha,
                        child: Transform.scale(
                          scale: scale,
                          child: _entry(
                            context: context,
                            color: color,
                            icon: icon,
                            label: label,
                            onTap: onTap,
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
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
    // 尺寸随屏径等比适配（与播放页同一套 watchScale 基准）。
    final s = context.watchScale();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(26 * s),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24 * s, vertical: 4 * s),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 46 * s,
              height: 46 * s,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Icon(icon, size: 22 * s, color: Colors.white),
            ),
            SizedBox(width: 14 * s),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 150 * s),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 17 * s,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            SizedBox(width: 5 * s),
            Icon(
              Icons.chevron_right_rounded,
              size: 22 * s,
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
