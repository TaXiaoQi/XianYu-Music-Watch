import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wearable_rotary/wearable_rotary.dart';

import '../../link/link_provider.dart';
import '../../link/protocol.dart';

/// 联接控制页（参考 QQ 音乐手表版形态）：
///
/// 顶部歌名/歌手 → 中央圆形大封面 + 环形进度（点按封面 = 播放/暂停）→
/// 底部五键（喜欢 / 上一首 / 播放暂停 / 下一首 / 播放顺序）；
/// 表冠旋转调手机音量（本地即时显示，250ms 节流下发）。
class WatchControllerPage extends ConsumerStatefulWidget {
  const WatchControllerPage({super.key});

  @override
  ConsumerState<WatchControllerPage> createState() =>
      _WatchControllerPageState();
}

class _WatchControllerPageState extends ConsumerState<WatchControllerPage> {
  static const _volumeStep = 0.05;

  StreamSubscription<RotaryEvent>? _rotarySub;

  /// 本地音量（null = 尚未初始化，跟随手机上报）。
  double? _volume;

  /// 表冠调节中标记：1s 内不覆盖本地显示。
  DateTime _lastRotary = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _volumeSendTimer;
  Timer? _volumeHideTimer;
  bool _volumeVisible = false;

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
    super.dispose();
  }

  void _onRotary(RotaryEvent event) {
    final link = ref.read(linkControllerProvider);
    if (link.phase != LinkPhase.connected) return;
    final dir = event.direction == RotaryDirection.clockwise ? 1 : -1;
    final cur = _volume ?? link.volume ?? 0.5;
    final next = (cur + dir * _volumeStep).clamp(0.0, 1.0);
    _lastRotary = DateTime.now();
    setState(() {
      _volume = next;
      _volumeVisible = true;
    });
    // 节流下发：250ms 静默后才发，避免连续旋转刷爆链路。
    _volumeSendTimer?.cancel();
    _volumeSendTimer = Timer(const Duration(milliseconds: 250), () {
      ref.read(linkControllerProvider.notifier).setVolume(_volume ?? 0.5);
    });
    _volumeHideTimer?.cancel();
    _volumeHideTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _volumeVisible = false);
    });
  }

  String _fmt(double secs) {
    final s = secs.clamp(0.0, 359999).round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  IconData _modeIcon(LinkPlayMode m) => switch (m) {
        LinkPlayMode.shuffle => Icons.shuffle_rounded,
        LinkPlayMode.one => Icons.repeat_one_rounded,
        LinkPlayMode.order => Icons.repeat_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final link = ref.watch(linkControllerProvider);
    final now = link.now;
    final size = MediaQuery.of(context).size;
    final ringSize = (size.shortestSide * 0.52).clamp(110.0, 190.0);

    // 手机推来的音量覆盖本地显示（表冠调节后 1s 内除外）。
    if (link.volume != null &&
        DateTime.now().difference(_lastRotary) > const Duration(seconds: 1)) {
      _volume = link.volume;
    }
    final progress =
        (now != null && now.duration > 0) ? link.position / now.duration : 0.0;

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // 歌名 / 歌手
                  Column(
                    children: [
                      Text(
                        now?.title ?? '手机未在播放',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        now?.artist ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ),
                  // 封面 + 环形进度（点按 = 播放/暂停）
                  GestureDetector(
                    onTap: () =>
                        ref.read(linkControllerProvider.notifier).toggle(),
                    child: SizedBox(
                      width: ringSize,
                      height: ringSize,
                      child: CustomPaint(
                        painter: _RingPainter(progress: progress),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: ClipOval(child: _cover(now)),
                        ),
                      ),
                    ),
                  ),
                  // 进度文本
                  Text(
                    '${_fmt(link.position)} / ${_fmt(now?.duration ?? 0)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                  // 五键控制
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _ctrlBtn(
                        icon: link.liked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        color: link.liked
                            ? const Color(0xFFFF4D6E)
                            : Colors.white.withValues(alpha: 0.85),
                        onTap: () =>
                            ref.read(linkControllerProvider.notifier).like(),
                        tooltip: '喜欢',
                      ),
                      _ctrlBtn(
                        icon: Icons.skip_previous_rounded,
                        onTap: () =>
                            ref.read(linkControllerProvider.notifier).prev(),
                        tooltip: '上一首',
                      ),
                      // 大播放/暂停键
                      GestureDetector(
                        onTap: () =>
                            ref.read(linkControllerProvider.notifier).toggle(),
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: const BoxDecoration(
                            color: Color(0xFFFF4D6E),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            link.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 32,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      _ctrlBtn(
                        icon: Icons.skip_next_rounded,
                        onTap: () =>
                            ref.read(linkControllerProvider.notifier).next(),
                        tooltip: '下一首',
                      ),
                      _ctrlBtn(
                        icon: _modeIcon(link.playMode),
                        onTap: () => ref
                            .read(linkControllerProvider.notifier)
                            .cycleMode(),
                        tooltip: '播放顺序',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // 音量 HUD（表冠调节时短暂显示）
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
                      (_volume ?? 0) <= 0
                          ? Icons.volume_off_rounded
                          : (_volume ?? 0) < 0.5
                              ? Icons.volume_down_rounded
                              : Icons.volume_up_rounded,
                      size: 15,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '${((_volume ?? 0) * 100).round()}%',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _cover(LinkNowPlaying? now) {
    final cover = now?.cover;
    if (cover == null || cover.isEmpty) {
      return const _CoverFallback();
    }
    if (now!.coverIsFile) {
      return Image.file(
        File(cover),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const _CoverFallback(),
      );
    }
    return Image.network(
      cover,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const _CoverFallback(),
    );
  }

  Widget _ctrlBtn({
    required IconData icon,
    required VoidCallback onTap,
    Color color = Colors.white,
    String? tooltip,
  }) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 24, color: color),
      tooltip: tooltip,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
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
        size: 36,
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
      ..strokeWidth = 5
      ..color = Colors.white.withValues(alpha: 0.14);
    canvas.drawArc(rect, 0, 2 * 3.141592653589793, false, track);

    final p = progress.clamp(0.0, 1.0);
    if (p > 0.001) {
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFFFF4D6E);
      canvas.drawArc(rect, -1.5707963267948966, 2 * 3.141592653589793 * p,
          false, arc);
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
