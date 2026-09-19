import 'package:flutter/material.dart';

import '../../core/watch_fit.dart';
import 'play_page_body.dart' show kPlayerAccent;

class PageDots extends StatelessWidget {
  const PageDots({
    super.key,
    required this.count,
    required this.current,
  });

  final int count;
  final int current;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) SizedBox(width: 6 * s),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 4 * s,
            height: 4 * s,
            decoration: BoxDecoration(
              color: i == current
                  ? kPlayerAccent
                  : Colors.white.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(2 * s),
            ),
          ),
        ],
      ],
    );
  }
}
