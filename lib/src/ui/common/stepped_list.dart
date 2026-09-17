import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:wearable_rotary/wearable_rotary.dart';
import '../../core/haptics.dart';
import '../../core/watch_fit.dart';

/// 统一页头（表头）：标题居中，左/右侧等宽占位保证几何居中（系统设置同款）。
/// 配合 [SteppedListView.header] 使用（做进滚动内容最顶部，随列表滚走，
/// 圆弧适配完整）。宿主若已有左上角悬浮返回键，则 [showBack] 传 false，
/// 避免双返回入口。
class PageTitleHeader extends StatelessWidget {
  const PageTitleHeader(this.title,
      {super.key, this.showBack = false, this.trailing});

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
          SizedBox(
            width: 48 * s,
            child: showBack ? const BackButton() : null,
          ),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15 * s,
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

/// 圆屏阶梯列表（One UI 表盘同款观感，全部二级页与功能页统一适配）：
/// 行为圆角胶囊卡片，一档一个条目——居中焦点行最大铺满中部，上下行
/// 陡衰减缩小（1.0 → 相邻 ~0.78 → 隔行 ~0.62 → 快速降至 0.60 封底），
/// 复刻 WearOS 原版梯形列表。
///
/// 间距跟随条大小等比缩放（用户澄清，WearOS 原版观感）：远处行不仅条
/// 本身缩小，其上下占用的**行高槽位也同步缩小**（行高 = 胶囊高×scale×
/// 1.1，缝隙随条等比缩放）——梯形列表若用固定大小间距，远处条已压缩
/// 到最小、间距仍是标准大小，会出现「远处行距拉得很开」的大空隙 bug；
/// 等比缝让整体紧凑堆叠成密度均匀的阶梯。焦点最大槽占满屏中部，相邻
/// 0.78 槽，远处 ~0.6；右缘有弧形滚动位置指示；表冠逐档滚动 + 档位
/// 振动；触控拖动/甩动由吸附物理直接落位最近档位。
///
/// 距离/缩放用「名义均匀档距」（_pitchBase）计算（与偏移量一一对应、无
/// 依赖环），行高/吸附则按实际测量槽位累加计算——两者在图层面解耦，保证
/// 表冠吸附、甩动吸附、振动都用同一套「最近档位」判定。
///
/// 性能：滚动监听下沉到每个条目的 AnimatedBuilder；[itemBuilder] 产出的
/// 行实例在滚动帧间保持稳定（identical 短路），且包在 RepaintBoundary
/// 内——行内容位图被栅格缓存，滚动帧只更新外层缩放矩阵/图层透明度/
/// 行高，文字不逐帧重栅格化；焦点行不包 Opacity，省一层 saveLayer。
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
  // 名义均匀档距 56*s：仅用于「距离→缩放」的归一化（焦点 1.0 →
  // 相邻 ~0.78 → 隔行 ~0.62 → 快速降至 0.60 封底）与行高基准。注意它
  // 只是「虚拟档距」，真实行高在 _rowH 里额外乘 _rowSpacing 留呼吸缝。
  static const double _pitchBase = 56;

  /// 胶囊标准高（56*s）：焦点行满高基准，其余行高 = 该值 ×scale×1.1。
  static const double _capsuleH = 56;

  /// 行高相对卡片高的间距系数：行高 = 卡片高×1.1，卡片上下各留 5%
  /// 呼吸缝——缝隙必须随卡片大小等比缩放（用户澄清：梯形列表若用
  /// 固定缝，远处条已缩到最小、间距仍是标准大小 → 远处行距拉得很开
  /// 的大空隙 bug；WearOS 原版即等比缝，整体密度均匀）。
  static const double _rowSpacing = 1.1;

  /// scale 封底（远处行最小倍率）。
  static const double _minScale = 0.55;

