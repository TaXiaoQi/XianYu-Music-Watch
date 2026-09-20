import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:wearable_rotary/wearable_rotary.dart';
import '../../core/haptics.dart';
import '../../core/watch_fit.dart';

/// 功能条统一胶囊底色：深灰实底 + 白字（对齐系统设置暗色风格）
const Color kSteppedTileBg = Color(0xFF26262A);

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
    this.rowSpacing,
    this.rowPadding,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  final Widget? header;
  final double headerExtent;

  final bool Function()? rotaryGuard;

  /// 可选：按行覆盖内容槽高（逻辑高度 ×s 为像素）。
  /// null 行回落 60 标准胶囊高；卡片/滑条等高内容行用它避免被钳制。
  final double? Function(int index)? rowExtent;

  /// 可选：覆盖行距系数（行高 × spacing = 占位高，默认 1.06），加大行间隙用
  final double? rowSpacing;

  /// 可选：覆盖行左右留白（逻辑值，默认圆屏 8 / 方屏 6），加宽梯形整体用
  final double? rowPadding;

  @override
  State<SteppedListView> createState() => _SteppedListViewState();
}

class _SteppedListViewState extends State<SteppedListView> {
  static const double _pitchBase = 60;

  static const double _capsuleH = 56;

  /// 行距系数默认值（功能页同款），可被 widget.rowSpacing 覆盖
  double get _rowSpacing => widget.rowSpacing ?? 1.12;

  static const double _minScale = 0.26;

  /// 相邻 0.72、隔行 0.47，三行外 0.37、四行外 0.32 渐进压平到 0.26 谷底
  static const double _decayTau = 1.28;
  static const double _decayPow = 2.1;

  /// 三行开外压向的更低谷底（两行内曲线不受影响），d=4 起压满
  static const double _farScale = 0.16;

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
    // 表冠增量平滑滑动（对齐手指拖拽的顺滑手感）：短时长缓动滑向目标，
    // 而非 jumpTo 瞬时硬跳导致机械感；连按会取消上一段并续滑，停止后仍由
    // 下方 60ms 定时器做网格吸附（ScrollEnd 200ms 守卫已屏蔽边滑边吸附）。
    unawaited(
      _scroll
          .animateTo(
            target,
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOutCubic,
          )
          .catchError((_) {}),
    );
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

  double _scaleFromDist(double d) {
    final base =
        (_minScale +
                (1 - _minScale) /
                    (1 + math.pow(d / _decayTau, _decayPow).toDouble()))
            .clamp(_minScale, 1.0)
            .toDouble();
    if (d <= 2) return base;
    // 三行开外整体再压小：从原曲线值渐进压向更低谷底 _farScale（d=4 压满）
    final t = ((d - 2) / 2).clamp(0.0, 1.0);
    final w = 1 - math.pow(1 - t, 2).toDouble();
    return base + (_farScale - base) * w;
  }

  double _scaleFor(int row, double offset) =>
      _round ? _layout(offset).scales[row] : 1.0;

  double _rowH(double scale, double capsule) =>
      _round ? capsule * _s * scale * _rowSpacing : capsule * _s;

  ({List<double> tops, List<double> heights, List<double> scales})?
  _layoutCache;

  // 恒定参考槽位：取列表中段（平移不变区）的压缩布局。
  // 滚动坐标系(max/offset)基于它构建，maxScrollExtent 永不随位置塌缩，
  // 杜绝接近底部时 Clamping 物理把 offset 瞬间钳到新 max（一滑就飞到底）；
  // 绘制仍走实时压缩布局，两者只差一个 Transform.translate，观感不变。
  List<double>? _refTops;
  List<double>? _refHeights;
  int _refCount = -1;
  double _refViewport = -1;
  double _refScale = -1;
  bool _refHeader = false;

