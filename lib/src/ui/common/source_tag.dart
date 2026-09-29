import 'dart:convert';

import '../../i18n/i18n.dart';
import '../../plugin/plugin_models.dart';
import '../../plugin/plugin_subscriptions.dart';

/// 付费订阅来源品牌：仅识别别名表中的已知付费品牌（linglan→聆澜）；
/// 插件名/作者内置品牌词（聆澜/ikun）辅助识别；仅带 key= 无来源名时回落「付费」。
/// source= 的未知值不再视为品牌——公开订阅也会用 source= 传自定义标识。
const Map<String, String> _kSubSourceBrandAlias = {
  'linglan': '聆澜',
};

String? _brandFromUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  final v = _sourceValue(url);
  if (v == null) return null;
  return _kSubSourceBrandAlias[v.toLowerCase()];
}

bool _urlHasKey(String? url) {
  if (url == null || url.isEmpty) return false;
  final v = Uri.tryParse(url)?.queryParameters['key']?.trim();
  return v != null && v.isNotEmpty;
}

String? _sourceValue(String? url) {
  if (url == null || url.isEmpty) return null;
  final v = Uri.tryParse(url)?.queryParameters['source']?.trim();
  return (v == null || v.isEmpty) ? null : v;
}

/// 订阅 URL 的 source 常带 .json 后缀（如 quandouyao.json），插件安装 URL 是去后缀的
/// 标识（如 quandouyao）——归属判定前统一去掉 .json 再比较
String _normSourceValue(String v) =>
    v.toLowerCase().replaceFirst(RegExp(r'\.json$'), '');

String? pluginIdFromOnlineSongJson(String? onlineSongJson) {
  if (onlineSongJson == null || onlineSongJson.isEmpty) return null;
  try {
    final json = jsonDecode(onlineSongJson) as Map<String, dynamic>;
    return json['pluginId'] as String?;
  } catch (_) {
    return null;
  }
}

/// 插件名/作者内置品牌词（ikun 插件 URL 只有 key 无 source，靠名称识别）
const List<(String, String)> _kSubSourceBrandKeywords = [
  ('聆澜', '聆澜'),
  ('ikun', 'ikun'),
];

String? _brandFromIdentity(String name, String author) {
  final hay = '${name.trim()} ${author.trim()}'.toLowerCase();
  if (hay.trim().isEmpty) return null;
  for (final (kw, brand) in _kSubSourceBrandKeywords) {
    if (hay.contains(kw)) return brand;
  }
  return null;
}

/// 插件付费订阅标签：优先看插件自身安装 URL/来源订阅 URL 与内置品牌词；插件 URL 带
/// source 标识时按 source 值精确归属订阅——同一台主机可挂多个订阅（公共+付费并存），
/// 禁止按 host/名称猜归属；都未命中返回 null，按普通音源显示。
({String label, bool highlight})? pluginSubTag(
  PluginSource p,
  List<PluginSubscription> subs,
) {
  final own = _brandFromUrl(p.sourceUrl) ?? _brandFromUrl(p.filePath);
  if (own != null) return (label: own, highlight: true);
  final named = _brandFromIdentity(p.name, p.author);
  if (named != null) return (label: named, highlight: true);
  if (_urlHasKey(p.sourceUrl) || _urlHasKey(p.filePath)) {
    return (label: tr('付费'), highlight: true);
  }
  final ownSrc = _sourceValue(p.filePath) ?? _sourceValue(p.sourceUrl);
  if (ownSrc == null) return null;
  final ownKey = _normSourceValue(ownSrc);
  for (final sub in subs) {
    final subSrc = _sourceValue(sub.url);
    if (subSrc == null || _normSourceValue(subSrc) != ownKey) continue;
    final brand = _brandFromUrl(sub.url);
    if (brand != null) return (label: brand, highlight: true);
    if (_urlHasKey(sub.url)) return (label: tr('付费'), highlight: true);
    break;
  }
  return null;
}

/// 插件管理页等直接持有 PluginSource 的场景使用
({String label, bool highlight})? pluginSubTagInfo(
  PluginSource p,
  List<PluginSubscription> subs,
) {
  final tag = pluginSubTag(p, subs);
  if (tag == null) return null;
  // 付费品牌标签加「付费」前缀（付费聆澜/付费ikun）；回落「付费」不重复前缀
  final paid = tr('付费');
  if (tag.label == paid || tag.label == '付费') return tag;
  return (label: '$paid${tag.label}', highlight: tag.highlight);
}

