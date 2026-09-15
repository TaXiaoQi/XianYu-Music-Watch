import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wearable_rotary/wearable_rotary.dart';

import '../../core/watch_fit.dart';
import 'rotary_input.dart';

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
  static const double _pitchBase = 58; // 一档 = 一个条目（对齐 One UI 行距/屏径 ≈29%）

  final ScrollController _scroll = ScrollController();
  StreamSubscription<RotaryEvent>? _rotarySub;
  final RotaryQuantizer _rotary = RotaryQuantizer();

  @override
  void initState() {
    super.initState();
    _rotarySub = rotaryEvents.listen(_onRotary);
  }

  @override
  void dispose() {
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
    // 量化：像素预算累积 + 限速，轻刮 1 格、快转加速、单次最多 2 格。
    final steps = _rotary.add(event);
    if (steps == 0) return;
    final s = context.watchScale();
    final pitch = _pitchBase * s;
    final max = _scroll.position.maxScrollExtent;
    // 以最近档位为基准步进：表冠落点永远在网格上，与松手吸附一致。
    final baseRow = (_scroll.offset / pitch).round() + steps;
    final target = (baseRow * pitch).clamp(0.0, max);
    if ((target - _scroll.offset).abs() < 0.5) return; // 已到边不空振
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
    );
    HapticFeedback.selectionClick(); // 表冠档位振动反馈
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
            NotificationListener<ScrollEndNotification>(
              onNotification: (n) {
                // One UI 式吸附：滚动结束后对齐最近档位，保证有一行精确
                // 停在正中（表冠步进本就落网格，这里兜住手势拖动/惯性）。
                if (!_scroll.hasClients) return false;
                final max = _scroll.position.maxScrollExtent;
                if (max <= 0) return false;
                final grid = (_scroll.offset / pitch).round() * pitch;
                final target = grid.clamp(0.0, max);
                if ((target - _scroll.offset).abs() > 0.5) {
                  _scroll.animateTo(
                    target,
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                  );
                }
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
                        final scale = (1.0 - distance * 0.225)
                            .clamp(0.30, 1.0);
                        // 透明度随阶梯继续下滑（0.55 以下再衰减），边缘
                        // 「小条子」几乎隐入圆屏轮廓。
                        final alpha = scale >= 0.55
                            ? 0.45 + 0.55 * ((scale - 0.55) / 0.45)
                            : (0.45 - (0.55 - scale) * 0.75)
                                .clamp(0.22, 0.45);
                        // 内收跟随圆屏弧度（先陡后缓的凹曲线，对齐原版：
                        // 相邻行 ≈61% 屏宽、边缘条 ≈34%），线性小步长会让
                        // 第二行往外全偏宽。
                        final inset = (10.5 + 27.7 * math.pow(distance, 0.7))
                            .clamp(0.0, 78.0) *
                            s;
                        return Padding(
                          // 上下 3：胶囊几乎贴合（原版 One UI 行距），
                          // 阶梯缩放自带额外视觉间隙。
                          padding: EdgeInsets.fromLTRB(
                              inset, 3 * s, inset, 3 * s),
                          child: Transform.scale(
                            scale: scale,
                            // 焦点行不透明度为 1，直接省掉一层 saveLayer。
                            child: alpha >= 1
                                ? child
                                : Opacity(opacity: alpha, child: child),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            // One UI 式右缘弧形滚动指示：短亮弧在右侧导轨上随位置移动，
            // 内容不溢出时不画。
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _ScrollThumbPainter(
                    controller: _scroll,
                    strokeWidth: 3.5 * s,
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
    // One UI 式限短：亮弧长度限制在导轨的 10%~30%（约 11°~33°），
    // 内容略长于视口时不再出现几乎绕圈的长弧。
    final thumbFrac = (pos.viewportDimension / total).clamp(0.10, 0.30);
    final off = (pos.pixels / pos.maxScrollExtent).clamp(0.0, 1.0);
    final thumb = span * thumbFrac;
    final start = -span / 2 + off * (span - thumb);
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.shortestSide / 2 - strokeWidth * 1.6,
    );
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.28);
    canvas.drawArc(rect, start, thumb, false, p);
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
          padding: EdgeInsets.symmetric(horizontal: 14 * s, vertical: 6 * s),
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
      width: 44 * s,
      height: 44 * s,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: child,
    );
  }
}
