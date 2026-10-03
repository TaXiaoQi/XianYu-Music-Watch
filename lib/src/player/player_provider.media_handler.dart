part of 'player_provider.dart';

class WatchAudioHandler extends asrv.BaseAudioHandler with asrv.SeekHandler {
  PlayerNotifier? _notifier;

  void bindNotifier(PlayerNotifier notifier) {
    _notifier = notifier;
  }

  void syncMediaItem(QueueItem item, double durationSecs) {
    mediaItem.add(
      asrv.MediaItem(
        id: item.path,
        album: item.album.isEmpty ? '弦予音乐' : item.album,
        title: item.title,
        artist: item.artist.isEmpty ? '未知歌手' : item.artist,
        duration: durationSecs > 0
            ? Duration(milliseconds: (durationSecs * 1000).round())
            : null,
        artUri: _artUriFor(item),
      ),
    );
  }

  Uri? _artUriFor(QueueItem item) {
    final local = item.coverPath;
    if (local != null &&
        local.isNotEmpty &&
        !local.startsWith('http') &&
        File(local).existsSync()) {
      return Uri.file(local);
    }
    final url = item.coverUrl;
    if (url != null && url.isNotEmpty) return Uri.tryParse(url);
    return null;
  }

  void syncPlaybackState({
    required bool isPlaying,
    required double positionSecs,
    double speed = 1.0,
  }) {
    playbackState.add(
      asrv.PlaybackState(
        controls: [
          asrv.MediaControl.skipToPrevious,
          if (isPlaying) asrv.MediaControl.pause else asrv.MediaControl.play,
          asrv.MediaControl.skipToNext,
        ],
        systemActions: const {
          asrv.MediaAction.seek,
          asrv.MediaAction.seekForward,
          asrv.MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: asrv.AudioProcessingState.ready,
        playing: isPlaying,
        updatePosition: Duration(milliseconds: (positionSecs * 1000).round()),
        bufferedPosition: Duration(milliseconds: (positionSecs * 1000).round()),
        speed: speed,
      ),
    );
  }

  void clearNowPlaying() {
    mediaItem.add(null);
    playbackState.add(asrv.PlaybackState());
    stop();
  }

  @override
  Future<void> play() => _notifier?.resumeFromSystem() ?? Future.value();

  @override
  Future<void> pause() => _notifier?.pauseFromSystem() ?? Future.value();

  @override
  Future<void> skipToNext() => _notifier?.next() ?? Future.value();

  @override
  Future<void> skipToPrevious() => _notifier?.previous() ?? Future.value();

  @override
  Future<void> seek(Duration position) =>
      _notifier?.seek(position.inMilliseconds / 1000.0) ?? Future.value();

  @override
  Future<void> onTaskRemoved() async {
    await _notifier?.pauseFromSystem();
    await super.stop();
    exit(0);
  }
}
