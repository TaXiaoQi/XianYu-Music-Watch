import 'package:shared_preferences/shared_preferences.dart';

/// 插件更新换 id 后的"不再恢复"墓碑。
///
/// 更新会移除旧 id 插件，但云端快照仍存有旧版本脚本；下轮「先拉后推」
/// 的下载会按 id 对比把旧脚本原样恢复回来，旧脚本一跑又自报更新，
/// 弹窗因此反复出现。墓碑命中的云端残留会在下载时跳过恢复并顺手清理；
/// 手动重新导入同内容脚本（同 id）时墓碑自动解除。
class PluginUpdateTombstones {
  PluginUpdateTombstones._();

  static const _key = 'watch_sync_plugin_update_tombstones_v1';

  static Future<Set<String>> _read() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? const []).toSet();
  }

  static Future<void> add(Iterable<String> ids) async {
    final list = ids.where((id) => id.isNotEmpty).toList();
    if (list.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(_key) ?? const []).toSet()..addAll(list);
    await prefs.setStringList(_key, set.toList());
  }

  static Future<void> remove(String id) async {
    if (id.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final set = (prefs.getStringList(_key) ?? const []).toSet()..remove(id);
    await prefs.setStringList(_key, set.toList());
  }

  static Future<bool> contains(String id) async =>
      id.isNotEmpty && (await _read()).contains(id);
}
