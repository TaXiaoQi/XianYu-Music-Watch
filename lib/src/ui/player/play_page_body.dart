import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wearable_rotary/wearable_rotary.dart';

import '../../core/haptics.dart';
import '../../core/watch_fit.dart';
import '../common/full_dialog.dart';
import '../common/rotary_input.dart';
import '../common/stepped_list.dart';
import 'effects_page.dart';
import 'player_source.dart';

const Color kPlayerAccent = Color(0xFFFF4D6E);

class PlayPageBody extends StatefulWidget {
  const PlayPageBody({
    super.key,
    required this.sourceBuilder,
    this.showCloudBadge = false,
    this.emptyText = '未在播放',
    this.emptyActionLabel,
    this.onEmptyAction,
    this.rotaryGuard,
  });

  final PlayerViewSource Function() sourceBuilder;

  final bool showCloudBadge;

  final String emptyText;

  final String? emptyActionLabel;
  final VoidCallback? onEmptyAction;

  final bool Function()? rotaryGuard;

  @override
  State<PlayPageBody> createState() => _PlayPageBodyState();
}

class _PlayPageBodyState extends State<PlayPageBody> {
  StreamSubscription<RotaryEvent>? _rotarySub;
  final RotaryQuantizer _rotary = RotaryQuantizer();

  double? _volume;

  DateTime _lastRotary = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _volumeSendTimer;

  bool _volumePageOpen = false;

  double? _scrubTarget;
  bool _longSeeking = false;
  bool _longSeekForward = true;
  Timer? _seekSendTimer;
  Timer? _longSeekTimer;

  @override
  void initState() {
    super.initState();
    _rotarySub = rotaryEvents.listen(_onRotary);
  }

  @override
  void dispose() {
    _rotarySub?.cancel();
    _volumeSendTimer?.cancel();
    _seekSendTimer?.cancel();
    _longSeekTimer?.cancel();
    super.dispose();
  }

