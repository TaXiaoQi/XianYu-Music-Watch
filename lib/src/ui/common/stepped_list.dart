import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:wearable_rotary/wearable_rotary.dart';
import '../../core/haptics.dart';
import '../../core/watch_fit.dart';

/// 功能条统一胶囊底色：近黑的深灰，贴近 WearOS 系统设置暗色菜单（对齐系统风格）
const Color kSteppedTileBg = Color(0xFF1E1E22);

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

  /// 可选：覆盖行距系数（槽高 × spacing，默认 1.0），加大行间隙用
  final double? rowSpacing;

  /// 可选：覆盖行左右留白（逻辑值，默认圆屏 8 / 方屏 6），加宽梯形整体用
  final double? rowPadding;

  @override
  State<SteppedListView> createState() => _SteppedListViewState();
}

class _SteppedListViewState extends State<SteppedListView> {
  static const double _pitchBase = 60;

  static const double _capsuleH = 56;

  /// 行距系数：压排布局中行高 = 胶囊×s×scale×此系数，间距绑定相邻
  /// 条的实际尺寸（缩得越小占位越窄），WearOS 观感的间隙来源
  double get _rowSpacing => widget.rowSpacing ?? 1.06;

  static const double _minScale = 0.26;

  /// 相邻 0.72、隔行 0.47，三行外 0.37、四行外 0.32 渐进压平到 0.26 谷底
  static const double _decayTau = 1.28;
  static const double _decayPow = 2.1;

  /// 三行开外压向的谷底：d=4 起压满。抬到 0.42 保证边缘行保持
  /// 可读的半尺寸直到滑出屏幕（系统列表观感），不会缩成碎条消失
  static const double _farScale = 0.42;

  double _viewportH = 0;
  double _startPad = 0;

  /// 统一槽位几何（WearOS ScalingLazyColumn 模式）：槽高不随缩放变化，
  /// 缩放/透明度只作用在槽内视觉上。滚动范围、构建范围、绘制位置
  /// 三者天然一致，列表两端不存在布局漂移，行永远不会被错误裁掉。
  List<double> _slotTops = const [];
  List<double> _slotHeights = const [];

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

  // ── 槽位几何 ─────────────────────────────────────────────

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

  /// 槽高：定距，不随缩放变化（滚动/构建/吸附坐标系）
  double _slotOf(int row) => _capsuleOf(row) * _s;

  /// 锚定焦点行的实时压缩布局（旧版观感的绘制层）：行高跟随缩放、
  /// 间距绑定相邻条尺寸。从分数锚点行向两侧外推，吸附后焦点行严格
  /// 居中；仅用于绘制位移/缩放/亮度，滚动/构建/吸附仍在定距槽坐标系，
  /// 列表两端不存在参考布局漂移，行不会因裁剪消失。
  ({
    List<double> centers,
    List<double> scales,
    List<double> heights,
  })? _paintCache;
  double _paintCacheOffset = double.negativeInfinity;
  int _paintCacheCount = -1;
  double _paintCacheScale = -1;
  double _paintCacheVh = -1;
  double _paintCachePad = -1;

  /// 视口中心对应的分数档位：按定距槽位表插值。行高可变时与线性档距
  /// 不一致，必须以槽位表为准——吸附偏移由槽位表导出，此处同源插值
  /// 才能保证吸附点 a 恰为整数、焦点行像素级居中、列表尾部不漂移。
  double _anchorRank(double offset) {
    final n = widget.itemCount;
    if (n == 0 || _slotTops.length != n) return 0;
    final c = offset + _viewportH / 2;
    var i = 0;
    while (i < n - 1 && _slotTops[i + 1] + _slotHeights[i + 1] / 2 <= c) {
      i++;
    }
    if (i >= n - 1) return (n - 1).toDouble();
    final c0 = _slotTops[i] + _slotHeights[i] / 2;
    final c1 = _slotTops[i + 1] + _slotHeights[i + 1] / 2;
    final f = ((c - c0) / (c1 - c0)).clamp(0.0, 1.0);
    return i + f;
  }

