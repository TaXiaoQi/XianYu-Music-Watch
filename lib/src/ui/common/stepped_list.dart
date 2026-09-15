import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wearable_rotary/wearable_rotary.dart';
import '../../core/haptics.dart';
import '../../core/watch_fit.dart';

/// 圆屏阶梯列表（One UI 表盘同款观感，全部二级页与功能页统一适配）：
/// 行为圆角胶囊卡片，一档一个条目、一屏只现约三行——居中焦点行最大
/// 铺满中部，上下行逐级缩小变窄变淡（1.0 → 相邻 0.775 → 0.55 封底）；
/// 右缘有弧形滚动位置指示；表冠逐档滚动 + 档位振动。
///
/// 性能：滚动监听下沉到每个条目的 AnimatedBuilder；[itemBuilder] 产出
/// 的行实例在滚动帧间保持稳定（identical 短路），滚动帧只重建缩放/
/// 透明包装；焦点行不包 Opacity，省一层 saveLayer。
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
  // 一档 46*s ≈ 23% 屏径（对齐系统量测修正：焦点行中心距 23.1%）；焦点
  // 胶囊高 51*s（25.5%）经 OverflowBox 溢出档位居中放大，相邻行 0.62 后
  // 高约 31.6*s——与焦点行间隙约 2.4% 屏径（系统 2.5%），紧凑但无重叠。
  static const double _pitchBase = 46;

  /// 胶囊标准高（51*s）：SteppedTile 自然高度（47 前导圆 + 2×2 内边距），
  /// OverflowBox 用它突破档位约束。
  static const double _capsuleH = 51;

  final ScrollController _scroll = ScrollController();
  StreamSubscription<RotaryEvent>? _rotarySub;

  /// 表冠位移预算（带符号像素）：累积原始 magnitude，逐事件全额消费为
  /// 连续滚动位移——原生的「滑动」手感，而非一格跳一行。
  double _rotaryAcc = 0;

  /// 上次振动所在行线：跨行才振一次，把振动节奏绑在滚过距离上（原生
  /// CLOCK_TICK 式稀疏反馈），而非每个棘轮都振。
  int _hapticRow = 0;

  /// 上次振动时刻：振动限速（华为事件风暴下跨行极频，无限速会变成
  /// 持续连振），最快约 8Hz。
  DateTime _lastHapticAt = DateTime.fromMillisecondsSinceEpoch(0);

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
    _settleTimer = Timer(
        const Duration(milliseconds: 150), () => _settleToGrid(pitch));
    // 跨过行线才振一次（按滚过距离稀疏反馈，原生节奏）+ 限速防连振；
    // 限速跳过时同样推进行线基准，快转多行只振一次。
    final row = (target / pitch).floor();
    if (row != _hapticRow) {
      _hapticRow = row;
      final now = DateTime.now();
      if (now.difference(_lastHapticAt) >=
          const Duration(milliseconds: 120)) {
        _lastHapticAt = now;
        Haptics.tick();
      }
    }
  }

  /// 吸附到最近档位：保证有一行精确停在正中、以完整尺寸居中放大。
  void _settleToGrid(double pitch) {
    if (!mounted || !_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final grid = (_scroll.offset / pitch).round() * pitch;
    final target = grid.clamp(0.0, max);
    if ((target - _scroll.offset).abs() > 0.5) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
      );
    }
    _hapticRow = (target / pitch).floor();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final pitch = _pitchBase * s;
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
                final pitch = _pitchBase * context.watchScale();
                _settleToGrid(pitch);
                return false;
              },
              child: ListView.builder(
                controller: _scroll,
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
                      child: widget.itemBuilder(context, row),
                      builder: (context, child) {
                        final offset = _scroll.hasClients ? _scroll.offset : 0.0;
                        final anchor = offset + viewportH / 2;
                        final distance = ((row + 0.5) * pitch +
                                startSpacer +
                                headerBand -
                                anchor)
                            .abs() /
                            pitch;
                        // 幂曲线（0.6）：相邻 0.62（≈系统 15.7%/25.4% 的
                        // 行高比）、隔行 0.42、更远 0.30 封底——焦点行
                        // 明显放大、相邻骤缩，系统的层级感。
                        final scale = (1.0 -
                                0.38 * math.pow(distance, 0.6))
                            .clamp(0.30, 1.0);
                        // 透明度随阶梯继续下滑，边缘「小条子」几乎隐入
                        // 圆屏轮廓。
                        final alpha = scale >= 0.55
                            ? 0.45 + 0.55 * ((scale - 0.55) / 0.45)
                            : (0.45 - (0.55 - scale) * 0.75)
                                .clamp(0.22, 0.45);
                        return Center(
                          child: OverflowBox(
                            // 焦点胶囊 51*s 高于档位 36*s：溢出档位居中
                            // 放大（系统焦点行 25% 屏径 > 档距 18% 的做法）。
                            minHeight: _capsuleH * s,
                            maxHeight: _capsuleH * s,
                            alignment: Alignment.center,
                            child: Padding(
                              // 左右各 2.5% 屏径：焦点行占 95% 屏宽。
                              padding: EdgeInsets.symmetric(
                                  horizontal: 5.0 * s),
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

/// 右缘弧形滚动指示：110° 导轨贴圆屏右缘，亮弧长度 = 视口占内容比，
/// 位置随滚动进度移动。重绘由 ScrollController 监听驱动。
class _ScrollThumbPainter extends CustomPainter {
  _ScrollThumbPainter({required this.controller, required this.strokeWidth})
      : super(repaint: controller);

  final ScrollController controller;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (controller.positions.isEmpty) return;
    final pos = controller.position;
    if (!pos.hasContentDimensions || pos.maxScrollExtent <= 0) return;
    const span = 110 * math.pi / 180;
    final total = pos.maxScrollExtent + pos.viewportDimension;
    // One UI 式限短：亮弧长度限制在导轨的 2.5%~4%（用户校准：再短一半）；
    // 暗导轨全程铺垫。
    final thumbFrac = (pos.viewportDimension / total).clamp(0.025, 0.04);
    final off = (pos.pixels / pos.maxScrollExtent).clamp(0.0, 1.0);
    final thumb = span * thumbFrac;
    final start = -span / 2 + off * (span - thumb);
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.shortestSide / 2 - strokeWidth * 1.6,
    );
    // 暗导轨：全程 110° 淡弧，亮弧在其上滑动（系统样式）。
    canvas.drawArc(
      rect,
      -span / 2,
      span,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.10),
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

/// 标准大号行（与 [SteppedListView] 配套）：胶囊卡 + 44*s 前导区 +
/// 居中主标题 17*s / 副标题 12*s + 可选尾部控件；行高由列表按档位
/// （64*s）以紧约束提供，焦点行铺满屏幕中部。
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
          // 纵向 2：档位 58*s 内要装下胶囊（行 Padding 3*s×2 → 胶囊上限
          // 52*s）。47*s 前导圆 + 2*s×2 内边距 = 51*s，留 1*s 余量；
          // 中文行高由下方 height 锁定，防止顶爆胶囊出溢出警告条。
          padding: EdgeInsets.symmetric(horizontal: 14 * s, vertical: 2 * s),
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

/// 标准大号圆形封面/图标前导区（44*s），统一各列表行的视觉分量。
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
      // 47*s：接近撑满胶囊（52*s 可用高），对齐系统焦点行图标占比。
      width: 47 * s,
      height: 47 * s,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: child,
    );
  }
}
