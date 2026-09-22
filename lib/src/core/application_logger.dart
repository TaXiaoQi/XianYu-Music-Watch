import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 单条运行日志：时间戳 + 级别 + 分类 + 内容。
class AppLogEntry {
  const AppLogEntry(this.time, this.level, this.category, this.message);

  final DateTime time;

  final String level; // DEBUG / INFO / WARN / ERROR

  final String category;

  final String message;

  /// `MM-dd HH:mm:ss.SSS` 紧凑时间戳。
  String get stamp {
    String p(int v) => v.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');
    return '${p(time.month)}-${p(time.day)} '
        '${p(time.hour)}:${p(time.minute)}:${p(time.second)}.$ms';
  }
}

/// 腕上端统一日志：console 输出（debugPrint）+ 内存环形缓冲。
/// 缓冲用于「推送给手机 / 保存到本地」导出；release 下照常记录，
/// 仅内存开销（上限 [kMaxEntries] 条，超出丢弃最旧）。
class AppLog {
  static const int kMaxEntries = 600;

  static final List<AppLogEntry> _entries = [];

  static List<AppLogEntry> get entries => List.unmodifiable(_entries);

  static bool get isEmpty => _entries.isEmpty;

  /// 清空内存日志（不影响已导出的文件）。
  static void clear() => _entries.clear();

  static void debug(String category, String message) =>
      _add('DEBUG', category, message);
  static void info(String category, String message) =>
      _add('INFO', category, message);
  static void warn(String category, String message) =>
      _add('WARN', category, message);
  static void error(String category, String message) =>
      _add('ERROR', category, message);

  static void _add(String level, String category, String message) {
    debugPrint('[$category] $message');
    _entries.add(AppLogEntry(DateTime.now(), level, category, message));
    if (_entries.length > kMaxEntries) {
      _entries.removeRange(0, _entries.length - kMaxEntries);
    }
  }

  /// 生成可读的导出文本：标题 + 时间 + 条目统计 + 明细，
  /// 格式与移动端日志导出对齐。
  static String exportText() {
    final now = DateTime.now();
    final counts = <String, int>{};
    for (final e in _entries) {
      counts[e.level] = (counts[e.level] ?? 0) + 1;
    }
    final stat = counts.isEmpty
        ? ''
        : '（${counts.entries.map((e) => '${e.key} ${e.value}').join(' / ')}）';
    final buf = StringBuffer()
      ..writeln('弦予音乐 腕上端运行日志')
      ..writeln('导出时间：$now')
      ..writeln('条目数：${_entries.length}$stat')
      ..writeln('─' * 32);
    for (final e in _entries) {
      buf.writeln('${e.stamp} [${e.level}] [${e.category}] ${e.message}');
    }
    return buf.toString();
  }
}

/// 生成带时间戳的日志文件名，与腕上备份同一命名风格。
String watchLogFileName() {
  final now = DateTime.now();
  String p(int v) => v.toString().padLeft(2, '0');
  return 'xianyu-watch-log-'
      '${now.year}-${p(now.month)}-${p(now.day)}'
      '-${p(now.hour)}-${p(now.minute)}-${p(now.second)}.txt';
}

/// 将日志文本写入腕上端文档目录，返回完整路径；失败抛出异常。
Future<String> writeWatchLogFileLocal(String text) async {
  final dir = await getApplicationDocumentsDirectory();
  final folder = Directory('${dir.path}/xianyu_watch_logs');
  if (!folder.existsSync()) await folder.create(recursive: true);
  final file = File('${folder.path}/${watchLogFileName()}');
  await file.writeAsString(text, flush: true);
  return file.path;
}
