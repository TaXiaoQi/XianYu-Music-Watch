import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'plugin_engine.dart';
import 'plugin_models.dart';
import 'plugin_preferences.dart';
import 'plugin_provider.dart';
import 'plugin_subscriptions.dart';

/// 插件更新检查结果。
class PluginUpdateCheckResult {
  final bool hasUpdate;
  final String currentVersion;
  final String newVersion;
  final String? newScript;
  final String updateUrl;

  PluginUpdateCheckResult({
    required this.hasUpdate,
    required this.currentVersion,
    required this.newVersion,
    this.newScript,
    required this.updateUrl,
  });
}

/// 版本号比较：返回 >0 表示 a 更新，<0 表示 b 更新，0 表示相同/独立（不触发更新）。
/// 语义：数字系列只和数字系列比（跨数字版本时后缀不参与，1.0.2-beta1 < 1.0.3）；
/// 同数字版本下，正式版与预发布互相独立（1.0.2-beta1 与 1.0.2 互不视为更新）；
/// 预发布之间按前缀（字母）再序号比较（beta2 > beta1）。
int compareVersions(String a, String b) {
  final pa = _parseVersion(a);
  final pb = _parseVersion(b);
  final maxLen =
      pa.fields.length > pb.fields.length ? pa.fields.length : pb.fields.length;
  for (var i = 0; i < maxLen; i++) {
    final av = i < pa.fields.length ? pa.fields[i] : 0;
    final bv = i < pb.fields.length ? pb.fields[i] : 0;
    if (av != bv) return av.compareTo(bv);
  }
  // 主版本数字相同：正式版与预发布互相独立，视为相同（不触发更新）。
  if (pa.pre == null || pb.pre == null) return 0;
  // 预发布之间：前缀（字母）不同按字母序（alpha < beta < rc），
  // 同前缀比序号，避免 beta10 与 beta9 被字符串比较误判。
  if (pa.preToken != pb.preToken) {
    return pa.preToken.compareTo(pb.preToken);
  }
  return pa.preNum.compareTo(pb.preNum);
}

/// 解析版本号：数字主版本段 + 预发布段（前缀字母 + 序号）。
/// 如 `1.0.2-beta1` → 主版本 [1,0,2]，预发布 `beta` + 1。
class _VersionParts {
  final List<int> fields;
  final String? pre;
  final String preToken;
  final int preNum;
  const _VersionParts(this.fields, this.pre, this.preToken, this.preNum);
}

_VersionParts _parseVersion(String v) {
  var s = v.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  final dash = s.indexOf('-');
  final main = dash >= 0 ? s.substring(0, dash) : s;
  final preStr = dash >= 0 ? s.substring(dash + 1) : null;
  final fields =
      main.split(RegExp(r'[._+]')).map((p) => int.tryParse(p) ?? 0).toList();
  var preToken = '';
  var preNum = 0;
  if (preStr != null) {
    preToken = RegExp(r'^[a-zA-Z]*').firstMatch(preStr)?.group(0) ?? '';
    final num = RegExp(r'(\d+)').firstMatch(preStr);
    preNum = num != null ? int.tryParse(num.group(1)!) ?? 0 : 0;
  }
  return _VersionParts(fields, preStr, preToken, preNum);
}

/// 从 MusicFree/Baka 脚本中提取版本号（不执行脚本）。
/// 优先匹配对象属性形式的 version（前面是 { 或 ,），取最后一个匹配。
String? _extractMusicFreeVersion(String script) {
  final propMatches = RegExp(
          r'[{,]\s*version\s*:\s*[\x27\x22]([^\x27\x22]+)[\x27\x22]')
      .allMatches(script);
  if (propMatches.isNotEmpty) {
    return propMatches.last.group(1);
  }
  final match = RegExp(
          r'version\s*[=:]\s*[\x27\x22]([^\x27\x22]+)[\x27\x22]')
      .firstMatch(script);
  return match?.group(1);
}

/// 从 MusicFree/Baka 脚本中提取 srcUrl（不执行脚本）。
String? _extractMusicFreeSrcUrl(String script) {
  final propMatches = RegExp(
          r'[{,]\s*srcUrl\s*:\s*[\x27\x22]([^\x27\x22]+)[\x27\x22]')
      .allMatches(script);
  if (propMatches.isNotEmpty) {
    return propMatches.last.group(1);
  }
  final match = RegExp(
          r'srcUrl\s*[=:]\s*[\x27\x22]([^\x27\x22]+)[\x27\x22]')
      .firstMatch(script);
  return match?.group(1);
}

/// 插件更新服务：检查更新 + 执行更新（与移动端 plugin_updates.dart 同源）。
class PluginUpdateService {
  final PluginEngine engine;
  final PluginManager manager;

