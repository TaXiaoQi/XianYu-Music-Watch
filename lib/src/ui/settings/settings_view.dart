import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_version.dart';
import '../../core/settings.dart';
import '../../core/watch_fit.dart';
import '../../library/library_provider.dart';
import '../../link/link_provider.dart';
import '../../player/stream_cache.dart';
import '../common/stepped_list.dart';
import '../controller/watch_controller_page.dart';
import '../online/plugin_manage_page.dart';
import '../pair/pair_view.dart';
import '../../plugin/plugin_provider.dart';

/// 设置主页（导航页，参照移动端分类式设置）：分类入口点进二级页改
/// 具体设置；主页与二级页都用居中阶梯列表适配圆屏 + 表冠逐档滚动。
class SettingsView extends ConsumerWidget {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    final link = ref.watch(linkControllerProvider);

    String linkSubtitle;
    if (!settings.watchLinkageEnabled) {
      linkSubtitle = '已关闭';
    } else {
      switch (link.phase) {
        case LinkPhase.connected:
          linkSubtitle = '已连接 ${link.pairedName ?? ''}';
        case LinkPhase.connecting:
          linkSubtitle = '正在连接…';
        case LinkPhase.disconnected:
          linkSubtitle = '未连接';
      }
    }

    final rows = <Widget>[
      _categoryRow(
        s: s,
        color: const Color(0xFF4A90D9),
        icon: Icons.watch_rounded,
        title: '手机联动',
        subtitle: linkSubtitle,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const _LinkagePage()),
        ),
      ),
      _categoryRow(
        s: s,
        color: const Color(0xFFFF4D6E),
        icon: Icons.play_circle_rounded,
        title: '播放',
        subtitle: '常亮 / 模式 / 音质 / 缓存',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const _PlaybackPage()),
        ),
      ),
      _categoryRow(
        s: s,
        color: const Color(0xFF4DA3B8),
        icon: Icons.lyrics_rounded,
        title: '歌词',
        subtitle: '翻译 / 字号 / 偏移',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const _LyricsPage()),
        ),
      ),
      _categoryRow(
        s: s,
        color: const Color(0xFFE8A33D),
        icon: Icons.library_music_rounded,
        title: '本地库',
        subtitle: '扫描 / 格式 / 时长',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const _LibraryPage()),
        ),
      ),
      _categoryRow(
        s: s,
        color: const Color(0xFF9B6BD9),
        icon: Icons.extension_rounded,
        title: '插件',
        subtitle: _pluginSubtitle(ref),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const PluginManagePage()),
        ),
      ),
      _categoryRow(
        s: s,
        color: const Color(0xFF5FA97C),
        icon: Icons.info_rounded,
        title: '关于',
        subtitle: 'v$kAppVersion · 弦予音乐 腕上版',
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const _AboutPage()),
        ),
      ),
    ];

    return _SteppedPage(rows: rows);
  }

  /// 插件分类副标题：已启用数/总数（对齐移动端插件入口）。
  String _pluginSubtitle(WidgetRef ref) {
    final plugins = ref.watch(pluginManagerProvider).sources;
    if (plugins.isEmpty) return '未安装';
    final enabled = plugins.where((p) => p.enabled).length;
    return '$enabled/${plugins.length} 个已启用';
  }
}

/// 手机联动二级页：开关 + 连接状态 + 操作按钮。
class _LinkagePage extends ConsumerWidget {
  const _LinkagePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    final link = ref.watch(linkControllerProvider);
    return _SteppedPage(rows: [
      _switchRow(
        s: s,
        title: '腕上联动',
        subtitle: settings.watchLinkageEnabled ? '连接手机后可远程控制播放' : '已关闭，不自动连接手机',
        value: settings.watchLinkageEnabled,
        onChanged: (v) =>
            ref.read(settingsProvider.notifier).setWatchLinkageEnabled(v),
      ),
      _linkStatusRow(context, ref, link, 64 * s, s),
      if (link.phase != LinkPhase.connecting)
        _linkActionsRow(context, ref, link, 64 * s, s),
    ]);
  }
}

