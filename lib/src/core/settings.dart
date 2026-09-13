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
    this.keepScreenOn = true,
    this.libraryMinDurationSeconds = 0,
    this.scanFormats = kSupportedScanFormats,
    this.watchLinkageEnabled = true,
  });

  final double volume;
  final int playMode;
  final bool keepScreenOn;
  final int libraryMinDurationSeconds;
  final List<String> scanFormats;

  /// 手机联动总开关（对齐移动端 watchLinkageEnabled，移动端默认开启）。
  final bool watchLinkageEnabled;

  AppSettings copyWith({
    double? volume,
    int? playMode,
    bool? keepScreenOn,
    int? libraryMinDurationSeconds,
    List<String>? scanFormats,
    bool? watchLinkageEnabled,
  }) {
    return AppSettings(
      volume: volume ?? this.volume,
      playMode: playMode ?? this.playMode,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      libraryMinDurationSeconds:
          libraryMinDurationSeconds ?? this.libraryMinDurationSeconds,
      scanFormats: scanFormats ?? this.scanFormats,
      watchLinkageEnabled: watchLinkageEnabled ?? this.watchLinkageEnabled,
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
      keepScreenOn: prefs.getBool('keepScreenOn') ?? true,
      libraryMinDurationSeconds:
          prefs.getInt('libraryMinDurationSeconds') ?? 0,
      // 与移动端同 key：后补格式与支持列表取并集，保证新格式直接生效。
      scanFormats: _mergeScanFormats(prefs.getStringList('scanFormats')),
      watchLinkageEnabled: prefs.getBool('watchLinkageEnabled') ?? true,
    );
  }

  Future<void> _save(AppSettings next) async {
    state = AsyncData(next);
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setDouble('volume', next.volume),
      prefs.setInt('playMode', next.playMode),
      prefs.setBool('keepScreenOn', next.keepScreenOn),
      prefs.setInt(
          'libraryMinDurationSeconds', next.libraryMinDurationSeconds),
      prefs.setStringList('scanFormats', next.scanFormats),
      prefs.setBool('watchLinkageEnabled', next.watchLinkageEnabled),
    ]);
  }

  Future<void> setVolume(double v) =>
      _save((state.valueOrNull ?? const AppSettings()).copyWith(volume: v));
  Future<void> setPlayMode(int m) =>
      _save((state.valueOrNull ?? const AppSettings()).copyWith(playMode: m));
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

  /// 整体保存（自动同步合并后调用）。
  Future<void> saveAll(AppSettings next) => _save(next);
}

final settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
