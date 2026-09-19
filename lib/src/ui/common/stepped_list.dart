import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wearable_rotary/wearable_rotary.dart';
import '../../core/haptics.dart';
import '../../core/watch_fit.dart';

class PageTitleHeader extends StatelessWidget {
  const PageTitleHeader(
    this.title, {
    super.key,
    this.showBack = false,
    this.trailing,
  });

  final String title;
  final bool showBack;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4 * s),
      child: Row(
        children: [
          SizedBox(width: 48 * s, child: showBack ? const BackButton() : null),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15 * s,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
          ),
          SizedBox(width: 48 * s, child: trailing ?? const SizedBox.shrink()),
        ],
      ),
    );
  }
}

class SteppedListView extends StatefulWidget {
  const SteppedListView({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.header,
    this.headerExtent = 56,
    this.rotaryGuard,
    this.rowExtent,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  final Widget? header;
  final double headerExtent;

  final bool Function()? rotaryGuard;

  /// 可选：按行覆盖内容槽高（逻辑高度 ×s 为像素）。
  /// null 行回落 60 标准胶囊高；卡片/滑条等高内容行用它避免被钳制。
  final double? Function(int index)? rowExtent;

  @override
  State<SteppedListView> createState() => _SteppedListViewState();
}

class _SteppedListViewState extends State<SteppedListView> {
  static const double _pitchBase = 60;

  static const double _capsuleH = 56;

  static const double _rowSpacing = 1.06;

  static const double _minScale = 0.26;

  /// 相邻 0.72、隔行 0.47，三行外 0.37、四行外 0.32 渐进压平到 0.26 谷底
  static const double _decayTau = 1.28;
  static const double _decayPow = 2.1;

  double _viewportH = 0;
  double _startPad = 0;

  double _layoutCacheOffset = double.negativeInfinity;

  int _layoutCacheCount = -1;

  final ScrollController _scroll = ScrollController();
  StreamSubscription<RotaryEvent>? _rotarySub;

  double _rotaryAcc = 0;

  Timer? _settleTimer;

  int _hapticRow = 0;

  DateTime _lastRotaryAt = DateTime.fromMillisecondsSinceEpoch(0);

  DateTime _lastCrownTickAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool _thumbVisible = false;
  Timer? _thumbHideTimer;

  void _showThumb() {
    _thumbHideTimer?.cancel();
    if (!_thumbVisible && mounted) setState(() => _thumbVisible = true);
  }

  void _scheduleThumbHide() {
    _thumbHideTimer?.cancel();
    _thumbHideTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _thumbVisible = false);
    });
  }

  @override
  void initState() {
    super.initState();
    _rotarySub = rotaryEvents.listen(_onRotary);
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _thumbHideTimer?.cancel();
    _rotarySub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onRotary(RotaryEvent event) {
    if (!mounted || !_scroll.hasClients) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final guard = widget.rotaryGuard;
    if (guard != null && !guard()) return;
    final pitch = _nomPitch;
    final max = _scroll.position.maxScrollExtent;
    final dir = event.direction == RotaryDirection.clockwise ? 1.0 : -1.0;
    final m = (event.magnitude ?? 48).clamp(0.0, 64.0).toDouble();
    if (dir * _rotaryAcc < 0) _rotaryAcc = 0;
    _rotaryAcc = (dir * m + _rotaryAcc).clamp(-1.5 * pitch, 1.5 * pitch);
    final delta = _rotaryAcc * 0.5;
    _rotaryAcc = 0;
    final target = (_scroll.offset + delta).clamp(0.0, max);
    if ((target - _scroll.offset).abs() < 0.5) return;
    _scroll.jumpTo(target);
    _lastRotaryAt = DateTime.now();
    _settleTimer?.cancel();
    _settleTimer = Timer(
      const Duration(milliseconds: 60),
      () => _settleToGrid(feedback: true),
    );
  }

  // ── 变高行几何 ─────────────────────────────────────────────

  bool get _round {
    if (context.isRoundWatch) return true;
    final mq = MediaQuery.sizeOf(context);
    return mq.width > 0 &&
        mq.height > 0 &&
        ((mq.width / mq.height) - 1).abs() < 0.08;
  }

  bool get _hasHeader => widget.header != null;
  double get _headerBand => (_hasHeader ? widget.headerExtent : 0.0) * _s;
  double get _s => context.watchScale();
  double get _nomPitch => _pitchBase * _s;

  double _capsuleOf(int row) => widget.rowExtent?.call(row) ?? _capsuleH;

  double _scaleFromDist(double d) =>
      (_minScale +
              (1 - _minScale) /
                  (1 + math.pow(d / _decayTau, _decayPow).toDouble()))
          .clamp(_minScale, 1.0)
          .toDouble();

  double _scaleFor(int row, double offset) =>
      _round ? _layout(offset).scales[row] : 1.0;

  double _rowH(double scale, double capsule) =>
      _round ? capsule * _s * scale * _rowSpacing : capsule * _s;

  ({List<double> tops, List<double> heights, List<double> scales})?
  _layoutCache;

  ({List<double> tops, List<double> heights, List<double> scales}) _layout(
    double offset,
  ) {
    if (_layoutCacheOffset == offset &&
        _layoutCacheCount == widget.itemCount &&
        _layoutCache != null) {
      return _layoutCache!;
    }
    final n = widget.itemCount;
    var scales = List<double>.filled(n, 1.0);
    var tops = List<double>.filled(n, 0.0);
    var heights = List<double>.filled(n, 0.0);
    for (var it = 0; it < 12; it++) {
      var acc = _startPad + (_hasHeader ? _headerBand : 0.0);
      for (var i = 0; i < n; i++) {
        tops[i] = acc;
        heights[i] = _rowH(scales[i], _capsuleOf(i));
        acc += heights[i];
      }
      if (it == 11) break;
      for (var i = 0; i < n; i++) {
        final center = tops[i] + heights[i] / 2;
        final d = ((center - (offset + _viewportH / 2)).abs()) / _nomPitch;
        scales[i] = _scaleFromDist(d);
      }
    }
    _layoutCache = (tops: tops, heights: heights, scales: scales);
    _layoutCacheOffset = offset;
    _layoutCacheCount = n;
    return _layoutCache!;
  }

  int _focusRow(double offset) {
    final lay = _layout(offset);
    final anchor = offset + _viewportH / 2;
    var best = 0;
    var bestD = double.infinity;
    for (var d = 0; d < widget.itemCount; d++) {
      final c = lay.tops[d] + lay.heights[d] / 2;
      final dd = (c - anchor).abs();
      if (dd < bestD) {
        bestD = dd;
        best = d;
      }
    }
    return best;
  }

  double _snapFor(int row) {
    if (widget.itemCount == 0) return 0;
    var offset =
        (row + 0.5) * _nomPitch * _rowSpacing +
        _startPad +
        _headerBand -
        _viewportH / 2;
    for (var i = 0; i < 24; i++) {
      final lay = _layout(offset);
      final next = lay.tops[row] + lay.heights[row] / 2 - _viewportH / 2;
      if ((next - offset).abs() < 0.01) {
        offset = next;
        break;
      }
      offset = next;
    }
    return offset;
  }

  void _settleToGrid({bool feedback = false}) {
    if (!mounted || !_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final row = _focusRow(_scroll.offset);
    final target = _snapFor(row).clamp(0.0, max).toDouble();
    if ((target - _scroll.offset).abs() > 0.5) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 65),
        curve: Curves.easeOutCubic,
      );
    }
    if (feedback) _crownTick(row);
  }

  void _crownTick(int row) {
    final now = DateTime.now();
    if (now.difference(_lastCrownTickAt).inMilliseconds < 35) return;
    if (row == _hapticRow) return;
    _lastCrownTickAt = now;
    _hapticRow = row;
    Haptics.tick();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final round = context.isRoundWatch;
    final header = widget.header;
    final headerBand = header == null ? 0.0 : widget.headerExtent * s;
    final nomPitch = _pitchBase * s;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportH = constraints.maxHeight;
        final rowPad = (round ? 8.0 : 6.0) * s;
        final rowW = math.max(0.0, constraints.maxWidth - 2 * rowPad);
        final endPad = ((viewportH - nomPitch * _rowSpacing) / 2).clamp(
          0.0,
          double.infinity,
        );
        final startPad = math.max(0.0, endPad - headerBand);
        final tailPad = _round
            ? endPad + nomPitch * _rowSpacing * (1 - _minScale) * 2
            : endPad;
        final padExtra = _round
            ? nomPitch * _rowSpacing * (1 - _minScale) * 2
            : 0.0;
        _viewportH = viewportH;
        _startPad = startPad;
        final hasHeader = header != null;
        return Stack(
          children: [
            NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollEndNotification) {
                  _scheduleThumbHide();
                } else {
                  _showThumb();
                }
                if (n is! ScrollEndNotification) return false;
                if (!_scroll.hasClients) return false;
                if (DateTime.now().difference(_lastRotaryAt) <
                    const Duration(milliseconds: 200)) {
                  return false;
                }
                _settleToGrid();
                return false;
              },
              child: ListView.builder(
                controller: _scroll,
                physics: _SnapPhysics(snap: _nearestGridOffset),
                padding: EdgeInsets.fromLTRB(0, startPad, 0, tailPad),
                itemCount: widget.itemCount + (hasHeader ? 1 : 0),
                itemBuilder: (context, i) {
                  if (hasHeader && i == 0) {
                    return SizedBox(
                      height: headerBand,
                      child: Center(child: header),
                    );
                  }
                  final row = hasHeader ? i - 1 : i;
                  return AnimatedBuilder(
                    animation: _scroll,
                    child: RepaintBoundary(
                      child: widget.itemBuilder(context, row),
                    ),
                    builder: (context, child) {
                      final offset = _scroll.hasClients ? _scroll.offset : 0.0;
                      final scale = _scaleFor(row, offset);
                      final cap = _capsuleOf(row);
                      final rowH = _rowH(scale, cap);
                      double alpha = 1.0;
                      if (round) {
                        final lay = _layout(offset);
                        final c = lay.tops[row] + lay.heights[row] / 2 - offset;
                        final edge = math.min(c, viewportH - c);
                        final t = (edge / _nomPitch).clamp(0.0, 1.0);
                        alpha = (0.55 + 0.45 * scale) * (0.35 + 0.65 * t);
                      }
                      return SizedBox(
                        height: rowH,
                        child: Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: rowPad),
                            child: Transform.scale(
                              scale: scale,
                              child: OverflowBox(
                                alignment: Alignment.center,
                                minWidth: rowW,
                                maxWidth: rowW,
                                minHeight: cap * s,
                                maxHeight: cap * s,
                                child: alpha >= 1
                                    ? child
                                    : Opacity(opacity: alpha, child: child),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _thumbVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  child: CustomPaint(
                    painter: _ScrollThumbPainter(
                      controller: _scroll,
                      strokeWidth: 3.5 * s,
                      round: round,
                      extraExtent: padExtra,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  double _nearestGridOffset(double offset) {
    if (!_scroll.hasClients) return offset;
    final row = _focusRow(offset);
    return _snapFor(
      row,
    ).clamp(0.0, _scroll.position.maxScrollExtent).toDouble();
  }
}

class _SnapPhysics extends ClampingScrollPhysics {
  const _SnapPhysics({required this.snap, super.parent});

  final double Function(double pixels) snap;

  @override
  _SnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _SnapPhysics(snap: snap, parent: buildParent(ancestor));

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
    mass: 0.5,
    stiffness: 600.0,
    ratio: 1.0,
  );

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final double projected = velocity.abs() > toleranceFor(position).velocity
        ? position.pixels + velocity * 0.12
        : position.pixels;
    final double target = snap(
      projected,
    ).clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();
    if ((target - position.pixels).abs() < 0.5) return null;
    return ScrollSpringSimulation(spring, position.pixels, target, velocity);
  }
}

class _ScrollThumbPainter extends CustomPainter {
  _ScrollThumbPainter({
    required this.controller,
    required this.strokeWidth,
    required this.round,
    this.extraExtent = 0.0,
  }) : super(repaint: controller);

  final ScrollController controller;
  final double strokeWidth;

  final double extraExtent;

  final bool round;

  @override
  void paint(Canvas canvas, Size size) {
    if (controller.positions.isEmpty) return;
    final pos = controller.position;
    if (!pos.hasContentDimensions || pos.maxScrollExtent <= 0) return;
    final total = pos.maxScrollExtent + pos.viewportDimension;
    if (!round) {
      final track = size.height * 0.42;
      final bar = (track * pos.viewportDimension / total)
          .clamp(track * 0.18, track)
          .toDouble();
      final y =
          (pos.pixels / pos.maxScrollExtent).clamp(0.0, 1.0) * (track - bar);
      final rect = Rect.fromLTWH(
        size.width - strokeWidth * 1.8,
        (size.height - track) / 2 + y,
        strokeWidth,
        bar,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(strokeWidth / 2)),
        Paint()..color = Colors.white.withValues(alpha: 0.72),
      );
      return;
    }
    // 短总行程 + 长亮弧 + 短步距 = 系统设置右侧紧凑指示条观感
    const span = 55 * math.pi / 180;
    final content = math.max(
      pos.maxScrollExtent + pos.viewportDimension - extraExtent,
      pos.viewportDimension,
    );
    final thumbFrac = (pos.viewportDimension / content).clamp(0.18, 1.0);
    final off = (pos.pixels / math.max(pos.maxScrollExtent, 1.0)).clamp(
      0.0,
      1.0,
    );
    final thumb = span * thumbFrac;
    final start = -span / 2 + off * (span - thumb);
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.shortestSide / 2 - strokeWidth / 2 - 1.0,
    );
    canvas.drawArc(
      rect,
      -span / 2,
      span,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.08),
    );
    canvas.drawArc(
      rect,
      start,
      thumb,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.72),
    );
  }

  @override
  bool shouldRepaint(_ScrollThumbPainter oldDelegate) => false;
}

class SteppedPill extends StatelessWidget {
  const SteppedPill({super.key, this.onTap, this.child});

  final VoidCallback? onTap;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Ink(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(999),
      ),
      child: onTap == null
          ? child
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(999),
              child: child,
            ),
    );
  }
}

