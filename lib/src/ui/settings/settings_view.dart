import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_version.dart';
import '../../core/settings.dart';
import '../../i18n/i18n.dart';
import '../common/full_dialog.dart';
import '../../core/watch_fit.dart';
import '../../auth/auth_provider.dart';
import '../../library/library_provider.dart';
import '../../player/stream_cache.dart';
import '../common/stepped_list.dart';
import '../online/plugin_manage_page.dart';
import '../../plugin/plugin_provider.dart';
import '../../backup/watch_backup.dart';
import '../../core/application_logger.dart';
import '../../link/link_provider.dart';
import '../../update/app_update.dart';

const String kWatchProjectUrl = 'https://github.com/TaXiaoQi/XianYu-Music-Watch';

class SettingsView extends ConsumerWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();

    final rows = <Widget>[
      _categoryRow(
        s: s,
        color: const Color(0xFFFF4D6E),
        icon: Icons.play_circle_rounded,
        title: tr('播放'),
        subtitle: tr('常亮 / 模式 / 音质 / 缓存'),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const _PlaybackPage()),
        ),
      ),
      _categoryRow(
        s: s,
        color: const Color(0xFF4DA3B8),
        icon: Icons.lyrics_rounded,
        title: tr('歌词'),
        subtitle: tr('翻译 / 字号 / 偏移'),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const _LyricsPage()),
        ),
      ),
      _categoryRow(
        s: s,
        color: const Color(0xFFE8A33D),
        icon: Icons.library_music_rounded,
        title: tr('本地库'),
        subtitle: tr('扫描 / 格式 / 时长'),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const _LibraryPage()),
        ),
      ),
      _categoryRow(
        s: s,
        color: const Color(0xFF9B6BD9),
        icon: Icons.extension_rounded,
        title: tr('插件'),
        subtitle: _pluginSubtitle(ref),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const PluginManagePage()),
        ),
      ),
      _categoryRow(
        s: s,
        color: const Color(0xFFE8963D),
        icon: Icons.settings_backup_restore_rounded,
        title: tr('备份'),
        subtitle: tr('推送给手机 / 保存到本地'),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const _BackupPage()),
        ),
      ),
      _categoryRow(
        s: s,
        color: const Color(0xFF4CA6A6),
        icon: Icons.article_outlined,
        title: tr('日志'),
        subtitle: tr('推送给手机 / 保存到本地'),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const _LogsPage()),
        ),
      ),
      _categoryRow(
        s: s,
        color: const Color(0xFF6B7DE8),
        icon: Icons.translate_rounded,
        title: tr('语言'),
        subtitle: _languageLabel(ref),
        onTap: () => _pickLanguage(context, ref),
      ),
      _categoryRow(
        s: s,
        color: const Color(0xFF5FA97C),
        icon: Icons.info_rounded,
        title: tr('关于'),
        subtitle: 'v$kAppVersion · ${tr('弦予音乐 腕上版')}',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const _AboutPage()),
        ),
      ),
    ];

    return _SteppedPage(title: tr('设置'), rows: rows);
  }

  String _pluginSubtitle(WidgetRef ref) {
    final plugins = ref.watch(pluginManagerProvider).sources;
    if (plugins.isEmpty) return tr('未安装');
    final enabled = plugins.where((p) => p.enabled).length;
    return tr('{enabled}/{total} 个已启用', {
      'enabled': enabled,
      'total': plugins.length,
    });
  }

  String _languageLabel(WidgetRef ref) {
    final v = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.language ?? 'system'),
    );
    return switch (v) {
      'zhCN' => tr('简体中文'),
      'zhTW' => tr('繁體中文'),
      'en' => 'English',
      _ => tr('跟随系统'),
    };
  }
}

Future<void> _pickLanguage(BuildContext context, WidgetRef ref) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final current =
      container.read(settingsProvider).valueOrNull?.language ?? 'system';
  const options = ['system', 'zhCN', 'zhTW', 'en'];
  final v = await showFullPicker<String>(
    context,
    title: tr('语言'),
    current: current,
    options: [
      for (final o in options)
        (
          o,
          switch (o) {
            'zhCN' => tr('简体中文'),
            'zhTW' => tr('繁體中文'),
            'en' => 'English',
            _ => tr('跟随系统'),
          }
        ),
    ],
  );
  if (v != null) {
    await container.read(settingsProvider.notifier).setLanguage(v);
  }
}

