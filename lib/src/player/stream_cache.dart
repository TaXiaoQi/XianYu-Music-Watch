// ignore_for_file: experimental_member_use

import 'dart:io';

import 'package:just_audio/just_audio.dart';

/// 在线播放流缓存（独立播放场景）：基于 just_audio 的 LockCachingAudioSource，
/// 边播边把整曲落到应用缓存目录，重播同一 URL（同一直链）时秒开零流量。
///
/// 预算管理：LRU 按「最近访问时间」淘汰，超出 [budgetMB] 后在起播成功后
/// 异步清理；正在播放的文件不淘汰。直链通常带签名参数，URL 变化即视为
/// 不同条目（与桌面/移动端 Rust 流缓存按 URL 分键的口径一致）。
class StreamCache {
  StreamCache._();

  static final StreamCache instance = StreamCache._();

  /// 缓存预算（MB），0 = 关闭流缓存（回退直连）。默认 200（表端存储有限，
  /// 移动端默认 500 对手表过大）。
  int budgetMB = 200;

  Directory? _dir;
  /// 当前正在播放的缓存文件（预算清理时跳过）。
  File? _activeFile;

  /// 由 player_provider 注入应用缓存目录（getTemporaryDirectory 结果）。
  set rootDir(String path) {
    _dir = Directory('$path/stream_cache');
  }

  Directory? get _root => _dir;

  /// 为直链创建落盘缓存源；关闭（预算 0）/非 http(s)/创建失败时返回 null，
  /// 调用方回退 `_player.setUrl` 直连。
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
      // just_audio 官方缓存源（标记 experimental，当前是唯一无代理依赖的
      // 落盘缓存方案；若未来移除再评估本地代理方案）。
      return LockCachingAudioSource(
        Uri.parse(url),
        cacheFile: f,
        headers: headers ?? const {},
      );
    } catch (_) {
      return null;
    }
  }

  /// 起播结束后调用：解除当前活动文件占用，并按预算异步清理。
  Future<void> settle() async {
    _activeFile = null;
    try {
      await enforceBudget();
    } catch (_) {}
  }

  /// 删除指定 URL 的缓存文件（播放错误自愈：半截/损坏的缓存直接重下）。
  Future<void> evict(String url) async {
    final root = _root;
    if (root == null) return;
    try {
      final f = File('${root.path}/${_keyOf(url)}.audio');
      if (await f.exists()) {
        if (_activeFile?.path == f.path) _activeFile = null;
        await f.delete();
      }
    } catch (_) {}
  }

  /// LRU 清理：按文件访问时间从旧到新删除，直到总大小 ≤ 预算；
  /// 正在播放的文件跳过。
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
      } catch (_) {}
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
      } catch (_) {}
    }
  }

  /// 当前缓存总大小（字节）。
  Future<int> sizeBytes() async {
    final root = _root;
    if (root == null) return 0;
    var total = 0;
    await for (final e in root.list()) {
      if (e is! File || !e.path.endsWith('.audio')) continue;
      try {
        total += (await e.stat()).size;
      } catch (_) {}
    }
    return total;
  }

  /// 清空全部缓存（正在播放的文件除外）。
  Future<void> clearAll() async {
    final root = _root;
    if (root == null) return;
    await for (final e in root.list()) {
      if (e is! File || !e.path.endsWith('.audio')) continue;
      if (_activeFile?.path == e.path) continue;
      try {
        await e.delete();
      } catch (_) {}
    }
  }

  /// URL → 稳定文件名：FNV-1a 32 位 hex + URL 长度后缀。
  /// 不引入 crypto 依赖；对 CDN URL 的区分度足够。
  String _keyOf(String url) {
    var hash = 0x811c9dc5;
    for (var i = 0; i < url.length; i++) {
      hash ^= url.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return '${hash.toRadixString(16).padLeft(8, '0')}-${url.length}';
  }
}
