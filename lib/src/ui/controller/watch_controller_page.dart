import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../link/link_provider.dart';
import '../../lyrics/lyric_model.dart';
import '../../lyrics/lyrics_repository.dart';
import '../../core/watch_fit.dart';
import '../player/play_page_body.dart';
import '../player/cover_backdrop.dart';
import '../player/lyrics_view.dart';
import '../player/page_dots.dart';
import '../player/player_source.dart';

/// 联接控制页（网易云手表版形态）：左右横移双页 + 底部圆点指示。
///
/// 播放页 = 通用 PlayPageBody（联动数据源：表冠调手机音量、环形 seek、
/// 喜欢/播放模式，云中继显示小云标）；歌词页 = 手机推送的当前歌歌词
/// （type 0x13），当前行高亮自动居中，点行 seek。
class WatchControllerPage extends ConsumerStatefulWidget {
  const WatchControllerPage({super.key});

  @override
  ConsumerState<WatchControllerPage> createState() =>
      _WatchControllerPageState();
}

class _WatchControllerPageState extends ConsumerState<WatchControllerPage> {
  final PageController _pageCtrl = PageController();
  int _page = 0;

  /// 联动歌词解析缓存（lyricSongId → 行列表）。
  final Map<String, List<LyricLine>> _parsedLyrics = {};
  bool _parsing = false;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  /// 取当前歌歌词行；未命中缓存时后台解析（解析完 setState 生效）。
  List<LyricLine> _lyricsOf(LinkState link) {
    final id = link.lyricSongId;
    final payload = link.lyricPayload;
    // 歌词与当前歌不一致（未到/已过期）→ 视为无歌词。
    if (id == null || payload == null || id != (link.now?.id ?? '')) {
      return const [];
    }
    final cached = _parsedLyrics[id];
    if (cached != null) return cached;
    if (!_parsing) {
      _parsing = true;
      Future(() => parsePayload(payload)).then((lines) {
        _parsing = false;
        if (!mounted) return;
        _parsedLyrics[id] = lines;
        if (_parsedLyrics.length > 8) {
          _parsedLyrics.remove(_parsedLyrics.keys.first);
        }
        setState(() {});
      }).catchError((_) {
        _parsing = false;
      });
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final link = ref.watch(linkControllerProvider);
    final lyrics = _lyricsOf(link);
    final now = link.now;

    return Scaffold(
      body: Stack(
        children: [
          // 全屏封面模糊背景（网易云手表版）：双页共享一层，横移时背景不动。
          Positioned.fill(
            child: CoverBackdrop(
              cover: CoverRef(
                filePath: now?.coverIsFile == true ? now!.cover : null,
                url: now?.coverIsFile == true ? null : now?.cover,
              ),
            ),
          ),
          PageView(
            controller: _pageCtrl,
            onPageChanged: (i) => setState(() => _page = i),
            children: [
              PlayPageBody(
                sourceBuilder: () => LinkPlayerSource(
                  link,
                  ref.read(linkControllerProvider.notifier),
                ),
                showCloudBadge: link.viaCloud,
                emptyText: '手机未在播放',
                // 表冠门禁：仅播放页是 PageView 当前页时才调音量。
                rotaryGuard: () => _page == 0,
              ),
              LyricsView(
                lines: lyrics,
                position: link.position,
                isPlaying: link.isPlaying,
                onSeek: (secs) =>
                    ref.read(linkControllerProvider.notifier).seek(secs),
              ),
            ],
          ),
          // 底部页指示圆点（贴下缘居中，间距随屏径等比）
          Positioned(
            left: 0,
            right: 0,
            bottom: 10 * context.watchScale(),
            child: Center(
              child: PageDots(count: 2, current: _page),
            ),
          ),
        ],
      ),
    );
  }
}
