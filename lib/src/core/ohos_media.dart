import 'dart:io';

import 'package:flutter/services.dart';

import 'application_logger.dart';

/// 鸿蒙本地音乐通道。
///
/// API 21 SDK 上普通应用没有任何音频枚举 API（mediaLibrary 已移除、
/// photoAccessHelper 仅图片视频、fileAccess 为系统 API），唯一官方途径是
/// 免权限的 AudioViewPicker：原生侧把选中 URI 拷入沙箱 filesDir/music，
/// 之后复用现有 Rust 扫描管线（见 EntryAbility.ets 的 xianyu/media 实现）。
class OhosMedia {
  static const _ch = MethodChannel('xianyu/media');

  /// flutter-ohos 框架同款判定（foundation/_platform_io.dart）
  static bool get isOhos => Platform.operatingSystem == 'ohos';

  /// 确保沙箱音乐目录存在，返回目录路径与已导入文件数
  static Future<({String folder, int count})> musicDir() async {
    final r = await _ch.invokeMethod<Map<Object?, Object?>>('musicDir');
    return (
      folder: r?['folder'] as String? ?? '',
      count: (r?['count'] as num?)?.toInt() ?? 0,
    );
  }

  /// 拉起系统音频选择器并导入；用户取消或选择器不可用时返回 imported=0
  static Future<({String folder, int imported, int total})> pickAudio() async {
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('pickAudio');
      return (
        folder: r?['folder'] as String? ?? '',
        imported: (r?['imported'] as num?)?.toInt() ?? 0,
        total: (r?['total'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException catch (e) {
      // 选择器取消（镜像上多为 cancel）按「未导入」处理，不打扰用户
      AppLog.debug('ohos', 'pickAudio failed: ${e.code} ${e.message}');
      return (folder: '', imported: 0, total: 0);
    }
  }
}