/// 播放二级页：屏幕常亮 / 默认音量 / 播放模式 / 播放倍速。
class _PlaybackPage extends ConsumerWidget {
  const _PlaybackPage();

  /// 播放模式文案（0 顺序 / 1 单曲循环 / 2 随机，同播放页）。
  static const _playModeLabels = ['顺序循环', '单曲循环', '随机播放'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    return _SteppedPage(rows: [
      _switchRow(
        s: s,
        title: '保持屏幕常亮',
        subtitle: '播放时屏幕不自动熄灭',
        value: settings.keepScreenOn,
        onChanged: (v) =>
            ref.read(settingsProvider.notifier).setKeepScreenOn(v),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.volume_up_rounded, size: 24 * s),
        title: '默认音量',
        subtitle: '新会话起始音量，表冠可随时微调',
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
        title: '播放模式',
        trailing: Text(
          _playModeLabels[settings.playMode.clamp(0, 2)],
          style: TextStyle(
              fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
        ),
        onTap: () => _pickPlayMode(context, settings),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.high_quality_rounded, size: 24 * s),
        title: '音质偏好',
        subtitle: '在线播放音质',
        trailing: Text(
          settings.onlineQuality == 'flac' ? '无损' : '320k',
          style: TextStyle(
              fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
        ),
        onTap: () => _pickQuality(context, settings),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.speed_rounded, size: 24 * s),
        title: '播放倍速',
        subtitle: '独立播放生效，联动由手机端自控',
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
        title: '起播失败',
        subtitle: '在线歌曲起播失败时的处理',
        trailing: Text(
          settings.onlineFailureBehavior == 'autoswitch' ? '自动换源' : '停止',
          style: TextStyle(
              fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
        ),
        onTap: () => _pickFailureBehavior(context, settings),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.save_alt_rounded, size: 24 * s),
        title: '流缓存',
        subtitle: '在线播放边下边存，重播秒开',
        trailing: Text(
          settings.streamCacheSizeMB <= 0
              ? '关闭'
              : '${settings.streamCacheSizeMB} MB',
          style: TextStyle(
              fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
        ),
        onTap: () => _pickStreamCache(context, settings),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.cleaning_services_rounded, size: 24 * s),
        title: '清除流缓存',
        subtitle: '删除已缓存的在线音频',
        onTap: () => _clearStreamCache(context),
      ),
    ]);
  }

  /// 倍速文案：1 → 1.0，1.25 → 1.25。
  static String _speedLabel(double v) =>
      v == v.truncateToDouble() ? v.toStringAsFixed(1) : v.toString();
}

/// 默认音量：滑杆点选（5% 步进），写设置即全链路生效。
Future<void> _pickVolume(BuildContext context, AppSettings s) async {
  final sc = context.watchScale();
  final container = ProviderScope.containerOf(context, listen: false);
  var value = s.volume.clamp(0.0, 1.0);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('默认音量', style: TextStyle(fontSize: 15 * sc)),
      content: StatefulBuilder(
        builder: (context, setDialogState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${(value * 100).round()}%',
                style: TextStyle(fontSize: 20 * sc, fontWeight: FontWeight.w700)),
            Slider(
              value: value,
              divisions: 20,
              activeColor: const Color(0xFFFF4D6E),
              onChanged: (v) => setDialogState(() => value = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('取消', style: TextStyle(fontSize: 13 * sc)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text('确定', style: TextStyle(fontSize: 13 * sc)),
        ),
      ],
    ),
  );
  if (ok == true) {
    await container.read(settingsProvider.notifier).setVolume(value);
  }
}

/// 播放模式：三选一（0 顺序 / 1 单曲循环 / 2 随机）。
Future<void> _pickPlayMode(BuildContext context, AppSettings s) async {
  final sc = context.watchScale();
  final container = ProviderScope.containerOf(context, listen: false);
  const labels = ['顺序循环', '单曲循环', '随机播放'];
  final v = await showDialog<int>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('播放模式', style: TextStyle(fontSize: 15 * sc)),
      children: [
        for (var i = 0; i < labels.length; i++)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, i),
            child: Row(
              children: [
                if (s.playMode == i)
                  Icon(Icons.check_rounded,
                      size: 16 * sc, color: const Color(0xFFFF4D6E))
                else
                  SizedBox(width: 16 * sc),
                SizedBox(width: 8 * sc),
                Text(labels[i], style: TextStyle(fontSize: 13 * sc)),
              ],
            ),
          ),
      ],
    ),
  );
  if (v != null) {
    await container.read(settingsProvider.notifier).setPlayMode(v);
  }
}