class _PlaybackPage extends ConsumerWidget {
  const _PlaybackPage();

  static List<String> _playModeLabels() =>
      [tr('顺序循环'), tr('单曲循环'), tr('随机播放')];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    return _SteppedPage(title: tr('播放'), rows: [
      _switchRow(
        s: s,
        title: tr('保持屏幕常亮'),
        subtitle: tr('播放时屏幕不自动熄灭'),
        value: settings.keepScreenOn,
        onChanged: (v) =>
            ref.read(settingsProvider.notifier).setKeepScreenOn(v),
      ),
      _switchRow(
        s: s,
        title: tr('被打断后自动恢复'),
        subtitle: tr('来电、导航语音等临时打断结束后自动继续'),
        value: settings.autoResumeAfterInterruption,
        onChanged: (v) => ref
            .read(settingsProvider.notifier)
            .setAutoResumeAfterInterruption(v),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.volume_up_rounded, size: 24 * s),
        title: tr('默认音量'),
        subtitle: tr('新会话起始音量，表冠可随时微调'),
        trailing: Text(
          '${(settings.volume.clamp(0.0, 1.0) * 100).round()}%',
          style: TextStyle(
              fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
        ),
        onTap: () => _pickVolume(context, settings),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.repeat_rounded, size: 24 * s),
        title: tr('播放模式'),
        trailing: Text(
          _playModeLabels()[settings.playMode.clamp(0, 2)],
          style: TextStyle(
              fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
        ),
        onTap: () => _pickPlayMode(context, settings),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.high_quality_rounded, size: 24 * s),
        title: tr('音质偏好'),
        subtitle: tr('在线播放音质'),
        trailing: Text(
          settings.onlineQuality == 'flac' ? tr('无损') : '320k',
          style: TextStyle(
              fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
        ),
        onTap: () => _pickQuality(context, settings),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.speed_rounded, size: 24 * s),
        title: tr('播放倍速'),
        subtitle: tr('独立播放生效，联动由手机端自控'),
        trailing: Text(
          '${_speedLabel(settings.playbackSpeed)}x',
          style: TextStyle(
              fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
        ),
        onTap: () => _pickSpeed(context, settings),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.swap_horiz_rounded, size: 24 * s),
        title: tr('起播失败'),
        subtitle: tr('在线歌曲起播失败时的处理'),
        trailing: Text(
          settings.onlineFailureBehavior == 'autoswitch'
              ? tr('自动换源')
              : tr('停止'),
          style: TextStyle(
              fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
        ),
        onTap: () => _pickFailureBehavior(context, settings),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.save_alt_rounded, size: 24 * s),
        title: tr('流缓存'),
        subtitle: tr('在线播放边下边存，重播秒开'),
        trailing: Text(
          settings.streamCacheSizeMB <= 0
              ? tr('关闭')
              : '${settings.streamCacheSizeMB} MB',
          style: TextStyle(
              fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
        ),
        onTap: () => _pickStreamCache(context, settings),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.cleaning_services_rounded, size: 24 * s),
        title: tr('清除流缓存'),
        subtitle: tr('删除已缓存的在线音频'),
        onTap: () => _clearStreamCache(context),
      ),
    ]);
  }

  static String _speedLabel(double v) =>
      v == v.truncateToDouble() ? v.toStringAsFixed(1) : v.toString();
}

Future<void> _pickVolume(BuildContext context, AppSettings s) async {
  final container = ProviderScope.containerOf(context, listen: false);
  var value = s.volume.clamp(0.0, 1.0);
  final ok = await showFullSlider(
    context,
    title: tr('默认音量'),
    initial: value,
    min: 0,
    max: 1,
    divisions: 20,
    label: (v) => '${(v * 100).round()}%',
  );
  if (ok != null) {
    await container.read(settingsProvider.notifier).setVolume(ok);
  }
}

Future<void> _pickPlayMode(BuildContext context, AppSettings s) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final labels = _PlaybackPage._playModeLabels();
  final v = await showFullPicker<int>(
    context,
    title: tr('播放模式'),
    current: s.playMode,
    options: [for (var i = 0; i < labels.length; i++) (i, labels[i])],
  );
  if (v != null) {
    await container.read(settingsProvider.notifier).setPlayMode(v);
  }
}

