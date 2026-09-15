import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ambient.dart';
import 'player_source.dart' show CoverRef;

/// 全屏封面背景（网易云手表版形态）：当前封面低清解码 + 高斯模糊 + 压暗
/// 渐变，播放页/歌词页/选择页共享一层（横移换页时背景不动）。
///
/// 性能：约 72px 低清解码再拉伸模糊，模糊层近乎零开销；RepaintBoundary
/// 保证前景（进度环等）逐帧重绘不会反复触发模糊重栅格化。
/// 另一处关键：模糊子树按封面缓存（State 字段）。宿主随播放进度逐秒
/// 重建时若重建本 widget，ImageFilter.blur 新实例会让 ImageFiltered 判定
/// 滤镜变更而 markNeedsPaint——全屏模糊每秒重栅格化，表上严重卡顿。
/// ambient 常显时隐藏（OLED 防烧屏 + 常显要求近黑背景），无封面时留黑底。
class CoverBackdrop extends ConsumerStatefulWidget {
  const CoverBackdrop({super.key, required this.cover});

  final CoverRef cover;

  @override
  ConsumerState<CoverBackdrop> createState() => _CoverBackdropState();
}

class _CoverBackdropState extends ConsumerState<CoverBackdrop> {
  String? _cachedKey;
  Widget? _cached;

  @override
  Widget build(BuildContext context) {
    if (ref.watch(ambientModeProvider) || widget.cover.isEmpty) {
      return const SizedBox.expand();
    }
    final key = '${widget.cover.filePath ?? ''}|${widget.cover.url ?? ''}';
    // 同一封面复用缓存子树：build 返回同一实例，Element 走 identical
    // 短路，底层渲染对象完全不动，零重绘。
    if (_cached == null || key != _cachedKey) {
      _cachedKey = key;
      _cached = _buildBackdrop(widget.cover);
    }
    return _cached!;
  }

  Widget _buildBackdrop(CoverRef cover) {
    ImageProvider? provider;
    if (cover.filePath != null && cover.filePath!.isNotEmpty) {
      final f = File(cover.filePath!);
      if (f.existsSync()) provider = FileImage(f);
    }
    provider ??= (cover.url != null && cover.url!.isNotEmpty)
        ? NetworkImage(cover.url!)
        : null;
    if (provider == null) return const SizedBox.expand();

    return SizedBox.expand(
      child: RepaintBoundary(
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 低清解码（ResizeImage 宽 72px）再拉伸：模糊层近乎零开销。
              Image(
                image: ResizeImage(provider, width: 72),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
              // 压暗：整面半透明黑 + 上下缘渐深，保证文字可读。
              Container(color: Colors.black.withValues(alpha: 0.45)),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.0, 0.25, 0.75, 1.0],
                    colors: [
                      Colors.black54,
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black54,
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
