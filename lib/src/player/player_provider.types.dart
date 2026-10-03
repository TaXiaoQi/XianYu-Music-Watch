part of 'player_provider.dart';

class QueueItem {
  final String path;
  final String title;
  final String artist;
  final String album;
  final int durationMs;
  final String? coverPath;
  final String? onlineSongJson;
  final String? coverUrl;
  final String? onlineQuality;
  final String? source;
  final String? onlineInfoJson;
  final bool fromDailyRecommend;
  const QueueItem({
    required this.path,
    required this.title,
    required this.artist,
    required this.album,
    this.durationMs = 0,
    this.coverPath,
    this.onlineSongJson,
    this.coverUrl,
    this.onlineQuality,
    this.source,
    this.onlineInfoJson,
    this.fromDailyRecommend = false,
  });

  QueueItem copyWith({
    String? coverPath,
    String? coverUrl,
    String? onlineSongJson,
  }) => QueueItem(
    path: path,
    title: title,
    artist: artist,
    album: album,
    durationMs: durationMs,
    coverPath: coverPath ?? this.coverPath,
    coverUrl: coverUrl ?? this.coverUrl,
    onlineSongJson: onlineSongJson ?? this.onlineSongJson,
    onlineQuality: onlineQuality,
    source: source,
    onlineInfoJson: onlineInfoJson,
    fromDailyRecommend: fromDailyRecommend,
  );
}

class PlaybackState {
  final QueueItem? current;
  final List<QueueItem> queue;
  final int queueIndex;
  final bool isPlaying;
  final double position;
  final double duration;
  final int playMode;
  final double speed;
  final String? error;

  /// 当前实际生效的在线音质（探测解析后的真实档位）
  final String? currentQuality;

  /// 音质菜单当前展示的档位（探测推进中会逐步补全）
  final List<String> availableQualities;

  /// 音质菜单探测是否进行中
  final bool qualityMenuProbing;
  const PlaybackState({
    this.current,
    this.queue = const [],
    this.queueIndex = -1,
    this.isPlaying = false,
    this.position = 0,
    this.duration = 0,
    this.playMode = 0,
    this.speed = 1.0,
    this.error,
    this.currentQuality,
    this.availableQualities = const [],
    this.qualityMenuProbing = false,
  });

  PlaybackState copyWith({
    QueueItem? current,
    List<QueueItem>? queue,
    int? queueIndex,
    bool? isPlaying,
    double? position,
    double? duration,
    int? playMode,
    double? speed,
    Object? error = _noChange,
    String? currentQuality,
    List<String>? availableQualities,
    bool? qualityMenuProbing,
  }) {
    return PlaybackState(
      current: current ?? this.current,
      queue: queue ?? this.queue,
      queueIndex: queueIndex ?? this.queueIndex,
      isPlaying: isPlaying ?? this.isPlaying,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      playMode: playMode ?? this.playMode,
      speed: speed ?? this.speed,
      error: error == _noChange ? this.error : error as String?,
      currentQuality: currentQuality ?? this.currentQuality,
      availableQualities: availableQualities ?? this.availableQualities,
      qualityMenuProbing: qualityMenuProbing ?? this.qualityMenuProbing,
    );
  }
}

const Object _noChange = Object();