Future<void> _pickSpeed(BuildContext context, AppSettings s) async {
  final container = ProviderScope.containerOf(context, listen: false);
  const steps = [0.75, 1.0, 1.25, 1.5, 2.0];
  String label(double v) =>
      v == v.truncateToDouble() ? v.toStringAsFixed(1) : v.toString();
  final v = await showFullPicker<double>(
    context,
    title: tr('播放倍速'),
    current: s.playbackSpeed,
    options: [for (final step in steps) (step, '${label(step)}x')],
  );
  if (v != null) {
    await container.read(settingsProvider.notifier).setPlaybackSpeed(v);
  }
}

class _LyricsPage extends ConsumerWidget {
  const _LyricsPage();

  static List<String> _fontSizeLabels() => [tr('小'), tr('标准'), tr('大'), tr('特大')];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    return _SteppedPage(title: tr('歌词'), rows: [
      _switchRow(
        s: s,
        title: tr('显示翻译'),
        subtitle: tr('外语歌词下方显示译文行'),
        value: settings.showLyricsTranslation,
        onChanged: (v) =>
            ref.read(settingsProvider.notifier).setShowLyricsTranslation(v),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.format_size_rounded, size: 24 * s),
        title: tr('歌词字号'),
        trailing: Text(
          _fontSizeLabels()[settings.lyricFontSize.clamp(0, 3)],
          style: TextStyle(
              fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
        ),
        onTap: () => _pickLyricFontSize(context, settings),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.schedule_rounded, size: 24 * s),
        title: tr('同步偏移'),
        subtitle: tr('蓝牙耳机延迟时可整体校准'),
        trailing: Text(
          _offsetLabel(settings.lyricOffsetMs),
          style: TextStyle(
              fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
        ),
        onTap: () => _pickLyricOffset(context, settings),
      ),
    ]);
  }

  static String _offsetLabel(int v) =>
      v > 0 ? '+$v ms' : v < 0 ? '$v ms' : '0 ms';
}

Future<void> _pickLyricFontSize(BuildContext context, AppSettings s) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final labels = _LyricsPage._fontSizeLabels();
  final v = await showFullPicker<int>(
    context,
    title: tr('歌词字号'),
    current: s.lyricFontSize,
    options: [for (var i = 0; i < labels.length; i++) (i, labels[i])],
  );
  if (v != null) {
    await container.read(settingsProvider.notifier).setLyricFontSize(v);
  }
}

Future<void> _pickLyricOffset(BuildContext context, AppSettings s) async {
  final container = ProviderScope.containerOf(context, listen: false);
  var value = s.lyricOffsetMs.toDouble();
  final ok = await showFullSlider(
    context,
    title: tr('同步偏移'),
    initial: value,
    min: -100,
    max: 100,
    divisions: 40,
    label: (v) => v.round() > 0
        ? '+${v.round()} ms'
        : v.round() < 0
            ? '${v.round()} ms'
            : '0 ms',
    hint: tr('正=歌词更晚，负=歌词更早'),
  );
  if (ok != null) {
    await container
        .read(settingsProvider.notifier)
        .setLyricOffsetMs(ok.round());
  }
}

Future<void> _pickFailureBehavior(BuildContext context, AppSettings s) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final options = [('autoswitch', tr('自动换源')), ('stop', tr('停止播放'))];
  final v = await showFullPicker<String>(
    context,
    title: tr('起播失败'),
    current: s.onlineFailureBehavior,
    options: options,
  );
  if (v != null) {
    await container
        .read(settingsProvider.notifier)
        .setOnlineFailureBehavior(v);
  }
}

Future<void> _pickStreamCache(BuildContext context, AppSettings s) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final options = [
    (0, tr('关闭')),
    (100, '100 MB'),
    (200, '200 MB'),
    (500, '500 MB')
  ];
  final v = await showFullPicker<int>(
    context,
    title: tr('流缓存'),
    current: s.streamCacheSizeMB,
    options: options,
  );
  if (v != null) {
    await container.read(settingsProvider.notifier).setStreamCacheSizeMB(v);
  }
}

