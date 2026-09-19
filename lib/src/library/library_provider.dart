import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../core/settings.dart';
import '../player/player_provider.dart';
import '../rust/api.dart';

class Song {
  final String path;
  final String title;
  final String artist;
  final String album;
  final String albumKey;
  final int duration;
  final String format;
  final String? coverThumbPath;
  const Song({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    required this.albumKey,
    required this.duration,
    required this.format,
    this.coverThumbPath,
  });

  factory Song.fromJson(Map<String, dynamic> j) => Song(
    path: j['path'] as String? ?? '',
    title: j['title'] as String? ?? '',
    artist: j['artist'] as String? ?? '',
    album: j['album'] as String? ?? '',
    albumKey: j['album_key'] as String? ?? '',
    duration: (j['duration'] as num?)?.toInt() ?? 0,
    format: j['format'] as String? ?? '',
    coverThumbPath: j['cover_thumb_path'] as String?,
  );

  QueueItem toQueueItem() => QueueItem(
    path: path,
    title: title,
    artist: artist,
    album: album,
    durationMs: duration * 1000,
    coverPath: coverThumbPath,
  );
}

class ArtistInfo {
  final int id;
  final String name;
  final int count;
  final String? avatarPath;
  final String firstSongPath;
  const ArtistInfo({
    required this.id,
    required this.name,
    required this.count,
    this.avatarPath,
    this.firstSongPath = '',
  });

  factory ArtistInfo.fromJson(Map<String, dynamic> j) => ArtistInfo(
    id: (j['id'] as num?)?.toInt() ?? 0,
    name: j['name'] as String? ?? '',
    count: (j['count'] as num?)?.toInt() ?? 0,
    avatarPath: (j['avatar_path'] ?? j['avatarPath']) as String?,
    firstSongPath:
        ((j['first_song_path'] ?? j['firstSongPath']) as String?) ?? '',
  );
}

class AlbumInfo {
  final String key;
  final String name;
  final int count;
  final String artist;
  final String firstSongPath;
  const AlbumInfo({
    required this.key,
    required this.name,
    required this.count,
    required this.artist,
    required this.firstSongPath,
  });

  factory AlbumInfo.fromJson(Map<String, dynamic> j) => AlbumInfo(
    key: j['key'] as String? ?? '',
    name: j['name'] as String? ?? '',
    count: (j['count'] as num?)?.toInt() ?? 0,
    artist: j['artist'] as String? ?? '',
    firstSongPath:
        ((j['first_song_path'] ?? j['firstSongPath']) as String?) ?? '',
  );
}

class FolderNodeData {
  final String name;
  final String path;
  final List<FolderNodeData> children;
  final int childCount;
  final int songCount;
  const FolderNodeData({
    required this.name,
    required this.path,
    required this.children,
    required this.childCount,
    this.songCount = 0,
  });

  factory FolderNodeData.fromJson(Map<String, dynamic> j) => FolderNodeData(
    name: j['name'] as String? ?? '',
    path: j['path'] as String? ?? '',
    children: (j['children'] as List? ?? [])
        .map((e) => FolderNodeData.fromJson(e as Map<String, dynamic>))
        .toList(),
    childCount: ((j['child_count'] ?? j['childCount']) as num?)?.toInt() ?? 0,
    songCount: ((j['song_count'] ?? j['songCount']) as num?)?.toInt() ?? 0,
  );
}

class LibraryState {
  final List<Song> songs;
  final List<String> folders;
  final List<ArtistInfo> artists;
  final List<AlbumInfo> albums;
  final List<FolderNodeData> folderRoot;
  final bool loading;
  final String? error;
  const LibraryState({
    this.songs = const [],
    this.folders = const [],
    this.artists = const [],
    this.albums = const [],
    this.folderRoot = const [],
    this.loading = true,
    this.error,
  });

