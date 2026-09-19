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
              // WearOS 原版：页面标题过长自动换行（两行居中），不做单行
              // 省略；ellipsis 仅作超长兜底。行高锁 1.2，两行 ~36s 仍在
              // headerBand（46/56s）内，Center 保持几何居中。
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

/// 圆屏阶梯列表（One UI 表盘同款观感，全部二级页与功能页统一适配）：
/// 行为圆角胶囊卡片，一档一个条目——居中焦点行最大铺满中部，上下行
/// 陡衰减缩小（1.0 → 相邻 ~0.73 → 隔行 ~0.60 → 三行 ~0.53 → 长尾缓降
/// 趋 0.32，无高位平台），复刻 WearOS 原版梯形列表。
///
/// 间距跟随条大小等比缩放（用户澄清，WearOS 原版观感）：远处行不仅条
/// 本身缩小，其上下占用的**行高槽位也同步缩小**（行高 = 胶囊高×scale×
/// 1.06，缝隙随条等比缩放、紧凑衔接）——梯形列表若用固定大小间距，远处条已压缩
/// 到最小、间距仍是标准大小，会出现「远处行距拉得很开」的大空隙 bug；
/// 等比缝让整体紧凑堆叠成密度均匀的阶梯。焦点最大槽占满屏中部，相邻
/// ~0.73 槽，远处缓降至 ~0.32；右缘有弧形滚动位置指示；表冠逐档滚动 +
/// 档位振动；触控拖动/甩动由吸附物理直接落位最近档位。
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
  // 名义均匀档距 60*s：仅用于「距离→缩放」的归一化（焦点 1.0 →
  // 相邻 ~0.73 → 隔行 ~0.60 → 三行 ~0.53 → 长尾缓降 0.32）与行高基准。
  // 注意它只是「虚拟档距」，真实行高在 _rowH 里额外乘 _rowSpacing 留呼吸缝。
  static const double _pitchBase = 60;

  /// 胶囊标准高（60*s）：焦点行满高基准，其余行高 = 该值 ×scale×1.1。
  /// 与 _pitchBase 同步 56→60 = 全梯形等比放大一档（用户校准：中间三行
  /// 再大一点），Lorentzian 归一化距离不变 → 缩放曲线自洽不变。
  static const double _capsuleH = 60;

  /// 行高相对卡片高的间距系数：行高 = 卡片高×1.06，上下各留 3% 呼吸缝
  /// ——缝隙必须随卡片大小等比缩放（固定缝会让远处条已缩到最小、
  /// 间距仍是标准大小 → 远处行距拉得很开的大空隙 bug）。1.1→1.06
  /// （用户校准：系统条缩小后条与条依然「衔接」，缝要紧——焦点缝
  /// 3.6s，远处缝随条等比收到 ~2s）。
  static const double _rowSpacing = 1.06;

  /// scale 渐近底（远处行趋近而不低于的倍率）。0.55 高位封底会让三行外
  /// 全部挤在 0.55~0.565（差异 <3% 不可辨）——用户反馈「除中间放大外
  /// 上下大小都一样」的根因：原版远场是持续缩小的长尾，无高位平台，
  /// 故降为 0.32 让逐行衰减一直可辨。
  static const double _minScale = 0.32;

  /// 陡降幂（>1）与半高半径：Lorentzian 幂曲线 scale = min + (1-min)/
  /// (1+(d/τ)^p)——近场高台、远场长尾缓降。τ=1.234/p=1.324 与
  /// [_minScale]=0.32 联合拟合两个系统实测锚点（收敛后相邻 0.726、
  /// 隔行 0.60 不变），同时让三行外保持可见的逐行衰减
  /// （0.53 → 0.49 → 0.46 → 0.44 → …）；旧参数 τ=0.81/p=3.3 配 0.55
  /// 封底在隔行之外立刻压平成平台（用户反馈「上下大小都一样」）。
  /// 纯指数衰减无法两头兼顾：τ 调大近场变大时远场跟着一起放大，
  /// 观感变成整页放大而非中间突出。
  static const double _decayTau = 1.234;
  static const double _decayPow = 1.324;

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
  /// 平滑跟手（华为兼容层事件风暴自然摊成平滑小步）。
  double _rotaryAcc = 0;

  /// 表冠停转吸附定时器：表冠 jumpTo 位移可停在任意位置，停转 60ms
  /// 后主动对齐最近档位（ScrollEnd 门控会漏掉最后一次 jumpTo，这里兜底；
  /// 短延迟让焦点行几乎总锁在中线——中间放大的根因）。
  Timer? _settleTimer;

  /// 上次吸附落定的行：吸附后行变化才振一次（用户校准：转过去没滚到
  /// 下一行又转回来 = 行没变 = 不振；只有真正切到新行才反馈）。
  int _hapticRow = 0;

  /// 最近一次表冠事件时刻：ScrollEnd 吸附的门——表冠滚动中 jumpTo 与
  /// 吸附动画会往复拉锯（跨行线反复触发振动=持续震动的根因），滚动中
  /// 跳过吸附，停转后由 debounce 定时器兜底对齐。
  DateTime _lastRotaryAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 最近一次表冠轻刻时刻：跨行刻度按此节流（快速风暴下不给一串连振）。
  DateTime _lastCrownTickAt = DateTime.fromMillisecondsSinceEpoch(0);

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
    final delta = _rotaryAcc * 0.5; // 0.5 齿轮比：一格 → 半行，行程绵密跟手
    _rotaryAcc = 0;
    final target = (_scroll.offset + delta).clamp(0.0, max);
    if ((target - _scroll.offset).abs() < 0.5) return; // 已到边不空振
    _scroll.jumpTo(target); // 跟手位移；停转后由 debounce 吸附回网格
    _lastRotaryAt = DateTime.now();
    // 停转 60ms 后主动吸附：否则列表停在任意偏移上，正中行错档缩小
    // （「中间不放大」的根因）；短延迟让焦点行几乎总锁在中线。
    // 吸附后行变了才给轻刻（触摸路径不振动）。
    _settleTimer?.cancel();
    _settleTimer =
        Timer(const Duration(milliseconds: 60), () => _settleToGrid(feedback: true));
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

  /// 行高 = 名义档距 × 缩放 × 间距系数（焦点槽 = 满档 ×1.06 → 首行/焦点行
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
    // 表头条带为固定槽（不参与阶梯缩放，用户校准：标题恒定原尺寸，
    // 可读性优先）。固定槽高与实际布局永远一致（无逐帧变化），顶部
    // 一条固定头部带不干扰居中几何——startPad 已按完整条带预留。
    for (var it = 0; it < 12; it++) {
      var acc = _startPad + (_hasHeader ? _headerBand : 0.0);
      for (var i = 0; i < n; i++) {
        tops[i] = acc;
        heights[i] = _rowH(scales[i]);
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

  /// 让焦点行 [row] 精确停在中线的滚动偏移（以实际行高为初值，迭代到残差
  /// 消失收敛到实测槽位中心）。迭代必须收敛到位：几何自耦合（行高依赖
  /// 缩放、缩放依赖位置）时固定少量迭代对下行剩大幅残差——数值验证
  /// 36 档 3 轮残差最大 ~22px 且随行号递增，焦点行停在圆心偏下（用户多
  /// 次反馈「居中偏下」的确切根因）；迭代 16 轮残差降到 0.15px、24 轮为 0。
  double _snapFor(int row) {
    var offset = (row + 0.5) * _nomPitch * _rowSpacing +
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

  /// 落定吸附：保证有一条精确停在正中、以完整尺寸居中放大。
  /// [feedback] 为 true 时（仅表冠定时器路径）跨行给轻刻；触摸滚动/惯性
  /// 落定走 false，不振动（用户校准：滑动不振动，振动只在表冠）。
  void _settleToGrid({bool feedback = false}) {
    if (!mounted || !_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final row = _focusRow(_scroll.offset);
    final target = _snapFor(row).clamp(0.0, max).toDouble();
    if ((target - _scroll.offset).abs() > 0.5) {
      // 65ms 硬曲线快拉回：吸附干脆（原版「咔哒」锁定感），不留
      // 拖泥带水的回中动画——吸附窗口越短，焦点行越像始终卡在正中
      // （用户校准：90ms easeOutQuad 观感偏软，缩短+加陡曲线增强
      // 「咬合」力度，滑动与表冠共用此落定）。
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 65),
        curve: Curves.easeOutCubic,
      );
    }
    // 落定行变化才振（仅表冠，触摸不振）：滚动途中不振——只有吸附后真正
    // 停在新的一行才给一次轻刻确认。
    if (feedback) _crownTick(row);
  }

  /// 表冠轻刻（系统级轻微）：行变化 + 节流后触发，触摸路径绝不调用。
  void _crownTick(int row) {
    final now = DateTime.now();
    if (now.difference(_lastCrownTickAt).inMilliseconds < 35) return; // 防连振
    if (row == _hapticRow) return; // 行没变 = 无反馈
    _lastCrownTickAt = now;
    _hapticRow = row;
    Haptics.tick();
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
        // 行内水平留白（圆屏左右各 6% 屏径 / 方屏 3%）与行可用宽：
        // OverflowBox 内容帧宽 = 行宽 − 两侧留白，保证胶囊铺满行可用宽。
        final rowPad = (round ? 12.0 : 6.0) * s;
        final rowW = math.max(0.0, constraints.maxWidth - 2 * rowPad);
        final endPad = ((viewportH - nomPitch * _rowSpacing) / 2)
            .clamp(0.0, double.infinity);
        // 顶部留白 = endPad 减完整表头条带（固定槽，不缩放）：首行停正中、
        // 页面头恰好露在顶端（One UI 式：标题在最上，随列表滚走）。
        final startPad = math.max(0.0, endPad - headerBand);
        // 尾部补偿（只加底边，startPad 不动——头部居中不能受影响）：
        // 甩动冲向尾部时框架还按「尾部行 0.55 小槽」测量 maxScrollExtent，
        // 真实居中偏移被吸附 clamp 咬住 → 焦点行停在圆心偏下、怎么滚都
        // 差一截（用户诊断：底部空白不够）。最坏情况（按全列最小槽测量）
        // 需要补 ≈ 2 档生长量（Σ 尾部收敛生长，用户实测校准），这里给
        // 2×(1−0.32)×63.6s ≈ 86s 保证 _snapFor(尾部任一行) 恒可达；
        // 吸附目标始终是精确居中偏移，多余余量只在视口外、永不停留。
        final tailPad = _round
            ? endPad + nomPitch * _rowSpacing * (1 - _minScale) * 2
            : endPad;
        // 尾部补偿中「非内容」的量：滚动指示算亮弧长度时要从内容总高
        // 里扣除，否则弧长被 padding 虚增压短。
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
                padding: EdgeInsets.fromLTRB(0, startPad, 0, tailPad),
                itemCount: widget.itemCount + (hasHeader ? 1 : 0),
                itemBuilder: (context, i) {
                  if (hasHeader && i == 0) {
                    // 页面头条带：不参与阶梯缩放（用户校准：标题恒定原尺寸，
                    // 可读性优先），随内容自然滚走。固定槽高与几何模型永远
                    // 一致，无需逐帧跟随。
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
                      // 圆屏：Lorentzian 幂曲线——相邻 ~0.73、隔行
                      // ~0.60，长尾缓降趋 0.32（远处行持续缩小，无
                      // 高位平台）；方屏恒 1。
                      // 透明度双层：随尺寸浅衰减（0.55+0.45·scale）+
                      // 边缘淡化——系统对快出视线的条在缩小之外还做
                      // 淡化（用户校准）：行中心距视口上/下缘一个档距
                      // 内线性淡到基础值的 35%，焦点邻域不受影响，
                      // 焦点行恰好为 1 省一层 saveLayer。方屏恒 1。
                      double alpha = 1.0;
                      if (round) {
                        final lay = _layout(offset); // 同帧缓存，命中
                        final c =
                            lay.tops[row] + lay.heights[row] / 2 - offset;
                        final edge = math.min(c, viewportH - c);
                        final t = (edge / _nomPitch).clamp(0.0, 1.0);
                        alpha = (0.55 + 0.45 * scale) * (0.35 + 0.65 * t);
                      }
                      return SizedBox(
                        height: rowH,
                        child: Center(
                          child: Padding(
                            // 圆屏左右各 6% 屏径：焦点行占 88% 屏宽
                            // （用户校准：比系统居中行再宽一点点），相邻
                            // 行随缩放进一步收窄；方屏只留 3% 呼吸边。
                            padding: EdgeInsets.symmetric(horizontal: rowPad),
                            child: Transform.scale(
                              scale: scale,
                              // 前置锁定内容帧高 = 胶囊标准高（60s），缩放
                              // 后 = 标准高×scale，与 _rowH 几何一致 → 吸附/
                              // 焦点判定准确。OverflowBox 强制内容帧约束
                              // （宽 = 行可用宽、高恒 60s）：远处行槽位
                              // rowH = 60s×scale×1.06 在 scale<0.943 时小于
                              // 60s，普通 SizedBox 会被槽位松约束钳到 rowH
                              // ——内容帧缩水，绘制胶囊变
                              // rowH×scale = 60s×1.06×scale²（二次缩小，
                              // 远处行比模型小一圈、缝显大），且文字层
                              // Column 按 60s 排版被钳后溢出（副标题行
                              // scale<0.61 时溢出报错）。不能用
                              // UnconstrainedBox：其内部
                              // ConstraintsTransformBox 仍按未缩放布局尺寸
                              // 对越界子级报溢出条纹（debug 假警报，缩放后
                              // 胶囊 ≤ 槽位实际不越界）；OverflowBox 对越界
                              // 子级不报溢出、不裁剪，是这里的正确原语。
                              child: OverflowBox(
                                alignment: Alignment.center,
                                minWidth: rowW,
                                maxWidth: rowW,
                                minHeight: _capsuleH * s,
                                maxHeight: _capsuleH * s,
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
        stiffness: 600.0, // 高刚度：甩动落位干脆，无软绵绵的回弹感
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
/// 比、最小 2.5% 保底，位置随滚动进度移动）；方屏 = 右缘竖直圆角短条贴
/// 直边。重绘由 ScrollController 监听驱动。
class _ScrollThumbPainter extends CustomPainter {
  _ScrollThumbPainter({
    required this.controller,
    required this.strokeWidth,
    required this.round,
    this.extraExtent = 0.0,
  }) : super(repaint: controller);

  final ScrollController controller;
  final double strokeWidth;

  /// 尾部吸附补偿等「非内容」padding 的量：从内容总高中扣除，否则亮弧
  /// 比真实视口占比偏短（列表越长补偿越多，短弧越明显）。
  final double extraExtent;

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
        Paint()..color = Colors.white.withValues(alpha: 0.72),
      );
      return;
    }
    // 圆屏：导轨总长 110° 贴圆屏右缘（系统同款；旧值 55° 是亮弧被钳成
    // 小点时代的补偿校准，弧长修正后一并还原）；亮弧长度 = 视口占内容比
    // （total 扣除 [extraExtent] 虚增），最小 2.5% 保底——旧代码
    // clamp(0.02, 0.025) 把上限也钳到 2.5%，任何列表都只剩一个小点
    // （用户反馈「滚动条很小、间隔很宽」的根因）。半径外沿距表框 1px
    // 贴住屏缘（旧内缩 strokeWidth×1.6 会在弧与表框之间留一圈宽缝）。
    // 暗导轨全程铺垫、极淡（0.08，提供位置参照）；亮弧 WearOS 灰白
    // （alpha 0.72）。
    const span = 110 * math.pi / 180;
    final content = math.max(
      pos.maxScrollExtent + pos.viewportDimension - extraExtent,
      pos.viewportDimension,
    );
    final thumbFrac = (pos.viewportDimension / content).clamp(0.025, 1.0);
    final off =
        (pos.pixels / math.max(pos.maxScrollExtent, 1.0)).clamp(0.0, 1.0);
    final thumb = span * thumbFrac;
    final start = -span / 2 + off * (span - thumb);
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.shortestSide / 2 - strokeWidth / 2 - 1.0,
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

/// 标准大号行（与 [SteppedListView] 配套）：胶囊卡 + 贴左 40*s 前导区 +
/// **整胶囊几何居中**的主标题 17*s / 副标题 12*s + 可选尾部控件；行高由
/// 列表按档位（66*s = 胶囊 60×1.1）以紧约束提供，焦点行铺满屏幕中部。
/// 文字居中基准 = 胶囊中线（One UI 系统样式）：图标靠左后文字若跟着
/// 在「图标右侧剩余空间」里居中，整行重心会偏移（用户校准）。
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
    // 文字层左右对称预留：预留量相等 → 文字中心严格落在胶囊中线上。
    // 48s/侧（收窄校准：旧 56s 把主流表标题可用宽压到 58s，四字标题
    // 17s×4=68s 必然省略）：左侧仍盖住前导区（40s 圆标贴 3s 起占 43s
    // 余 5s；44s 封面占 47s 余 1s），右侧远大于 chevron 22s；四字标题
    // 可用 74s 放得下，长标题先于图标省略、重心不偏。
    final textReserve = leading != null
        ? 48.0 * s
        : (trailing != null ? 28.0 * s : 0.0);
    return SteppedPill(
      onTap: onTap,
      child: Padding(
        // 横向 3：图标几乎贴胶囊左缘（系统样式，用户校准去缝隙）；
        // 纵向 2：档位内装下胶囊。中文行高由下方 height 锁定。
        padding: EdgeInsets.symmetric(horizontal: 3 * s, vertical: 2 * s),
        child: Stack(
          children: [
            // 文字层：铺满整胶囊后几何居中——不随图标/尾部控件偏移。
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
              ),
            ),
            // 图标层：贴胶囊左缘。
            if (leading != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [leading!, SizedBox(width: 12 * s)],
                ),
              ),
            // 尾部层：贴胶囊右缘。
            if (trailing != null)
              Align(alignment: Alignment.centerRight, child: trailing!),
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
