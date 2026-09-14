import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wearable_rotary/wearable_rotary.dart';

import '../../core/watch_fit.dart';
import 'player_source.dart';

/// 主题色（与 app.dart ColorScheme.primary 一致）。
const Color kPlayerAccent = Color(0xFFFF4D6E);

/// 通用播放页主体（网易云手表版形态）：顶部歌名/歌手 → 中部
/// 上一首 | 小封面红圈进度（点按=播放暂停，拖拽=seek，长按左右=±10s）|
/// 下一首 → 底部 喜欢（可选）/ 音量 / 更多（⸬ 键：播放模式 + 倍速面板）。
///
/// 数据经 [PlayerViewSource] 抽象，联动（手机）与本地两种模式共用。
/// 表冠旋转调音量（本地即时显示，250ms 节流下发）。
/// 尺寸按 [watchScale] 等比适配任意表径；本页背景透明，全屏封面模糊
/// 背景由宿主层 CoverBackdrop 提供。
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

  /// 每次 build 从 provider 取最新状态构造数据源。
  final PlayerViewSource Function() sourceBuilder;

  /// 联动云中继标识（歌手名旁小云标）。
  final bool showCloudBadge;

  final String emptyText;

  /// 空态引导按钮（如「去选歌」）；不传则只显示提示文字。
  final String? emptyActionLabel;
  final VoidCallback? onEmptyAction;

  /// 表冠事件门禁：宿主在 PageView 里时，只有本页是当前页才允许响应
  /// （表冠是全局流，PageView 邻页/隐藏页收到会误触音量）。返回 true
  /// 表示当前可以响应。不传 = 总是响应（独占路由的宿主）。
  final bool Function()? rotaryGuard;

  @override
  State<PlayPageBody> createState() => _PlayPageBodyState();
}

class _PlayPageBodyState extends State<PlayPageBody> {
  static const _volumeStep = 0.05;

  /// 倍速档位（更多面板点选，与本地播放引擎档位一致）。
  static const _speedSteps = [0.75, 1.0, 1.25, 1.5, 2.0];

  StreamSubscription<RotaryEvent>? _rotarySub;

  /// 本地音量回显（null = 跟随 source）。
  double? _volume;

  /// 表冠调节中标记：1s 内不覆盖本地显示。
  DateTime _lastRotary = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _volumeSendTimer;
  Timer? _volumeHideTimer;
  bool _volumeVisible = false;

