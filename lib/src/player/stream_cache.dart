
import 'dart:io';

import 'package:just_audio/just_audio.dart';

import '../core/application_logger.dart';

class StreamCache {
  StreamCache._();

  static final StreamCache instance = StreamCache._();

  int budgetMB = 200;

  Directory? _dir;
  File? _activeFile;

  set rootDir(String path) {
    _dir = Directory('$path/stream_cache');
  }

  Directory? get _root => _dir;

  Future<LockCachingAudioSource?> sourceFor(
    String url, {
    Map<String, String>? headers,
  }) async {
    final root = _root;
    if (root == null || budgetMB <= 0) return null;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return null;
    }
    try {
      await root.create(recursive: true);
      final f = File('${root.path}/${_keyOf(url)}.audio');
      _activeFile = f;
      return LockCachingAudioSource(
        Uri.parse(url),
        cacheFile: f,
        headers: headers ?? const {},
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> settle() async {
    _activeFile = null;
    try {
      await enforceBudget();
    } catch (e) {
      AppLog.debug('cache', '清理流缓存超限文件失败: $e');
    }
  }

  Future<void> evict(String url) async {
    final root = _root;
    if (root == null) return;
    try {
      final f = File('${root.path}/${_keyOf(url)}.audio');
      if (await f.exists()) {
        if (_activeFile?.path == f.path) _activeFile = null;
        await f.delete();
      }
    } catch (e) {
      AppLog.warn('cache', '删除流缓存文件失败: $e');
    }
  }

  Future<void> enforceBudget() async {
    final root = _root;
    if (root == null || budgetMB <= 0) return;
    final budgetBytes = budgetMB * 1024 * 1024;
    final entries = <(File, int, DateTime)>[];
    await for (final e in root.list()) {
      if (e is! File || !e.path.endsWith('.audio')) continue;
      try {
        final stat = await e.stat();
        entries.add((e, stat.size, stat.modified));
      } catch (err) {
        AppLog.debug('cache', '读取缓存文件信息失败: $err');
      }
    }
    var total = entries.fold<int>(0, (sum, e) => sum + e.$2);
    if (total <= budgetBytes) return;
    entries.sort((a, b) => a.$3.compareTo(b.$3));
    for (final (file, size, _) in entries) {
      if (total <= budgetBytes) break;
      if (_activeFile?.path == file.path) continue;
      try {
        await file.delete();
        total -= size;
      } catch (err) {
        AppLog.debug('cache', '删除超限缓存文件失败: $err');
      }
    }
  }

  Future<int> sizeBytes() async {
    final root = _root;
    if (root == null) return 0;
    var total = 0;
    await for (final e in root.list()) {
      if (e is! File || !e.path.endsWith('.audio')) continue;
      try {
        total += (await e.stat()).size;
      } catch (err) {
        AppLog.debug('cache', '统计缓存文件大小失败: $err');
      }
    }
    return total;
  }

  Future<void> clearAll() async {
    final root = _root;
    if (root == null) return;
    await for (final e in root.list()) {
      if (e is! File || !e.path.endsWith('.audio')) continue;
      if (_activeFile?.path == e.path) continue;
      try {
        await e.delete();
      } catch (err) {
        AppLog.warn('cache', '清空流缓存失败: $err');
      }
    }
  }

  String _keyOf(String url) {
    var hash = 0x811c9dc5;
    for (var i = 0; i < url.length; i++) {
      hash ^= url.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return '${hash.toRadixString(16).padLeft(8, '0')}-${url.length}';
  }
}
