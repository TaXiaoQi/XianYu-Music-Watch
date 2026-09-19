import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../player/player_provider.dart' show QueueItem;

class CloudSong {
  final String path;
  final String title;
  final String artist;
  final String album;
  final int durationSec;
  final String? coverUrl;
  final String pluginId;
  final String source;
  final String format;
  final Map<String, dynamic> musicInfo;
  final bool addedInApp;

  const CloudSong({
    required this.path,
    required this.title,
    this.artist = '',
    this.album = '',
    this.durationSec = 0,
    this.coverUrl,
    this.pluginId = '',
    this.source = '',
    this.format = '',
    this.musicInfo = const {},
    this.addedInApp = false,
  });

  bool get isOnline =>
      pluginId.isNotEmpty ||
      path.startsWith('lx://') ||
      path.startsWith('plugin://') ||
      path.startsWith('http://') ||
      path.startsWith('https://');

  factory CloudSong.fromJson(Map<String, dynamic> j) {
    final rawPath = j['localPath'] as String? ?? j['path'] as String? ?? '';
    final musicInfo = j['musicInfo'] is Map
        ? (j['musicInfo'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    return CloudSong(
      path: rawPath,
      title: (j['title'] ?? j['name'] ?? '').toString(),
      artist: (j['artist'] ?? '').toString(),
      album: (j['album'] ?? '').toString(),
      durationSec: (((j['duration'] as num?) ?? 0) / 1000).round(),
      coverUrl: (j['coverUrl'] as String?)?.isNotEmpty == true
          ? j['coverUrl'] as String
          : null,
      pluginId: (j['pluginId'] ?? '').toString(),
      source: (j['source'] ?? '').toString(),
      format: (j['format'] ?? '').toString(),
      musicInfo: musicInfo,
      addedInApp: j['addedInApp'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'title': title,
        'artist': artist,
        'album': album,
        'duration': durationSec,
        'coverUrl': coverUrl,
        'pluginId': pluginId,
        'source': source,
        'format': format,
        'musicInfo': musicInfo,
        'addedInApp': addedInApp,
      };

  QueueItem toQueueItem() {
    String? onlineSongJson;
    if (isOnline && pluginId.isNotEmpty) {
      onlineSongJson = jsonEncode({
        'pluginId': pluginId,
        'format': format.isEmpty ? 'lx' : format,
        'source': source,
        'musicInfo': musicInfo,
      });
    }
    return QueueItem(
      path: path,
      title: title,
      artist: artist,
      album: album,
      durationMs: durationSec * 1000,
      coverUrl: coverUrl,
      source: source.isEmpty ? null : source,
      onlineSongJson: onlineSongJson,
    );
  }
}

class CloudPlaylist {
  final String cloudId;
  final String name;
  final List<CloudSong> songs;
  final String? sourcePluginId;
  final String? sourceUrl;
  final Map<String, dynamic>? sourceRaw;

  const CloudPlaylist({
    required this.cloudId,
    required this.name,
    required this.songs,
    this.sourcePluginId,
    this.sourceUrl,
    this.sourceRaw,
  });

  bool get hasSource =>
      (sourcePluginId ?? '').isNotEmpty ||
      (sourceUrl ?? '').isNotEmpty ||
      (sourceRaw ?? {}).isNotEmpty;

  CloudPlaylist copyWith({String? name, List<CloudSong>? songs}) =>
      CloudPlaylist(
        cloudId: cloudId,
        name: name ?? this.name,
        songs: songs ?? this.songs,
        sourcePluginId: sourcePluginId,
        sourceUrl: sourceUrl,
        sourceRaw: sourceRaw,
      );

  factory CloudPlaylist.fromJson(Map<String, dynamic> j) {
    final raw = j['sourceRaw'];
    return CloudPlaylist(
      cloudId: (j['cloudId'] ?? '').toString(),
      name: (j['name'] ?? '未命名歌单').toString(),
      sourcePluginId: (j['sourcePluginId'] as String?)?.isNotEmpty == true
          ? j['sourcePluginId'] as String
          : null,
      sourceUrl: (j['sourceUrl'] as String?)?.isNotEmpty == true
          ? j['sourceUrl'] as String
          : null,
      sourceRaw: raw is Map ? raw.cast<String, dynamic>() : null,
      songs: ((j['songs'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => CloudSong.fromJson(e.cast<String, dynamic>()))
          .where((s) => s.path.isNotEmpty)
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'cloudId': cloudId,
        'name': name,
        'songs': songs.map((e) => e.toJson()).toList(),
        if (sourcePluginId != null) 'sourcePluginId': sourcePluginId,
        if (sourceUrl != null) 'sourceUrl': sourceUrl,
        if (sourceRaw != null) 'sourceRaw': sourceRaw,
      };
}

class CloudPlaylistStore {
  static const _key = 'xianyu_watch_cloud_playlists_v1';

  static Future<List<CloudPlaylist>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => CloudPlaylist.fromJson(e.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveAll(List<CloudPlaylist> playlists) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(playlists.map((e) => e.toJson()).toList()));
  }
}