/// 播放倍速：五档点选（与播放页「更多」面板一致）。
Future<void> _pickSpeed(BuildContext context, AppSettings s) async {
  final sc = context.watchScale();
  final container = ProviderScope.containerOf(context, listen: false);
  const steps = [0.75, 1.0, 1.25, 1.5, 2.0];
  String label(double v) =>
      v == v.truncateToDouble() ? v.toStringAsFixed(1) : v.toString();
  final v = await showDialog<double>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('播放倍速', style: TextStyle(fontSize: 15 * sc)),
      children: [
        for (final step in steps)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, step),
            child: Row(
              children: [
                if ((s.playbackSpeed - step).abs() < 0.01)
                  Icon(Icons.check_rounded,
                      size: 16 * sc, color: const Color(0xFFFF4D6E))
                else
                  SizedBox(width: 16 * sc),
                SizedBox(width: 8 * sc),
                Text('${label(step)}x', style: TextStyle(fontSize: 13 * sc)),
              ],
            ),
          ),
      ],
    ),
  );
  if (v != null) {
    await container.read(settingsProvider.notifier).setPlaybackSpeed(v);
  }
}

/// 歌词二级页：翻译开关 / 字号档位 / 同步偏移。
class _LyricsPage extends ConsumerWidget {
  const _LyricsPage();

  /// 字号档位文案（0-3，同移动端 [24,28,32,36] 的档位语义）。
  static const _fontSizeLabels = ['小', '标准', '大', '特大'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    return _SteppedPage(rows: [
      _switchRow(
        s: s,
        title: '显示翻译',
        subtitle: '外语歌词下方显示译文行',
        value: settings.showLyricsTranslation,
        onChanged: (v) =>
            ref.read(settingsProvider.notifier).setShowLyricsTranslation(v),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.format_size_rounded, size: 24 * s),
        title: '歌词字号',
        trailing: Text(
          _fontSizeLabels[settings.lyricFontSize.clamp(0, 3)],
          style: TextStyle(
              fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
        ),
        onTap: () => _pickLyricFontSize(context, settings),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.schedule_rounded, size: 24 * s),
        title: '同步偏移',
        subtitle: '蓝牙耳机延迟时可整体校准',
        trailing: Text(
          _offsetLabel(settings.lyricOffsetMs),
          style: TextStyle(
              fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
        ),
        onTap: () => _pickLyricOffset(context, settings),
      ),
    ]);
  }

  /// 偏移文案：+50ms / 0ms / -30ms。
  static String _offsetLabel(int v) =>
      v > 0 ? '+$v ms' : v < 0 ? '$v ms' : '0 ms';
}

/// 歌词字号：四档点选（小/标准/大/特大）。
Future<void> _pickLyricFontSize(BuildContext context, AppSettings s) async {
  final sc = context.watchScale();
  // 跨 async 不能再用 context，先取容器。
  final container = ProviderScope.containerOf(context, listen: false);
  const labels = ['小', '标准', '大', '特大'];
  final v = await showDialog<int>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('歌词字号', style: TextStyle(fontSize: 15 * sc)),
      children: [
        for (var i = 0; i < labels.length; i++)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, i),
            child: Row(
              children: [
                if (s.lyricFontSize == i)
                  Icon(Icons.check_rounded,
                      size: 16 * sc, color: const Color(0xFFFF4D6E))
                else
                  SizedBox(width: 16 * sc),
                SizedBox(width: 8 * sc),
                Text(labels[i], style: TextStyle(fontSize: 13 * sc)),
              ],
            ),
          ),
      ],
    ),
  );
  if (v != null) {
    await container.read(settingsProvider.notifier).setLyricFontSize(v);
  }
}