  /// 环形 seek 状态：拖拽预览目标进度（null = 未拖拽）、长按快进快退。
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
    _volumeHideTimer?.cancel();
    _seekSendTimer?.cancel();
    _longSeekTimer?.cancel();
    super.dispose();
  }

  void _onRotary(RotaryEvent event) {
    // 上层有推送页（设置/账号等）时不响应表冠。
    if (ModalRoute.of(context)?.isCurrent != true) return;
    // 宿主在 PageView 中：非当前页的表冠事件不归本页（隐藏页误触音量）。
    final guard = widget.rotaryGuard;
    if (guard != null && !guard()) return;
    HapticFeedback.selectionClick(); // 表冠档位振动反馈
    final src = widget.sourceBuilder();
    final dir = event.direction == RotaryDirection.clockwise ? 1 : -1;
    final cur = _volume ?? src.volume;
    final next = (cur + dir * _volumeStep).clamp(0.0, 1.0);
    _lastRotary = DateTime.now();
    setState(() {
      _volume = next;
      _volumeVisible = true;
    });
    // 节流下发：250ms 静默后才发，避免连续旋转刷爆链路。
    _volumeSendTimer?.cancel();
    _volumeSendTimer = Timer(const Duration(milliseconds: 250), () {
      widget.sourceBuilder().setVolume(_volume ?? 0.5);
    });
    _volumeHideTimer?.cancel();
    _volumeHideTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _volumeVisible = false);
    });
  }

  void _showVolumeHud() {
    setState(() => _volumeVisible = true);
    _volumeHideTimer?.cancel();
    _volumeHideTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _volumeVisible = false);
    });
  }

  /// 倍速档位文案：1 → 1.0x，1.5 → 1.5x，1.25 → 1.25x。
  static String _speedLabel(double s) =>
      s == s.roundToDouble() ? '${s.toStringAsFixed(1)}x' : '${s}x';

  /// 播放模式文案/图标（0 顺序 / 1 单曲循环 / 2 随机）。
  static String _modeLabel(int m) => switch (m) {
        1 => '单曲循环',
        2 => '随机播放',
        _ => '列表循环',
      };

  IconData _modeIcon(int m) => switch (m) {
        2 => Icons.shuffle_rounded,
        1 => Icons.repeat_one_rounded,
        _ => Icons.repeat_rounded,
      };

  /// 更多面板（底部 ⸬ 键，网易云手表版样式）：播放模式三选一 + 倍速档位
  /// （联动模式不支持倍速时整组隐藏）。点选即生效，StatefulBuilder +
  /// 现取数据源让面板高亮随设置结果刷新。
  void _openMoreSheet() {
    HapticFeedback.selectionClick();
    final s = context.watchScale();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF17171C),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18 * s)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) {
          final src = widget.sourceBuilder();
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16 * s, 12 * s, 16 * s, 10 * s),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sheetLabel('播放模式', s),
                  SizedBox(height: 7 * s),
                  Wrap(
                    spacing: 7 * s,
                    runSpacing: 7 * s,
                    children: [
                      for (var m = 0; m < 3; m++)
                        _sheetChip(
                          s: s,
                          active: src.playMode == m,
                          onTap: () {
                            src.setMode(m);
                            HapticFeedback.selectionClick();
                            setSheet(() {});
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
                  if (src.speed != null) ...[
                    SizedBox(height: 13 * s),
                    _sheetLabel('倍速', s),
                    SizedBox(height: 7 * s),
                    Wrap(
                      spacing: 7 * s,
                      runSpacing: 7 * s,
                      children: [
                        for (final v in _speedSteps)
                          _sheetChip(
                            s: s,
                            active: (src.speed! - v).abs() < 0.01,
                            onTap: () {
                              src.setSpeed(v);
                              HapticFeedback.selectionClick();
                              setSheet(() {});
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
                  ],
                ],
              ),
            ),
          );
        },
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

  /// 环形拖拽 seek：触点角度（12 点起顺时针）映射为播放进度。
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

  /// 长按环形：右半区快进 +10s，左半区快退 -10s，按住持续跳。
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
    HapticFeedback.selectionClick();
  }

  void _sendSeek(double pos) {
    final src = widget.sourceBuilder();
    if (src.duration <= 0) return;
    src.seekTo(pos * src.duration);
  }

  /// 拖拽过程节流下发（120ms 尾发送，避免刷爆链路）。
  void _sendSeekThrottled(double pos) {
    _seekSendTimer?.cancel();
    _seekSendTimer = Timer(const Duration(milliseconds: 120), () {
      if (_scrubTarget != null) _sendSeek(pos);
    });
  }

  /// 触点相对环形中心的方位角 → 进度（0 在 12 点，顺时针）。
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
    // 小封面（网易云手表版）：屏径约 30%，红圈进度贴封面留窄缝。
    final ringSize = 70 * s;

    // 手机推来的音量覆盖本地显示（表冠调节后 1s 内除外）。
    if (DateTime.now().difference(_lastRotary) > const Duration(seconds: 1)) {
      _volume = src.volume;
    }
    // 拖拽 seek 中本地预览进度，上报进度在松手前不覆盖。
    final displayProgress = _scrubTarget ??
        ((src.duration > 0) ? (src.position / src.duration) : 0.0);

    return Scaffold(
      // 透明：全屏封面模糊背景由宿主层 CoverBackdrop 提供，本页只画前景。
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          SafeArea(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16 * s, vertical: 4 * s),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // 歌名 / 歌手（云中继附小云标）
                  Column(
                    children: [
                      Text(
                        src.hasTrack ? (src.title ?? '') : widget.emptyText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: src.hasTrack ? 17.5 * s : 13 * s,
                          fontWeight: FontWeight.w700,
                          color: src.hasTrack
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                      if (!src.hasTrack && widget.emptyActionLabel != null) ...[
                        SizedBox(height: 8 * s),
                        FilledButton.tonal(
                          onPressed: widget.onEmptyAction,
                          style: FilledButton.styleFrom(
                            padding: EdgeInsets.symmetric(
                                horizontal: 14 * s, vertical: 6 * s),
                            minimumSize: Size(0, 30 * s),
                          ),
                          child: Text(widget.emptyActionLabel!,
                              style: TextStyle(fontSize: 12 * s)),
                        ),
                      ],
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
                            Text(
                              src.artist ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11 * s,
                                color: Colors.white.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                  // 中部：上一首 | 封面红圈 | 下一首
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _sideBtn(
                        s: s,
                        icon: Icons.skip_previous_rounded,
                        onTap: src.prev,
                      ),
                      GestureDetector(
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
                              strokeWidth: 3.5 * s,
                            ),
                            child: Padding(
                              padding: EdgeInsets.all(2.5 * s),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  ClipOval(child: _cover(src.cover)),
                                  // 大播放/暂停键（网易云样式：白色大图标
                                  // 直接压在封面上，无底色圆片）。
                                  Icon(
                                    src.isPlaying
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    size: ringSize * 0.40,
                                    color: Colors.white,
                                    shadows: [
                                      Shadow(
                                        color: Colors.black
                                            .withValues(alpha: 0.5),
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
                      _sideBtn(
                        s: s,
                        icon: Icons.skip_next_rounded,
                        onTap: src.next,
                      ),
                    ],
                  ),
                  // 底部：喜欢（可选）/ 音量 / 更多（播放模式+倍速）
                  Row(
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
                      _bottomBtn(
                        s: s,
                        icon: (_volume ?? src.volume) <= 0
                            ? Icons.volume_off_rounded
                            : (_volume ?? src.volume) < 0.5
                                ? Icons.volume_down_rounded
                                : Icons.volume_up_rounded,
                        onTap: _showVolumeHud,
                        tooltip: '音量（表冠调节）',
                      ),
                      _bottomBtn(
                        s: s,
                        icon: Icons.apps_rounded,
                        onTap: _openMoreSheet,
                        tooltip: '更多（播放模式/倍速）',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // 音量 HUD（表冠调节或点音量键时短暂显示）
          if (_volumeVisible)
            Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: EdgeInsets.only(top: 8 * s),
                padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 5 * s),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(18 * s),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      (_volume ?? src.volume) <= 0
                          ? Icons.volume_off_rounded
                          : (_volume ?? src.volume) < 0.5
                              ? Icons.volume_down_rounded
                              : Icons.volume_up_rounded,
                      size: 14 * s,
                    ),
                    SizedBox(width: 5 * s),
                    Text(
                      '${((_volume ?? src.volume) * 100).round()}%',
                      style: TextStyle(fontSize: 11.5 * s),
                    ),
                  ],
                ),
              ),
            ),
          // 长按 seek HUD（快进/快退提示）
          if (_longSeeking)
            Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: EdgeInsets.only(top: 8 * s),
                padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 5 * s),
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
        final f = File(cover.filePath!);
        if (f.existsSync()) {
          return Image.file(
            f,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const _CoverFallback(),
          );
        }
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
      icon: Icon(icon, size: 21 * s, color: Colors.white.withValues(alpha: 0.92)),
      padding: EdgeInsets.all(4 * s),
      constraints: BoxConstraints(minWidth: 38 * s, minHeight: 38 * s),
    );
  }

  Widget _bottomBtn({
    required double s,
    required IconData icon,
    required VoidCallback onTap,
    Color color = Colors.white,
    String? tooltip,
  }) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 15.5 * s, color: color),
      tooltip: tooltip,
      padding: EdgeInsets.all(5 * s),
      constraints: BoxConstraints(minWidth: 34 * s, minHeight: 34 * s),
    );
  }
}

/// 封面占位：暗色圆底 + 音符。
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

/// 环形进度（底环 + 进度弧，进度从 12 点方向顺时针）。
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
