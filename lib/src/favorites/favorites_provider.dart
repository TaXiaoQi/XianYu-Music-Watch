import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FavoriteEntry {
  final String path;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final String? coverPath;
  final String? coverUrl;
  final String? onlineSongJson;
  final String? onlineQuality;
  final String? source;
  final String? onlineInfoJson;
  final int addedAt;

  const FavoriteEntry({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    this.durationMs = 0,
    this.coverPath,
    this.coverUrl,
    this.onlineSongJson,
    this.onlineQuality,
    this.source,
    this.onlineInfoJson,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'title': title,
    'artist': artist,
    'album': album,
    'durationMs': durationMs,
    'coverPath': coverPath,
    'coverUrl': coverUrl,
    'onlineSongJson': onlineSongJson,
    'onlineQuality': onlineQuality,
    'source': source,
    'onlineInfoJson': onlineInfoJson,
    'addedAt': addedAt,
  };

  factory FavoriteEntry.fromJson(Map<String, dynamic> j) => FavoriteEntry(
    path: j['path'] as String? ?? '',
    title: j['title'] as String? ?? '',
    artist: j['artist'] as String? ?? '',
    album: j['album'] as String? ?? '',
    durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
    coverPath: j['coverPath'] as String?,
    coverUrl: j['coverUrl'] as String?,
    onlineSongJson: j['onlineSongJson'] as String?,
    onlineQuality: j['onlineQuality'] as String?,
    source: j['source'] as String?,
    onlineInfoJson: j['onlineInfoJson'] as String?,
    addedAt: (j['addedAt'] as num?)?.toInt() ?? 0,
  );
}

class FavoritesState {
  final List<FavoriteEntry> entries;

  const FavoritesState({this.entries = const []});

  bool contains(String path) => entries.any((e) => e.path == path);
}

class FavoritesManager extends StateNotifier<FavoritesState> {
  FavoritesManager() : super(const FavoritesState()) {
    _load();
  }

  static const _key = 'xianyu_watch_favorites_v1';
  static const _maxEntries = 2000;

  Future<void> _persistQueue = Future<void>.value();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List;
      final entries = list
          .whereType<Map>()
          .map((e) => FavoriteEntry.fromJson(e.cast<String, dynamic>()))
          .where((e) => e.path.isNotEmpty)
          .toList();
      entries.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      if (state.entries.isNotEmpty) return;
      state = FavoritesState(entries: entries);
    } catch (_) {}
  }

  Future<bool> toggle(FavoriteEntry entry) async {
    final exists = state.contains(entry.path);
    final entries = [...state.entries];
    if (exists) {
      entries.removeWhere((e) => e.path == entry.path);
    } else {
      entries.insert(0, entry);
      if (entries.length > _maxEntries)
        entries.removeRange(_maxEntries, entries.length);
    }
    state = FavoritesState(entries: entries);
    await _persist();
    return !exists;
  }

  Future<bool> addIfAbsent(FavoriteEntry entry) async {
    if (state.contains(entry.path)) return false;
    final entries = [entry, ...state.entries];
    if (entries.length > _maxEntries)
      entries.removeRange(_maxEntries, entries.length);
    state = FavoritesState(entries: entries);
    await _persist();
    return true;
  }

  Future<int> removeByPaths(Iterable<String> paths) async {
    final remove = paths.toSet();
    final entries = state.entries
        .where((e) => !remove.contains(e.path))
        .toList();
    if (entries.length == state.entries.length) return 0;
    final removed = state.entries.length - entries.length;
    state = FavoritesState(entries: entries);
    await _persist();
    return removed;
  }

  Future<void> _persist() {
    final snapshot = state.entries;
    _persistQueue = _persistQueue
        .catchError((_) {})
        .then((_) => _write(snapshot))
        .catchError((_) {});
    return _persistQueue;
  }

  Future<void> _write(List<FavoriteEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }
}

final favoritesProvider =
    StateNotifierProvider<FavoritesManager, FavoritesState>(
      (ref) => FavoritesManager(),
    );