/// 歌词同步偏移：滑杆 -100~+100ms（5ms 步进），正=歌词更晚（同移动端）。
Future<void> _pickLyricOffset(BuildContext context, AppSettings s) async {
  final sc = context.watchScale();
  // 跨 async 不能再用 context，先取容器。
  final container = ProviderScope.containerOf(context, listen: false);
  var value = s.lyricOffsetMs.toDouble();
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('同步偏移', style: TextStyle(fontSize: 15 * sc)),
      content: StatefulBuilder(
        builder: (context, setDialogState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value.round() > 0
                  ? '+${value.round()} ms'
                  : value.round() < 0
                      ? '${value.round()} ms'
                      : '0 ms',
              style: TextStyle(fontSize: 20 * sc, fontWeight: FontWeight.w700),
            ),
            Text('正=歌词更晚，负=歌词更早',
                style: TextStyle(
                    fontSize: 11 * sc,
                    color: Colors.white.withValues(alpha: 0.5))),
            Slider(
              value: value,
              min: -100,
              max: 100,
              divisions: 40, // 200/40 = 5ms 步进，同移动端
              activeColor: const Color(0xFFFF4D6E),
              onChanged: (v) => setDialogState(() => value = v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('取消', style: TextStyle(fontSize: 13 * sc)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text('确定', style: TextStyle(fontSize: 13 * sc)),
        ),
      ],
    ),
  );
  if (ok == true) {
    await container.read(settingsProvider.notifier).setLyricOffsetMs(value.round());
  }
}

/// 起播失败行为：自动换源 / 停止（同移动端 onlineFailureBehavior）。
Future<void> _pickFailureBehavior(BuildContext context, AppSettings s) async {
  final sc = context.watchScale();
  // 跨 async 不能再用 context，先取容器。
  final container = ProviderScope.containerOf(context, listen: false);
  const options = [('autoswitch', '自动换源'), ('stop', '停止播放')];
  final v = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('起播失败', style: TextStyle(fontSize: 15 * sc)),
      children: [
        for (final (val, label) in options)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, val),
            child: Row(
              children: [
                if (s.onlineFailureBehavior == val)
                  Icon(Icons.check_rounded,
                      size: 16 * sc, color: const Color(0xFFFF4D6E))
                else
                  SizedBox(width: 16 * sc),
                SizedBox(width: 8 * sc),
                Text(label, style: TextStyle(fontSize: 13 * sc)),
              ],
            ),
          ),
      ],
    ),
  );
  if (v != null) {
    await container
        .read(settingsProvider.notifier)
        .setOnlineFailureBehavior(v);
  }
}

/// 流缓存预算：关闭 / 100 / 200 / 500 MB（表端默认 200）。
Future<void> _pickStreamCache(BuildContext context, AppSettings s) async {
  final sc = context.watchScale();
  // 跨 async 不能再用 context，先取容器。
  final container = ProviderScope.containerOf(context, listen: false);
  const options = [(0, '关闭'), (100, '100 MB'), (200, '200 MB'), (500, '500 MB')];
  final v = await showDialog<int>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('流缓存', style: TextStyle(fontSize: 15 * sc)),
      children: [
        for (final (mb, label) in options)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, mb),
            child: Row(
              children: [
                if (s.streamCacheSizeMB == mb)
                  Icon(Icons.check_rounded,
                      size: 16 * sc, color: const Color(0xFFFF4D6E))
                else
                  SizedBox(width: 16 * sc),
                SizedBox(width: 8 * sc),
                Text(label, style: TextStyle(fontSize: 13 * sc)),
              ],
            ),
          ),
      ],
    ),
  );
  if (v != null) {
    await container.read(settingsProvider.notifier).setStreamCacheSizeMB(v);
  }
}

/// 清除流缓存：删除已落盘的在线音频缓存文件。
Future<void> _clearStreamCache(BuildContext context) async {
  final sizeMB = (await StreamCache.instance.sizeBytes() / 1048576).round();
  await StreamCache.instance.clearAll();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(sizeMB > 0 ? '已清除 ${sizeMB}MB 缓存' : '缓存为空'),
      duration: const Duration(seconds: 1),
    ),
  );
}

