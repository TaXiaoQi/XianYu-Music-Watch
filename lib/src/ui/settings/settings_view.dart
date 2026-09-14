import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings.dart';
import '../../core/watch_fit.dart';
import '../../library/library_provider.dart';
import '../../link/link_provider.dart';
import '../controller/watch_controller_page.dart';
import '../pair/pair_view.dart';

/// 设置页（底栏左侧 tab）：手机联动 / 播放 / 本地库 / 在线音源 / 关于。
///
/// 原「控制」tab 收编进「手机联动」区块：连接状态、重连、更换设备、
/// 播放控制入口都在这里；连接成功也会自动跳转播放控制页。
class SettingsView extends ConsumerStatefulWidget {
  const SettingsView({super.key});

  @override
  ConsumerState<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends ConsumerState<SettingsView> {
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

  Future<void> _pickScanFormats(AppSettings s) async {
    final selected = {...s.scanFormats};
    final sc = context.watchScale();
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
      final next = selected.isEmpty ? List<String>.from(kSupportedScanFormats) : selected.toList();
      await ref.read(settingsProvider.notifier).setScanFormats(next);
    }
  }

  Future<void> _pickMinDuration(AppSettings s) async {
    const options = [(0, '不过滤'), (30, '30 秒以上'), (60, '1 分钟以上'), (120, '2 分钟以上')];
    final sc = context.watchScale();
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
      await ref.read(settingsProvider.notifier).setLibraryMinDurationSeconds(v);
    }
  }

  Future<void> _pickQuality(AppSettings s) async {
    const options = [('320k', '标准 320kbps'), ('flac', '无损 FLAC')];
    final sc = context.watchScale();
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
      await ref.read(settingsProvider.notifier).setOnlineQuality(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final link = ref.watch(linkControllerProvider);
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    final accent = const Color(0xFFFF4D6E);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          // 屏径等比缩放适配。
          padding: EdgeInsets.symmetric(horizontal: 14 * s, vertical: 6 * s),
          children: [
            // 顶栏：返回 + 标题（push 页面，系统返回也可退出）。
            Row(
              children: [
                const BackButton(),
                SizedBox(width: 4 * s),
                Text('设置',
                    style: TextStyle(
                        fontSize: 15 * s,
                        fontWeight: FontWeight.w700,
                        color: Colors.white.withValues(alpha: 0.9))),
              ],
            ),
            _sectionLabel('手机联动', s),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: settings.watchLinkageEnabled,
              activeThumbColor: accent,
              title: Text('腕上联动',
                  style: TextStyle(fontSize: 13 * s, fontWeight: FontWeight.w600)),
              subtitle: Text(
                settings.watchLinkageEnabled ? '连接手机后可远程控制播放' : '已关闭，不自动连接手机',
                style: TextStyle(fontSize: 11 * s, color: Colors.white.withValues(alpha: 0.5)),
              ),
              onChanged: (v) =>
                  ref.read(settingsProvider.notifier).setWatchLinkageEnabled(v),
            ),
            _linkStatusCard(link, s),
            SizedBox(height: 6 * s),
            _sectionLabel('播放', s),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: settings.keepScreenOn,
              activeThumbColor: accent,
              title: Text('保持屏幕常亮',
                  style: TextStyle(fontSize: 13 * s, fontWeight: FontWeight.w600)),
              subtitle: Text('播放时屏幕不自动熄灭',
                  style: TextStyle(fontSize: 11 * s, color: Colors.white.withValues(alpha: 0.5))),
              onChanged: (v) =>
                  ref.read(settingsProvider.notifier).setKeepScreenOn(v),
            ),
            SizedBox(height: 6 * s),
            _sectionLabel('本地库', s),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: _scanning
                  ? SizedBox(
                      width: 18 * s, height: 18 * s,
                      child: CircularProgressIndicator(strokeWidth: 2 * s))
                  : Icon(Icons.refresh_rounded, size: 20 * s),
              title: Text('立即扫描',
                  style: TextStyle(fontSize: 13 * s, fontWeight: FontWeight.w600)),
              onTap: _scanning ? null : _scanNow,
            ),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.audio_file_rounded, size: 20 * s),
              title: Text('扫描格式',
                  style: TextStyle(fontSize: 13 * s, fontWeight: FontWeight.w600)),
              subtitle: Text(
                settings.scanFormats.isEmpty ? '未选择' : settings.scanFormats.join(' / '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11 * s, color: Colors.white.withValues(alpha: 0.5)),
              ),
              onTap: () => _pickScanFormats(settings),
            ),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.timer_outlined, size: 20 * s),
              title: Text('最短时长',
                  style: TextStyle(fontSize: 13 * s, fontWeight: FontWeight.w600)),
              subtitle: Text('过滤铃声等短音频',
                  style: TextStyle(fontSize: 11 * s, color: Colors.white.withValues(alpha: 0.5))),
              trailing: Text(
                settings.libraryMinDurationSeconds <= 0
                    ? '不过滤'
                    : '${settings.libraryMinDurationSeconds}s',
                style: TextStyle(fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
              ),
              onTap: () => _pickMinDuration(settings),
            ),
            SizedBox(height: 6 * s),
            _sectionLabel('在线音源', s),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.high_quality_rounded, size: 20 * s),
              title: Text('音质偏好',
                  style: TextStyle(fontSize: 13 * s, fontWeight: FontWeight.w600)),
              trailing: Text(
                settings.onlineQuality == 'flac' ? '无损' : '320k',
                style: TextStyle(fontSize: 12 * s, color: Colors.white.withValues(alpha: 0.7)),
              ),
              onTap: () => _pickQuality(settings),
            ),
            SizedBox(height: 6 * s),
            _sectionLabel('关于', s),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.music_note_rounded, size: 20 * s),
              title: Text('弦予音乐 腕上版',
                  style: TextStyle(fontSize: 13 * s, fontWeight: FontWeight.w600)),
              subtitle: Text('v0.1.0+1 · 独立播放 / 手机联动',
                  style: TextStyle(fontSize: 11 * s)),
            ),
            SizedBox(height: 12 * s),
          ],
        ),
      ),
    );
  }

  /// 联动状态卡：已连接（进控制页）/ 连接中 / 未连接（重连/配对）。
  Widget _linkStatusCard(LinkState link, double s) {
    final accent = const Color(0xFFFF4D6E);
    final controller = ref.read(linkControllerProvider.notifier);
    final btnStyle = OutlinedButton.styleFrom(
      padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 4 * s),
      minimumSize: Size(0, 32 * s),
      textStyle: TextStyle(fontSize: 12 * s),
    );

    final List<Widget> children;
    switch (link.phase) {
      case LinkPhase.connected:
        children = [
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.watch_rounded,
                size: 20 * s, color: Colors.greenAccent),
            title: Text(link.pairedName ?? '手机',
                style: TextStyle(fontSize: 13 * s, fontWeight: FontWeight.w600)),
            subtitle: Text('已连接 · 点击进入播放控制',
                style: TextStyle(fontSize: 11 * s, color: Colors.white.withValues(alpha: 0.5))),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const WatchControllerPage()),
            ),
          ),
          Row(
            children: [
              OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const WatchControllerPage()),
                ),
                style: btnStyle,
                child: const Text('播放控制'),
              ),
              SizedBox(width: 8 * s),
              OutlinedButton(
                onPressed: controller.disconnectManually,
                style: btnStyle,
                child: const Text('断开'),
              ),
              SizedBox(width: 8 * s),
              OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const PairView()),
                ),
                style: btnStyle,
                child: const Text('更换设备'),
              ),
            ],
          ),
        ];
      case LinkPhase.connecting:
        children = [
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: SizedBox(
                width: 18 * s, height: 18 * s,
                child: CircularProgressIndicator(strokeWidth: 2 * s)),
            title: Text('正在连接 ${link.pairedName ?? ''}',
                style: TextStyle(fontSize: 13 * s)),
            trailing: TextButton(
              onPressed: controller.disconnectManually,
              child: Text('取消', style: TextStyle(fontSize: 12 * s)),
            ),
          ),
        ];
      case LinkPhase.disconnected:
        children = [
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.watch_off_rounded,
                size: 20 * s, color: Colors.white.withValues(alpha: 0.5)),
            title: Text(
              link.pairedAddress == null ? '未配对手机' : '未连接 ${link.pairedName ?? ''}',
              style: TextStyle(fontSize: 13 * s, fontWeight: FontWeight.w600),
            ),
          ),
          Row(
            children: [
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
                  style: btnStyle.copyWith(
                    backgroundColor: WidgetStatePropertyAll(accent),
                  ),
                  child: const Text('选择设备'),
                ),
              SizedBox(width: 8 * s),
              if (link.pairedAddress != null)
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const PairView()),
                  ),
                  style: btnStyle,
                  child: const Text('更换设备'),
                ),
            ],
          ),
        ];
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  Widget _sectionLabel(String text, double s) {
    return Padding(
      padding: EdgeInsets.only(top: 8 * s, bottom: 2 * s),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11 * s,
          fontWeight: FontWeight.w700,
          letterSpacing: 1 * s,
          color: Colors.white.withValues(alpha: 0.4),
        ),
      ),
    );
  }
}
