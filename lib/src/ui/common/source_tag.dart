import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/watch_fit.dart';
import '../../i18n/i18n.dart';
import '../../plugin/plugin_models.dart';
import '../../plugin/plugin_provider.dart';
import '../../plugin/plugin_subscriptions.dart';

/// 付费订阅来源品牌：订阅/插件安装 URL 的 query 带 source=（聆澜/ikun 等）时，
/// 标签直接显示来源品牌名；仅带 key= 无来源名时回落显示「付费」。
const Map<String, String> _kSubSourceBrandAlias = {
  'linglan': '聆澜',
};

String? _brandFromUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  final v = Uri.tryParse(url)?.queryParameters['source']?.trim();
  if (v == null || v.isEmpty) return null;
  return _kSubSourceBrandAlias[v.toLowerCase()] ?? v;
}

bool _urlHasKey(String? url) {
  if (url == null || url.isEmpty) return false;
  final v = Uri.tryParse(url)?.queryParameters['key']?.trim();
  return v != null && v.isNotEmpty;
}

String? _urlHost(String? url) {
  final host = Uri.tryParse(url ?? '')?.host;
  return (host == null || host.isEmpty) ? null : host;
}

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

/// 插件付费订阅标签：优先看插件自身安装 URL 与内置品牌词；否则按「订阅名=插件名」或
/// 「订阅 host=安装 URL host」匹配订阅记录（订阅条目 URL 常不带 key/source）；
/// 都未命中返回 null，按普通音源显示（维持现状）。
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
  final ownHost = _urlHost(p.sourceUrl.isNotEmpty ? p.sourceUrl : p.filePath);
  final pname = p.name.trim();
  for (final sub in subs) {
    final subName = sub.name.trim();
    final matched = (subName.isNotEmpty && subName == pname) ||
        (ownHost != null && _urlHost(sub.url) == ownHost);
    if (!matched) continue;
    final brand = _brandFromUrl(sub.url);
    if (brand != null) return (label: brand, highlight: true);
    if (_urlHasKey(sub.url)) return (label: tr('付费'), highlight: true);
    break;
  }
  return null;
}

/// 付费订阅来源品牌小 pill（金色高亮）；未命中订阅时渲染为空，不占位。
class SourceSubTag extends ConsumerWidget {
  const SourceSubTag({
    super.key,
    required this.pluginId,
    this.onlineSongJson,
  });

  final String? pluginId;
  final String? onlineSongJson;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pid = pluginId ?? pluginIdFromOnlineSongJson(onlineSongJson);
    if (pid == null || pid.isEmpty) return const SizedBox.shrink();
    final plugins = ref.watch(pluginManagerProvider).sources;
    PluginSource? plugin;
    for (final p in plugins) {
      if (p.id == pid) {
        plugin = p;
        break;
      }
    }
    if (plugin == null) return const SizedBox.shrink();
    final tag = pluginSubTag(plugin, ref.watch(pluginSubscriptionsProvider));
    if (tag == null) return const SizedBox.shrink();

    // 付费订阅来源（聆澜/ikun 等品牌或「付费」）用金色高亮，与普通音源区分
    const highlightColor = Color(0xFFE6A23C);
    final s = context.watchScale();
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 5 * s, vertical: 1 * s),
      decoration: BoxDecoration(
        color: highlightColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: highlightColor.withValues(alpha: 0.4),
          width: 0.5,
        ),
      ),
      child: Text(
        tag.label,
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: TextStyle(
          fontSize: 10 * s,
          height: 1.2,
          color: highlightColor,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
