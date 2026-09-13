import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../core/settings.dart';
import '../player/player_provider.dart';
import '../rust/api.dart';

/// 曲库歌曲（小而美：仅保留播放/展示所需字段，同移动端）。
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

/// 歌手目录项。
class ArtistInfo {
  final int id;
  final String name;
  final int count;
  final String? avatarPath;
  /// 该歌手任一歌曲路径，用于展示歌手封面（内嵌封面）。
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

/// 专辑目录项。
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

/// 文件夹树节点。
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
        childCount:
            ((j['child_count'] ?? j['childCount']) as num?)?.toInt() ?? 0,
        songCount:
            ((j['song_count'] ?? j['songCount']) as num?)?.toInt() ?? 0,
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
    String? error,
  }) {
    return LibraryState(
      songs: songs ?? this.songs,
      folders: folders ?? this.folders,
      artists: artists ?? this.artists,
      albums: albums ?? this.albums,
      folderRoot: folderRoot ?? this.folderRoot,
      loading: loading ?? this.loading,
      error: error ?? this.error,
    );
  }
}

class LibraryNotifier extends StateNotifier<LibraryState> {
  LibraryNotifier(this._ref) : super(const LibraryState()) {
    load();
  }

  final Ref _ref;

  Future<void> load() async {
    state = state.copyWith(loading: true, error: null);
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      // 并行拉取全部曲库数据源（相互独立），首屏等待时长降到「最慢一项」。
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

  /// 起始即只从 DB 读取当前已入库歌曲，刷新到 UI（不动 loading/目录/目录树）。
  /// 用于增量扫描：每扫完一个目录就把该目录已入库结果先展示出来。
  Future<void> _reloadSongsFromDb() async {
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final songsJson = await getLibrarySongsCached(dbPath: dbPath);
      state = state.copyWith(
        songs: _parseSongs(songsJson),
        loading: false,
        error: null,
      );
    } catch (_) {
      // 增量刷新失败不阻断扫描，最终由 load() 兜底。
    }
  }

  /// 格式大类 → 实际扩展名白名单（与 Rust is_ext_allowed 对应）。
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
    // QQ 音乐 QMC 加密格式（播放/解析前按需解密，与桌面端一致）
    'qmc': ['mgg', 'mgg0', 'mggl', 'mflac', 'mflac0', 'qmc0', 'qmc2', 'qmc3', 'qmcflac', 'qmcogg'],
  };

  /// 扫描全部已配置目录，按选定格式白名单入库，返回扫描到的歌曲总数。
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
        // 单个目录失败不阻断其它目录，但记录错误以便暴露给用户。
        errors.add('$folder: $e');
      }
      // 该目录扫描已完成（已入库），立即刷新歌曲到 UI，先见先出。
      await _reloadSongsFromDb();
    }
    await load();
    // 一首都没扫到且有错误时，抛出以便 UI 展示真实原因。
    if (total == 0 && errors.isNotEmpty) {
      throw Exception('扫描失败：${errors.first}');
    }
    return total;
  }

  /// 按歌手取歌曲列表。
  Future<List<Song>> songsByArtist(String name) async {
    final dbPath = await _ref.read(dbPathProvider.future);
    final pathsJson = await getLibrarySongPathsByArtist(
        dbPath: dbPath, artistName: name);
    final paths = (jsonDecode(pathsJson) as List).cast<String>();
    final songsJson =
        await getLibrarySongsByPaths(dbPath: dbPath, paths: paths);
    return _parseSongs(songsJson);
  }

  /// 按专辑 key 取歌曲列表。
  Future<List<Song>> songsByAlbum(String key) async {
    if (!state.loading && state.songs.isNotEmpty) {
      final hit = state.songs.where((s) => s.albumKey == key).toList();
      if (hit.isNotEmpty) return hit;
    }
    final dbPath = await _ref.read(dbPathProvider.future);
    final pathsJson =
        await getLibrarySongPathsByAlbum(dbPath: dbPath, albumKey: key);
    final paths = (jsonDecode(pathsJson) as List).cast<String>();
    final songsJson =
        await getLibrarySongsByPaths(dbPath: dbPath, paths: paths);
    return _parseSongs(songsJson);
  }

  /// 按文件夹取歌曲列表。
  Future<List<Song>> songsByFolder(String path) async {
    final dbPath = await _ref.read(dbPathProvider.future);
    final pathsJson = await getLibrarySongPathsForFolderView(
        dbPath: dbPath, folderPath: path, query: null, sortMode: 'title');
    final paths = (jsonDecode(pathsJson) as List).cast<String>();
    final songsJson =
        await getLibrarySongsByPaths(dbPath: dbPath, paths: paths);
    return _parseSongs(songsJson);
  }

  /// 按路径批量取歌曲（用于收藏等自定义路径集合）。
  Future<List<Song>> songsByPaths(List<String> paths) async {
    if (paths.isEmpty) return const [];
    final dbPath = await _ref.read(dbPathProvider.future);
    final songsJson =
        await getLibrarySongsByPaths(dbPath: dbPath, paths: paths);
    return _parseSongs(songsJson);
  }

  /// 播放全部歌曲（或从指定索引开始）。
  Future<void> playFrom(int index) async {
    final songs = state.songs;
    if (songs.isEmpty) return;
    await _playList(songs, index);
  }

  /// 播放任意歌曲列表。
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
