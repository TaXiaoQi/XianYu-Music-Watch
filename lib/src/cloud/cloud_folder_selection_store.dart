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