/// 本地库二级页：立即扫描 / 扫描格式 / 最短时长。
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
          const SnackBar(content: Text('扫描完成'), duration: Duration(seconds: 1)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('扫描失败：$e'), duration: const Duration(seconds: 2)),
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
    return _SteppedPage(rows: [
      _actionRow(
        s: s,
        icon: _scanning
            ? SizedBox(
                width: 18 * s,
                height: 18 * s,
                child: CircularProgressIndicator(strokeWidth: 2 * s))
            : Icon(Icons.refresh_rounded, size: 24 * s),
        title: '立即扫描',
        onTap: _scanning ? null : _scanNow,
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.audio_file_rounded, size: 24 * s),
        title: '扫描格式',
        subtitle: settings.scanFormats.isEmpty
            ? '未选择'
            : settings.scanFormats.join(' / '),
        onTap: () => _pickScanFormats(context, settings),
      ),
      _actionRow(
        s: s,
        icon: Icon(Icons.timer_outlined, size: 24 * s),
        title: '最短时长',
        subtitle: '过滤铃声等短音频',
        trailing: Text(
          settings.libraryMinDurationSeconds <= 0
              ? '不过滤'
              : '${settings.libraryMinDurationSeconds}s',
          style: TextStyle(
              fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
        ),
        onTap: () => _pickMinDuration(context, settings),
      ),
    ]);
  }
}

/// 关于二级页。
class _AboutPage extends ConsumerWidget {
  const _AboutPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    return _SteppedPage(rows: [
      _actionRow(
        s: s,
        icon: Icon(Icons.music_note_rounded, size: 24 * s),
        title: '弦予音乐 腕上版',
        subtitle: 'v$kAppVersion · 独立播放 / 手机联动',
      ),
    ]);
  }
}

/// 居中阶梯列表页骨架：滚动/表冠/阶梯效果由共享 SteppedListView 提供
/// （与功能页同款：一屏约三行，焦点行最大铺满中部、上下行缩小变淡），
/// 本骨架只叠加返回键浮层，rows 由宿主页传入，宿主重建即刷新。
class _SteppedPage extends StatelessWidget {
  const _SteppedPage({required this.rows});

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
            ),
            // 返回键浮层：阶梯列表占满全屏，返回键固定悬浮左上角。
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

/// 左上角悬浮返回键。
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

/// 分类入口行：彩色圆图标 + 标题/副标题 + 箭头（移动端分类页风格，
/// 分量对齐功能页大号行：44*s 圆标 + 16*s 标题）。
Widget _categoryRow({
  required double s,
  required Color color,
  required IconData icon,
  required String title,
  required String subtitle,
  required VoidCallback onTap,
}) {
  return SteppedPill(
    onTap: onTap,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: 14 * s),
      child: Row(
        children: [
          Container(
            width: 44 * s,
            height: 44 * s,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, size: 22 * s, color: Colors.white),
          ),
          SizedBox(width: 12 * s),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 16 * s, fontWeight: FontWeight.w600)),
                SizedBox(height: 2 * s),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5 * s,
                        color: Colors.white.withValues(alpha: 0.5))),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 22 * s,
            color: Colors.white.withValues(alpha: 0.38),
          ),
        ],
      ),
    ),
  );
}

/// 开关行：整行可点切换，Switch 靠右。
Widget _switchRow({
  required double s,
  required String title,
  required String subtitle,
  required bool value,
  required ValueChanged<bool> onChanged,
}) {
  return InkWell(
    onTap: () => onChanged(!value),
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: 14 * s),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 16 * s, fontWeight: FontWeight.w600)),
                SizedBox(height: 2 * s),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5 * s,
                        color: Colors.white.withValues(alpha: 0.5))),
              ],
            ),
          ),
          SizedBox(
            width: 48 * s,
            child: Switch(
                value: value,
                activeThumbColor: const Color(0xFFFF4D6E),
                onChanged: onChanged),
          ),
        ],
      ),
    ),
  );
}

