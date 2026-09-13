import 'package:flutter/foundation.dart';

/// 腕上端极简日志（对齐移动端 AppLog 的调用面，落 debugPrint）。
class AppLog {
  static void debug(String category, String message) =>
      debugPrint('[$category] $message');
  static void info(String category, String message) =>
      debugPrint('[$category] $message');
  static void warn(String category, String message) =>
      debugPrint('[$category] $message');
  static void error(String category, String message) =>
      debugPrint('[$category] $message');
}
