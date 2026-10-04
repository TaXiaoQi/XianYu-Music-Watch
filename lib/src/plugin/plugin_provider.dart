import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_http.dart' show appGet;
import '../core/application_logger.dart';
import '../core/db_path.dart';
import '../core/rust_init.dart';
import '../rust/api.dart' as frb;
import 'plugin_engine.dart';
import 'plugin_models.dart';
import 'plugin_store.dart';
import 'plugin_subscriptions.dart';
import 'plugin_user_vars.dart';
import '../i18n/i18n.dart';

const _bilibiliCookieKeys = {
  'SESSDATA',
  'buvid3',
  'buvid4',
  'bili_jct',
  'DedeUserID',
  'DedeUserID__ckMd5',
  'b_nut',
  '_uuid',
  'PVID',
  'sid',
};

const int _maxScriptBytes = 2 * 1024 * 1024;

/// 用户取消在线导入：在请求间隙抛出，静默终止安装流程（对齐移动端语义）。
/// 手表端当前安装期间无取消入口，参数管道已就位，UI 接入时直接传探针即可。
class PluginInstallCancelled implements Exception {
  const PluginInstallCancelled();

  @override
  String toString() => 'PluginInstallCancelled';
}

/// body 读取超时：connectionTimeout/响应头 timeout 只覆盖到收到响应头，
/// body 中途断流时 chunk 流会永久挂起（安装无响应卡死的根因，对齐移动端 bodyTimeout）
const Duration _bodyTimeout = Duration(seconds: 60);

