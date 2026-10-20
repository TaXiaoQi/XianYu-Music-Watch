import 'package:shared_preferences/shared_preferences.dart';

/// 网盘伪音源开关（腕上端）：已绑定网盘在插件管理页独立成条，
/// 关闭后来源列表不含该盘。腕上无排序 UI，仅存关闭集合。
class CloudSourcePrefs {
  static const _disabledKey = 'plugin_cloud_sources_disabled';

  static Future<Set<String>> getDisabled() async {
    final list =
        (await SharedPreferences.getInstance()).getStringList(_disabledKey);
    return list?.toSet() ?? <String>{};
  }

  static Future<void> setDisabled(String providerId, bool disabled) async {
    final sp = await SharedPreferences.getInstance();
    final cur = sp.getStringList(_disabledKey)?.toSet() ?? <String>{};
    if (disabled) {
      cur.add(providerId);
    } else {
      cur.remove(providerId);
    }
    await sp.setStringList(_disabledKey, cur.toList());
  }
}