/// 联动状态行：已连接（点击进控制页）/ 连接中（可取消）/ 未连接。
Widget _linkStatusRow(
    BuildContext context, WidgetRef ref, LinkState link, double pitch, double s) {
  final controller = ref.read(linkControllerProvider.notifier);
  late Widget child;
  switch (link.phase) {
    case LinkPhase.connected:
      child = Row(
        children: [
          Icon(Icons.watch_rounded, size: 24 * s, color: Colors.greenAccent),
          SizedBox(width: 12 * s),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(link.pairedName ?? '手机',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 16 * s, fontWeight: FontWeight.w600)),
                SizedBox(height: 2 * s),
                Text('已连接 · 点击进入播放控制',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5 * s,
                        color: Colors.white.withValues(alpha: 0.5))),
              ],
            ),
          ),
        ],
      );
    case LinkPhase.connecting:
      child = Row(
        children: [
          SizedBox(
              width: 20 * s,
              height: 20 * s,
              child: CircularProgressIndicator(strokeWidth: 2 * s)),
          SizedBox(width: 12 * s),
          Expanded(
            child: Text('正在连接 ${link.pairedName ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14 * s)),
          ),
          TextButton(
            onPressed: controller.disconnectManually,
            style: TextButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: 8 * s),
              minimumSize: Size(0, 32 * s),
              textStyle: TextStyle(fontSize: 12 * s),
            ),
            child: const Text('取消'),
          ),
        ],
      );
    case LinkPhase.disconnected:
      child = Row(
        children: [
          Icon(Icons.watch_off_rounded,
              size: 24 * s, color: Colors.white.withValues(alpha: 0.5)),
          SizedBox(width: 12 * s),
          Expanded(
            child: Text(
              link.pairedAddress == null ? '未配对手机' : '未连接 ${link.pairedName ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 16 * s, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      );
  }
  return SizedBox(
    height: pitch,
    child: SteppedPill(
      onTap: link.phase == LinkPhase.connected
          ? () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                    builder: (_) => const WatchControllerPage()),
              )
          : null,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 14 * s),
        child: child,
      ),
    ),
  );
}

/// 联动操作行：连接态为 播放控制/断开/更换设备，未连接为 重连/配对入口。
Widget _linkActionsRow(
    BuildContext context, WidgetRef ref, LinkState link, double pitch, double s) {
  final accent = const Color(0xFFFF4D6E);
  final controller = ref.read(linkControllerProvider.notifier);
  final btnStyle = OutlinedButton.styleFrom(
    padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 2 * s),
    minimumSize: Size(0, 30 * s),
    textStyle: TextStyle(fontSize: 11.5 * s),
  );
  final List<Widget> buttons;
  switch (link.phase) {
    case LinkPhase.connected:
      buttons = [
        OutlinedButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
                builder: (_) => const WatchControllerPage()),
          ),
          style: btnStyle,
          child: const Text('播放控制'),
        ),
        OutlinedButton(
          onPressed: controller.disconnectManually,
          style: btnStyle,
          child: const Text('断开'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const PairView()),
          ),
          style: btnStyle,
          child: const Text('更换设备'),
        ),
      ];
    case LinkPhase.connecting:
      buttons = const [];
    case LinkPhase.disconnected:
      buttons = [
        if (link.pairedAddress != null)
          OutlinedButton(
            onPressed: controller.retry,
            style: btnStyle,
            child: const Text('重新连接'),
          )
        else
          FilledButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const PairView()),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 2 * s),
              minimumSize: Size(0, 30 * s),
              textStyle: TextStyle(fontSize: 11.5 * s),
            ),
            child: const Text('选择设备'),
          ),
        if (link.pairedAddress != null)
          OutlinedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const PairView()),
            ),
            style: btnStyle,
            child: const Text('更换设备'),
          ),
      ];
  }
  return SizedBox(
    height: pitch,
    child: SteppedPill(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 14 * s),
        child: Row(children: [
          for (var i = 0; i < buttons.length; i++) ...[
            if (i > 0) SizedBox(width: 6 * s),
            buttons[i],
          ],
        ]),
      ),
    ),
  );
}

