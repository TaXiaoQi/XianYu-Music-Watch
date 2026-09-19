import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../link/link_provider.dart';
import '../../lyrics/lyric_model.dart';
import '../../lyrics/lyrics_repository.dart';
import '../../core/watch_fit.dart';
import '../common/root_back_scope.dart';
import '../player/play_page_body.dart';
import '../player/cover_backdrop.dart';
import '../player/lyrics_view.dart';
import '../player/page_dots.dart';
import '../player/player_source.dart';

class WatchControllerPage extends ConsumerStatefulWidget {
  const WatchControllerPage({
    super.key,
    this.frontBuilder,
    this.isRootHome = false,
  });

  final Widget Function({required bool Function() isCurrent})? frontBuilder;

  final bool isRootHome;

  @override
  ConsumerState<WatchControllerPage> createState() =>
      _WatchControllerPageState();
}

class _WatchControllerPageState extends ConsumerState<WatchControllerPage> {
  bool get _hasFront => widget.frontBuilder != null;
  int get _playIndex => _hasFront ? 1 : 0;
  int get _lyricsIndex => _hasFront ? 2 : 1;

  late final PageController _pageCtrl;
  late int _page;

  final Map<String, List<LyricLine>> _parsedLyrics = {};
  bool _parsing = false;

  @override
  void initState() {
    super.initState();
    _page = _hasFront ? 1 : 0;
    _pageCtrl = PageController(initialPage: _page);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  List<LyricLine> _lyricsOf(LinkState link) {
    final id = link.lyricSongId;
    final payload = link.lyricPayload;
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

    final body = Scaffold(
      body: Stack(
        children: [
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
              if (_hasFront)
                widget.frontBuilder!(isCurrent: () => _page == 0),
              PlayPageBody(
                sourceBuilder: () => LinkPlayerSource(
                  link,
                  ref.read(linkControllerProvider.notifier),
                ),
                showCloudBadge: link.viaCloud,
                emptyText: '手机未在播放',
                rotaryGuard: () => _page == _playIndex,
              ),
              LyricsView(
                lines: lyrics,
                position: link.position,
                isPlaying: link.isPlaying,
                onSeek: (secs) =>
                    ref.read(linkControllerProvider.notifier).seek(secs),
                rotaryGuard: () => _page == _lyricsIndex,
              ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 10 * context.watchScale(),
            child: Center(
              child: PageDots(
                count: (_hasFront ? 3 : 2),
                current: _page,
              ),
            ),
          ),
        ],
      ),
    );

    if (!widget.isRootHome) return body;
    return RootBackScope(pageCtrl: _pageCtrl, child: body);
  }
}
