import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

/// 手表屏形（圆表 / 方表）：运行时经平台通道探测一次（Android 官方判定
/// `resources.configuration.isScreenRound`），UI 据此切换两套布局——
/// 圆屏阶梯列表（行两端被圆弧裁切，逐级收窄 + 右缘弧形指示）/
/// 方屏全宽列表（四角不裁，行等大全宽 + 直线滚动条）。
///
/// 探测在 main() 首帧前 await 完成（通道往返 <10ms），此后形状运行时
/// 不变，widget 直接读静态值无需响应式；探测失败兜底按圆表（现有 UI
/// 即圆屏基准，向后兼容）。
class WatchScreenShape {
  static const _ch = MethodChannel('xianyu/screen_shape');

  /// true = 圆表；false = 方表。初始按圆表，probe 后落定。
  static bool isRound = true;

  /// 首帧前调用一次；异常静默兜底圆表。
  static Future<void> probe() async {
    try {
      final r = await _ch.invokeMethod<bool>('isRound');
      if (r != null) isRound = r;
    } catch (_) {
      // 非 Android 宿主 / 通道缺失：保持圆表兜底。
    }
    // 通道误报兜底：ohos Flutter 对未注册通道可能 resolve 为 false（而非抛
    // MissingPluginException），圆表分辨率必为 1:1（如 Watch 3 466×466），
    // 据此纠正误判；方表分辨率非 1:1（如 Watch Fit 456×280）不受影响。
    if (!isRound) {
      final views = WidgetsBinding.instance.platformDispatcher.views;
      if (views.isNotEmpty) {
        final s = views.first.physicalSize;
        if (s.width > 0 && s.height > 0 &&
            ((s.width / s.height) - 1).abs() < 0.08) {
          isRound = true;
        }
      }
    }
  }
}

extension WatchShapeContext on BuildContext {
  /// 当前设备是否圆表（方表返回 false；探测失败兜底圆表）。
  bool get isRoundWatch => WatchScreenShape.isRound;
}
