import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wearable_rotary/wearable_rotary.dart';

import 'player_source.dart';

/// 主题色（与 app.dart ColorScheme.primary 一致）。
const Color kPlayerAccent = Color(0xFFFF4D6E);

/// 通用播放页主体（网易云手表版形态）：顶部歌名/歌手 → 中部
/// 上一首 | 封面环形进度（点按=播放暂停，拖拽=seek，长按左右=±10s）| 下一首
/// → 底部 喜欢（可选）/ 音量 / 播放模式。
///
/// 数据经 [PlayerViewSource] 抽象，联动（手机）与本地两种模式共用。
/// 表冠旋转调音量（本地即时显示，250ms 节流下发）。
class PlayPageBody extends StatefulWidget {
  const PlayPageBody({
    super.key,
    required this.sourceBuilder,
    this.showCloudBadge = false,
    this.emptyText = '未在播放',
    this.emptyActionLabel,
    this.onEmptyAction,
  });

  /// 每次 build 从 provider 取最新状态构造数据源。
  final PlayerViewSource Function() sourceBuilder;

  /// 联动云中继标识（歌手名旁小云标）。
  final bool showCloudBadge;

  final String emptyText;

  /// 空态引导按钮（如「去选歌」）；不传则只显示提示文字。
  final String? emptyActionLabel;
  final VoidCallback? onEmptyAction;

  @override
  State<PlayPageBody> createState() => _PlayPageBodyState();
}

class _PlayPageBodyState extends State<PlayPageBody> {
  static const _volumeStep = 0.05;

  StreamSubscription<RotaryEvent>? _rotarySub;

  /// 本地音量回显（null = 跟随 source）。
  double? _volume;

  /// 表冠调节中标记：1s 内不覆盖本地显示。
  DateTime _lastRotary = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _volumeSendTimer;
  Timer? _volumeHideTimer;
  bool _volumeVisible = false;

