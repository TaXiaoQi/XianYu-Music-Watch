import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:shared_preferences/shared_preferences.dart';

const kSupportedScanFormats = [
  'flac',
  'mp3',
  'wav',
  'aac',
  'm4a',
  'ogg',
  'opus',
  'aiff',
  'dsf',
  'dff',
  'ape',
  'wv',
  'qmc',
];

List<String> _mergeScanFormats(List<String>? saved) {
  if (saved == null) return kSupportedScanFormats;
  return saved;
}

class AppSettings {
  const AppSettings({
    this.volume = 1.0,
    this.playMode = 0,
    this.playbackSpeed = 1.0,
    this.keepScreenOn = true,
    this.libraryMinDurationSeconds = 0,
    this.scanFormats = kSupportedScanFormats,
    this.watchLinkageEnabled = true,
    this.onlineQuality = '320k',
    this.showLyricsTranslation = true,
    this.lyricFontSize = 1,
    this.lyricOffsetMs = 0,
    this.onlineFailureBehavior = 'autoswitch',
    this.streamCacheSizeMB = 200,
    this.autoResumeAfterInterruption = true,
    this.language = 'system',
  });

  final double volume;
  final int playMode;

  final double playbackSpeed;
  final bool keepScreenOn;
  final int libraryMinDurationSeconds;
  final List<String> scanFormats;

  final bool watchLinkageEnabled;

  final String onlineQuality;

  final bool showLyricsTranslation;

  final int lyricFontSize;

  final int lyricOffsetMs;

  final String onlineFailureBehavior;

  final int streamCacheSizeMB;

  final bool autoResumeAfterInterruption;

  /// 'system' | 'zhCN' | 'zhTW' | 'en'
  final String language;