Future<String?> fetchPluginScript(String url, {bool Function()? cancelled}) async {
  try {
    if (cancelled?.call() ?? false) return null;
    final uri = Uri.parse(url);
    final resp = await appGet(uri, headers: const {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': '*/*',
    }).timeout(const Duration(seconds: 20));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      await resp.drain<void>();
      return null;
    }
    final buf = StringBuffer();
    // stream.timeout 为事件间超时：断流 60s 无新 chunk 即抛 TimeoutException，
    // 慢速但不断流的下载不受总时长限制
    await for (final chunk
        in resp.transform(utf8.decoder).timeout(_bodyTimeout)) {
      if (cancelled?.call() ?? false) return null;
      buf.write(chunk);
      if (buf.length > _maxScriptBytes) return null;
    }
    if (cancelled?.call() ?? false) return null;
    return buf.toString();
  } catch (e) {
    AppLog.warn('plugin', '[fetchScript] 获取插件脚本失败: $e');
    return null;
  }
}

final pluginEngineProvider = FutureProvider<PluginEngine>((ref) async {
  await ref.watch(rustInitProvider.future);
  final dataDir = await ref.watch(appDataDirProvider.future);
  final store = PluginStore(dataDir);
  final engine = PluginEngine(dataDir, store);
  engine.userVarsProvider = (pluginId) =>
      ref.read(pluginUserVarValuesProvider.notifier).valuesOf(pluginId);
  try {
    await frbPluginEngineInit(dataDir);
  } catch (e) {
    AppLog.warn('plugin', '插件引擎初始化失败: $e');
  }
  return engine;
});

class PluginListState {
  final List<PluginSource> sources;
  final bool loading;
  final String? error;

  const PluginListState({
    this.sources = const [],
    this.loading = false,
    this.error,
  });

  PluginListState copyWith({
    List<PluginSource>? sources,
    bool? loading,
    String? error,
  }) {
    return PluginListState(
      sources: sources ?? this.sources,
      loading: loading ?? this.loading,
      error: error,
    );
  }
}

class PluginInstallResult {
  final List<String> names;
  final int failCount;
  final List<String> errors;

  const PluginInstallResult({
    this.names = const [],
    this.failCount = 0,
    this.errors = const [],
  });

  bool get success => names.isNotEmpty;
}

class PluginManager extends StateNotifier<PluginListState> {
  PluginManager(this._ref) : super(const PluginListState());

  final Ref _ref;

  PluginEngine? _engine;

  Future<void>? _firstLoad;

  Future<void> _ensureLoaded() => _firstLoad ??= refresh();

  List<PluginSource> get sources => state.sources;

  Future<PluginEngine> _getEngine() async {
    final cached = _engine;
    if (cached != null) return cached;
    final engine = await _ref.read(pluginEngineProvider.future);
    _engine = engine;
    return engine;
  }

  Future<void> refresh() async {
    final engine = await _getEngine();
    final sources = await engine.store.loadSources();
    state = PluginListState(sources: sources);
  }

  Future<PluginSource> installFromScript(
    String script, {
    String? fileName,
    String? nameOverride,
    String? versionOverride,
    String? sourceUrl,
  }) async {
    await _ensureLoaded();
    final engine = await _getEngine();
    final trimmed = script.trim();
    if (trimmed.isEmpty) {
      throw PluginEngineException(tr('插件内容为空'));
    }
    final bytes = utf8.encode(trimmed);
    if (bytes.length > 2 * 1024 * 1024) {
      throw PluginEngineException(tr('插件大小超过 2MB'));
    }

    final isLx = engine.isLxPluginScript(trimmed);
    final isAnime = !isLx && engine.isAnimePluginScript(trimmed);
    final info = engine.parseLxScriptInfo(trimmed);
    final id = sha256.convert(bytes).toString();

    final existing = state.sources.where((s) => s.id == id).toList();
    if (existing.isNotEmpty) {
      return existing.first;
    }

    Map<String, dynamic>? metadata;
    if (isLx) {
      metadata = await engine.loadLx(id, trimmed, scriptInfo: info);
      if (metadata == null) {
        throw PluginEngineException(tr('LX 插件初始化失败'));
      }
    } else {
      metadata = await engine.loadMusicFree(id, trimmed);
      if (metadata == null) {
        throw PluginEngineException(tr('插件加载失败'));
      }
    }

    final path = await engine.store.saveScript(id, trimmed);

    final sources = _extractSources(isLx, metadata);
    final fallbackName = isLx
        ? (info['name'] ?? fileName ?? tr('未知插件'))
        : ((metadata['pluginName'] ?? metadata['platform']) ??
            fileName ??
            tr('未知插件'));
    final mAuthor = isLx
        ? (info['author'] ?? '')
        : (metadata['author']?.toString() ?? '');
    final mVersion =
        versionOverride ??
        (isLx
            ? (info['version'] ?? '')
            : (metadata['version']?.toString() ?? ''));
    final mDesc = isLx
        ? (info['description'] ?? '')
        : (metadata['description']?.toString() ?? '');
    final source = PluginSource(
      id: id,
      name: (nameOverride ?? fallbackName).toString(),
      format: isLx
          ? PluginFormat.lx
          : (isAnime ? PluginFormat.anime : PluginFormat.musicfree),
      version: mVersion,
      author: mAuthor,
      description: mDesc,
      filePath: path,
      sourceUrl: sourceUrl ?? '',
      importedAt: DateTime.now().millisecondsSinceEpoch,
      enabled: true,
      sources: sources,
      sortOrder: state.sources.length,
    );

    final list = [...state.sources, source];
    await engine.store.saveSources(list);
    state = PluginListState(sources: list);
    return source;
  }

  Future<PluginInstallResult> installFromUrl(
    String url, {
    bool Function()? cancelled,
  }) async {
    void checkCancelled() {
      if (cancelled?.call() ?? false) throw const PluginInstallCancelled();
    }

    checkCancelled();
    final script = await fetchPluginScript(url, cancelled: cancelled);
    checkCancelled();
    if (script == null || script.isEmpty) {
      throw PluginEngineException(tr('无法获取插件脚本，请检查 URL 与网络'));
    }

    final batch = _parsePluginList(script);
    if (batch != null && batch.isNotEmpty) {
      final result = await _installBatch(batch, cancelled: cancelled);
      if (result.success) {
        await _recordSubscription(url);
      }
      return result;
    }

    checkCancelled();
    final source = await installFromScript(
      script,
      fileName: url,
      sourceUrl: url,
    );
    await _recordSubscription(url, name: source.name);
    return PluginInstallResult(names: [source.name]);
  }

  Future<void> _recordSubscription(String url, {String? name}) async {
    try {
      await _ref
          .read(pluginSubscriptionsProvider.notifier)
          .addFromInstall(url, name: name);
    } catch (e) {
      AppLog.warn('plugin', '记录插件订阅失败: $e');
    }
  }

  List<Map<String, dynamic>>? _parsePluginList(String content) {
    final trimmed = content.trim();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return null;
    try {
      final json = jsonDecode(trimmed);
      final List? list;
      if (json is List) {
        list = json;
      } else if (json is Map) {
        final v = json['plugins'] ?? json['plugin'];
        list = v is List ? v : null;
      } else {
        list = null;
      }
      if (list == null || list.isEmpty) return null;
      final items = list
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .where((e) => (e['url'] ?? '').toString().isNotEmpty)
          .toList();
      if (items.isEmpty) return null;
      return items;
    } catch (_) {
      // 解析兜底：非插件列表 JSON 按单脚本安装处理
      return null;
    }
  }

  Future<PluginInstallResult> _installBatch(
    List<Map<String, dynamic>> items, {
    bool Function()? cancelled,
  }) async {
    final names = <String>[];
    final errors = <String>[];
    for (final item in items) {
      // 批量导入逐项响应取消（PluginInstallCancelled 向上穿透，
      // 由 installFromUrl 的调用方静默处理）
      if (cancelled?.call() ?? false) throw const PluginInstallCancelled();
      final url = item['url'].toString();
      final label = (item['name'] ?? url).toString();
      try {
        final script = await fetchPluginScript(url, cancelled: cancelled);
        if (cancelled?.call() ?? false) {
          throw const PluginInstallCancelled();
        }
        if (script == null || script.isEmpty) {
          errors.add(tr('{label}: 获取脚本失败', {'label': label}));
          continue;
        }
        final source = await installFromScript(
          script,
          fileName: url,
          nameOverride: item['name']?.toString(),
          versionOverride: item['version']?.toString(),
          sourceUrl: url,
        );
        names.add(source.name);
      } on PluginInstallCancelled {
        // 取消不能被吞成单项失败：向上穿透交给调用方静默处理
        rethrow;
      } on PluginEngineException catch (e) {
        errors.add('$label: ${e.message}');
      } catch (e) {
        AppLog.warn('plugin', '$label 安装失败: $e');
        errors.add(tr('{label}: 安装失败', {'label': label}));
      }
    }
    return PluginInstallResult(
      names: names,
      failCount: items.length - names.length,
      errors: errors,
    );
  }

  Future<void> toggleEnabled(String id) async {
    await _ensureLoaded();
    final engine = await _getEngine();
    final list = state.sources.map((s) {
      if (s.id == id) return s.copyWith(enabled: !s.enabled);
      return s;
    }).toList();
    await engine.store.saveSources(list);
    state = PluginListState(sources: list);

    final source = list.firstWhere((s) => s.id == id);
    if (!source.enabled) {
      await engine.destroy(id);
    }
    engine.bakaManager.clearCache(id);
  }

  Future<void> setUpdateAvailable(String id, bool value) async {
    await _ensureLoaded();
    final changed = state.sources
        .where((s) => s.id == id && s.updateAvailable != value)
        .toList();
    if (changed.isEmpty) return;
    final engine = await _getEngine();
    final list = state.sources
        .map((s) => s.id == id ? s.copyWith(updateAvailable: value) : s)
        .toList();
    await engine.store.saveSources(list);
    state = PluginListState(sources: list);
  }

  Future<void> toggleAll(bool enabled) async {
    await _ensureLoaded();
    final changed = state.sources.where((s) => s.enabled != enabled).toList();
    if (changed.isEmpty) return;
    final engine = await _getEngine();
    final list = state.sources
        .map((s) => s.copyWith(enabled: enabled))
        .toList();
    await engine.store.saveSources(list);
    state = PluginListState(sources: list);
    for (final s in changed) {
      if (!enabled) {
        await engine.destroy(s.id);
      }
      engine.bakaManager.clearCache(s.id);
    }
  }

  Future<void> remove(String id) async {
    await _ensureLoaded();
    final engine = await _getEngine();
    await engine.destroy(id);
    await engine.store.deleteScript(id);
    final list = state.sources.where((s) => s.id != id).toList();
    await engine.store.saveSources(list);
    state = PluginListState(sources: list);
    engine.bakaManager.clearCache(id);
  }

  Future<void> reorder(List<String> orderedIds) async {
    await _ensureLoaded();
    final engine = await _getEngine();
    final current = state.sources;
    final idToIndex = <String, int>{
      for (var i = 0; i < orderedIds.length; i++) orderedIds[i]: i,
    };
    final remapped = current
        .map(
          (s) => idToIndex.containsKey(s.id)
              ? s.copyWith(sortOrder: idToIndex[s.id]!)
              : s,
        )
        .toList();
    final list = sortPluginSources(remapped);
    await engine.store.saveSources(list);
    state = PluginListState(sources: list);
  }

  Future<bool> reload(String id) async {
    final engine = await _getEngine();
    final source = state.sources.where((s) => s.id == id).toList();
    if (source.isEmpty) return false;
    final info = await engine.ensureLoaded(source.first);
    return info != null;
  }

  Future<void> updateScript(String oldId, String newScript) async {
    await _ensureLoaded();
    final oldSource = state.sources.where((s) => s.id == oldId).toList();
    if (oldSource.isEmpty) throw PluginEngineException(tr('插件不存在'));
    final engine = await _getEngine();
    final newSource = await installFromScript(
      newScript,
      nameOverride: oldSource.first.name,
      sourceUrl: oldSource.first.sourceUrl,
    );
    if (newSource.id == oldId) return;
    await engine.destroy(oldId);
    await engine.store.deleteScript(oldId);
    final list = state.sources.where((s) => s.id != oldId).toList();
    await engine.store.saveSources(list);
    state = PluginListState(sources: list);
    engine.bakaManager.clearCache(oldId);
    if (newSource.id != oldId) engine.bakaManager.clearCache(newSource.id);
  }

  Future<List<PluginUserVar>> getUserVars(String pluginId) async {
    final engine = await _getEngine();
    final source = state.sources.where((s) => s.id == pluginId).toList();
    if (source.isEmpty) return const [];
    return getPluginUserVars(engine, source.first);
  }

  Future<void> saveUserVars(String pluginId, Map<String, String> values) async {
    final engine = await _getEngine();
    await _ref
        .read(pluginUserVarValuesProvider.notifier)
        .save(pluginId, values);
    await syncBilibiliCookiesFromVars(pluginId, values);
    await engine.destroy(pluginId);
    final source = state.sources.where((s) => s.id == pluginId).toList();
    if (source.isNotEmpty && source.first.enabled) {
      await engine.ensureLoaded(source.first);
    }
  }

  Future<void> syncBilibiliCookiesFromVars(
    String pluginId,
    Map<String, String> values,
  ) async {
    final isBili = state.sources.any(
      (s) =>
          s.id == pluginId &&
          (s.name == 'bilibili' || s.id.contains('bilibili')),
    );
    if (!isBili) return;
    final cookies = <String, Map<String, String>>{};
    void put(String name, String value) {
      final v = value.trim();
      if (name.isEmpty || v.isEmpty) return;
      cookies[name] = {'value': v, 'domain': 'bilibili.com'};
    }

    for (final e in values.entries) {
      if (_bilibiliCookieKeys.contains(e.key)) put(e.key, e.value);
    }
    for (final raw in values.values) {
      final t = raw.trim();
      if (!(t.startsWith('[') || t.startsWith('{'))) continue;
      try {
        final parsed = jsonDecode(t);
        final items = parsed is List
            ? parsed
            : parsed is Map
            ? parsed.entries.toList()
            : const [];
        for (final it in items) {
          if (it is Map) {
            final name = it['name']?.toString() ?? '';
            final value = it['value'];
            if (name.isNotEmpty && value != null) put(name, value.toString());
          }
        }
      } catch (_) {
        // 解析兜底：非 JSON 的变量值跳过
      }
    }
    if (cookies.isEmpty) return;
    try {
      await frb.pluginEngineStoreImport(
        dataDir: await _ref.read(appDataDirProvider.future),
        payloadJson: jsonEncode({
          'cookies': cookies,
          'storage': <String, String>{},
          'overwriteCookies': true,
        }),
      );
    } catch (e) {
      AppLog.warn('plugin', '同步 B 站 Cookie 失败: $e');
    }
  }

  List<String> _extractSources(bool isLx, Map<String, dynamic>? metadata) {
    if (metadata == null) return const [];
    if (isLx) {
      final sources = metadata['sources'];
      if (sources is Map) {
        return sources.keys.map((k) => k.toString()).toList();
      }
      return const [];
    }
    // anime 聚合插件优先 platforms 列表
    final platforms = metadata['platforms'];
    if (platforms is List && platforms.isNotEmpty) {
      return platforms.map((e) => e.toString()).toList();
    }
    final platform = metadata['platform'];
    if (platform is String && platform.isNotEmpty) return [platform];
    return const [];
  }
}

final pluginManagerProvider =
    StateNotifierProvider<PluginManager, PluginListState>((ref) {
      final manager = PluginManager(ref);
      Future.microtask(manager._ensureLoaded).ignore();
      return manager;
    });

Future<void> frbPluginEngineInit(String dataDir) async {
  await frb.pluginEngineInit(dataDir: dataDir);
}