Future<void> _clearStreamCache(BuildContext context) async {
  final sizeMB = (await StreamCache.instance.sizeBytes() / 1048576).round();
  await StreamCache.instance.clearAll();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(sizeMB > 0
          ? tr('已清除 {n}MB 缓存', {'n': sizeMB})
          : tr('缓存为空')),
      duration: const Duration(seconds: 1),
    ),
  );
}

class _LibraryPage extends ConsumerStatefulWidget {
  const _LibraryPage();

  @override
  ConsumerState<_LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<_LibraryPage> {
  bool _scanning = false;

  Future<void> _scanNow() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      await ref.read(libraryProvider.notifier).scanAllFolders();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(tr('扫描完成')),
              duration: const Duration(seconds: 1)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(tr('扫描失败：{e}', {'e': e})),
              duration: const Duration(seconds: 2)),
        );
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    return _SteppedPage(title: tr('本地库'), rows: [
      _actionRow(
        s: s,
        icon: _scanning
            ? SizedBox(
                width: 18 * s,
                height: 18 * s,
                child: CircularProgressIndicator(strokeWidth: 2 * s))
            : Icon(Icons.refresh_rounded, size: 24 * s),
        title: tr('立即扫描'),
        onTap: _scanning ? null : _scanNow,
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.audio_file_rounded, size: 24 * s),
        title: tr('扫描格式'),
        subtitle: settings.scanFormats.isEmpty
            ? tr('未选择')
            : settings.scanFormats.join(' / '),
        onTap: () => _pickScanFormats(context, settings),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.timer_outlined, size: 24 * s),
        title: tr('最短时长'),
        subtitle: tr('过滤铃声等短音频'),
        trailing: Text(
          settings.libraryMinDurationSeconds <= 0
              ? tr('不过滤')
              : '${settings.libraryMinDurationSeconds}s',
          style: TextStyle(
              fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
        ),
        onTap: () => _pickMinDuration(context, settings),
      ),
    ]);
  }
}

class _BackupPage extends ConsumerStatefulWidget {
  const _BackupPage();

