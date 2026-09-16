import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wearable_rotary/wearable_rotary.dart';

import '../../core/ambient.dart';
import '../../core/settings.dart';
import '../../core/watch_fit.dart';
import '../../lyrics/lyric_model.dart';
import '../../core/haptics.dart';
import 'play_page_body.dart' show kPlayerAccent;

/// 歌词页视图（网易云手表版形态）：全屏滚动歌词，当前行主题色高亮 +
/// 自动居中滚动 + 上下缘淡出；点按歌词行 seek。环境模式下冻结动画
/// （OLED 防烧屏）。
///
/// 行高固定（单行主词 + 可选单行翻译）且随 [watchScale] 等比适配，
/// 保证居中滚动可按行号直算。表冠旋转手动浏览歌词（跨行轻振动），
/// 手动滚动后暂停自动跟随 4s 再恢复。
class LyricsView extends ConsumerStatefulWidget {
  const LyricsView({
    super.key,
    required this.lines,
    required this.position,
    required this.isPlaying,
    this.onSeek,
    this.emptyText = '暂无歌词',
    this.rotaryGuard,
  });

  final List<LyricLine> lines;

  /// 当前播放进度（秒）。
  final double position;

  final bool isPlaying;
  final ValueChanged<double>? onSeek;
  final String emptyText;

  /// 表冠事件门禁（如 PageView 宿主仅当前页响应）；不传 = 总是响应。
  final bool Function()? rotaryGuard;

