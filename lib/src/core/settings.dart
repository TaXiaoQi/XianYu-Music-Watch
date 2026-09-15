import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:shared_preferences/shared_preferences.dart';

/// 支持的扫描格式大类（与 Rust is_ext_allowed 对应，同移动端）。
const kSupportedScanFormats = ['flac', 'mp3', 'wav', 'aac', 'm4a', 'ogg', 'opus', 'aiff', 'dsf', 'dff', 'ape', 'wv', 'qmc'];

/// 已持久化的扫描格式与支持列表取并集（后补格式自动启用），未持久化时用全量默认。
List<String> _mergeScanFormats(List<String>? saved) {
  if (saved == null) return kSupportedScanFormats;
  return {...saved, ...kSupportedScanFormats}.toList(growable: false);
}

/// 腕上版设置（移动端 settings.dart 裁剪：仅保留播放/扫描/联动项）。
class AppSettings {
  const AppSettings({
    this.volume = 1.0,
    this.playMode = 0, // 0 顺序(列表循环) 1 单曲循环 2 随机
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
  });

  final double volume;
  final int playMode;

  /// 倍速（独立播放，跨会话保留；联动模式由手机端自控）。
  final double playbackSpeed;
  final bool keepScreenOn;
  final int libraryMinDurationSeconds;
  final List<String> scanFormats;

  /// 手机联动总开关（对齐移动端 watchLinkageEnabled，移动端默认开启）。
  final bool watchLinkageEnabled;

  /// 在线播放请求音质档（320k/flac 等，对齐移动端 onlineQuality 默认值）。
  final String onlineQuality;

  /// 歌词翻译显示开关（同移动端 showLyricsTranslation）。
  final bool showLyricsTranslation;

  /// 歌词字号档位 0-3（小/标准/大/特大，同移动端 lyricFontSize，默认标准）。
  final int lyricFontSize;

  /// 歌词同步偏移毫秒（-100~100，正=歌词更晚，同移动端 lyricOffsetMs）。
  final int lyricOffsetMs;

  /// 在线起播失败行为（同移动端 onlineFailureBehavior）：
  /// 'autoswitch' 自动换源重试 / 'stop' 停止。
  final String onlineFailureBehavior;

  /// 在线流缓存预算 MB（0 = 关闭；表端默认 200，移动端键名一致）。
  final int streamCacheSizeMB;

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
    );
  }
}

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      volume: prefs.getDouble('volume') ?? 1.0,
      playMode: prefs.getInt('playMode') ?? 0,
      playbackSpeed: prefs.getDouble('playbackSpeed') ?? 1.0,
      keepScreenOn: prefs.getBool('keepScreenOn') ?? true,
      libraryMinDurationSeconds:
          prefs.getInt('libraryMinDurationSeconds') ?? 0,
      // 与移动端同 key：后补格式与支持列表取并集，保证新格式直接生效。
      scanFormats: _mergeScanFormats(prefs.getStringList('scanFormats')),
      watchLinkageEnabled: prefs.getBool('watchLinkageEnabled') ?? true,
      onlineQuality: prefs.getString('onlineQuality') ?? '320k',
      showLyricsTranslation: prefs.getBool('showLyricsTranslation') ?? true,
      lyricFontSize: (prefs.getInt('lyricFontSize') ?? 1).clamp(0, 3),
      lyricOffsetMs: (prefs.getInt('lyricOffsetMs') ?? 0).clamp(-100, 100),
      onlineFailureBehavior:
          prefs.getString('onlineFailureBehavior') ?? 'autoswitch',
      streamCacheSizeMB: prefs.getInt('streamCacheSizeMB') ?? 200,
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
      prefs.setInt(
          'libraryMinDurationSeconds', next.libraryMinDurationSeconds),
      prefs.setStringList('scanFormats', next.scanFormats),
      prefs.setBool('watchLinkageEnabled', next.watchLinkageEnabled),
      prefs.setString('onlineQuality', next.onlineQuality),
      prefs.setBool('showLyricsTranslation', next.showLyricsTranslation),
      prefs.setInt('lyricFontSize', next.lyricFontSize),
      prefs.setInt('lyricOffsetMs', next.lyricOffsetMs),
      prefs.setString('onlineFailureBehavior', next.onlineFailureBehavior),
      prefs.setInt('streamCacheSizeMB', next.streamCacheSizeMB),
    ]);
  }

  Future<void> setVolume(double v) =>
      _save((state.valueOrNull ?? const AppSettings()).copyWith(volume: v));
  Future<void> setPlayMode(int m) =>
      _save((state.valueOrNull ?? const AppSettings()).copyWith(playMode: m));
  Future<void> setPlaybackSpeed(double s) => _save(
      (state.valueOrNull ?? const AppSettings()).copyWith(playbackSpeed: s));
  Future<void> setKeepScreenOn(bool v) =>
      _save((state.valueOrNull ?? const AppSettings()).copyWith(keepScreenOn: v));
  Future<void> setLibraryMinDurationSeconds(int s) => _save(
      (state.valueOrNull ?? const AppSettings())
          .copyWith(libraryMinDurationSeconds: s));
  Future<void> setScanFormats(List<String> v) =>
      _save((state.valueOrNull ?? const AppSettings()).copyWith(scanFormats: v));
  Future<void> setWatchLinkageEnabled(bool v) => _save(
      (state.valueOrNull ?? const AppSettings())
          .copyWith(watchLinkageEnabled: v));
  Future<void> setOnlineQuality(String v) =>
      _save((state.valueOrNull ?? const AppSettings()).copyWith(onlineQuality: v));
  Future<void> setShowLyricsTranslation(bool v) => _save(
      (state.valueOrNull ?? const AppSettings())
          .copyWith(showLyricsTranslation: v));
  Future<void> setLyricFontSize(int v) => _save(
      (state.valueOrNull ?? const AppSettings())
          .copyWith(lyricFontSize: v.clamp(0, 3)));
  Future<void> setLyricOffsetMs(int v) => _save(
      (state.valueOrNull ?? const AppSettings())
          .copyWith(lyricOffsetMs: v.clamp(-100, 100)));
  Future<void> setOnlineFailureBehavior(String v) => _save(
      (state.valueOrNull ?? const AppSettings())
          .copyWith(onlineFailureBehavior: v));
  Future<void> setStreamCacheSizeMB(int v) => _save(
      (state.valueOrNull ?? const AppSettings())
          .copyWith(streamCacheSizeMB: v.clamp(0, 2000)));

  /// 整体保存（自动同步合并后调用）。
  Future<void> saveAll(AppSettings next) => _save(next);
}

final settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