  void _onRotary(RotaryEvent event) {
    if (!mounted) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final guard = widget.rotaryGuard;
    if (guard != null && !guard()) return;
    final steps = _rotary.add(event);
    if (steps == 0 || _volumePageOpen) return;
    _volumePageOpen = true;
    Haptics.tick();
    final src = widget.sourceBuilder();
    _lastRotary = DateTime.now();
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => _VolumePage(
              initial: (_volume ?? src.volume).clamp(0.0, 1.0),
              onChanged: _onVolumePageChanged,
            ),
          ),
        )
        .whenComplete(() => _volumePageOpen = false);
  }

  void _onVolumePageChanged(double v) {
    _lastRotary = DateTime.now();
    setState(() => _volume = v);
    _volumeSendTimer?.cancel();
    _volumeSendTimer = Timer(const Duration(milliseconds: 250), () {
      widget.sourceBuilder().setVolume(_volume ?? 0.5);
    });
  }

  void _openMoreSheet() {
    Haptics.tick();
    showFullDialog<void>(
      context: context,
      builder: (_) => _PlayerSettingsSheet(
        sourceBuilder: widget.sourceBuilder,
        onOpenEffects: () {
          Haptics.tick();
          Navigator.of(context, rootNavigator: true).pop();
          openSoundEffectsPage(context);
        },
      ),
    );
  }

  void _onRingPanStart(DragStartDetails d, double size) {
    if (widget.sourceBuilder().duration <= 0) return;
    final pos = _angleToProgress(d.localPosition, size);
    setState(() => _scrubTarget = pos);
    _sendSeekThrottled(pos);
  }

  void _onRingPanUpdate(DragUpdateDetails d, double size) {
    if (_scrubTarget == null) return;
    final pos = _angleToProgress(d.localPosition, size);
    setState(() => _scrubTarget = pos);
    _sendSeekThrottled(pos);
  }

  void _onRingPanEnd() {
    _seekSendTimer?.cancel();
    _seekSendTimer = null;
    final target = _scrubTarget;
    setState(() => _scrubTarget = null);
    if (target != null) _sendSeek(target);
  }

  void _onRingLongPressStart(LongPressStartDetails d, double size) {
    if (widget.sourceBuilder().duration <= 0) return;
    _longSeekForward = d.localPosition.dx >= size / 2;
    setState(() => _longSeeking = true);
    _startLongSeek();
  }

  void _onRingLongPressMoveUpdate(LongPressMoveUpdateDetails d, double size) {
    final forward = d.localPosition.dx >= size / 2;
    if (forward != _longSeekForward) {
      _longSeekForward = forward;
      _startLongSeek();
    }
  }

  void _onRingLongPressEnd() {
    _longSeekTimer?.cancel();
    _longSeekTimer = null;
    if (mounted) setState(() => _longSeeking = false);
  }

  void _startLongSeek() {
    _longSeekTimer?.cancel();
    _doLongSeek();
    _longSeekTimer = Timer.periodic(const Duration(milliseconds: 600), (_) {
      _doLongSeek();
    });
  }

  void _doLongSeek() {
    final src = widget.sourceBuilder();
    if (src.duration <= 0) return;
    final delta = _longSeekForward ? 10.0 : -10.0;
    final target = (src.position + delta).clamp(0.0, src.duration);
    src.seekTo(target);
    Haptics.tick();
  }

  void _sendSeek(double pos) {
    final src = widget.sourceBuilder();
    if (src.duration <= 0) return;
    src.seekTo(pos * src.duration);
  }

  void _sendSeekThrottled(double pos) {
    _seekSendTimer?.cancel();
    _seekSendTimer = Timer(const Duration(milliseconds: 120), () {
      if (_scrubTarget != null) _sendSeek(pos);
    });
  }

  static double _angleToProgress(Offset p, double size) {
    final dx = p.dx - size / 2;
    final dy = p.dy - size / 2;
    var a = math.atan2(dy, dx) + math.pi / 2;
    if (a < 0) a += 2 * math.pi;
    return (a / (2 * math.pi)).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final src = widget.sourceBuilder();
    final s = context.watchScale();
    final ringSize = 92 * s;

    if (DateTime.now().difference(_lastRotary) > const Duration(seconds: 1)) {
      _volume = src.volume;
    }
    final displayProgress =
        _scrubTarget ??
        ((src.duration > 0) ? (src.position / src.duration) : 0.0);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          SafeArea(
            left: false,
            right: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(4 * s, 2 * s, 4 * s, 8 * s),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12 * s),
                    child: Column(
                      children: [
                        if (src.hasTrack)
                          SizedBox(
                            width: double.infinity,
                            child: _MarqueeText(
                              src.title ?? '',
                              style: TextStyle(
                                fontSize: 17.5 * s,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          )
                        else if (widget.emptyActionLabel == null)
                          SizedBox(
                            width: double.infinity,
                            child: _MarqueeText(
                              widget.emptyText,
                              style: TextStyle(
                                fontSize: 13 * s,
                                fontWeight: FontWeight.w700,
                                color: Colors.white.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                        if (!src.hasTrack && widget.emptyActionLabel != null)
                          FilledButton.tonal(
                            onPressed: widget.onEmptyAction,
                            style: FilledButton.styleFrom(
                              padding: EdgeInsets.symmetric(
                                horizontal: 14 * s,
                                vertical: 6 * s,
                              ),
                              minimumSize: Size(0, 30 * s),
                            ),
                            child: Text(
                              widget.emptyActionLabel!,
                              style: TextStyle(fontSize: 12 * s),
                            ),
                          ),
                        if (src.hasTrack) ...[
                          SizedBox(height: 2 * s),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (widget.showCloudBadge) ...[
                                Icon(
                                  Icons.cloud_outlined,
                                  size: 10 * s,
                                  color: Colors.white.withValues(alpha: 0.45),
                                ),
                                SizedBox(width: 3.5 * s),
                              ],
                              Flexible(
                                child: _MarqueeText(
                                  src.artist ?? '',
                                  style: TextStyle(
                                    fontSize: 11 * s,
                                    color: Colors.white.withValues(alpha: 0.6),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(height: 3 * s),
                  Row(
                    children: [
                      SizedBox(
                        width: 44 * s,
                        child: _sideBtn(
                          s: s,
                          icon: Icons.skip_previous_rounded,
                          onTap: src.prev,
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: GestureDetector(
                            onTap: src.toggle,
                            onPanStart: (d) => _onRingPanStart(d, ringSize),
                            onPanUpdate: (d) => _onRingPanUpdate(d, ringSize),
                            onPanEnd: (_) => _onRingPanEnd(),
                            onLongPressStart: (d) =>
                                _onRingLongPressStart(d, ringSize),
                            onLongPressMoveUpdate: (d) =>
                                _onRingLongPressMoveUpdate(d, ringSize),
                            onLongPressEnd: (_) => _onRingLongPressEnd(),
                            child: SizedBox(
                              width: ringSize,
                              height: ringSize,
                              child: CustomPaint(
                                painter: _RingPainter(
                                  progress: displayProgress,
                                  strokeWidth: 4.5 * s,
                                ),
                                child: Padding(
                                  padding: EdgeInsets.all(2.5 * s),
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      ClipOval(child: _cover(src.cover)),
                                      Icon(
                                        src.isPlaying
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                        size: ringSize * 0.42,
                                        color: Colors.white,
                                        shadows: [
                                          Shadow(
                                            color: Colors.black.withValues(
                                              alpha: 0.5,
                                            ),
                                            blurRadius: 10 * s,
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 44 * s,
                        child: _sideBtn(
                          s: s,
                          icon: Icons.skip_next_rounded,
                          onTap: src.next,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 2 * s),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12 * s),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        if (src.liked != null)
                          _bottomBtn(
                            s: s,
                            icon: src.liked!
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            color: src.liked!
                                ? kPlayerAccent
                                : Colors.white.withValues(alpha: 0.85),
                            onTap: src.like,
                            tooltip: '喜欢',
                          ),
                        if (src.fromDaily)
                          _bottomBtn(
                            s: s,
                            iconWidget: SizedBox(
                              width: 21 * s,
                              height: 21 * s,
                              child: CustomPaint(
                                painter: _DislikeStrokePainter(
                                  color: Colors.white.withValues(alpha: 0.85),
                                ),
                                child: Icon(
                                  Icons.favorite_border_rounded,
                                  size: 19 * s,
                                  color: Colors.white.withValues(alpha: 0.85),
                                ),
                              ),
                            ),
                            onTap: () async {
                              final ok = await src.dislike();
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(ok ? '已减少此类推荐' : '请先登录后使用每日推荐'),
                                  duration: const Duration(seconds: 1),
                                ),
                              );
                            },
                            tooltip: '不喜欢',
                          ),
                        _bottomBtn(
                          s: s,
                          icon: (_volume ?? src.volume) <= 0
                              ? Icons.volume_off_rounded
                              : (_volume ?? src.volume) < 0.5
                              ? Icons.volume_down_rounded
                              : Icons.volume_up_rounded,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _VolumePage(
                                initial: (_volume ?? src.volume).clamp(
                                  0.0,
                                  1.0,
                                ),
                                onChanged: _onVolumePageChanged,
                              ),
                            ),
                          ),
                          tooltip: '音量',
                        ),
                        _bottomBtn(
                          s: s,
                          icon: Icons.apps_rounded,
                          onTap: _openMoreSheet,
                          tooltip: '更多（播放模式/倍速）',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_longSeeking)
            Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: EdgeInsets.only(top: 8 * s),
                padding: EdgeInsets.symmetric(
                  horizontal: 12 * s,
                  vertical: 5 * s,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(18 * s),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_longSeekForward) ...[
                      Icon(Icons.fast_rewind_rounded, size: 14 * s),
                      SizedBox(width: 5 * s),
                    ],
                    Text(
                      _longSeekForward ? '+10s' : '-10s',
                      style: TextStyle(fontSize: 11.5 * s),
                    ),
                    if (_longSeekForward) ...[
                      SizedBox(width: 5 * s),
                      Icon(Icons.fast_forward_rounded, size: 14 * s),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _cover(CoverRef cover) {
    if (!cover.isEmpty) {
      if (cover.filePath != null && cover.filePath!.isNotEmpty) {
        return Image.file(
          File(cover.filePath!),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const _CoverFallback(),
        );
      }
      if (cover.url != null && cover.url!.isNotEmpty) {
        return Image.network(
          cover.url!,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const _CoverFallback(),
        );
      }
    }
    return const _CoverFallback();
  }

  Widget _sideBtn({
    required double s,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(
        icon,
        size: 28 * s,
        color: Colors.white.withValues(alpha: 0.92),
      ),
      padding: EdgeInsets.all(4 * s),
      constraints: BoxConstraints(minWidth: 44 * s, minHeight: 44 * s),
    );
  }

  Widget _bottomBtn({
    required double s,
    IconData? icon,
    Widget? iconWidget,
    required VoidCallback onTap,
    Color color = Colors.white,
    String? tooltip,
  }) {
    return IconButton(
      onPressed: onTap,
      icon: iconWidget ?? Icon(icon, size: 21 * s, color: color),
      tooltip: tooltip,
      padding: EdgeInsets.all(6 * s),
      constraints: BoxConstraints(minWidth: 44 * s, minHeight: 44 * s),
    );
  }
}

// 播放设置：与音效页统一的阶梯列表布局（标签行 + 胶囊组行 + 瘦长条入口）
class _PlayerSettingsSheet extends StatefulWidget {
  const _PlayerSettingsSheet({required this.sourceBuilder, this.onOpenEffects});

  final PlayerViewSource Function() sourceBuilder;

  final VoidCallback? onOpenEffects;

  @override
  State<_PlayerSettingsSheet> createState() => _PlayerSettingsSheetState();
}

class _PlayerSettingsSheetState extends State<_PlayerSettingsSheet> {
  static const _speedSteps = [0.75, 1.0, 1.25, 1.5, 2.0];

  static String _speedLabel(double s) =>
      s == s.roundToDouble() ? '${s.toStringAsFixed(1)}x' : '${s}x';

  static String _modeLabel(int m) => switch (m) {
    1 => '单曲循环',
    2 => '随机播放',
    _ => '列表循环',
  };

  static IconData _modeIcon(int m) => switch (m) {
    2 => Icons.shuffle_rounded,
    1 => Icons.repeat_one_rounded,
    _ => Icons.repeat_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final src = widget.sourceBuilder();
    final rows = <(Widget, double)>[
      (_sheetLabel('播放模式', s), 30.0),
      (
        Wrap(
          spacing: 7 * s,
          runSpacing: 7 * s,
          alignment: WrapAlignment.center,
          children: [
            for (var m = 0; m < 3; m++)
              _sheetChip(
                s: s,
                active: src.playMode == m,
                onTap: () {
                  src.setMode(m);
                  Haptics.tick();
                  setState(() {});
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _modeIcon(m),
                      size: 14.5 * s,
                      color: src.playMode == m
                          ? kPlayerAccent
                          : Colors.white.withValues(alpha: 0.7),
                    ),
                    SizedBox(width: 4.5 * s),
                    Text(
                      _modeLabel(m),
                      style: TextStyle(
                        fontSize: 11.5 * s,
                        color: src.playMode == m
                            ? kPlayerAccent
                            : Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        64.0,
      ),
      if (src.speed != null) ...[
        (_sheetLabel('倍速', s), 30.0),
        (
          Wrap(
            spacing: 7 * s,
            runSpacing: 7 * s,
            alignment: WrapAlignment.center,
            children: [
              for (final v in _speedSteps)
                _sheetChip(
                  s: s,
                  active: (src.speed! - v).abs() < 0.01,
                  onTap: () {
                    src.setSpeed(v);
                    Haptics.tick();
                    setState(() {});
                  },
                  child: Text(
                    _speedLabel(v),
                    style: TextStyle(
                      fontSize: 11.5 * s,
                      fontWeight: FontWeight.w600,
                      color: (src.speed! - v).abs() < 0.01
                          ? kPlayerAccent
                          : Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                ),
            ],
          ),
          64.0,
        ),
      ],
      if (src.supportsSoundEffects)
        (
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onOpenEffects,
            child: Container(
              height: 46 * s,
              padding: EdgeInsets.symmetric(horizontal: 12 * s),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(23 * s),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.graphic_eq_rounded,
                    size: 18 * s,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                  SizedBox(width: 10 * s),
                  Expanded(
                    child: Text(
                      '均衡器 · 音效调节',
                      style: TextStyle(
                        fontSize: 13 * s,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 15 * s,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                ],
              ),
            ),
          ),
          54.0,
        ),
    ];
    return Scaffold(
      backgroundColor: const Color(0xFF101014),
      body: SafeArea(
        child: SteppedListView(
          itemCount: rows.length,
          itemBuilder: (context, i) => rows[i].$1,
          rowExtent: (i) => rows[i].$2,
          header: const PageTitleHeader('播放设置'),
        ),
      ),
    );
  }

  Widget _sheetLabel(String text, double s) => Text(
    text,
    style: TextStyle(
      fontSize: 10 * s,
      fontWeight: FontWeight.w600,
      color: Colors.white.withValues(alpha: 0.45),
    ),
  );

  Widget _sheetChip({
    required double s,
    required bool active,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.symmetric(horizontal: 11 * s, vertical: 6.5 * s),
        decoration: BoxDecoration(
          color: active
              ? kPlayerAccent.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(15 * s),
          border: Border.all(
            color: active ? kPlayerAccent : Colors.transparent,
            width: 1,
          ),
        ),
        child: child,
      ),
    );
  }
}

class _DislikeStrokePainter extends CustomPainter {
  final Color color;
  const _DislikeStrokePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width * 0.14, size.height * 0.14),
      Offset(size.width * 0.86, size.height * 0.86),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _DislikeStrokePainter old) => old.color != color;
}

class _CoverFallback extends StatelessWidget {
  const _CoverFallback();

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Container(
      color: const Color(0xFF1A1A1E),
      child: Icon(
        Icons.music_note_rounded,
        size: 30 * s,
        color: Colors.white.withValues(alpha: 0.35),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, this.strokeWidth = 4});

  final double progress;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = Colors.white.withValues(alpha: 0.14);
    canvas.drawArc(rect, 0, 2 * math.pi, false, track);

    final p = progress.clamp(0.0, 1.0);
    if (p > 0.001) {
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = kPlayerAccent;
      canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * p, false, arc);
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.strokeWidth != strokeWidth;
}

class _MarqueeText extends StatefulWidget {
  const _MarqueeText(this.text, {required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  static const double _gapBase = 30;
  static const double _speed = 26;
  static const _headPause = Duration(milliseconds: 1400);

  late final AnimationController _c = AnimationController(vsync: this);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxW = constraints.maxWidth;
        final tp = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout();
        final textW = tp.width;
        final textH = tp.height;
        tp.dispose();
        if (boxW <= 0 || textW <= boxW || widget.text.isEmpty) {
          _c.stop();
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: widget.style,
          );
        }
        final travel = textW + _gapBase * s;
        final scrollMs = (travel / (_speed * s) * 1000).round();
        _c.duration = _headPause + Duration(milliseconds: scrollMs);
        if (!_c.isAnimating) _c.repeat();
        final pauseFrac =
            _headPause.inMilliseconds / _c.duration!.inMilliseconds;
        return ClipRect(
          child: SizedBox(
            width: boxW,
            height: textH,
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                final frac = _c.value <= pauseFrac
                    ? 0.0
                    : ((_c.value - pauseFrac) / (1 - pauseFrac)).clamp(
                        0.0,
                        1.0,
                      );
                return Stack(
                  children: [
                    Positioned(
                      left: -frac * travel,
                      top: 0,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(widget.text, maxLines: 1, style: widget.style),
                          SizedBox(width: _gapBase * s),
                          Text(widget.text, maxLines: 1, style: widget.style),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _VolumePage extends StatefulWidget {
  const _VolumePage({required this.initial, required this.onChanged});

  final double initial;
  final ValueChanged<double> onChanged;

  @override
  State<_VolumePage> createState() => _VolumePageState();
}

class _VolumePageState extends State<_VolumePage> {
  static const _crownStep = 0.04;

  late double _v = widget.initial.clamp(0.0, 1.0).toDouble();
  Timer? _closeTimer;
  StreamSubscription<RotaryEvent>? _rotarySub;
  final RotaryQuantizer _rotary = RotaryQuantizer();

  @override
  void initState() {
    super.initState();
    _rotarySub = rotaryEvents.listen(_onRotary);
    _armAutoClose();
  }

  @override
  void dispose() {
    _rotarySub?.cancel();
    _closeTimer?.cancel();
    super.dispose();
  }

  void _armAutoClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  void _update(double v, {bool haptic = true}) {
    final next = v.clamp(0.0, 1.0).toDouble();
    if (haptic) Haptics.tick();
    setState(() => _v = next);
    widget.onChanged(next);
    _armAutoClose();
  }

  void _onRotary(RotaryEvent event) {
    if (!mounted) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final steps = _rotary.add(event);
    if (steps == 0) return;
    _update(_v + steps * _crownStep);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final barWidth = 64 * s;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Text(
              '音量',
              style: TextStyle(
                fontSize: 12.5 * s,
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),
            SizedBox(height: 8 * s),
            Expanded(
              child: LayoutBuilder(
                builder: (context, cons) {
                  final barHeight = cons.maxHeight
                      .clamp(0.0, 240 * s)
                      .toDouble();
                  double valueFromY(double dy) =>
                      (1 - dy / barHeight).clamp(0.0, 1.0).toDouble();
                  return Center(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (d) => _update(
                        valueFromY(d.localPosition.dy),
                        haptic: false,
                      ),
                      onPanStart: (d) => _update(
                        valueFromY(d.localPosition.dy),
                        haptic: false,
                      ),
                      onPanUpdate: (d) => _update(
                        valueFromY(d.localPosition.dy),
                        haptic: false,
                      ),
                      child: Container(
                        width: barWidth,
                        height: barHeight,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(barWidth / 2),
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              height: barHeight * _v.clamp(0.0, 1.0),
                              child: ColoredBox(color: kPlayerAccent),
                            ),
                            Text(
                              '${(_v * 100).round()}',
                              style: TextStyle(
                                fontSize: 34 * s,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                shadows: const [
                                  Shadow(color: Colors.black45, blurRadius: 8),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