  void _ensureRefLayout() {
    final n = widget.itemCount;
    if (n == 0) {
      _refTops = _refHeights = null;
      _refCount = 0;
      return;
    }
    if (_refTops != null &&
        _refCount == n &&
        _refViewport == _viewportH &&
        _refScale == _s &&
        _refHeader == _hasHeader) {
      return;
    }
    var nominal = _startPad + (_hasHeader ? _headerBand : 0.0);
    for (var i = 0; i < n; i++) {
      nominal += _rowH(1.0, _capsuleOf(i));
    }
    final mid = (nominal / 2 - _viewportH / 2).clamp(0.0, double.infinity);
    final lay = _layout(mid);
    _refTops = List<double>.of(lay.tops);
    _refHeights = List<double>.of(lay.heights);
    _refCount = n;
    _refViewport = _viewportH;
    _refScale = _s;
    _refHeader = _hasHeader;
  }

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
    // g(o) = liveCenter(row, o) - o - vh/2 的穿零点 = 该行绘制居中的偏移。
    // 中心方程是正反馈映射，不动点迭代会发散（末端尤甚），改用二分：
    // g(0) >= 0（首行最近）且 g(max) <= 0（末行 liveCenter 最大），必然有解。
    final maxO = _scroll.hasClients
        ? math.max(_scroll.position.maxScrollExtent, 0.0)
        : 0.0;
    var lo = 0.0;
    var hi = maxO;
    var mid = 0.0;
    for (var k = 0; k < 40; k++) {
      mid = (lo + hi) / 2;
      final lay = _layout(mid);
      final g = lay.tops[row] + lay.heights[row] / 2 - _viewportH / 2 - mid;
      if (g > 0) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return mid;
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
        final rowPad = widget.rowPadding ?? (round ? 4.0 : 6.0) * s;
        final rowW = math.max(0.0, constraints.maxWidth - 2 * rowPad);
        final endPad = ((viewportH - nomPitch * _rowSpacing) / 2).clamp(
          0.0,
          double.infinity,
        );
        final startPad = math.max(0.0, endPad - headerBand);
        _viewportH = viewportH;
        _startPad = startPad;
        final hasHeader = header != null;
        if (round) _ensureRefLayout();
        // 底部余量自洽解：maxScrollExtent 恰好 = 「最后一行绘制居中」的偏移。
        // 该方程是正反馈映射（锚点下移→末行变高→中心再下移），增益可 >1，
        // 不动点迭代（含阻尼）会发散、闭式解假设末行 scale=1 也不成立——
        // 改用二分法求 g(o)=liveCenter(o)-vh/2-o 的穿零点，只依赖符号，
        // 任何增益下都收敛。
        var tailPad = endPad;
        if (round && widget.itemCount > 0 && _refTops != null) {
          final n = widget.itemCount;
          var refSum = 0.0;
          var fullSum = 0.0;
          for (var i = 0; i < n; i++) {
            refSum += _refHeights![i];
            fullSum += _rowH(1.0, _capsuleOf(i));
          }
          final base = _startPad + (hasHeader ? headerBand : 0.0);
          var lo = 0.0;
          var hi = base + fullSum + viewportH;
          var root = 0.0;
          for (var k = 0; k < 50; k++) {
            final mid = (lo + hi) / 2;
            final lay = _layout(mid);
            final g =
                lay.tops[n - 1] + lay.heights[n - 1] / 2 - viewportH / 2 - mid;
            root = mid;
            if (g > 0) {
              lo = mid;
            } else {
              hi = mid;
            }
          }
          // 无下限兜底：endPad 兜底会在大行高页面把 max 抬得比 root 高，
          // 多出一段"还能往上滚"的行程；精确解可能小于 endPad，直接采用
          // （max=root 时末行恰好居中，行程即止）。
          tailPad =
              (root +
                      viewportH -
                      startPad -
                      (hasHeader ? headerBand : 0.0) -
                      refSum)
                  .clamp(0.0, double.infinity);
        }
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
                // 三项全关：自动包装层（RepaintBoundary/AutomaticKeepAlive/
                // IndexedSemantics）尺寸 = 压缩槽位，其默认 hitTest 的
                // size.contains 会把落在槽外的视觉触点拦在 _SlotBox 之前，
                // 导致滚动后点击错位。关掉后 _SlotBox 直接成为 Sliver 子项，
                // 命中绕过才能生效，实现"点哪儿触发哪儿"。
                addRepaintBoundaries: false,
                addAutomaticKeepAlives: false,
                addSemanticIndexes: false,
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
                      var dy = 0.0;
                      var slotH = rowH;
                      if (round) {
                        final lay = _layout(offset);
                        // 实时行中心对齐参考槽行中心：胶囊落点与旧版逐像素一致
                        final refTop = _refTops?[row];
                        if (refTop != null) {
                          final refH = _refHeights?[row] ?? rowH;
                          dy =
                              (lay.tops[row] + lay.heights[row] / 2) -
                              (refTop + refH / 2);
                        }
                        slotH = _refHeights?[row] ?? rowH;
                        final c = lay.tops[row] + lay.heights[row] / 2 - offset;
                        final edge = math.min(c, viewportH - c);
                        final t = (edge / _nomPitch).clamp(0.0, 1.0);
                        alpha = (0.55 + 0.45 * scale) * (0.35 + 0.65 * t);
                      }
                      // 视觉胶囊在槽内的 y 偏移：行中心对齐 + 槽高与视觉高差的一半
                      final dy2 = dy + (slotH - cap * s) / 2;
                      return _SlotBox(
                        slotHeight: slotH,
                        childHeight: cap * s,
                        child: Transform.translate(
                          offset: Offset(0, dy2),
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: rowPad),
                            child: Transform.scale(
                              scale: scale,
                              child: SizedBox(
                                width: rowW,
                                height: cap * s,
                                // 渐隐行也保持所见即所得：透明度只是视觉，不拦命中
                                child: Center(
                                  child: alpha >= 1
                                      ? child
                                      : Opacity(opacity: alpha, child: child),
                                ),
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
  }) : super(repaint: controller);

  final ScrollController controller;
  final double strokeWidth;

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
      pos.maxScrollExtent + pos.viewportDimension,
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
  const SteppedPill({super.key, this.onTap, this.child, this.color});

  final VoidCallback? onTap;
  final Widget? child;

  /// 胶囊底色，null 回落统一深灰实底（对齐系统设置暗色风格）
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Ink(
      decoration: BoxDecoration(
        color: color ?? kSteppedTileBg,
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
    this.backgroundColor,
  });

  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? titleColor;
  final Color? subtitleColor;

  /// 胶囊底色，null 回落统一深灰实底 + 白字（系统设置暗色风）
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final textReserve = leading != null
        ? 48.0 * s
        : (trailing != null ? 28.0 * s : 0.0);
    return SteppedPill(
      onTap: onTap,
      color: backgroundColor,
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

/// 阶梯列表槽位盒：布局高度取压缩槽高（决定列表总高/裁剪），
/// 命中测试不按槽自身尺寸拦截，而是跟随平移/缩放后的视觉子树 ——
/// 否则 Center/OverflowBox 等中间盒会按槽尺寸 `size.contains` 拦截，
/// 导致点在平移后的视觉胶囊上命中无效。
class _SlotBox extends SingleChildRenderObjectWidget {
  const _SlotBox({
    required this.slotHeight,
    required this.childHeight,
    super.child,
  });

  final double slotHeight;
  final double childHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSlotBox(slotHeight: slotHeight, childHeight: childHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderSlotBox renderObject) {
    renderObject
      ..slotHeight = slotHeight
      ..childHeight = childHeight;
  }
}

class _RenderSlotBox extends RenderProxyBox {
  _RenderSlotBox({required double slotHeight, required double childHeight})
    : _slotHeight = slotHeight,
      _childHeight = childHeight;

  double _slotHeight;
  double _childHeight;

  double get slotHeight => _slotHeight;
  set slotHeight(double value) {
    if (_slotHeight == value) return;
    _slotHeight = value;
    markNeedsLayout();
  }

  double get childHeight => _childHeight;
  set childHeight(double value) {
    if (_childHeight == value) return;
    _childHeight = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child;
    size = constraints.constrain(Size(constraints.maxWidth, _slotHeight));
    if (child != null) {
      // 子树按视觉高度布局，允许溢出槽高（Transform.translate 已对位）
      child.layout(
        BoxConstraints(
          minWidth: 0,
          maxWidth: constraints.maxWidth,
          minHeight: 0,
        ),
        parentUsesSize: true,
      );
    }
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // 跳过槽自身尺寸拦截：坐标原样传子树（translate/scale 内部会逆变换）
    return hitTestChildren(result, position: position);
  }
}