  AppSettings copyWith({
    double? volume,
    int? playMode,
    double? playbackSpeed,
    bool? keepScreenOn,
    int? libraryMinDurationSeconds,
    List<String>? scanFormats,
    bool? watchLinkageEnabled,
    String? onlineQuality,
    bool? showLyricsTranslation,
    int? lyricFontSize,
    int? lyricOffsetMs,
    String? onlineFailureBehavior,
    int? streamCacheSizeMB,
    bool? autoResumeAfterInterruption,
    String? language,
  }) {
    return AppSettings(
      volume: volume ?? this.volume,
      playMode: playMode ?? this.playMode,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      libraryMinDurationSeconds:
          libraryMinDurationSeconds ?? this.libraryMinDurationSeconds,
      scanFormats: scanFormats ?? this.scanFormats,
      watchLinkageEnabled: watchLinkageEnabled ?? this.watchLinkageEnabled,
      onlineQuality: onlineQuality ?? this.onlineQuality,
      showLyricsTranslation:
          showLyricsTranslation ?? this.showLyricsTranslation,
      lyricFontSize: lyricFontSize ?? this.lyricFontSize,
      lyricOffsetMs: lyricOffsetMs ?? this.lyricOffsetMs,
      onlineFailureBehavior:
          onlineFailureBehavior ?? this.onlineFailureBehavior,
      streamCacheSizeMB: streamCacheSizeMB ?? this.streamCacheSizeMB,
      autoResumeAfterInterruption:
          autoResumeAfterInterruption ?? this.autoResumeAfterInterruption,
      language: language ?? this.language,
    );
  }
}

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  Future<AppSettings>? _buildFuture;

  Future<AppSettings> _current() async {
    final v = state.valueOrNull;
    if (v != null) return v;
    final f = _buildFuture;
    if (f != null) return f;
    return const AppSettings();
  }

  @override
  Future<AppSettings> build() {
    final f = _doBuild();
    _buildFuture = f;
    return f;
  }

  Future<AppSettings> _doBuild() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      volume: prefs.getDouble('volume') ?? 1.0,
      playMode: prefs.getInt('playMode') ?? 0,
      playbackSpeed: prefs.getDouble('playbackSpeed') ?? 1.0,
      keepScreenOn: prefs.getBool('keepScreenOn') ?? true,
      libraryMinDurationSeconds: prefs.getInt('libraryMinDurationSeconds') ?? 0,
      scanFormats: _mergeScanFormats(prefs.getStringList('scanFormats')),
      watchLinkageEnabled: prefs.getBool('watchLinkageEnabled') ?? true,
      onlineQuality: prefs.getString('onlineQuality') ?? '320k',
      showLyricsTranslation: prefs.getBool('showLyricsTranslation') ?? true,
      lyricFontSize: (prefs.getInt('lyricFontSize') ?? 1).clamp(0, 3),
      lyricOffsetMs: (prefs.getInt('lyricOffsetMs') ?? 0).clamp(-100, 100),
      onlineFailureBehavior:
          prefs.getString('onlineFailureBehavior') ?? 'autoswitch',
      streamCacheSizeMB: prefs.getInt('streamCacheSizeMB') ?? 200,
      autoResumeAfterInterruption:
          prefs.getBool('autoResumeAfterInterruption') ?? true,
      language: prefs.getString('language') ?? 'system',
    );
  }

  Future<void> _save(AppSettings next) async {
    state = AsyncData(next);
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setDouble('volume', next.volume),
      prefs.setInt('playMode', next.playMode),
      prefs.setDouble('playbackSpeed', next.playbackSpeed),
      prefs.setBool('keepScreenOn', next.keepScreenOn),
      prefs.setInt('libraryMinDurationSeconds', next.libraryMinDurationSeconds),
      prefs.setStringList('scanFormats', next.scanFormats),
      prefs.setBool('watchLinkageEnabled', next.watchLinkageEnabled),
      prefs.setString('onlineQuality', next.onlineQuality),
      prefs.setBool('showLyricsTranslation', next.showLyricsTranslation),
      prefs.setInt('lyricFontSize', next.lyricFontSize),
      prefs.setInt('lyricOffsetMs', next.lyricOffsetMs),
      prefs.setString('onlineFailureBehavior', next.onlineFailureBehavior),
      prefs.setInt('streamCacheSizeMB', next.streamCacheSizeMB),
      prefs.setBool('autoResumeAfterInterruption',
          next.autoResumeAfterInterruption),
      prefs.setString('language', next.language),
    ]);
  }

  Future<void> setVolume(double v) async =>
      _save((await _current()).copyWith(volume: v));
  Future<void> setPlayMode(int m) async =>
      _save((await _current()).copyWith(playMode: m));
  Future<void> setPlaybackSpeed(double s) async =>
      _save((await _current()).copyWith(playbackSpeed: s));
  Future<void> setKeepScreenOn(bool v) async =>
      _save((await _current()).copyWith(keepScreenOn: v));
  Future<void> setLibraryMinDurationSeconds(int s) async =>
      _save((await _current()).copyWith(libraryMinDurationSeconds: s));
  Future<void> setScanFormats(List<String> v) async =>
      _save((await _current()).copyWith(scanFormats: v));
  Future<void> setWatchLinkageEnabled(bool v) async =>
      _save((await _current()).copyWith(watchLinkageEnabled: v));
  Future<void> setOnlineQuality(String v) async =>
      _save((await _current()).copyWith(onlineQuality: v));
  Future<void> setShowLyricsTranslation(bool v) async =>
      _save((await _current()).copyWith(showLyricsTranslation: v));
  Future<void> setLyricFontSize(int v) async =>
      _save((await _current()).copyWith(lyricFontSize: v.clamp(0, 3)));
  Future<void> setLyricOffsetMs(int v) async =>
      _save((await _current()).copyWith(lyricOffsetMs: v.clamp(-100, 100)));
  Future<void> setOnlineFailureBehavior(String v) async =>
      _save((await _current()).copyWith(onlineFailureBehavior: v));
  Future<void> setStreamCacheSizeMB(int v) async =>
      _save((await _current()).copyWith(streamCacheSizeMB: v.clamp(0, 2000)));

  Future<void> setAutoResumeAfterInterruption(bool v) async =>
      _save((await _current()).copyWith(autoResumeAfterInterruption: v));

  Future<void> setLanguage(String v) async =>
      _save((await _current()).copyWith(language: v));

  Future<void> saveAll(AppSettings next) => _save(next);
}

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