  LibraryState copyWith({
    List<Song>? songs,
    List<String>? folders,
    List<ArtistInfo>? artists,
    List<AlbumInfo>? albums,
    List<FolderNodeData>? folderRoot,
    bool? loading,
    bool clearError = false,
    String? error,
  }) {
    return LibraryState(
      songs: songs ?? this.songs,
      folders: folders ?? this.folders,
      artists: artists ?? this.artists,
      albums: albums ?? this.albums,
      folderRoot: folderRoot ?? this.folderRoot,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class LibraryNotifier extends StateNotifier<LibraryState> {
  LibraryNotifier(this._ref) : super(const LibraryState()) {
    load();
  }

  final Ref _ref;

  Future<void> load() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final results = await Future.wait<String>([
        getLibrarySongsCached(dbPath: dbPath),
        getLibraryFolders(dbPath: dbPath),
        getLibraryArtistCatalog(dbPath: dbPath),
        getLibraryAlbumCatalog(dbPath: dbPath),
        getLibraryHierarchy(dbPath: dbPath),
      ]);
      final songsJson = results[0];
      final foldersJson = results[1];
      final artistsJson = results[2];
      final albumsJson = results[3];
      final treeJson = results[4];
      final folders = (jsonDecode(foldersJson) as List)
          .map((e) => (e as Map<String, dynamic>)['path'] as String? ?? '')
          .where((p) => p.isNotEmpty)
          .toList();
      state = LibraryState(
        songs: _parseSongs(songsJson),
        folders: folders,
        artists: (jsonDecode(artistsJson) as List)
            .map((e) => ArtistInfo.fromJson(e as Map<String, dynamic>))
            .toList(),
        albums: (jsonDecode(albumsJson) as List)
            .map((e) => AlbumInfo.fromJson(e as Map<String, dynamic>))
            .toList(),
        folderRoot: (jsonDecode(treeJson) as List)
            .map((e) => FolderNodeData.fromJson(e as Map<String, dynamic>))
            .toList(),
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  List<Song> _parseSongs(String json) => (jsonDecode(json) as List)
      .map((e) => Song.fromJson(e as Map<String, dynamic>))
      .toList();

  Future<void> _reloadSongsFromDb() async {
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final songsJson = await getLibrarySongsCached(dbPath: dbPath);
      state = state.copyWith(
        songs: _parseSongs(songsJson),
        loading: false,
        clearError: true,
      );
    } catch (_) {}
  }

  static const _formatExtensions = <String, List<String>>{
    'flac': ['flac'],
    'mp3': ['mp3'],
    'wav': ['wav'],
    'aac': ['aac'],
    'm4a': ['m4a', 'm4b', 'mp4'],
    'ogg': ['ogg', 'oga'],
    'opus': ['opus'],
    'aiff': ['aif', 'aiff'],
    'dsf': ['dsf', 'dff'],
    'ape': ['ape'],
    'wv': ['wv'],
    'qmc': [
      'mgg',
      'mgg0',
      'mggl',
      'mflac',
      'mflac0',
      'qmc0',
      'qmc2',
      'qmc3',
      'qmcflac',
      'qmcogg',
    ],
  };

  Future<int> scanAllFolders() async {
    final dbPath = await _ref.read(dbPathProvider.future);
    final settings = _ref.read(settingsProvider).valueOrNull;
    final selectedFormats = settings?.scanFormats ?? kSupportedScanFormats;
    final minDuration = settings?.libraryMinDurationSeconds ?? 0;

    final allowed = <String>[
      for (final f in selectedFormats) ...(_formatExtensions[f] ?? [f]),
    ];

    final foldersJson = await getLibraryFolders(dbPath: dbPath);
    final folders = (jsonDecode(foldersJson) as List)
        .map((e) => (e as Map<String, dynamic>)['path'] as String? ?? '')
        .where((p) => p.isNotEmpty)
        .toList();

    var total = 0;
    final errors = <String>[];
    for (final folder in folders) {
      try {
        final songsJson = await scanMusicFolder(
          dbPath: dbPath,
          folderPath: folder,
          minimumDurationSeconds: minDuration > 0 ? minDuration : null,
          allowedFormats: allowed,
        );
        total += (jsonDecode(songsJson) as List).length;
      } catch (e) {
        errors.add('$folder: $e');
      }
      await _reloadSongsFromDb();
    }
    await load();
    if (total == 0 && errors.isNotEmpty) {
      throw Exception('扫描失败：${errors.first}');
    }
    return total;
  }

  Future<List<Song>> songsByArtist(String name) async {
    final dbPath = await _ref.read(dbPathProvider.future);
    final pathsJson = await getLibrarySongPathsByArtist(
      dbPath: dbPath,
      artistName: name,
    );
    final paths = (jsonDecode(pathsJson) as List).cast<String>();
    final songsJson = await getLibrarySongsByPaths(
      dbPath: dbPath,
      paths: paths,
    );
    return _parseSongs(songsJson);
  }

  Future<List<Song>> songsByAlbum(String key) async {
    if (!state.loading && state.songs.isNotEmpty) {
      final hit = state.songs.where((s) => s.albumKey == key).toList();
      if (hit.isNotEmpty) return hit;
    }
    final dbPath = await _ref.read(dbPathProvider.future);
    final pathsJson = await getLibrarySongPathsByAlbum(
      dbPath: dbPath,
      albumKey: key,
    );
    final paths = (jsonDecode(pathsJson) as List).cast<String>();
    final songsJson = await getLibrarySongsByPaths(
      dbPath: dbPath,
      paths: paths,
    );
    return _parseSongs(songsJson);
  }

  Future<List<Song>> songsByFolder(String path) async {
    final dbPath = await _ref.read(dbPathProvider.future);
    final pathsJson = await getLibrarySongPathsForFolderView(
      dbPath: dbPath,
      folderPath: path,
      query: null,
      sortMode: 'title',
    );
    final paths = (jsonDecode(pathsJson) as List).cast<String>();
    final songsJson = await getLibrarySongsByPaths(
      dbPath: dbPath,
      paths: paths,
    );
    return _parseSongs(songsJson);
  }

  Future<List<Song>> songsByPaths(List<String> paths) async {
    if (paths.isEmpty) return const [];
    final dbPath = await _ref.read(dbPathProvider.future);
    final songsJson = await getLibrarySongsByPaths(
      dbPath: dbPath,
      paths: paths,
    );
    return _parseSongs(songsJson);
  }

  Future<void> playFrom(int index) async {
    final songs = state.songs;
    if (songs.isEmpty) return;
    await _playList(songs, index);
  }

  Future<void> playList(List<Song> songs, int index) async {
    if (songs.isEmpty) return;
    await _playList(songs, index);
  }

  Future<void> _playList(List<Song> songs, int index) async {
    final items = songs.map((s) => s.toQueueItem()).toList();
    await _ref
        .read(playerProvider.notifier)
        .playQueue(items, startIndex: index);
  }
}

final libraryProvider = StateNotifierProvider<LibraryNotifier, LibraryState>(
  (ref) => LibraryNotifier(ref),
);
