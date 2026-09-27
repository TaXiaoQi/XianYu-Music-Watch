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

/// 功能页入口 id 与默认顺序（当前磁盘默认：账号 → 每日推荐 → 音源榜单 →
/// 收藏 → 歌单 → 本地音乐 → 搜索 → 设置；对齐桌面端「侧边栏管理」的
/// DEFAULT_SIDEBAR_ORDER 设计）
const kDefaultHubEntryOrder = <String>[
  'account',
  'daily',
  'toplist',
  'favorites',
  'playlists',
  'local',
  'search',
  'settings',
];

/// 归一化已保存的功能页顺序（与桌面端 normalizeSidebarOrder 同策略）：
/// 非列表/为空回落默认；未知 id、重复 id 丢弃；缺失 id 按默认相对顺序
/// 追加末尾（新增入口默认排在最后）
List<String> normalizeHubEntryOrder(List<String>? saved) {
  if (saved == null || saved.isEmpty) {
    return List<String>.from(kDefaultHubEntryOrder);
  }
  final known = kDefaultHubEntryOrder.toSet();
  final seen = <String>{};
  final result = <String>[];
  for (final id in saved) {
    if (!known.contains(id) || !seen.add(id)) continue;
    result.add(id);
  }
  for (final id in kDefaultHubEntryOrder) {
    if (!seen.contains(id)) result.add(id);
  }
  return result;
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
    this.hubEntryOrder = kDefaultHubEntryOrder,
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

  /// 功能页（独立模式首页）入口显示顺序，元素为 kDefaultHubEntryOrder 的 id
  final List<String> hubEntryOrder;

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
    List<String>? hubEntryOrder,
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
      hubEntryOrder: hubEntryOrder ?? this.hubEntryOrder,
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
      hubEntryOrder:
          normalizeHubEntryOrder(prefs.getStringList('hubEntryOrder')),
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
      prefs.setStringList('hubEntryOrder', next.hubEntryOrder),
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

  Future<void> setHubEntryOrder(List<String> v) async =>
      _save((await _current()).copyWith(hubEntryOrder: v));

  Future<void> saveAll(AppSettings next) => _save(next);
}

final settingsProvider = AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