  /// 读取已保存的订阅清单列表。传入后更新检查优先按订阅清单声明的
  /// version 比对（订阅才是权威更新依据）。
  final List<PluginSubscription> Function()? subscriptionsReader;

  PluginUpdateService(this.engine, this.manager, {this.subscriptionsReader});

  /// 订阅清单按 URL 缓存（TTL 5 分钟），避免批量检查时对同一订阅重复请求。
  final Map<String,
          ({int at, List<({String url, String? version, String? name})> items})>
      _subCache = {};
  final Map<String,
          Future<({int at, List<({String url, String? version, String? name})> items})>>
      _subFetchInFlight = {};
  static const int _subCacheTtlMs = 5 * 60 * 1000;

  /// 解析订阅清单内容，提取插件条目。
  List<({String url, String? version, String? name})> _parseSubscriptionItems(
      String content) {
    try {
      final json = jsonDecode(content);
      final list = json is List
          ? json
          : (json is Map
              ? (json['plugins'] ?? json['plugin'] ?? json['sources'])
              : null);
      if (list is! List) return <({String url, String? version, String? name})>[];
      return [
        for (final it in list)
          if (it is Map &&
              it['url'] is String &&
              (it['url'] as String).trim().isNotEmpty)
            (
              url: (it['url'] as String).trim(),
              version: it['version'] is String
                  ? (it['version'] as String).trim()
                  : null,
              name: it['name'] is String ? it['name'] as String : null,
            ),
      ];
    } catch (_) {
      return <({String url, String? version, String? name})>[];
    }
  }

  Future<List<({String url, String? version, String? name})>>
      _getSubscriptionItems(String subUrl) async {
    final cached = _subCache[subUrl];
    if (cached != null &&
        DateTime.now().millisecondsSinceEpoch - cached.at <= _subCacheTtlMs) {
      return cached.items;
    }
    Future<({int at, List<({String url, String? version, String? name})> items})>?
        inFlight = _subFetchInFlight[subUrl];
    if (inFlight == null) {
      inFlight = (() async {
        final content = await _fetchScript(subUrl);
        return (
          at: DateTime.now().millisecondsSinceEpoch,
          items: content == null
              ? <({String url, String? version, String? name})>[]
              : _parseSubscriptionItems(content),
        );
      })();
      _subFetchInFlight[subUrl] = inFlight;
    }
    try {
      final entry = await inFlight;
      _subCache[subUrl] = entry;
      return entry.items;
    } finally {
      _subFetchInFlight.remove(subUrl);
    }
  }

  /// 去掉 query 后的 URL（origin + pathname），用于宽松匹配带缓存指纹的清单条目。
  String _stripUrlQuery(String u) {
    try {
      final uri = Uri.parse(u);
      return '${uri.scheme}://${uri.authority}${uri.path}';
    } catch (_) {
      return u;
    }
  }

  /// 判断插件是否命中订阅清单条目：URL 精确 / 去 query 宽松 / 名称匹配。
  bool _matchSubscriptionItem(
    ({String url, String? version, String? name}) item,
    String filePath,
    String pluginName,
  ) {
    if (item.url == filePath) return true;
    final itemStrip = _stripUrlQuery(item.url);
    final fileStrip = _stripUrlQuery(filePath);
    if (itemStrip.isNotEmpty &&
        fileStrip.isNotEmpty &&
        itemStrip == fileStrip) {
      return true;
    }
    final itemName = item.name;
    if (pluginName.isNotEmpty &&
        itemName != null &&
        itemName.trim() == pluginName.trim()) {
      return true;
    }
    return false;
  }

  /// 在已保存的订阅清单中按 sourceUrl/name 匹配插件。
  /// 命中即返回订阅声明的 version —— 订阅型插件真正的更新依据。
  Future<({String url, String? version, String? name, String subscriptionUrl})?>
      _findSubscriptionPlugin(String filePath, String pluginName) async {
    final subs = subscriptionsReader?.call() ?? const [];
    if (filePath.isEmpty || !filePath.startsWith('http')) return null;
    for (final sub in subs) {
      if (sub.url.isEmpty) continue;
      final items = await _getSubscriptionItems(sub.url);
      for (final item in items) {
        if (_matchSubscriptionItem(item, filePath, pluginName)) {
          return (
            url: item.url,
            version: item.version,
            name: item.name,
            subscriptionUrl: sub.url,
          );
        }
      }
    }
    return null;
  }