  @override
  ConsumerState<_BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<_BackupPage> {
  bool _busy = false;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<String> _export() async {
    final service = ref.read(watchBackupProvider);
    return service.exportJson();
  }

  Future<void> _saveLocal() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final json = await _export();
      await writeWatchBackupFileLocal(json);
      _toast(tr('已保存到本地'));
    } catch (e) {
      _toast(tr('保存失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pushToPhone() async {
    if (_busy) return;
    final link = ref.read(linkControllerProvider);
    if (link.phase != LinkPhase.connected) {
      _toast(tr('未连接手机，请先在「联动」连接'));
      return;
    }
    setState(() => _busy = true);
    try {
      final json = await _export();
      final result = await ref
          .read(linkControllerProvider.notifier)
          .pushBackup(name: watchBackupFileName(), content: json);
      switch (result) {
        case LinkController.backupPushSaved:
          _toast(tr('已完成：手机已保存备份'));
        case LinkController.backupPushCancelled:
          _toast(tr('已取消：手机端未保存'));
        case LinkController.backupPushTimeout:
          _toast(tr('推送超时，请确认手机已处理'));
        default:
          _toast(tr('推送失败：未收到回应'));
      }
    } catch (e) {
      _toast(tr('推送失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreLocal() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final json = await readLatestLocalBackupFile();
      if (json == null) {
        _toast(tr('未找到本地备份，请先「保存到本地」'));
        return;
      }
      final result = await ref.read(watchBackupProvider).importJson(json);
      final favCount = ((result['favorites'] as num?) ?? 0).toInt();
      final plCount = ((result['playlists'] as num?) ?? 0).toInt();
      final pluginCount = ((result['plugins'] as num?) ?? 0).toInt();
      final parts = <String>[
        if (favCount > 0) tr('收藏 {n} 条', {'n': favCount}),
        if (plCount > 0) tr('歌单 {n} 个', {'n': plCount}),
        if (pluginCount > 0) tr('插件 {n} 个', {'n': pluginCount}),
        if (((result['settings'] as num?) ?? 0) > 0) tr('设置'),
      ];
      if (parts.isEmpty) {
        _toast(tr('恢复完成：无新数据需要导入'));
      } else {
        _toast(tr('已恢复 {items}', {'items': parts.join('、')}));
      }
    } catch (e) {
      _toast(tr('恢复失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final link = ref.watch(linkControllerProvider);

    final rows = <Widget>[
      _rowPill(
        s,
        leading: _iconBubble(s, const Color(0xFF4A90D9), Icons.watch_rounded),
        title: tr('推送给手机'),
        subtitle: link.phase == LinkPhase.connected
            ? tr('已连接 {name}，发送后将等待回执', {
                'name': link.phoneName.isEmpty ? tr('手机') : link.phoneName
              })
            : tr('未连接手机，请在「联动」连接后再试'),
        trailing: _busy
            ? SizedBox(
                width: 18 * s,
                height: 18 * s,
                child: CircularProgressIndicator(strokeWidth: 2 * s),
              )
            : Icon(Icons.chevron_right_rounded,
                size: 22 * s, color: Colors.white.withValues(alpha: 0.38)),
        onTap:
            _busy || link.phase != LinkPhase.connected ? null : _pushToPhone,
      ),
      _rowPill(
        s,
        leading: _iconBubble(s, const Color(0xFF5FA97C), Icons.save_alt_rounded),
        title: tr('保存到本地'),
        subtitle: tr('生成备份文件保存到腕上端文档目录'),
        trailing: Icon(Icons.chevron_right_rounded,
            size: 22 * s, color: Colors.white.withValues(alpha: 0.38)),
        onTap: _busy ? null : _saveLocal,
      ),
      _rowPill(
        s,
        leading: _iconBubble(s, const Color(0xFFB07EE8), Icons.settings_backup_restore_rounded),
        title: tr('从本地恢复'),
        subtitle: tr('读取最新本地备份，恢复收藏、歌单、插件的本机设置'),
        trailing: _busy
            ? SizedBox(
                width: 18 * s,
                height: 18 * s,
                child: CircularProgressIndicator(strokeWidth: 2 * s),
              )
            : Icon(Icons.chevron_right_rounded,
                size: 22 * s, color: Colors.white.withValues(alpha: 0.38)),
        onTap: _busy ? null : _restoreLocal,
      ),
    ];

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SteppedListView(
          header: PageTitleHeader(tr('备份'), showBack: true),
          itemCount: rows.length,
          rowExtent: (_) => 62 * s,
          itemBuilder: (context, i) => rows[i],
        ),
      ),
    );
  }

  Widget _iconBubble(double s, Color color, IconData icon) {
    return Container(
      width: 36 * s,
      height: 36 * s,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Icon(icon, size: 20 * s, color: Colors.white),
    );
  }
}

class _LogsPage extends ConsumerStatefulWidget {
  const _LogsPage();

  @override
  ConsumerState<_LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends ConsumerState<_LogsPage> {
  bool _busy = false;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _saveLocal() async {
    if (_busy) return;
    if (AppLog.isEmpty) {
      _toast(tr('暂无日志'));
      return;
    }
    setState(() => _busy = true);
    try {
      await writeWatchLogFileLocal(AppLog.exportText());
      _toast(tr('已保存到本地'));
    } catch (e) {
      _toast(tr('保存失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pushToPhone() async {
    if (_busy) return;
    final link = ref.read(linkControllerProvider);
    if (link.phase != LinkPhase.connected) {
      _toast(tr('未连接手机，请先在「联动」连接'));
      return;
    }
    if (AppLog.isEmpty) {
      _toast(tr('暂无日志'));
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(linkControllerProvider.notifier)
          .pushLogFile(name: watchLogFileName(), content: AppLog.exportText());
      switch (result) {
        case LinkController.backupPushSaved:
          _toast(tr('已完成：手机已收到日志'));
        case LinkController.backupPushCancelled:
          _toast(tr('已取消：手机端未处理'));
        case LinkController.backupPushTimeout:
          _toast(tr('推送超时，请确认手机已处理'));
        default:
          _toast(tr('推送失败：未收到回应'));
      }
    } catch (e) {
      _toast(tr('推送失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final link = ref.watch(linkControllerProvider);

    final rows = <Widget>[
      _rowPill(
        s,
        leading: _iconBubble(s, const Color(0xFF4A90D9), Icons.watch_rounded),
        title: tr('推送给手机'),
        subtitle: link.phase == LinkPhase.connected
            ? tr('已连接 {name}，发送后将等待回执', {
                'name': link.phoneName.isEmpty ? tr('手机') : link.phoneName
              })
            : tr('未连接手机，请在「联动」连接后再试'),
        trailing: _busy
            ? SizedBox(
                width: 18 * s,
                height: 18 * s,
                child: CircularProgressIndicator(strokeWidth: 2 * s),
              )
            : Icon(Icons.chevron_right_rounded,
                size: 22 * s, color: Colors.white.withValues(alpha: 0.38)),
        onTap:
            _busy || link.phase != LinkPhase.connected ? null : _pushToPhone,
      ),
      _rowPill(
        s,
        leading: _iconBubble(s, const Color(0xFF5FA97C), Icons.save_alt_rounded),
        title: tr('保存到本地'),
        subtitle: tr('生成日志文件保存到腕上端文档目录'),
        trailing: Icon(Icons.chevron_right_rounded,
            size: 22 * s, color: Colors.white.withValues(alpha: 0.38)),
        onTap: _busy ? null : _saveLocal,
      ),
    ];

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SteppedListView(
          header: PageTitleHeader(tr('日志'), showBack: true),
          itemCount: rows.length,
          rowExtent: (_) => 62 * s,
          itemBuilder: (context, i) => rows[i],
        ),
      ),
    );
  }

  Widget _iconBubble(double s, Color color, IconData icon) {
    return Container(
      width: 36 * s,
      height: 36 * s,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Icon(icon, size: 20 * s, color: Colors.white),
    );
  }
}

class _AboutPage extends ConsumerStatefulWidget {
  const _AboutPage();

  @override
  ConsumerState<_AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends ConsumerState<_AboutPage> {
  bool _checking = false;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final latest = await fetchWatchLatest(ref);
      if (!mounted) return;
      if (latest == null || !hasNewVersion(latest)) {
        _toast(tr('当前已是最新版本（v{version}）', {'version': kAppVersion}));
        return;
      }
      await showUpdatePage(context, latest,
          onUpdate: () => toastUpdateOnPhone(context));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final cfg =
        ref.watch(aboutConfigProvider).valueOrNull ?? const WatchAboutConfig();

    final rows = <Widget>[
      _rowPill(
        s,
        leading: Icon(Icons.system_update_alt_rounded,
            size: 24 * s, color: const Color(0xFFFF4D6E)),
        title: tr('版本更新'),
        subtitle: _checking
            ? tr('正在检查…')
            : 'v$kAppVersion · ${tr('检查更新')}',
        trailing: _checking
            ? SizedBox(
                width: 18 * s,
                height: 18 * s,
                child: CircularProgressIndicator(strokeWidth: 2 * s),
              )
            : Icon(Icons.chevron_right_rounded,
                size: 22 * s, color: Colors.white.withValues(alpha: 0.38)),
        onTap: _checking ? null : _checkUpdate,
      ),
      if (cfg.officialSiteUrl.isNotEmpty)
        _aboutLink(
          s,
          icon: Icons.language_rounded,
          label: tr('前往官网'),
          sub: cfg.officialSiteUrl,
          onTap: () => _aboutOpenExternal(context, tr('前往官网')),
        ),
      if (cfg.joinGroupUrl.isNotEmpty)
        _aboutLink(
          s,
          icon: Icons.group_rounded,
          label: tr('加入群组'),
          sub: tr('与开发者和玩友交流'),
          onTap: () => _aboutOpenExternal(context, tr('加入群组')),
        ),
      _aboutLink(
        s,
        icon: Icons.code_rounded,
        label: tr('项目地址'),
        sub: kWatchProjectUrl.replaceFirst('https://', ''),
        onTap: () => _aboutOpenExternal(context, tr('项目仓库')),
      ),
      _aboutLink(
        s,
        icon: Icons.favorite_rounded,
        label: tr('致谢名单'),
        sub: cfg.acknowledgements.isEmpty
            ? tr('暂无致谢名单')
            : tr('感谢以下项目的贡献者'),
        onTap: () => _aboutShowAcknowledgements(context, cfg.acknowledgements),
      ),
      _rowPill(
        s,
        leading: Icon(Icons.verified_rounded,
            size: 24 * s, color: const Color(0xFF4A90D9)),
        title: tr('开发者'),
        subtitle: 'xiaoqi',
      ),
      Center(
        child: Text(
          tr('© 2026 弦予音乐 · 源码可见协议 XSAL-1.0'),
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 9.5 * s, color: Colors.white.withValues(alpha: 0.32)),
        ),
      ),
    ];

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SteppedListView(
          header: Padding(
            padding: EdgeInsets.symmetric(horizontal: 4 * s),
            child: Row(
              children: [
                SizedBox(width: 48 * s, child: const BackButton()),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6 * s),
                        child: Container(
                          width: 22 * s,
                          height: 22 * s,
                          color: const Color(0xFFFFFFFF),
                          padding: EdgeInsets.all(3 * s),
                          child: Image.asset(
                            'assets/img/splash_logo.png',
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                      SizedBox(width: 6 * s),
                      Text(
                        tr('关于'),
                        style: TextStyle(
                          fontSize: 14 * s,
                          fontWeight: FontWeight.w700,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 48 * s),
              ],
            ),
          ),
          itemCount: rows.length,
          itemBuilder: (context, i) => rows[i],
        ),
      ),
    );
  }

  void _aboutOpenExternal(BuildContext context, String label) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('请在手机端打开：{label}', {'label': label})),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _aboutShowAcknowledgements(
      BuildContext context, List<AboutAck> acks) {
    final s = context.watchScale();
    showFullDialog<void>(
      context: context,
      builder: (context) => FullDialogScaffold(
        title: tr('致谢名单'),
        content: acks.isEmpty
            ? Text(
                tr('暂无致谢名单'),
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12 * s,
                    color: Colors.white.withValues(alpha: 0.6)),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final a in acks)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 4 * s),
                      child: Center(
                        child: Text(
                          a.name,
                          style: TextStyle(
                              fontSize: 13 * s, color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
        actions: [
          FullDialogButton(label: tr('知道了'), primary: true, onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }
}

Widget _aboutLink(
  double s, {
  required IconData icon,
  required String label,
  required String sub,
  required VoidCallback onTap,
}) {
  return _rowPill(
    s,
    leading: Icon(icon, size: 24 * s, color: const Color(0xFFFF4D6E)),
    title: label,
    subtitle: sub,
    onTap: onTap,
  );
}

class _SteppedPage extends StatelessWidget {
  const _SteppedPage({this.title = '', required this.rows});

  final String title;

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            SteppedListView(
              itemCount: rows.length,
              itemBuilder: (context, i) => rows[i],
              header: title.isEmpty
                  ? null
                  : Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4 * s),
                      child: Row(
                        children: [
                          const SizedBox(width: 48),
                          Expanded(
                            child: Text(
                              title,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15 * s,
                                height: 1.2,
                                fontWeight: FontWeight.w700,
                                color: Colors.white.withValues(alpha: 0.9),
                              ),
                            ),
                          ),
                          const SizedBox(width: 48),
                        ],
                      ),
                    ),
            ),
            Positioned(
              top: 2 * s,
              left: 2 * s,
              child: _backChip(s),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _backChip(double s) {
  return Material(
    color: Colors.white.withValues(alpha: 0.08),
    shape: const CircleBorder(),
    clipBehavior: Clip.antiAlias,
    child: Builder(
      builder: (context) => InkWell(
        onTap: () => Navigator.of(context).maybePop(),
        child: Padding(
          padding: EdgeInsets.all(9 * s),
          child: Icon(Icons.arrow_back_rounded,
              size: 18 * s, color: Colors.white.withValues(alpha: 0.85)),
        ),
      ),
    ),
  );
}

/// 设置/详情页统一行：内容整体左对齐，前置图标 + 标题/副标题靠左，右侧只留非装饰控件
Widget _rowPill(
  double s, {
  Widget? leading,
  String? title,
  String? subtitle,
  Widget? trailing,
  VoidCallback? onTap,
}) {
  return SteppedPill(
    onTap: onTap,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: 5 * s, vertical: 2 * s),
      child: Row(
        children: [
          if (leading != null) ...[
            leading,
            SizedBox(width: 12 * s),
          ],
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null)
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 16 * s, fontWeight: FontWeight.w600)),
                if ((subtitle ?? '').isNotEmpty) ...[
                  SizedBox(height: 2 * s),
                  Text(subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5 * s,
                          color: Colors.white.withValues(alpha: 0.5))),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            SizedBox(width: 8 * s),
            trailing,
          ],
        ],
      ),
    ),
  );
}

Widget _categoryRow({
  required double s,
  required Color color,
  required IconData icon,
  required String title,
  required String subtitle,
  required VoidCallback onTap,
}) {
  return _rowPill(
    s,
    leading: Container(
      width: 44 * s,
      height: 44 * s,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Icon(icon, size: 22 * s, color: Colors.white),
    ),
    title: title,
    subtitle: subtitle,
    onTap: onTap,
  );
}

Widget _switchRow({
  required double s,
  required String title,
  required String subtitle,
  required bool value,
  required ValueChanged<bool> onChanged,
}) {
  return _rowPill(
    s,
    title: title,
    subtitle: subtitle,
    trailing: SizedBox(
      width: 48 * s,
      child: Switch(
          value: value,
          activeThumbColor: const Color(0xFFFF4D6E),
          onChanged: onChanged),
    ),
    onTap: () => onChanged(!value),
  );
}

Widget _actionRow({
  required double s,
  required Widget icon,
  required String title,
  String? subtitle,
  Widget? trailing,
  VoidCallback? onTap,
}) {
  return _rowPill(
    s,
    leading: icon,
    title: title,
    subtitle: subtitle,
    trailing: trailing,
    onTap: onTap,
  );
}

Future<void> _pickScanFormats(BuildContext context, AppSettings s) async {
  final sc = context.watchScale();
  final container = ProviderScope.containerOf(context, listen: false);
  final selected = {...s.scanFormats};
  final ok = await showFullDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => FullDialogScaffold(
        title: tr('扫描格式'),
        content: Wrap(
          spacing: 6 * sc,
          runSpacing: 8 * sc,
          alignment: WrapAlignment.center,
          children: [
            for (final f in kSupportedScanFormats)
              FilterChip(
                label: Text(f, style: TextStyle(fontSize: 12 * sc)),
                selected: selected.contains(f),
                onSelected: (v) => setState(() {
                  v ? selected.add(f) : selected.remove(f);
                }),
              ),
          ],
        ),
        actions: [
          FullDialogButton(
            label: tr('取消'),
            onPressed: () => Navigator.pop(context),
          ),
          FullDialogButton(
            label: tr('确定'),
            primary: true,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    ),
  );
  if (ok == true) {
    final next = selected.isEmpty
        ? List<String>.from(kSupportedScanFormats)
        : selected.toList();
    await container
        .read(settingsProvider.notifier)
        .setScanFormats(next);
  }
}

Future<void> _pickMinDuration(BuildContext context, AppSettings s) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final options = [
    (0, tr('不过滤')),
    (30, tr('30 秒以上')),
    (60, tr('1 分钟以上')),
    (120, tr('2 分钟以上'))
  ];
  final v = await showFullPicker<int>(
    context,
    title: tr('最短时长'),
    current: s.libraryMinDurationSeconds,
    options: options,
  );
  if (v != null) {
    await container
        .read(settingsProvider.notifier)
        .setLibraryMinDurationSeconds(v);
  }
}

Future<void> _pickQuality(BuildContext context, AppSettings s) async {
  final container = ProviderScope.containerOf(context, listen: false);
  // 与移动端设置页同款 12 档（kQualityLadder 全梯）
  final options = [
    ('mgg', tr('低清 · 96k 极速试听')),
    ('128k', tr('普通 · 128kbps')),
    ('192k', tr('中等 · 192kbps')),
    ('320k', tr('HQ · 高品质 320k')),
    ('flac', tr('SQ · 无损 FLAC')),
    ('flac24bit', tr('Hi-Res · FLAC 24bit')),
    ('hires', tr('高解析度 · Hi-Res')),
    ('vinyl', tr('黑胶音色 · 无损')),
    ('dolby', tr('杜比全景声')),
    ('atmos', tr('臻品音质 · 立体空间声场')),
    ('atmos_plus', tr('臻品全景声')),
    ('master', tr('臻品母带')),
  ];
  final v = await showFullPicker<String>(
    context,
    title: tr('在线音质'),
    current: s.onlineQuality,
    options: options,
  );
  if (v != null) {
    await container.read(settingsProvider.notifier).setOnlineQuality(v);
  }
}