class SteppedTile extends StatelessWidget {
  const SteppedTile({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.titleColor,
    this.subtitleColor,
  });

  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? titleColor;
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final textReserve = leading != null
        ? 48.0 * s
        : (trailing != null ? 28.0 * s : 0.0);
    return SteppedPill(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 3 * s, vertical: 2 * s),
        child: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: textReserve),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 17 * s,
                          height: 1.25,
                          fontWeight: FontWeight.w600,
                          color: titleColor,
                        ),
                      ),
                      if (subtitle != null) ...[
                        SizedBox(height: 2 * s),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12 * s,
                            height: 1.2,
                            color:
                                subtitleColor ??
                                Colors.white.withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (leading != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: EdgeInsets.only(left: 4 * s),
                      child: leading!,
                    ),
                    SizedBox(width: 12 * s),
                  ],
                ),
              ),
            if (trailing != null)
              Align(alignment: Alignment.centerRight, child: trailing!),
          ],
        ),
      ),
    );
  }
}

class SteppedLeadCircle extends StatelessWidget {
  const SteppedLeadCircle({
    super.key,
    this.color = const Color(0xFFFFFFFF),
    this.child,
  });

  final Color color;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Container(
      width: 40 * s,
      height: 40 * s,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: child,
    );
  }
}
