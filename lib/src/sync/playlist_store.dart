import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../player/player_provider.dart' show QueueItem;

/// 云端歌单下载到腕上后的本机模型（只读消费：点歌单 → 整单入队播放；
/// 歌单的增删改仍在手机/桌面端，腕上每次同步整表刷新）。
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
  });

  bool get isOnline =>
      pluginId.isNotEmpty ||
      path.startsWith('lx://') ||
      path.startsWith('plugin://') ||
      path.startsWith('http://') ||
      path.startsWith('https://');

  /// 云端同步载荷 → 本地模型（与移动端 _songFromSyncPayload 同构，
  /// duration 毫秒 → 秒；在线歌 localPath 置空语义由 isOnline 判定替代）。
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
      };

  /// 直接起播的队列条目：在线歌带插件解析信息，本地歌走文件路径。
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

  const CloudPlaylist({
    required this.cloudId,
    required this.name,
    required this.songs,
  });

  factory CloudPlaylist.fromJson(Map<String, dynamic> j) => CloudPlaylist(
        cloudId: (j['cloudId'] ?? '').toString(),
        name: (j['name'] ?? '未命名歌单').toString(),
        songs: ((j['songs'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => CloudSong.fromJson(e.cast<String, dynamic>()))
            .where((s) => s.path.isNotEmpty)
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'cloudId': cloudId,
        'name': name,
        'songs': songs.map((e) => e.toJson()).toList(),
      };
}

/// 云端歌单本机持久化（SharedPreferences JSON；歌单量级在几十个 ×
/// 每单几百首，整表刷新场景够用）。
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