  /// 倍速切换 HUD（点倍速键后短暂显示当前档位）。
  Timer? _speedHideTimer;
  bool _speedVisible = false;

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
    _speedHideTimer?.cancel();
    _seekSendTimer?.cancel();
    _longSeekTimer?.cancel();
    super.dispose();
  }

  void _onRotary(RotaryEvent event) {
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

  /// 倍速键：循环切档 + 顶部 HUD 回显新档位。
  void _onSpeedTap() {
    widget.sourceBuilder().cycleSpeed();
    setState(() => _speedVisible = true);
    _speedHideTimer?.cancel();
    _speedHideTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _speedVisible = false);
    });
  }

  /// 倍速档位文案：1 → 1.0x，1.5 → 1.5x，1.25 → 1.25x。
  static String _speedLabel(double s) =>
      s == s.roundToDouble() ? '${s.toStringAsFixed(1)}x' : '${s}x';

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

  IconData _modeIcon(int m) => switch (m) {
        2 => Icons.shuffle_rounded,
        1 => Icons.repeat_one_rounded,
        _ => Icons.repeat_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final src = widget.sourceBuilder();
    final size = MediaQuery.of(context).size;
    final ringSize = (size.shortestSide * 0.42).clamp(100.0, 160.0);

    // 手机推来的音量覆盖本地显示（表冠调节后 1s 内除外）。
    if (DateTime.now().difference(_lastRotary) > const Duration(seconds: 1)) {
      _volume = src.volume;
    }
    // 拖拽 seek 中本地预览进度，上报进度在松手前不覆盖。
    final displayProgress = _scrubTarget ??
        ((src.duration > 0) ? (src.position / src.duration) : 0.0);

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
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
                          fontSize: src.hasTrack ? 16 : 14,
                          fontWeight: FontWeight.w600,
                          color: src.hasTrack
                              ? Colors.white
                              : Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                      if (!src.hasTrack && widget.emptyActionLabel != null) ...[
                        const SizedBox(height: 10),
                        FilledButton.tonal(
                          onPressed: widget.onEmptyAction,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 6),
                            minimumSize: const Size(0, 32),
                          ),
                          child: Text(widget.emptyActionLabel!,
                              style: const TextStyle(fontSize: 12)),
                        ),
                      ],
                      if (src.hasTrack) ...[
                        const SizedBox(height: 2),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.showCloudBadge) ...[
                              Icon(
                                Icons.cloud_outlined,
                                size: 11,
                                color: Colors.white.withValues(alpha: 0.45),
                              ),
                              const SizedBox(width: 4),
                            ],
                            Text(
                              src.artist ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white.withValues(alpha: 0.55),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                  // 中部：上一首 | 封面环形 | 下一首
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _sideBtn(
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
                            painter: _RingPainter(progress: displayProgress),
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  ClipOval(child: _cover(src.cover)),
                                  // 播放/暂停覆盖标（参考网易云：封面中央小圆标）
                                  Container(
                                    width: 34,
                                    height: 34,
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(alpha: 0.35),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      src.isPlaying
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      size: 22,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      _sideBtn(
                        icon: Icons.skip_next_rounded,
                        onTap: src.next,
                      ),
                    ],
                  ),
                  // 底部：喜欢（可选）/ 音量 / 播放模式
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      if (src.liked != null)
                        _bottomBtn(
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
                        icon: (_volume ?? src.volume) <= 0
                            ? Icons.volume_off_rounded
                            : (_volume ?? src.volume) < 0.5
                                ? Icons.volume_down_rounded
                                : Icons.volume_up_rounded,
                        onTap: _showVolumeHud,
                        tooltip: '音量（表冠调节）',
                      ),
                      // 倍速键（本地模式显示；联动模式 speed=null 隐藏）
                      if (src.speed != null)
                        _bottomTextBtn(
                          label: _speedLabel(src.speed!),
                          active: src.speed! != 1.0,
                          onTap: _onSpeedTap,
                          tooltip: '倍速',
                        ),
                      _bottomBtn(
                        icon: _modeIcon(src.playMode),
                        onTap: src.cycleMode,
                        tooltip: '播放顺序',
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
                margin: const EdgeInsets.only(top: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
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
                      size: 15,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '${((_volume ?? src.volume) * 100).round()}%',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          // 倍速 HUD（点倍速键后短暂显示当前档位）
          if (_speedVisible)
            Align(
              alignment: Alignment.topCenter,
              child: Container(
                margin: const EdgeInsets.only(top: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.speed_rounded, size: 15),
                    const SizedBox(width: 5),
                    Text(
                      _speedLabel(src.speed ?? 1.0),
                      style: const TextStyle(fontSize: 12),
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
                margin: const EdgeInsets.only(top: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_longSeekForward) ...[
                      const Icon(Icons.fast_rewind_rounded, size: 15),
                      const SizedBox(width: 5),
                    ],
                    Text(
                      _longSeekForward ? '+10s' : '-10s',
                      style: const TextStyle(fontSize: 12),
                    ),
                    if (_longSeekForward) ...[
                      const SizedBox(width: 5),
                      const Icon(Icons.fast_forward_rounded, size: 15),
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
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 28, color: Colors.white.withValues(alpha: 0.9)),
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
    );
  }

  Widget _bottomBtn({
    required IconData icon,
    required VoidCallback onTap,
    Color color = Colors.white,
    String? tooltip,
  }) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 22, color: color),
      tooltip: tooltip,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
    );
  }

  /// 文本按钮（倍速档位）：非 1.0 档高亮主题色，一眼看出在倍速播放。
  Widget _bottomTextBtn({
    required String label,
    required VoidCallback onTap,
    bool active = false,
    String? tooltip,
  }) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      icon: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: active ? kPlayerAccent : Colors.white.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}

/// 封面占位：暗色圆底 + 音符。
class _CoverFallback extends StatelessWidget {
  const _CoverFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A1A1E),
      child: Icon(
        Icons.music_note_rounded,
        size: 34,
        color: Colors.white.withValues(alpha: 0.35),
      ),
    );
  }
}

/// 环形进度（底环 + 进度弧，进度从 12 点方向顺时针）。
class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = Colors.white.withValues(alpha: 0.14);
    canvas.drawArc(rect, 0, 2 * math.pi, false, track);

    final p = progress.clamp(0.0, 1.0);
    if (p > 0.001) {
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..color = kPlayerAccent;
      canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * p, false, arc);
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
