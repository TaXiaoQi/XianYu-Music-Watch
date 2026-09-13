import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ambient.dart';
import '../../lyrics/lyric_model.dart';
import 'play_page_body.dart' show kPlayerAccent;

/// 歌词页视图（网易云手表版形态）：全屏滚动歌词，当前行主题色高亮 +
/// 自动居中滚动；点按歌词行 seek。环境模式下冻结动画（OLED 防烧屏）。
///
/// 行高固定（单行主词 + 可选单行翻译），保证居中滚动可按行号直算。
class LyricsView extends ConsumerStatefulWidget {
  const LyricsView({
    super.key,
    required this.lines,
    required this.position,
    required this.isPlaying,
    this.onSeek,
    this.emptyText = '暂无歌词',
  });

  final List<LyricLine> lines;

  /// 当前播放进度（秒）。
  final double position;

  final bool isPlaying;
  final ValueChanged<double>? onSeek;
  final String emptyText;

  @override
  ConsumerState<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<LyricsView> {
  static const _rowExtent = 52.0;

  final ScrollController _scroll = ScrollController();
  TimingNavigator? _navigator;
  List<LyricLine> _lines = const [];
  int _currentIndex = -1;

  @override
  void initState() {
    super.initState();
    _syncLines();
  }

  @override
  void didUpdateWidget(LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lines, widget.lines) &&
        oldWidget.lines != widget.lines) {
      _syncLines();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _syncLines() {
    _lines = widget.lines;
    _navigator = _lines.isEmpty ? null : TimingNavigator(_lines);
    _currentIndex = -1;
  }

  void _applyPosition() {
    if (_navigator == null) return;
    final idx = _navigator!.findIndex((widget.position * 1000).round());
    if (idx == _currentIndex) return;
    _currentIndex = idx;
    if (idx < 0) return;
    _centerOn(idx);
  }

  /// 当前行驶向屏幕中央；环境模式下直接跳转（无动画省电）。
  void _centerOn(int index) {
    if (!_scroll.hasClients) return;
    final viewport = _scroll.position.viewportDimension;
    final target =
        (index * _rowExtent + _rowExtent / 2 - viewport / 2)
            .clamp(0.0, _scroll.position.maxScrollExtent);
    if (ref.read(ambientModeProvider)) {
      _scroll.jumpTo(target);
      return;
    }
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 环境模式参与重建：ambient 冻结时静态渲染当前帧即可。
    ref.watch(ambientModeProvider);
    // 每帧对齐进度（findIndex 为 O(log N) + 步进，单帧开销可忽略）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyPosition();
    });

    if (_lines.isEmpty) {
      return Center(
        child: Text(
          widget.emptyText,
          style: TextStyle(
            fontSize: 13,
            color: Colors.white.withValues(alpha: 0.4),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scroll,
      itemExtent: _rowExtent,
      padding: EdgeInsets.symmetric(
        vertical: MediaQuery.of(context).size.height * 0.3,
        horizontal: 18,
      ),
      itemCount: _lines.length,
      itemBuilder: (context, i) {
        final line = _lines[i];
        final current = i == _currentIndex;
        final baseColor = current
            ? kPlayerAccent
            : Colors.white.withValues(alpha: 0.38);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onSeek == null
              ? null
              : () => widget.onSeek!(line.timeMs / 1000),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                line.text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: current ? 15 : 13,
                  fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                  color: baseColor,
                ),
              ),
              if (line.translation != null && line.translation!.isNotEmpty)
                Text(
                  line.translation!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: current ? 11 : 10,
                    color: current
                        ? kPlayerAccent.withValues(alpha: 0.75)
                        : Colors.white.withValues(alpha: 0.25),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