  /// 检查单个插件是否有可用更新。
  Future<PluginUpdateCheckResult?> checkPluginUpdate(
      PluginSource source) async {
    // 该插件已标记"跳过版本检查"，直接不检查。
    if (await PluginPreferences.getSkipUpdateCheck(source.id)) {
      return null;
    }

    // 订阅型插件优先走订阅清单：无论 musicfree 还是 lx 格式，只要它来自
    // 订阅，清单里声明的 version 才是真正的更新依据。
    final subPlugin =
        await _findSubscriptionPlugin(source.sourceUrl, source.name);
    if (subPlugin != null && subPlugin.version != null) {
      final hasUpdate = compareVersions(subPlugin.version!, source.version) > 0;
      if (!hasUpdate) {
        return PluginUpdateCheckResult(
          hasUpdate: false,
          currentVersion: source.version,
          newVersion: subPlugin.version!,
          updateUrl: subPlugin.url,
        );
      }
      final newScript = await _fetchScript(subPlugin.url);
      if (newScript != null && newScript.isNotEmpty) {
        return PluginUpdateCheckResult(
          hasUpdate: true,
          currentVersion: source.version,
          newVersion: subPlugin.version!,
          newScript: newScript,
          updateUrl: subPlugin.url,
        );
      }
    }

    String? updateUrl;

    if (source.format == PluginFormat.musicfree) {
      // MusicFree：脚本内 srcUrl 优先（自更新指向），来源 URL 兜底。
      final script = await engine.store.readScript(source.id);
      if (script != null) {
        updateUrl = _extractMusicFreeSrcUrl(script);
      }
      if (updateUrl == null && source.sourceUrl.startsWith('http')) {
        updateUrl = source.sourceUrl;
      }
    } else {
      // LX 插件：优先用来源 URL（脚本自身托管地址）重取比对；本地导入
      // （无来源 URL）才回退解析脚本里的 @homepage。
      if (source.sourceUrl.startsWith('http')) {
        updateUrl = source.sourceUrl;
      } else {
        final script = await engine.store.readScript(source.id);
        if (script != null) {
          final info = engine.parseLxScriptInfo(script);
          if (info['homepage'] != null && info['homepage']!.isNotEmpty) {
            updateUrl = info['homepage'];
          }
        }
      }
    }

    if (updateUrl == null || updateUrl.isEmpty) return null;

    final newScript = await _fetchScript(updateUrl);
    if (newScript == null || newScript.isEmpty) return null;

    // 脚本哈希对比：source.id 就是安装时脚本 SHA256 哈希。
    // 哈希一致说明内容未变化，直接判定无更新。
    if (source.format == PluginFormat.musicfree && source.id.isNotEmpty) {
      final newHash = sha256.convert(utf8.encode(newScript)).toString();
      if (newHash == source.id) {
        return PluginUpdateCheckResult(
          hasUpdate: false,
          currentVersion: source.version,
          newVersion: source.version,
          updateUrl: updateUrl,
        );
      }
    }

    String newVersion = '';
    if (source.format == PluginFormat.musicfree) {
      newVersion = _extractMusicFreeVersion(newScript) ?? '';
    } else {
      newVersion = engine.parseLxScriptInfo(newScript)['version'] ?? '';
    }
    if (newVersion.isEmpty) return null;

    final hasUpdate = compareVersions(newVersion, source.version) > 0;
    return PluginUpdateCheckResult(
      hasUpdate: hasUpdate,
      currentVersion: source.version,
      newVersion: newVersion,
      newScript: hasUpdate ? newScript : null,
      updateUrl: updateUrl,
    );
  }

  /// 执行插件更新：安装新脚本并替换旧插件。
  Future<({bool success, PluginSource? newSource, String message})>
      performPluginUpdate(
          PluginSource source, PluginUpdateCheckResult checkResult) async {
    if (checkResult.newScript == null) {
      return (success: false, newSource: null, message: '无新脚本可更新');
    }
    try {
      final newSource = await manager.installFromScript(
        checkResult.newScript!,
        fileName: checkResult.updateUrl,
        sourceUrl: checkResult.updateUrl,
      );
      // 脚本哈希变化 → 新 ID，替换旧插件；哈希一致时直接返回现有条目。
      if (newSource.id != source.id) {
        await manager.remove(source.id);
      }
      return (
        success: true,
        newSource: newSource,
        message: '${source.name} 已更新到 ${newSource.version}',
      );
    } catch (e) {
      final msg = e is PluginEngineException ? e.message : e.toString();
      return (success: false, newSource: null, message: '更新失败: $msg');
    }
  }

  /// 批量检查所有插件的更新。
  Future<Map<String, PluginUpdateCheckResult>> checkAll() async {
    final results = <String, PluginUpdateCheckResult>{};
    for (final source in manager.sources) {
      try {
        final result = await checkPluginUpdate(source);
        if (result != null) results[source.id] = result;
      } catch (_) {
        // 单个插件检查失败不影响其他
      }
    }
    return results;
  }

  Future<String?> _fetchScript(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers
          .set('User-Agent', 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36');
      req.headers.set('Accept', '*/*');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      return await resp.transform(utf8.decoder).join();
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }
}
