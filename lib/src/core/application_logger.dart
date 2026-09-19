import 'package:flutter/foundation.dart';

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