  ({List<double> centers, List<double> scales, List<double> heights})
  _paintLayout(double offset) {
    if (_paintCacheOffset == offset &&
        _paintCacheCount == widget.itemCount &&
        _paintCacheScale == _s &&
        _paintCacheVh == _viewportH &&
        _paintCachePad == _startPad &&
        _paintCache != null) {
      return _paintCache!;
    }
    final n = widget.itemCount;
    final centers = List<double>.filled(n, 0);
    final scales = List<double>.filled(n, 1.0);
    final heights = List<double>.filled(n, 0.0);
    if (n > 0 && _round && _viewportH > 0) {
      final vh = _viewportH;
      final pitch0 = _nomPitch;
      // 分数锚点 a ∈ [0, n-1]：从槽位表插值，吸附后 a 为整数，
      // 焦点行精确居中
      final a = _anchorRank(offset);
      final i0 = a.floor().clamp(0, n - 1);
      final f = a - i0;
      final lo = math.max(0, i0 - 8);
      final hi = math.min(n - 1, i0 + 9);
      final m = hi - lo + 1;
      final pos = List<double>.generate(
        m,
        (k) => vh / 2 + (lo + k - a) * pitch0,
      );
      final h = List<double>.filled(m, 0.0);
      final sc = List<double>.filled(m, 1.0);
      for (var it = 0; it < 5; it++) {
        for (var k = 0; k < m; k++) {
          sc[k] = _scaleFromDist((pos[k] - vh / 2).abs() / pitch0);
          h[k] = _capsuleOf(lo + k) * _s * sc[k] * _rowSpacing;
        }
        final h0 = h[i0 - lo];
        final h1 = h[math.min(i0 + 1, n - 1) - lo];
        final boundary = vh / 2 + (0.5 - f) * (h0 + h1) / 2;
        // 边界到相邻行中心 = 中心距的一半（(h0+h1)/4），吸附点 f=0 时
        // 焦点行精确落在视口中心
        var down = boundary - (h0 + h1) / 4;
        for (var j = i0; j >= lo; j--) {
          if (j < i0) down -= (h[j - lo] + h[j - lo + 1]) / 2;
          pos[j - lo] = down;
        }
        var up = boundary + (h0 + h1) / 4;
        for (var j = i0 + 1; j <= hi; j++) {
          if (j > i0 + 1) up += (h[j - lo] + h[j - lo - 1]) / 2;
          pos[j - lo] = up;
        }
      }
      for (var k = 0; k < m; k++) {
        final row = lo + k;
        scales[row] = _scaleFromDist((pos[k] - vh / 2).abs() / pitch0);
        heights[row] = _capsuleOf(row) * _s * scales[row] * _rowSpacing;
        centers[row] = pos[k];
      }
    }
    _paintCache = (centers: centers, scales: scales, heights: heights);
    _paintCacheOffset = offset;
    _paintCacheCount = n;
    _paintCacheScale = _s;
    _paintCacheVh = _viewportH;
    _paintCachePad = _startPad;
    return _paintCache!;
  }

  /// 每次构建重算槽位表（O(n)，n 为可见条目量级，可忽略）
  void _computeSlots() {
    final n = widget.itemCount;
    final tops = List<double>.filled(n, 0);
    final hs = List<double>.filled(n, 0);
    var acc = _startPad + _headerBand;
    for (var i = 0; i < n; i++) {
      tops[i] = acc;
      hs[i] = _slotOf(i);
      acc += hs[i];
    }
    _slotTops = tops;
    _slotHeights = hs;
  }

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

