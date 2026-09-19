import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wearable_rotary/wearable_rotary.dart';

import '../../core/ambient.dart';
import '../../core/settings.dart';
import '../../core/watch_fit.dart';
import '../../lyrics/lyric_model.dart';
import '../../core/haptics.dart';
import 'play_page_body.dart' show kPlayerAccent;

class LyricsView extends ConsumerStatefulWidget {
  const LyricsView({
    super.key,
    required this.lines,
    required this.position,
    required this.isPlaying,
    this.onSeek,
    this.emptyText = '暂无歌词',
    this.rotaryGuard,
  });

  final List<LyricLine> lines;

  final double position;

  final bool isPlaying;
  final ValueChanged<double>? onSeek;
  final String emptyText;

  final bool Function()? rotaryGuard;

  @override
  ConsumerState<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<LyricsView>
    with SingleTickerProviderStateMixin {
  double _rowExtent = 32;

  double _vPad = 0;

  final ScrollController _scroll = ScrollController();
  StreamSubscription<RotaryEvent>? _rotarySub;
  TimingNavigator? _navigator;
  List<LyricLine> _lines = const [];
  int _currentIndex = -1;

  double _rotaryAcc = 0;

  int _hapticRow = 0;
  Timer? _hapticDebounce;

  DateTime _manualUntil = DateTime.fromMillisecondsSinceEpoch(0);

  int _offsetMs = 0;

  bool _showTranslation = true;

  late final Ticker _ticker;
  final ValueNotifier<double> _smoothPos = ValueNotifier(0);
  double _basePos = 0;
  double _baseTime = 0;

  @override
  void initState() {
    super.initState();
    _basePos = widget.position;
    _baseTime = _nowSec();
    _smoothPos.value = _basePos;
    _ticker = createTicker((_) => _pushSmooth());
    _syncLines();
    _rotarySub = rotaryEvents.listen(_onRotary);
    ref.listenManual(ambientModeProvider, (_, _) => _updateTicker());
  }

  @override
  void didUpdateWidget(LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lines, widget.lines) &&
        oldWidget.lines != widget.lines) {
      _syncLines();
    }
    if (widget.position != oldWidget.position ||
        widget.isPlaying != oldWidget.isPlaying) {
      _basePos = widget.position;
      _baseTime = _nowSec();
      if (!_ticker.isActive) _smoothPos.value = _basePos;
      _updateTicker();
    }
  }

  @override
  void dispose() {
    _rotarySub?.cancel();
    _hapticDebounce?.cancel();
    _ticker.dispose();
    _smoothPos.dispose();
    _scroll.dispose();
    super.dispose();
  }

  static double _nowSec() => DateTime.now().microsecondsSinceEpoch / 1e6;

  double get _estimate =>
      _ticker.isActive ? _basePos + (_nowSec() - _baseTime) : _basePos;

  void _pushSmooth([bool force = false]) {
    final pos = _estimate;
    if (force || (pos - _smoothPos.value).abs() >= 0.012) {
      _smoothPos.value = pos;
    }
  }

  void _updateTicker() {
    final shouldRun = widget.isPlaying &&
        !ref.read(ambientModeProvider) &&
        (widget.rotaryGuard?.call() ?? true);
    if (shouldRun && !_ticker.isActive) {
      _basePos = widget.position;
      _baseTime = _nowSec();
      _ticker.start();
      _pushSmooth(true);
    } else if (!shouldRun && _ticker.isActive) {
      final frozen = _basePos + (_nowSec() - _baseTime);
      _ticker.stop();
      _basePos = frozen;
      _baseTime = _nowSec();
      _smoothPos.value = frozen;
    }
  }

  void _onRotary(RotaryEvent event) {
    if (!mounted || !_scroll.hasClients) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final guard = widget.rotaryGuard;
    if (guard != null && !guard()) return;
    final dir = event.direction == RotaryDirection.clockwise ? 1.0 : -1.0;
    final m = (event.magnitude ?? 48).clamp(0.0, 64.0).toDouble();
    if (dir * _rotaryAcc < 0) _rotaryAcc = 0;
    _rotaryAcc += dir * m;
    final delta = _rotaryAcc * 0.5;
    _rotaryAcc = 0;
    final target = (_scroll.offset + delta)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    if ((target - _scroll.offset).abs() < 0.5) return;
    _scroll.jumpTo(target);
    _manualUntil = DateTime.now().add(const Duration(seconds: 4));
    _hapticDebounce?.cancel();
    _hapticDebounce = Timer(const Duration(milliseconds: 150), () {
      if (!mounted || !_scroll.hasClients) return;
      final row = (_scroll.offset / _rowExtent).floor();
      if (row != _hapticRow) {
        _hapticRow = row;
        Haptics.tick();
      }
    });
  }

  void _syncLines() {
    _lines = widget.lines;
    _navigator = _lines.isEmpty ? null : TimingNavigator(_lines);
    _currentIndex = -1;
    _hapticRow = 0;
  }

  void _applyPosition() {
    if (_navigator == null) return;
    final offsetMs = _offsetMs;
    final idx = _navigator!
        .findIndex((widget.position * 1000).round() - offsetMs);
    if (idx == _currentIndex) return;
    _currentIndex = idx;
    setState(() {});
    if (idx < 0) return;
    if (DateTime.now().isBefore(_manualUntil)) return;
    _centerOn(idx);
  }

  void _centerOn(int index) {
    if (!_scroll.hasClients) return;
    final viewport = _scroll.position.viewportDimension;
    final target = (_vPad + index * _rowExtent + _rowExtent / 2 - viewport / 2)
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
    final s = context.watchScale();
    final settings = ref.watch(settingsProvider).valueOrNull;
    final fontMul = const [0.85, 1.0, 1.15, 1.3][
        (settings?.lyricFontSize ?? 1).clamp(0, 3)];
    _offsetMs = (settings?.lyricOffsetMs ?? 0).clamp(-100, 100);
    _showTranslation = settings?.showLyricsTranslation ?? true;
    _rowExtent = 32 * s * fontMul;
    _vPad = MediaQuery.of(context).size.height * 0.3;

    ref.watch(ambientModeProvider);
    _updateTicker();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyPosition();
    });

    if (_lines.isEmpty) {
      return Center(
        child: Text(
          widget.emptyText,
          style: TextStyle(
            fontSize: 12 * s,
            color: Colors.white.withValues(alpha: 0.4),
          ),
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        final manual = (n is ScrollUpdateNotification &&
                n.dragDetails != null) ||
            n is ScrollEndNotification;
        if (manual) {
          _manualUntil = DateTime.now().add(const Duration(seconds: 4));
        }
        return false;
      },
      child: ShaderMask(
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: [0.0, 0.10, 0.90, 1.0],
        colors: [
          Colors.transparent,
          Colors.white,
          Colors.white,
          Colors.transparent,
        ],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: ListView.builder(
        controller: _scroll,
        itemExtent: _rowExtent,
        padding: EdgeInsets.symmetric(
          vertical: _vPad,
          horizontal: 16 * s,
        ),
        itemCount: _lines.length,
        itemBuilder: (context, i) {
          final line = _lines[i];
          final current = i == _currentIndex;
          final baseColor = current
              ? kPlayerAccent
              : Colors.white.withValues(alpha: 0.55);
          final mainFont = (current ? 13.5 : 10.5) * s * fontMul;
          final karaoke = current && line.words.isNotEmpty;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onSeek == null
                ? null
                : () => widget.onSeek!(line.timeMs / 1000),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (karaoke)
                  RepaintBoundary(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _smoothPos,
                      builder: (context, pos, _) => FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            for (final w in line.words)
                              _karaokeWord(
                                  w, pos - _offsetMs / 1000.0, mainFont),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  Text(
                    line.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: mainFont,
                      fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                      color: baseColor,
                    ),
                  ),
                if (_showTranslation &&
                    line.translation != null &&
                    line.translation!.isNotEmpty)
                  Text(
                    line.translation!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: (current ? 10 : 8.5) * s * fontMul,
                      color: current
                          ? kPlayerAccent.withValues(alpha: 0.75)
                          : Colors.white.withValues(alpha: 0.32),
                    ),
                  ),
              ],
            ),
          );
        },
        ),
      ),
    );
  }

  Widget _karaokeWord(LyricWord w, double pos, double fontSize) {
    final dur = math.max(0.001, w.end - w.start);
    final progress = ((pos - w.start) / dur).clamp(0.0, 1.0);
    const accent = kPlayerAccent;
    final dim = Colors.white.withValues(alpha: 0.30);
    final style = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      height: 1.2,
    );

    if (progress <= 0) {
      return Text(w.text, style: style.copyWith(color: dim));
    }
    if (progress >= 1) {
      return Text(
        w.text,
        style: style.copyWith(
          color: accent,
          shadows: [
            Shadow(color: accent.withValues(alpha: 0.35), blurRadius: 8),
          ],
        ),
      );
    }

    final featherEnd = (progress + 0.12).clamp(0.0, 1.0);
    final pop = math.sin(progress * math.pi);
    return Transform.translate(
      offset: Offset(0, -1.5 * pop),
      child: Transform.scale(
        scale: 1.0 + 0.04 * pop,
        child: ShaderMask(
          shaderCallback: (bounds) => LinearGradient(
            colors: [accent, dim],
            stops: [progress, featherEnd],
          ).createShader(bounds),
          child: Text(w.text, style: style.copyWith(color: accent)),
        ),
      ),
    );
  }
}
