import 'package:flutter/material.dart';

/// 手表屏等比显示适配（抄网易云手表版观感：一切尺寸随屏径等比缩放）。
///
/// Flutter 的 dp 只保证「密度无关」；但表径的 dp 档位跨度大（约 200–290dp），
/// 固定 dp 值在不同表上比例失调（小表溢出发挤、大表松散）。这里以 200dp
/// 为设计基准（网易云式大字号大图标的紧凑基准）：所有视觉尺寸 = 设计值 ×
/// [watchScale]。设计基准刻意低于主流圆表的 233dp（466px @ 320dpi），
/// 使主流表上实际渲染约 +16%，与网易云「界面元素顶满、字大」的显示逻辑
/// 对齐；换更小/更大的表仍整体等比，观感比例一致。
/// 系数钳制 0.85–1.30，避免极端屏径下过小/过大。
extension WatchFitContext on BuildContext {
  /// 全 UI 统一等比缩放系数（设计基准 200dp，主流 233dp 表 ≈ 1.16）。
  double watchScale() =>
      (MediaQuery.of(this).size.shortestSide / 200).clamp(0.85, 1.30);
}