  int _focusRow(double offset) {
    final anchor = offset + _viewportH / 2;
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < widget.itemCount; i++) {
      final c = _slotTops[i] + _slotHeights[i] / 2;
      final dd = (c - anchor).abs();
      if (dd < bestD) {
        bestD = dd;
        best = i;
      }
    }
    return best;
  }

  double _snapFor(int row) {
    if (row >= _slotTops.length) return 0;
    final maxO = _scroll.hasClients
        ? math.max(_scroll.position.maxScrollExtent, 0.0)
        : 0.0;
    final target = _slotTops[row] + _slotHeights[row] / 2 - _viewportH / 2;
    return target.clamp(0.0, maxO).toDouble();
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportH = constraints.maxHeight;
        final rowPad = widget.rowPadding ?? (round ? 4.0 : 6.0) * s;
        final rowW = math.max(0.0, constraints.maxWidth - 2 * rowPad);
        // 端部对称留白：首行 o=0 恰好居中、末行 o=max 恰好居中，
        // 吸附目标全部落在 [0, max] 内，无需任何求解。
        final endPad = ((viewportH - _slotOf(0)) / 2).clamp(
          0.0,
          double.infinity,
        );
        final startPad = math.max(0.0, endPad - headerBand);
        final tailPad = widget.itemCount > 0
            ? ((viewportH - _slotOf(widget.itemCount - 1)) / 2).clamp(
                0.0,
                double.infinity,
              )
            : endPad;
        _viewportH = viewportH;
        _startPad = startPad;
        _computeSlots();
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
                // 列表视口被 SafeArea 内缩（圆屏上下各 ~60px），默认框内
                // 裁剪会让边缘行在物理屏幕边缘之前 ~60px 处被裁掉、提前
                // 消失。关闭裁剪让行画满到物理屏幕边缘（系统列表观感），
                // 圆屏物理切角即最终边界。
                clipBehavior: Clip.none,
                // 压排使远处行的绘制间距远小于槽位间距（绘制在视口内的
                // 行，其槽位可能在数档之外），构建缓存必须覆盖这一偏差：
                // 2 倍视口保证「画得下的行必已构建」，边缘行不会凭空消失
                scrollCacheExtent: ScrollCacheExtent.pixels(viewportH * 2),
                // 三项全关：自动包装层（RepaintBoundary/AutomaticKeepAlive/
                // IndexedSemantics）尺寸 = 槽位，其默认 hitTest 的
                // size.contains 会把落在槽外的视觉触点拦在 _SlotBox 之前，
                // 导致滚动后点击错位。关掉后 _SlotBox 直接成为 Sliver 子项，
                // 命中绕过才能生效，实现"点哪儿触发哪儿"。
                addRepaintBoundaries: false,
                addAutomaticKeepAlives: false,
                addSemanticIndexes: false,
                itemCount: widget.itemCount + (header != null ? 1 : 0),
                itemBuilder: (context, i) {
                  if (header != null && i == 0) {
                    return AnimatedBuilder(
                      animation: _scroll,
                      child: SizedBox(
                        height: headerBand,
                        child: Center(child: header),
                      ),
                      builder: (context, child) {
                        // 表头跟随首行压排位置：贴在首行上方滚动
                        var dy = 0.0;
                        if (round && widget.itemCount > 0 && _scroll.hasClients) {
                          final lay = _paintLayout(_scroll.offset);
                          final headerTopLive =
                              lay.centers[0] -
                              lay.heights[0] / 2 -
                              4 * s -
                              headerBand;
                          dy = headerTopLive - (startPad - _scroll.offset);
                        }
                        return Transform.translate(
                          offset: Offset(0, dy),
                          child: child,
                        );
                      },
                    );
                  }
                  final row = header != null ? i - 1 : i;
                  return AnimatedBuilder(
                    animation: _scroll,
                    child: RepaintBoundary(
                      child: widget.itemBuilder(context, row),
                    ),
                    builder: (context, child) {
                      final offset = _scroll.hasClients ? _scroll.offset : 0.0;
                      final slotH = _slotOf(row);
                      final cap = _capsuleOf(row);
                      double alpha = 1.0;
                      double scale = 1.0;
                      var dy = 0.0;
                      if (round) {
                        // 旧版压排观感：行高跟随缩放、间距绑定相邻条尺寸。
                        // 绘制中心来自锚定焦点行的实时压缩布局；位移 =
                        // 压排中心 − 定距槽中心。缩放/亮度跟随压排位置，
                        // 无级连续。
                        final lay = _paintLayout(offset);
                        scale = lay.scales[row];
                        final painted = lay.centers[row];
                        final slotCenter =
                            _slotTops[row] + slotH / 2 - offset;
                        dy = painted - slotCenter;
                        final kx =
                            ((scale - _farScale) / (1.0 - _farScale)).clamp(
                              0.0,
                              1.0,
                            );
                        alpha = 0.45 + 0.55 * kx;
                      }
                      // 视觉在槽内居中缩放 + 压排布局位移；透明度只是视觉，不拦命中
                      return _SlotBox(
                        slotHeight: slotH,
                        childHeight: cap * s,
                        child: Transform.translate(
                          offset: Offset(0, dy),
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: rowPad),
                            child: Transform.scale(
                              scale: scale,
                              child: SizedBox(
                                width: rowW,
                                height: cap * s,
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
    final shape = BorderRadius.circular(999);
    // 胶囊底色必须画在行子树内（DecoratedBox），随整行的 Opacity/Transform
    // 一起淡出缩放。Ink 的装饰挂在祖先 Material 上绘制，绕过行的 Opacity
    // saveLayer —— 远行会变成「全浓度纯条 + 内容已淡出」的裂图。
    final box = DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? kSteppedTileBg,
        borderRadius: shape,
      ),
      child: child,
    );
    if (onTap == null) return box;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(onTap: onTap, borderRadius: shape, child: box),
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