  /// 陡降幂（>1）与半高半径：Lorentzian 幂曲线 scale = min + (1-min)/
  /// (1+(d/τ)^p)——近场高台、远场陡降，复刻 WearOS 原版梯形列表：焦点
  /// 1.0 → 相邻 ~0.78 → 隔行 ~0.62 → 再外 ~0.58 → 缓趋 [_minScale]。
  /// 纯指数衰减无法两头兼顾：τ 调大近场变大时远场跟着一起放大，观感
  /// 变成整页放大而非中间突出（用户反馈校准）。
  static const double _decayTau = 1.0;
  static const double _decayPow = 2.5;

  /// build/LayoutBuilder 里确定的视口与顶部留白（供几何辅助方法读取）。
  double _viewportH = 0;
  double _startPad = 0;

  /// 收敛布局缓存：同一滚动帧内各行共用整列布局（避免每行重算 O(n)）。
  double _layoutCacheOffset = double.negativeInfinity;
  ({List<double> tops, List<double> heights, List<double> scales})?
      _layoutCache;

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

  /// 表冠停转吸附定时器：表冠 jumpTo 位移可停在任意位置，停转 60ms
  /// 后主动对齐最近档位（ScrollEnd 门控会漏掉最后一次 jumpTo，这里兜底；
  /// 60ms 短延迟 = 焦点行偏离正中的窗口极小，观感始终「锁定在中线」）。
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
    final pitch = _nomPitch;
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
    // 停转 60ms 后主动吸附：否则列表停在任意偏移上，正中行错档缩小
    // （「中间不放大」的根因）；短延迟让焦点行几乎总锁在中线。
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 60), _settleToGrid);
  }

  // ── 变高行几何 ─────────────────────────────────────────────
  // 距离/缩放用「名义均匀档距」计算，行高/吸附用「实测槽位」累加计算：
  // 缩放曲线与界面偏移一一对应（无依赖环），行高则由条大小等比收缩。

  /// 是否走圆表阶梯布局。默认与全局探测一致；若通道把圆表误报成方表
  /// （ohos Flutter 对未注册通道 resolve false），用本帧 MediaQuery 的逻辑
  /// 尺寸比例兜底——圆表逻辑分辨率必为 1:1（Watch 3 466×466），方表为长条
  /// （Watch Fit 456×280），比值差 8% 内判圆表。MediaQuery 构建时必然可用，
  /// 比 platformDispatcher 兜底更强（鸿蒙虚拟视口下 physicalSize 可能取不到）。
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

  /// 距离 → 缩放（方屏恒 1）：Lorentzian 幂曲线，近场高台（中间三条
  /// 突出）、远场陡降封底（梯形层级清晰，不会整页一起放大）。
  double _scaleFromDist(double d) =>
      (_minScale +
              (1 - _minScale) /
                  (1 + math.pow(d / _decayTau, _decayPow).toDouble()))
          .clamp(_minScale, 1.0)
          .toDouble();

  /// 单行缩放：读收敛布局（该行实测中心距屏中之距），方屏恒 1。
  double _scaleFor(int row, double offset) =>
      _round ? _layout(offset).scales[row] : 1.0;

  /// 行高 = 名义档距 × 缩放 × 间距系数（焦点槽 = 满档 ×1.1 → 首行/焦点行
  /// 精确居中；缝隙随卡片大小等比缩放——固定缝会让远处行距过大，用户
  /// 澄清校准）。方屏全宽等大恒满档。
  double _rowH(double scale) =>
      _round ? _nomPitch * scale * _rowSpacing : _nomPitch;

  /// 收敛布局：迭代让「缩放 ↔ 槽位」自洽（行高依赖缩放、缩放依赖位置，
  /// 数轮收敛），得每行实测 top/height/scale。同一滚动帧共用一份缓存，
  /// 只算一遍整列（O(n)）。
  ({List<double> tops, List<double> heights, List<double> scales}) _layout(
      double offset) {
    if (_layoutCacheOffset == offset && _layoutCache != null) {
      return _layoutCache!;
    }
    final n = widget.itemCount;
    var scales = List<double>.filled(n, 1.0);
    var tops = List<double>.filled(n, 0.0);
    var heights = List<double>.filled(n, 0.0);
    for (var it = 0; it < 4; it++) {
      var acc = _startPad + _headerBand;
      for (var i = 0; i < n; i++) {
        tops[i] = acc;
        heights[i] = _rowH(scales[i]);
        acc += heights[i];
      }
      if (it == 3) break;
      for (var i = 0; i < n; i++) {
        final center = tops[i] + heights[i] / 2;
        final d = ((center - (offset + _viewportH / 2)).abs()) / _nomPitch;
        scales[i] = _scaleFromDist(d);
      }
    }
    _layoutCache = (tops: tops, heights: heights, scales: scales);
    _layoutCacheOffset = offset;
    return _layoutCache!;
  }

  /// 最近档位：以「实测槽位中心」距视口中线最近者为准（与缩放共用同一套
  /// 收敛几何，保证吸附/振动/表冠都落位到同一条）。
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

  /// 让焦点行 [row] 精确停在中线的滚动偏移（以实际行高为初值，迭代 3 次
  /// 收敛到实测槽位中心；行高是偏移的平滑函数，数轮即收敛）。
  double _snapFor(int row) {
    var offset = (row + 0.5) * _nomPitch * _rowSpacing +
        _startPad +
        _headerBand -
        _viewportH / 2;
    for (var i = 0; i < 3; i++) {
      final lay = _layout(offset);
      final next = lay.tops[row] + lay.heights[row] / 2 - _viewportH / 2;
      if ((next - offset).abs() < 0.1) {
        offset = next;
        break;
      }
      offset = next;
    }
    return offset;
  }

  /// 吸附到最近档位：保证有一条精确停在正中、以完整尺寸居中放大。
  void _settleToGrid() {
    if (!mounted || !_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final row = _focusRow(_scroll.offset);
    final target = _snapFor(row).clamp(0.0, max).toDouble();
    if ((target - _scroll.offset).abs() > 0.5) {
      // 90ms 硬曲线快拉回：吸附干脆（原版「咔哒」锁定感），不留
      // 拖泥带水的回中动画——吸附窗口越短，焦点行越像始终卡在正中。
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOutQuad,
      );
    }
    // 落定行变化才振：滚动途中不振（转过去又转回来行没变 = 无反馈），
    // 只有吸附后真正停在新的一行才给一次轻触觉确认。
    if (row != _hapticRow) {
      _hapticRow = row;
      Haptics.tick();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    // 屏形分支：圆屏 = 阶梯缩放 + 右缘弧形指示；方屏 = 全宽等大行 +
    // 直线滚动条（四角不裁，无弧度可让）。
    final round = context.isRoundWatch;
    final header = widget.header;
    final headerBand = header == null ? 0.0 : widget.headerExtent * s;
    final nomPitch = _pitchBase * s;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 首尾留白：底部补 (视口高-焦点行高)/2，最后一行精确停在正中；
        // 顶部在同基础上扣除头部条带——第一行停正中、页面头恰好露在
        // 顶端（One UI 式：标题在最上，随列表滚走）。居中基准必须用
        // 实际焦点行高（名义档距×间距系数），用虚拟档距会让首帧/短列表
        // 焦点行中心偏下 (1.1-1)/2×档距（用户反馈校准）。
        final viewportH = constraints.maxHeight;
        final endPad = ((viewportH - nomPitch * _rowSpacing) / 2)
            .clamp(0.0, double.infinity);
        final startPad = math.max(0.0, endPad - headerBand);
        _viewportH = viewportH;
        _startPad = startPad;
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
                _settleToGrid();
                return false;
              },
              child: ListView.builder(
                controller: _scroll,
                // 触控吸附物理：拖动松手/甩动由物理直接落位最近档位，
                // 与表冠 debounce 吸附共用同一网格（表冠走 jumpTo +
                // 定时器 animateTo，不经滚动物理，互不冲突）。
                physics: _SnapPhysics(snap: _nearestGridOffset),
                padding: EdgeInsets.fromLTRB(0, startPad, 0, endPad),
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
                  return AnimatedBuilder(
                    animation: _scroll,
                    // RepaintBoundary 放在缩放/透明度变换内侧：行内容
                    // 位图在滚动帧间被栅格缓存，逐帧只更新外层变换
                    // 矩阵与图层透明度/行高，文字不重栅格化（低端表
                    // GPU 滚动流畅度的关键）。
                    child:
                        RepaintBoundary(child: widget.itemBuilder(context, row)),
                    builder: (context, child) {
                      final offset =
                          _scroll.hasClients ? _scroll.offset : 0.0;
                      final scale = _scaleFor(row, offset);
                      // 行高随条大小等比收缩：焦点槽最大，远处槽变小，
                      // 空隙不再按标准档位留白。方屏全宽等大恒一。
                      final rowH = _rowH(scale);
                      // 圆屏：Lorentzian 幂曲线——相邻 ~0.78、隔行
                      // ~0.62，0.55 封底防远处行缩没；方屏恒 1。
                      // 透明度随尺寸线性浅衰减（0.55+0.45·scale）：远处
                      // 行保持可读（系统边缘行几乎全亮），焦点行恰好
                      // 为 1 省一层 saveLayer。方屏恒 1。
                      final alpha = round
                          ? (0.55 + 0.45 * scale).clamp(0.0, 1.0)
                          : 1.0;
                      return SizedBox(
                        height: rowH,
                        child: Center(
                          child: Padding(
                            // 圆屏左右各 6% 屏径：焦点行占 88% 屏宽
                            // （用户校准：比系统居中行再宽一点点），相邻
                            // 行随缩放进一步收窄；方屏只留 3% 呼吸边。
                            padding: EdgeInsets.symmetric(
                                horizontal: (round ? 12.0 : 6.0) * s),
                            child: Transform.scale(
                              scale: scale,
                              // 前置锁定内容帧高 = 胶囊标准高，保证所有行
                              // 缩放前等大（条高统一），缩放后 = 标准高×
                              // scale，与 _rowH 几何一致 → 吸附/焦点判定准确。
                              child: SizedBox(
                                height: _capsuleH * s,
                                child: alpha >= 1
                                    ? child
                                    : Opacity(
                                        opacity: alpha, child: child),
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

  /// 甩动物理用的网格函数：把任意投影偏移落到最近档位的吸附偏移。
  double _nearestGridOffset(double offset) {
    if (!_scroll.hasClients) return offset;
    final row = _focusRow(offset);
    return _snapFor(row)
        .clamp(0.0, _scroll.position.maxScrollExtent)
        .toDouble();
  }
}

/// 触控吸附物理：拖动松手/甩动结束后由滚动物理直接落位最近档位
/// （表冠走自身 debounce 吸附，不经此路径）。甩动按速度投射自然滑行
/// 距离并吸附到网格；静止松手就近落位；临界阻尼弹簧快速落位无回弹。
class _SnapPhysics extends ClampingScrollPhysics {
  const _SnapPhysics({required this.snap, super.parent});

  /// 把任意投影偏移映射到「最近档位」的吸附偏移（SteppedListView 提供，
  /// 基于实测变高槽位判定焦点行再迭代出居中偏移）。
  final double Function(double pixels) snap;

  @override
  _SnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _SnapPhysics(snap: snap, parent: buildParent(ancestor));

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
        mass: 0.5,
        stiffness: 420.0, // 高刚度：甩动落位干脆，无软绵绵的回弹感
        ratio: 1.0,
      );

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    final double projected = velocity.abs() > toleranceFor(position).velocity
        ? position.pixels + velocity * 0.12 // 甩动投射：快甩多走几档
        : position.pixels;
    final double target = snap(projected)
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
/// （62*s = 胶囊 56×1.1）以紧约束提供，焦点行铺满屏幕中部。
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
