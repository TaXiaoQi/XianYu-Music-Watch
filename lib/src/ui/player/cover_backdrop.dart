import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ambient.dart';
import 'player_source.dart' show CoverRef;

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
              Image(
                image: ResizeImage(provider, width: 72),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
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