  @override
  ConsumerState<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<LyricsView> {
  /// 行高（build 里按屏径等比更新；居中滚动按行号直算依赖此值）。
  double _rowExtent = 32;

  /// 列表上下留白（build 里按屏高刷新；居中滚动必须计入顶部留白，
  /// 否则当前行会落在屏幕偏下位置）。
  double _vPad = 0;

  final ScrollController _scroll = ScrollController();
  StreamSubscription<RotaryEvent>? _rotarySub;
  TimingNavigator? _navigator;
  List<LyricLine> _lines = const [];
  int _currentIndex = -1;

  /// 表冠位移预算（带符号像素）：换向清账，逐事件消费为连续滚动位移。
  double _rotaryAcc = 0;

  /// 上次落定的行 + 停转判定定时器：停转 150ms 后行变化才振一次
  /// （同阶梯列表——转过去没滚到下一行又转回来 = 行没变 = 不振）。
  int _hapticRow = 0;
  Timer? _hapticDebounce;

  /// 手动浏览截止时刻：表冠/触控滚动歌词后暂停自动跟随 4s（系统行为：
  /// 手动浏览不被自动滚动抢走），到期后恢复居中当前行。
  DateTime _manualUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// 歌词同步偏移毫秒（build 里随设置刷新，供 tick 路径读取）。
  int _offsetMs = 0;

  /// 显示翻译（build 里随设置刷新）。
  bool _showTranslation = true;

  @override
  void initState() {
    super.initState();
    _syncLines();
    _rotarySub = rotaryEvents.listen(_onRotary);
  }

  @override
  void didUpdateWidget(LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lines, widget.lines) &&
        oldWidget.lines != widget.lines) {
      _syncLines();
    }
  }

  @override
  void dispose() {
    _rotarySub?.cancel();
    _hapticDebounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// 表冠手动浏览歌词：位移跟手（一格棘轮 ≈ 半行），停转后行变化才振；
  /// 手动滚动后 4s 内不自动居中。
  void _onRotary(RotaryEvent event) {
    if (!mounted || !_scroll.hasClients) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final guard = widget.rotaryGuard;
    if (guard != null && !guard()) return;
    final dir = event.direction == RotaryDirection.clockwise ? 1.0 : -1.0;
    final m = (event.magnitude ?? 48).clamp(0.0, 64.0).toDouble();
    if (dir * _rotaryAcc < 0) _rotaryAcc = 0; // 换向清账
    _rotaryAcc += dir * m;
    final delta = _rotaryAcc * 0.5;
    _rotaryAcc = 0;
    final target = (_scroll.offset + delta)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    if ((target - _scroll.offset).abs() < 0.5) return; // 已到边不空振
    _scroll.jumpTo(target);
    _manualUntil = DateTime.now().add(const Duration(seconds: 4));
    // 停转 150ms 后落定行变化才振（滚动途中与往返不振）。
    _hapticDebounce?.cancel();
    _hapticDebounce = Timer(const Duration(milliseconds: 150), () {
      if (!mounted || !_scroll.hasClients) return;
      final row = (_scroll.offset / _rowExtent).floor();
      if (row != _hapticRow) {
        _hapticRow = row;
        Haptics.tick();
      }
    });
  }

  void _syncLines() {
    _lines = widget.lines;
    _navigator = _lines.isEmpty ? null : TimingNavigator(_lines);
    _currentIndex = -1;
    _hapticRow = 0;
  }

  void _applyPosition() {
    if (_navigator == null) return;
    // 歌词同步偏移（同移动端口径）：curMs = posMs - offsetMs，正=歌词更晚。
    final offsetMs = _offsetMs;
    final idx = _navigator!
        .findIndex((widget.position * 1000).round() - offsetMs);
    if (idx == _currentIndex) return;
    _currentIndex = idx;
    if (idx < 0) return;
    // 手动浏览窗口内只更新高亮，不抢滚动位置。
    if (DateTime.now().isBefore(_manualUntil)) return;
    _centerOn(idx);
  }

  /// 当前行驶向屏幕中央；环境模式下直接跳转（无动画省电）。
  void _centerOn(int index) {
    if (!_scroll.hasClients) return;
    final viewport = _scroll.position.viewportDimension;
    // 条目在内容里的位置含顶部留白：目标 = 留白 + 行中心 - 半视口，
    // 少算留白当前行会停在偏下（30% 屏高处正好差一整个留白）。
    final target = (_vPad + index * _rowExtent + _rowExtent / 2 - viewport / 2)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    if (ref.read(ambientModeProvider)) {
      _scroll.jumpTo(target);
      return;
    }
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    // 歌词样式设置（同移动端口径）：字号 0-3 档 / 翻译开关 / 时间偏移。
    final settings = ref.watch(settingsProvider).valueOrNull;
    final fontMul = const [0.85, 1.0, 1.15, 1.3][
        (settings?.lyricFontSize ?? 1).clamp(0, 3)];
    _offsetMs = (settings?.lyricOffsetMs ?? 0).clamp(-100, 100);
    _showTranslation = settings?.showLyricsTranslation ?? true;
    // 行高随字号档位等比缩放，保证固定 itemExtent 居中直算不溢出。
    _rowExtent = 32 * s * fontMul;
    // 上下留白 30% 屏高（居中滚动需要同源数值，见 _centerOn）。
    _vPad = MediaQuery.of(context).size.height * 0.3;

    // 环境模式参与重建：ambient 冻结时静态渲染当前帧即可。
    ref.watch(ambientModeProvider);
    // 每帧对齐进度（findIndex 为 O(log N) + 步进，单帧开销可忽略）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyPosition();
    });

    if (_lines.isEmpty) {
      return Center(
        child: Text(
          widget.emptyText,
          style: TextStyle(
            fontSize: 12 * s,
            color: Colors.white.withValues(alpha: 0.4),
          ),
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        // 触控滚动歌词 → 手动浏览窗口（与表冠同待遇）：手指拖拽中、
        // 惯性结束都算手动操作，4s 内自动跟随让位。表冠 jumpTo 的通知
        // 无 dragDetails，不会在这里重复计时（_onRotary 自行计时）。
        final manual = (n is ScrollUpdateNotification &&
                n.dragDetails != null) ||
            n is ScrollEndNotification;
        if (manual) {
          _manualUntil = DateTime.now().add(const Duration(seconds: 4));
        }
        return false;
      },
      child: ShaderMask(
      // 上下缘淡出（网易云歌词页样式）：边缘行渐隐，视觉聚焦当前行。
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: [0.0, 0.10, 0.90, 1.0],
        colors: [
          Colors.transparent,
          Colors.white,
          Colors.white,
          Colors.transparent,
        ],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: ListView.builder(
        controller: _scroll,
        itemExtent: _rowExtent,
        padding: EdgeInsets.symmetric(
          vertical: _vPad,
          horizontal: 16 * s,
        ),
        itemCount: _lines.length,
        itemBuilder: (context, i) {
          final line = _lines[i];
          final current = i == _currentIndex;
          final baseColor = current
              ? kPlayerAccent
              : Colors.white.withValues(alpha: 0.55);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onSeek == null
                ? null
                : () => widget.onSeek!(line.timeMs / 1000),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  line.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: (current ? 13.5 : 10.5) * s * fontMul,
                    fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                    color: baseColor,
                  ),
                ),
                if (_showTranslation &&
                    line.translation != null &&
                    line.translation!.isNotEmpty)
                  Text(
                    line.translation!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: (current ? 10 : 8.5) * s * fontMul,
                      color: current
                          ? kPlayerAccent.withValues(alpha: 0.75)
                          : Colors.white.withValues(alpha: 0.32),
                    ),
                  ),
              ],
            ),
          );
        },
        ),
      ),
    );
  }
}
