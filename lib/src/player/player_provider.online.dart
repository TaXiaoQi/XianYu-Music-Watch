part of 'player_provider.dart';

extension PlayerNotifierOnline on PlayerNotifier {
  /// 下载解密加密流到临时文件（QMC2 ekey / CENC cek，Rust 侧解密），带
  /// 磁盘缓存与容量清理。与移动端 _decryptUrlToTemp 同构；缓存上限取 8
  /// （腕上存储有限，解密产物为全量明文音频）。
  Future<String> _decryptUrlToTemp(
    String url,
    Map<String, String>? headers, {
    String? ekey,
    String? cek,
  }) async {
    final cached = _decryptPathCache[url];
    if (cached != null) {
      final f = File(cached);
      if (f.existsSync() && f.lengthSync() > 0) return cached;
    }
    final dir = Directory(p.join(
        (await getTemporaryDirectory()).path, 'xianyu_decrypt'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    final list = dir
        .listSync(followLinks: false)
        .whereType<File>()
        .toList()
      ..sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
    for (var i = 0; i < list.length - PlayerNotifier._decryptCacheMax + 1; i++) {
      try {
        list[i].deleteSync();
      } catch (e) {
        AppLog.warn('play', '清理解密缓存旧文件失败: $e');
      }
    }
    final dest = p.join(dir.path,
        'dec_${sha256.convert(utf8.encode(url)).toString().substring(0, 24)}.tmp');
    if (File(dest).existsSync()) {
      try {
        final f = File(dest);
        if (f.lengthSync() > 0) {
          _decryptPathCache[url] = dest;
          return dest;
        }
        f.deleteSync();
      } catch (e) {
        AppLog.warn('play', '处理解密缓存文件失败: $e');
      }
    }
    final plainPath = await downloadOnlineSong(
      url: url,
      destPath: dest,
      ekey: ekey,
      cek: cek,
      headersJson: jsonEncode(headers ?? <String, String>{}),
    );
    _decryptPathCache[url] = plainPath;
    if (_decryptPathCache.length > PlayerNotifier._decryptCacheMax) {
      final key0 = _decryptPathCache.keys.first;
      _decryptPathCache.remove(key0);
    }
    return plainPath;
  }

  /// 按音质解析插件直链：mf 格式走 getMusicFreeUrl 自带降级链（fallback
  /// pause 只试请求档），lx 格式走 getMusicUrl 单档直取。
  Future<ResolvedMediaUrl?> _resolvePluginUrl(
    Map<String, dynamic> songJson,
    String quality,
  ) async {
    final pluginId = songJson['pluginId'] as String? ?? '';
    if (pluginId.isEmpty) return null;
    final format = songJson['format'] as String? ?? 'lx';
    final sourceKey = songJson['source'] as String? ?? '';
    final musicInfo = songJson['musicInfo'] as Map<String, dynamic>? ?? {};
    final engine = await _ref.read(pluginEngineProvider.future);
    final source = await _findPluginSource(engine, pluginId);
    if (source == null) return null;
    if (isMfFormatValue(format)) {
      return engine.getMusicFreeUrl(
        source,
        musicInfo,
        preferred: quality,
        fallback: 'pause',
      );
    }
    final result = await engine.getMusicUrl(source, sourceKey, musicInfo, quality);
    final url = result?['url'] as String?;
    if (result == null || !PlayerNotifier._isPlayableUrl(url)) return null;
    final h = result['headers'];
    return ResolvedMediaUrl(
      url: url!,
      headers: h is Map ? h.cast<String, String>() : null,
      quality: quality,
    );
  }

  Future<ResolvedMediaUrl?> _lxResolveQuality(
      String songInfoJson, String quality) async {
    try {
      final engine = await _ref.read(pluginEngineProvider.future);
      final songInfo = jsonDecode(songInfoJson) as Map<String, dynamic>;
      final resolved = await engine
          .resolveLxUrl(songInfo, quality)
          .timeout(const Duration(seconds: 8));
      final url = resolved?['url'] as String?;
      if (!PlayerNotifier._isPlayableUrl(url)) {
        AppLog.warn('lx', '[lxResolve] 插件 $quality 无结果/非法直链: $url');
        return null;
      }
      return ResolvedMediaUrl(
        url: url!,
        headers: resolved?['headers'] as Map<String, String>?,
      );
    } catch (e) {
      AppLog.error('lx', '[lxResolve] 插件 $quality 异常: $e');
      return null;
    }
  }

  Future<PluginSource?> _findPluginSource(
    PluginEngine engine,
    String pluginId,
  ) async {
    final sources = await engine.store.loadSources();
    for (final s in sources) {
      if (s.id == pluginId) return s;
    }
    return null;
  }
}
