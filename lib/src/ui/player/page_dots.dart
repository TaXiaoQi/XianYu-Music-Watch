import 'package:flutter/material.dart';

import 'play_page_body.dart' show kPlayerAccent;

/// 页指示圆点（参考网易云手表版）：当前页为主题色小胶囊，其余灰点。
/// 放在 PageView 外层底部居中（round 屏幕贴下缘安全区内）。
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: i == current ? 14 : 4,
            height: 4,
            decoration: BoxDecoration(
              color: i == current
                  ? kPlayerAccent
                  : Colors.white.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ],
    );
  }
}