/// 普通设置行：图标 + 标题/副标题 + 可选右侧值，整行可点。
Widget _actionRow({
  required double s,
  required Widget icon,
  required String title,
  String? subtitle,
  Widget? trailing,
  VoidCallback? onTap,
}) {
  return SteppedPill(
    onTap: onTap,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: 14 * s),
      child: Row(
        children: [
          icon,
          SizedBox(width: 12 * s),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 16 * s, fontWeight: FontWeight.w600)),
                ...?subtitle == null
                    ? null
                    : [
                        SizedBox(height: 2 * s),
                        Text(subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11.5 * s,
                                color:
                                    Colors.white.withValues(alpha: 0.5))),
                      ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    ),
  );
}

Future<void> _pickScanFormats(BuildContext context, AppSettings s) async {
  final sc = context.watchScale();
  // 跨 async 不能再用 context，先取容器。
  final container = ProviderScope.containerOf(context, listen: false);
  final selected = {...s.scanFormats};
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('扫描格式', style: TextStyle(fontSize: 15 * sc)),
      // 233dp 圆屏上 260 固定宽必裁边，收敛到 200 并随屏径缩放。
      content: SizedBox(
        width: 200 * sc,
        child: StatefulBuilder(
          builder: (context, setDialogState) => SingleChildScrollView(
            child: Wrap(
              spacing: 6 * sc,
              runSpacing: 0,
              children: [
                for (final f in kSupportedScanFormats)
                  FilterChip(
                    label: Text(f, style: TextStyle(fontSize: 12 * sc)),
                    selected: selected.contains(f),
                    onSelected: (v) => setDialogState(() {
                      v ? selected.add(f) : selected.remove(f);
                    }),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('取消', style: TextStyle(fontSize: 13 * sc)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text('确定', style: TextStyle(fontSize: 13 * sc)),
        ),
      ],
    ),
  );
  if (ok == true) {
    // 至少保留一种格式，避免全关后扫描为空难以发现原因。
    final next = selected.isEmpty
        ? List<String>.from(kSupportedScanFormats)
        : selected.toList();
    await container
        .read(settingsProvider.notifier)
        .setScanFormats(next);
  }
}

Future<void> _pickMinDuration(BuildContext context, AppSettings s) async {
  final sc = context.watchScale();
  // 跨 async 不能再用 context，先取容器。
  final container = ProviderScope.containerOf(context, listen: false);
  const options = [(0, '不过滤'), (30, '30 秒以上'), (60, '1 分钟以上'), (120, '2 分钟以上')];
  final v = await showDialog<int>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('最短时长', style: TextStyle(fontSize: 15 * sc)),
      children: [
        for (final (secs, label) in options)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, secs),
            child: Row(
              children: [
                if (s.libraryMinDurationSeconds == secs)
                  Icon(Icons.check_rounded,
                      size: 16 * sc, color: const Color(0xFFFF4D6E))
                else
                  SizedBox(width: 16 * sc),
                SizedBox(width: 8 * sc),
                Text(label, style: TextStyle(fontSize: 13 * sc)),
              ],
            ),
          ),
      ],
    ),
  );
  if (v != null) {
    await container
        .read(settingsProvider.notifier)
        .setLibraryMinDurationSeconds(v);
  }
}

Future<void> _pickQuality(BuildContext context, AppSettings s) async {
  final sc = context.watchScale();
  // 跨 async 不能再用 context，先取容器。
  final container = ProviderScope.containerOf(context, listen: false);
  const options = [('320k', '标准 320kbps'), ('flac', '无损 FLAC')];
  final v = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('在线音质', style: TextStyle(fontSize: 15 * sc)),
      children: [
        for (final (q, label) in options)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, q),
            child: Row(
              children: [
                if (s.onlineQuality == q)
                  Icon(Icons.check_rounded,
                      size: 16 * sc, color: const Color(0xFFFF4D6E))
                else
                  SizedBox(width: 16 * sc),
                SizedBox(width: 8 * sc),
                Text(label, style: TextStyle(fontSize: 13 * sc)),
              ],
            ),
          ),
      ],
    ),
  );
  if (v != null) {
    await container.read(settingsProvider.notifier).setOnlineQuality(v);
  }
}
