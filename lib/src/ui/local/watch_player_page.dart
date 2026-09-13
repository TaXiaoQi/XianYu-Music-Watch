import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wearable_rotary/wearable_rotary.dart';

import '../../player/player_provider.dart';

/// 独立模式播放页：圆屏大封面 + 环形进度（点按封面 = 播放/暂停）+
/// 上一首/播放暂停/下一首 + 播放顺序；表冠旋转调本地音量。
class WatchPlayerPage extends ConsumerStatefulWidget {
  const WatchPlayerPage({super.key});

  @override
  ConsumerState<WatchPlayerPage> createState() => _WatchPlayerPageState();
}

class _WatchPlayerPageState extends ConsumerState<WatchPlayerPage> {
  static const _volumeStep = 0.05;

  StreamSubscription<RotaryEvent>? _rotarySub;
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
    final dir = event.direction == RotaryDirection.clockwise ? 1 : -1;
    final cur = ref.read(volumeProvider);
    final next = (cur + dir * _volumeStep).clamp(0.0, 1.0);
    setState(() => _volumeVisible = true);
    _volumeSendTimer?.cancel();
    _volumeSendTimer = Timer(const Duration(milliseconds: 250), () {
      ref.read(playerProvider.notifier).setVolume(next);
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

  IconData _modeIcon(int m) => switch (m) {
        2 => Icons.shuffle_rounded,
        1 => Icons.repeat_one_rounded,
        _ => Icons.repeat_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(playerProvider);
    final current = state.current;
    final size = MediaQuery.of(context).size;
    final ringSize = (size.shortestSide * 0.5).clamp(110.0, 180.0);
    final progress =
        state.duration > 0 ? (state.position / state.duration) : 0.0;
    final vol = ref.watch(volumeProvider);

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Column(
                    children: [
                      Text(
                        current?.title ?? '未在播放',
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
                        current?.artist ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.55),
                        ),
                      ),
                    ],
                  ),
                  GestureDetector(
                    onTap: () =>
                        ref.read(playerProvider.notifier).toggle(),
                    child: SizedBox(
                      width: ringSize,
                      height: ringSize,
                      child: CustomPaint(
                        painter: _RingPainter(progress: progress),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: ClipOval(
                              child: _cover(
                                  current?.coverPath, current?.coverUrl)),
                        ),
                      ),
                    ),
                  ),
                  Text(
                    '${_fmt(state.position)} / ${_fmt(state.duration)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        onPressed: () =>
                            ref.read(playerProvider.notifier).previous(),
                        icon: const Icon(Icons.skip_previous_rounded,
                            size: 24),
                        padding: const EdgeInsets.all(6),
                        constraints:
                            const BoxConstraints(minWidth: 36, minHeight: 36),
                      ),
                      GestureDetector(
                        onTap: () =>
                            ref.read(playerProvider.notifier).toggle(),
                        child: Container(
                          width: 56,
                          height: 56,
                          decoration: const BoxDecoration(
                            color: Color(0xFFFF4D6E),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            state.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 32,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () =>
                            ref.read(playerProvider.notifier).next(),
                        icon: const Icon(Icons.skip_next_rounded, size: 24),
                        padding: const EdgeInsets.all(6),
                        constraints:
                            const BoxConstraints(minWidth: 36, minHeight: 36),
                      ),
                      IconButton(
                        onPressed: () =>
                            ref.read(playerProvider.notifier).cyclePlayMode(),
                        icon: Icon(_modeIcon(state.playMode), size: 24),
                        padding: const EdgeInsets.all(6),
                        constraints:
                            const BoxConstraints(minWidth: 36, minHeight: 36),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // 表冠音量 HUD
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
                      vol <= 0
                          ? Icons.volume_off_rounded
                          : vol < 0.5
                              ? Icons.volume_down_rounded
                              : Icons.volume_up_rounded,
                      size: 15,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '${(vol * 100).round()}%',
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

  Widget _cover(String? coverPath, String? coverUrl) {
    if (coverUrl != null && coverUrl.isNotEmpty) {
      return Image.network(
        coverUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const _CoverFallback(),
      );
    }
    if (coverPath == null || coverPath.isEmpty || !File(coverPath).existsSync()) {
      return const _CoverFallback();
    }
    return Image.file(
      File(coverPath),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const _CoverFallback(),
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
