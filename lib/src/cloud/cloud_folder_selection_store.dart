// 网盘已选文件夹存储（每账号多路径），移植自移动端
// lib/src/cloud/cloud_folder_selection_store.dart。
//
// 路径不是敏感数据，直接明文 SecureStore JSON：
// key `xianyu.cloud.folder_sel.v1`，结构
// `{"<providerId>|<accountId>": [path, ...]}`。
//
// 路径语义与浏览页一致：path 型盘存绝对路径，id 型盘存目录 id
//（取「条目 path 非空且异于当前目录时用 path，否则用 id」）。

import 'dart:convert';

import '../core/application_logger.dart';
import '../core/secure_store.dart';

const String _kFolderSelKey = 'xianyu.cloud.folder_sel.v1';

String cloudFolderSelKey(String providerId, String accountId) =>
    '$providerId|$accountId';

/// 已选目录的名称缓存（纯展示用，移植自移动端）：id 型盘的存储键是
/// 目录 id 串，无法从键还原可读名。腕上无选择器 UI，本地不产生新名称，
/// 仅作为同步中转承载：随凭据密封串（`__fnames__` 保留键）导入合并、
/// 导出携带，供三端互传；后续若加选择器 UI 可直接复用。
class CloudFolderNameCache {
  CloudFolderNameCache._();

  static final CloudFolderNameCache instance = CloudFolderNameCache._();

  static const String _kNamesKey = 'xianyu.cloud.folder_names.v1';

  Map<String, Map<String, String>>? _cache;

  Future<Map<String, Map<String, String>>> _ensureLoaded() async {
    if (_cache != null) return _cache!;
    final map = <String, Map<String, String>>{};
    try {
      final stored = await SecureStore.read(_kNamesKey);
      if (stored != null && stored.isNotEmpty) {
        final raw = jsonDecode(stored) as Map<String, dynamic>;
        raw.forEach((k, v) {
          if (v is Map) {
            map[k] = v.map((kk, vv) => MapEntry('$kk', '$vv'));
          }
        });
      }
    } catch (e) {
      AppLog.warn('cloud', '网盘已选目录名称缓存读取失败: $e');
    }
    _cache = map;
    return map;
  }

  Future<void> _persist() async {
    final map = _cache;
    if (map == null) return;
    try {
      await SecureStore.write(_kNamesKey, jsonEncode(map));
    } catch (e) {
      AppLog.warn('cloud', '网盘已选目录名称缓存写入失败: $e');
    }
  }

  /// 全量导出（跨设备同步随凭据密封串携带）。
  Future<Map<String, Map<String, String>>> allNames() async {
    final map = await _ensureLoaded();
    if (map.isEmpty) return const {};
    return map.map((k, v) => MapEntry(k, Map<String, String>.of(v)));
  }

  /// 并集合并云端名称（不动本地已有条目）。返回是否发生变化。
  Future<bool> mergeNames(Map<String, Map<String, String>> incoming) async {
    if (incoming.isEmpty) return false;
    final map = await _ensureLoaded();
    var changed = false;
    incoming.forEach((k, v) {
      if (k.isEmpty || v.isEmpty) return;
      final bucket = map[k] ??= <String, String>{};
      v.forEach((key, name) {
        if (key.isEmpty || name.isEmpty) return;
        if (bucket[key] != name) {
          bucket[key] = name;
          changed = true;
        }
      });
    });
    if (!changed) return false;
    await _persist();
    return true;
  }
}

class CloudFolderSelectionStore {
  CloudFolderSelectionStore._();

  static final CloudFolderSelectionStore instance =
      CloudFolderSelectionStore._();

  /// 目录选择落盘后的变更通知（sync 层注册做云端自动上传；未注册时为
  /// no-op）。同步合并会触发，回调内自行处理防抖。
  static void Function()? onPersisted;

  Map<String, List<String>>? _cache;

  Future<Map<String, List<String>>> _ensureLoaded() async {
    if (_cache != null) return _cache!;
    final map = <String, List<String>>{};
    try {
      final stored = await SecureStore.read(_kFolderSelKey);
      if (stored != null && stored.isNotEmpty) {
        final raw = jsonDecode(stored) as Map<String, dynamic>;
        raw.forEach((k, v) {
          if (v is List) {
            map[k] = v.whereType<String>().toList();
          }
        });
      }
    } catch (e) {
      AppLog.warn('cloud', '网盘已选文件夹读取失败: $e');
    }
    _cache = map;
    return map;
  }

  Future<void> _persist() async {
    final map = _cache;
    if (map == null) return;
    try {
      await SecureStore.write(_kFolderSelKey, jsonEncode(map));
    } catch (e) {
      AppLog.warn('cloud', '网盘已选文件夹写入失败: $e');
    }
  }

  /// 某账号已选文件夹路径列表（未选过返回空）。
  Future<List<String>> pathsFor(String providerId, String accountId) async {
    final map = await _ensureLoaded();
    return map[cloudFolderSelKey(providerId, accountId)] ?? const [];
  }

  /// 全量导出（跨设备同步随凭据密封串携带）。
  Future<Map<String, List<String>>> allPaths() async {
    final map = await _ensureLoaded();
    return map.map((k, v) => MapEntry(k, List<String>.of(v)));
  }

  /// 合并云端目录选择（并集去重，不动本地已有条目）。
  /// 空串路径合法：id 型盘（迅雷/PikPak）根目录 id 为空串。
  Future<void> mergePaths(Map<String, List<String>> incoming) async {
    if (incoming.isEmpty) return;
    final map = await _ensureLoaded();
    var changed = false;
    incoming.forEach((k, v) {
      final paths = v.whereType<String>().toList();
      if (paths.isEmpty) return;
      final merged = [...?map[k]];
      final before = merged.length;
      for (final p in paths) {
        if (!merged.contains(p)) merged.add(p);
      }
      if (merged.length != before) {
        map[k] = merged;
        changed = true;
      }
    });
    if (!changed) return;
    await _persist();
    onPersisted?.call();
  }
}
