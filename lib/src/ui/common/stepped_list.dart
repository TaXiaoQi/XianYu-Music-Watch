import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wearable_rotary/wearable_rotary.dart';
import '../../core/haptics.dart';
import '../../core/watch_fit.dart';

/// 圆屏阶梯列表（One UI 表盘同款观感，全部二级页与功能页统一适配）：
/// 行为圆角胶囊卡片，一档一个条目、一屏 3~4 行，三行外上下还各露一条
/// 边缘行（系统同款）——居中焦点行最大铺满中部，上下行缓衰减缩小
/// （1.0 → 相邻 0.79 → 隔行 ~0.75 → 缓降至 0.60 封底）；
/// 右缘有弧形滚动位置指示；表冠逐档滚动 + 档位振动；触控拖动/甩动
/// 由吸附物理直接落位最近档位（与表冠同一网格）。
///
/// 性能：滚动监听下沉到每个条目的 AnimatedBuilder；[itemBuilder] 产出
/// 的行实例在滚动帧间保持稳定（identical 短路），且包在 RepaintBoundary
/// 内——行内容位图被栅格缓存，滚动帧只更新外层缩放矩阵/图层透明度，
/// 文字不逐帧重栅格化；焦点行不包 Opacity，省一层 saveLayer。
class SteppedListView extends StatefulWidget {
  const SteppedListView({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.header,
    this.headerExtent = 56,
    this.rotaryGuard,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// 页面头（One UI 式）：作为滚动内容的最顶部条带，随列表一起滚动、
  /// 滚走后由圆屏裁掉——标题不再固定占位破坏圆弧适配。头部不参与
  /// 阶梯缩放。加载/错误等无列表状态需自行渲染头部。
  /// [headerExtent] 为头部条带高度（设计 dp，随屏径等比缩放）。
  final Widget? header;
  final double headerExtent;

  /// 表冠事件门禁：宿主在 PageView 里时，只有本页是当前页才允许响应
  /// （表冠是全局流，PageView 邻页/隐藏页收到会误触）。返回 true 表示
  /// 可以响应。不传 = 仅按路由栈顶判断（独占路由的宿主）。
  final bool Function()? rotaryGuard;

  @override
  State<SteppedListView> createState() => _SteppedListViewState();
}

class _SteppedListViewState extends State<SteppedListView> {
  // 一档 52*s ≈ 26% 屏径（系统设置截图量测：中心距 ~26%，行间空隙极小
  // ~2-3%——用户校准：旧 28.5% 行距下最远两行间隔太远，要系统紧凑排布）；
  // 焦点胶囊高 52*s（26%）恰好占满档位，相邻行 0.79 后高约 41*s（20.5%），
  // 行间空隙 = 52 − (52+41)/2 ≈ 5.5*s（2.8% 屏径），一屏 3~4 行（系统同款）；
  // 缓衰减曲线让三行外上下还各露一条边缘行。
  static const double _pitchBase = 52;

  /// 胶囊标准高（52*s）：SteppedTile 自然高度（40 前导圆 + 2×2 内边距），
  /// OverflowBox 用它以紧约束撑满档位。
  static const double _capsuleH = 52;

  final ScrollController _scroll = ScrollController();
  StreamSubscription<RotaryEvent>? _rotarySub;

  /// 表冠位移预算（带符号像素）：累积原始 magnitude，逐事件全额消费为
  /// 连续滚动位移——原生的「滑动」手感，而非一格跳一行。
  double _rotaryAcc = 0;

  /// 上次吸附落定的行：吸附后行变化才振一次（用户校准：转过去没滚到
  /// 下一行又转回来 = 行没变 = 不振；只有真正切到新行才反馈）。
  int _hapticRow = 0;

  /// 最近一次表冠事件时刻：ScrollEnd 吸附的门——表冠滚动中 jumpTo 与
  /// 吸附动画会往复拉锯（跨行线反复触发振动=持续震动的根因），滚动中
  /// 跳过吸附，停转后由 debounce 定时器兜底对齐。
  DateTime _lastRotaryAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 表冠停转吸附定时器：表冠 jumpTo 位移可停在任意位置，停转 150ms
  /// 后主动对齐最近档位（ScrollEnd 门控会漏掉最后一次 jumpTo，这里兜底）。
  Timer? _settleTimer;

  /// 右缘滚动指示显隐：滚动时出现，停止约 900ms 后淡出（系统行为）。
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
    // 表冠是全局流：仅本页处于路由栈顶时响应（弹窗打开或上层压着
    // 别的页时 isCurrent 为 false，不滚动不振动）。
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final guard = widget.rotaryGuard;
    if (guard != null && !guard()) return;
    final s = context.watchScale();
    final pitch = _pitchBase * s;
    final max = _scroll.position.maxScrollExtent;
    // 位移模式：一格棘轮（48-64px 预算）≈ 滚半行，跟手连续；华为兼容层
    // 的事件风暴自然摊成平滑小步。预算上限 1.5 行防尖峰风暴。
    final dir = event.direction == RotaryDirection.clockwise ? 1.0 : -1.0;
    final m = (event.magnitude ?? 48).clamp(0.0, 64.0).toDouble();
    if (dir * _rotaryAcc < 0) _rotaryAcc = 0; // 换向清账
    _rotaryAcc = (dir * m + _rotaryAcc).clamp(-1.5 * pitch, 1.5 * pitch);
    final delta = _rotaryAcc * 0.5;
    _rotaryAcc = 0;
    final target = (_scroll.offset + delta).clamp(0.0, max);
    if ((target - _scroll.offset).abs() < 0.5) return; // 已到边不空振
    _scroll.jumpTo(target); // 跟手位移；停转后由 debounce 吸附回网格
    _lastRotaryAt = DateTime.now();
    // 停转 150ms 后主动吸附：否则列表停在任意偏移上，正中行错档缩小
    // （「中间不放大」的根因）。
    _settleTimer?.cancel();
    final headerBand =
        widget.header == null ? 0.0 : widget.headerExtent * s;
    _settleTimer = Timer(
        const Duration(milliseconds: 150), () => _settleToGrid(pitch, headerBand));
  }

  /// 吸附到最近档位：保证有一行精确停在正中、以完整尺寸居中放大。
  /// [base] 为头部条带偏移：有 header 时行网格线整体下移（居中
  /// offset = row×pitch − headerBand），不修正会吸附偏一截（触控
  /// 「没有居中」的来源之一）。
  void _settleToGrid(double pitch, double base) {
    if (!mounted || !_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final grid =
        ((_scroll.offset + base) / pitch).round() * pitch - base;
    final target = grid.clamp(0.0, max);
    if ((target - _scroll.offset).abs() > 0.5) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
    }
    // 落定行变化才振：滚动途中不振（转过去又转回来行没变 = 无反馈），
    // 只有吸附后真正停在新的一行才给一次轻触觉确认。
    final row = (target / pitch).floor();
    if (row != _hapticRow) {
      _hapticRow = row;
      Haptics.tick();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final pitch = _pitchBase * s;
    // 屏形分支：圆屏 = 阶梯缩放 + 右缘弧形指示；方屏 = 全宽等大行 +
    // 直线滚动条（四角不裁，无弧度可让）。
    final round = context.isRoundWatch;
    final header = widget.header;
    final headerBand = header == null ? 0.0 : widget.headerExtent * s;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 首尾留白：底部补 (视口高-节距)/2，最后一行精确停在正中；
        // 顶部在同基础上扣除头部条带——第一行停正中、页面头恰好露在
        // 顶端（One UI 式：标题在最上，随列表滚走）。
        final viewportH = constraints.maxHeight;
        final endSpacer = ((viewportH - pitch) / 2).clamp(0.0, double.infinity);
        final startSpacer = math.max(0.0, endSpacer - headerBand);
        final hasHeader = header != null;
        return Stack(
          children: [
            NotificationListener<ScrollNotification>(
              onNotification: (n) {
                // 滚动进行中显示右缘指示，停止后延迟淡出。
                if (n is ScrollEndNotification) {
                  _scheduleThumbHide();
                } else {
                  _showThumb();
                }
                // One UI 式吸附：滚动结束后对齐最近档位（兜手势拖动/
                // 惯性）。表冠滚动中跳过——jumpTo 与吸附动画往复拉锯
                // 会反复跨行线触发振动（持续震动的根因）；停转后由
                // debounce 定时器兜底对齐。
                if (n is! ScrollEndNotification) return false;
                if (!_scroll.hasClients) return false;
                if (DateTime.now().difference(_lastRotaryAt) <
                    const Duration(milliseconds: 200)) {
                  return false;
                }
                final s2 = context.watchScale();
                _settleToGrid(_pitchBase * s2,
                    header == null ? 0.0 : widget.headerExtent * s2);
                return false;
              },
              child: ListView.builder(
                controller: _scroll,
                // 触控吸附物理：拖动松手/甩动由物理直接落位最近档位，
                // 与表冠 debounce 吸附共用同一网格（表冠走 jumpTo +
                // 定时器 animateTo，不经滚动物理，互不冲突）。
                physics: _SnapPhysics(pitch: pitch, base: headerBand),
                padding: EdgeInsets.fromLTRB(0, startSpacer, 0, endSpacer),
                itemCount: widget.itemCount + (hasHeader ? 1 : 0),
                itemBuilder: (context, i) {
                  if (hasHeader && i == 0) {
                    // 页面头条带：不参与阶梯缩放，随内容自然滚走。
                    return SizedBox(
                      height: headerBand,
                      child: Center(child: header),
                    );
                  }
                  final row = hasHeader ? i - 1 : i;
                  return SizedBox(
                    height: pitch,
                    child: AnimatedBuilder(
                      animation: _scroll,
                      // RepaintBoundary 放在缩放/透明变换内侧：行内容
                      // 位图在滚动帧间被栅格缓存，逐帧只更新外层变换
                      // 矩阵与图层透明度，文字不重栅格化（低端表 GPU
                      // 滚动流畅度的关键）。
                      child: RepaintBoundary(
                          child: widget.itemBuilder(context, row)),
                      builder: (context, child) {
                        final offset = _scroll.hasClients ? _scroll.offset : 0.0;
                        final anchor = offset + viewportH / 2;
                        final distance = ((row + 0.5) * pitch +
                                startSpacer +
                                headerBand -
                                anchor)
                            .abs() /
                            pitch;
                        // 圆屏：幂曲线（0.25）缓衰减——相邻 0.79（高 20.5%
                        // 屏径，系统量测 210/265），衰减随距离快速趋缓
                        // （隔行 ~0.75），三行之外的上下两条边缘行保持较大
                        // 且几乎全亮（系统同款）；0.60 封底防远处行缩没。
                        // 方屏：四角不裁，全部行等大（恒 1）。
                        final scale = round
                            ? (1.0 - 0.21 * math.pow(distance, 0.25))
                                .clamp(0.60, 1.0)
                            : 1.0;
                        // 透明度随尺寸线性浅衰减（0.55+0.45·scale）：远处
                        // 行保持可读（系统边缘行几乎全亮），焦点行恰好
                        // 为 1 省一层 saveLayer。方屏恒 1。
                        final alpha = round
                            ? (0.55 + 0.45 * scale).clamp(0.0, 1.0)
                            : 1.0;
                        return Center(
                          child: OverflowBox(
                            // 焦点胶囊 57*s 恰好占满档位 57*s；相邻行经
                            // Transform.scale 缩小后自然留出行间空隙。
                            minHeight: _capsuleH * s,
                            maxHeight: _capsuleH * s,
                            alignment: Alignment.center,
                            child: Padding(
                              // 圆屏左右各 6% 屏径：焦点行占 88% 屏宽
                              // （用户校准：比系统居中行再宽一点点），相邻
                              // 行随缩放进一步收窄；方屏只留 3% 呼吸边。
                              padding: EdgeInsets.symmetric(
                                  horizontal: (round ? 12.0 : 6.0) * s),
                              child: Transform.scale(
                                scale: scale,
                                // 焦点行不透明度为 1，直接省掉一层
                                // saveLayer。
                                child: alpha >= 1
                                    ? child
                                    : Opacity(
                                        opacity: alpha, child: child),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            // One UI 式右缘弧形滚动指示：短亮弧在右侧导轨上随位置移动，
            // 内容不溢出时不画；滚动停止约 900ms 后整体淡出（系统行为）。
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
}

/// 触控吸附物理：拖动松手/甩动结束后由滚动物理直接落位最近档位
/// （表冠走自身 debounce 吸附，不经此路径）。甩动按速度投射自然滑行
/// 距离并吸附到网格；静止松手就近落位；临界阻尼弹簧快速落位无回弹。
class _SnapPhysics extends ClampingScrollPhysics {
  const _SnapPhysics({required this.pitch, required this.base, super.parent});

  /// 档位节距与网格基准（有 header 时网格线整体下移 headerBand）。
  final double pitch;
  final double base;

  @override
  _SnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _SnapPhysics(pitch: pitch, base: base, parent: buildParent(ancestor));

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
        mass: 0.5,
        stiffness: 320.0,
        ratio: 1.0,
      );

  double _gridOf(double pixels) =>
      ((pixels + base) / pitch).roundToDouble() * pitch - base;

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    final double projected = velocity.abs() > toleranceFor(position).velocity
        ? position.pixels + velocity * 0.12 // 甩动投射：快甩多走几档
        : position.pixels;
    final double target = _gridOf(projected)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((target - position.pixels).abs() < 0.5) return null;
    return ScrollSpringSimulation(spring, position.pixels, target, velocity);
  }
}

/// 右缘滚动位置指示：圆屏 = 110° 导轨贴圆屏右缘（亮弧长度 = 视口占内容
/// 比，位置随滚动进度移动）；方屏 = 右缘竖直圆角短条贴直边。重绘由
/// ScrollController 监听驱动。
class _ScrollThumbPainter extends CustomPainter {
  _ScrollThumbPainter({
    required this.controller,
    required this.strokeWidth,
    required this.round,
  }) : super(repaint: controller);

  final ScrollController controller;
  final double strokeWidth;

  /// 圆屏画弧形导轨+亮弧；方屏画竖直圆角短条。
  final bool round;

  @override
  void paint(Canvas canvas, Size size) {
    if (controller.positions.isEmpty) return;
    final pos = controller.position;
    if (!pos.hasContentDimensions || pos.maxScrollExtent <= 0) return;
    final total = pos.maxScrollExtent + pos.viewportDimension;
    if (!round) {
      // 方屏：右缘竖直圆角短条（贴直边），长度 = 视口占内容比、位置随
      // 滚动进度在轨道（视口 42% 高）内移动；无暗轨（方屏系统样式裸条）。
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
        Paint()..color = Colors.white.withValues(alpha: 0.45),
      );
      return;
    }
    // 圆屏：导轨总长 55°（用户校准：110° 减半）；亮弧长度 = 视口占内容比、
    // 限制在导轨的 2%~2.5%；暗导轨全程铺垫、极淡（0.05，仅提供位置参照）。
    const span = 55 * math.pi / 180;
    final thumbFrac = (pos.viewportDimension / total).clamp(0.02, 0.025);
    final off = (pos.pixels / pos.maxScrollExtent).clamp(0.0, 1.0);
    final thumb = span * thumbFrac;
    final start = -span / 2 + off * (span - thumb);
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.shortestSide / 2 - strokeWidth * 1.6,
    );
    // 暗导轨：全程淡弧，亮弧在其上滑动（系统样式）。
    canvas.drawArc(
      rect,
      -span / 2,
      span,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.05),
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
        ..color = Colors.white.withValues(alpha: 0.45),
    );
  }

  @override
  bool shouldRepaint(_ScrollThumbPainter oldDelegate) => false;
}

/// 胶囊卡片底（One UI 表盘风）：半透白圆角胶囊。传 [onTap] 时内置
/// InkWell（水波贴胶囊裁剪；Ink 把胶囊底画在 Material 上、水波在其上，
/// 不会出现高亮被底色盖住的问题）；不传时仅作容器（行内自带交互件）。
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

/// 标准大号行（与 [SteppedListView] 配套）：胶囊卡 + 40*s 前导区 +
/// 居中主标题 17*s / 副标题 12*s + 可选尾部控件；行高由列表按档位
/// （57*s）以紧约束提供，焦点行铺满屏幕中部。
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
    return SteppedPill(
      onTap: onTap,
      child: Padding(
          // 横向 3：图标几乎贴胶囊左缘（系统样式，用户校准去缝隙）；
          // 纵向 2：档位内装下胶囊。中文行高由下方 height 锁定。
          padding: EdgeInsets.symmetric(horizontal: 3 * s, vertical: 2 * s),
          child: Row(
            children: [
              ?leading,
              if (leading != null) SizedBox(width: 12 * s),
              Expanded(
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
                        height: 1.25, // 锁行高：中文字体默认行高偏大易顶爆胶囊
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
                          color: subtitleColor ??
                              Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
        ),
    );
  }
}

/// 标准大号圆形封面/图标前导区（40*s），统一各列表行的视觉分量。
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
      // 40*s ≈ 0.70 焦点行高：系统焦点行图标圆上下各留 ~5% 屏径空白，
      // 不再接近撑满（旧 47*s 校准对应 53*s 行高已过时）。
      width: 40 * s,
      height: 40 * s,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: child,
    );
  }
}
