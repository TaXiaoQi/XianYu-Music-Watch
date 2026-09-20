import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_mode.dart';
import '../../core/settings.dart';
import '../../core/watch_fit.dart';
import '../../link/link_provider.dart';
import '../common/full_dialog.dart';
import '../common/stepped_list.dart';
import '../controller/watch_controller_page.dart';
import '../pair/pair_view.dart';

class LinkEntryTile extends ConsumerWidget {
  const LinkEntryTile({
    super.key,
    this.titleColor,
    this.subtitleColor,
    this.backgroundColor,
  });

  final Color? titleColor;
  final Color? subtitleColor;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    final link = ref.watch(linkControllerProvider);

    String subtitle;
    if (!settings.watchLinkageEnabled) {
      subtitle = '已关闭';
    } else {
      switch (link.phase) {
        case LinkPhase.connected:
          subtitle = '已连接 ${link.pairedName ?? ''}';
        case LinkPhase.connecting:
          subtitle = '正在连接…';
        case LinkPhase.disconnected:
          subtitle = link.pairedAddress == null ? '点此配对手机' : '未连接，点此连接设备';
      }
    }

    return SteppedTile(
      titleColor: titleColor,
      subtitleColor: subtitleColor,
      backgroundColor: backgroundColor,
      leading: SteppedLeadCircle(
        color: const Color(0xFF4A90D9),
        child: Icon(
          link.phase == LinkPhase.connected
              ? Icons.watch_rounded
              : Icons.watch_off_rounded,
          size: 22 * s,
          color: Colors.white,
        ),
      ),
      title: '联动',
      subtitle: subtitle,
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 22 * s,
        color:
            titleColor?.withValues(alpha: 0.38) ??
            Colors.white.withValues(alpha: 0.38),
      ),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const LinkagePage())),
    );
  }
}

class LinkagePage extends ConsumerWidget {
  const LinkagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    final link = ref.watch(linkControllerProvider);
    final isStandalone = ref.watch(appModeProvider) == appModeStandalone;
    final rows = <Widget>[
      _switchRow(
        s: s,
        title: '联动',
        subtitle: settings.watchLinkageEnabled ? '连接手机后可远程控制播放' : '已关闭，不自动连接手机',
        value: settings.watchLinkageEnabled,
        onChanged: (v) =>
            ref.read(settingsProvider.notifier).setWatchLinkageEnabled(v),
      ),
      if (isStandalone) _toLinkModeRow(context, ref, s),
      ..._linkRows(context, ref, link, s),
    ];
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            SteppedListView(
              header: const PageTitleHeader('联动'),
              headerExtent: 46,
              itemCount: rows.length,
              itemBuilder: (context, i) => rows[i],
            ),
            Positioned(top: 2 * s, left: 2 * s, child: _backChip(s)),
          ],
        ),
      ),
    );
  }
}

List<Widget> _linkRows(
  BuildContext context,
  WidgetRef ref,
  LinkState link,
  double s,
) {
  final rows = <Widget>[];
  switch (link.phase) {
    case LinkPhase.connected:
      rows.add(_connectedRow(context, link, s));
    case LinkPhase.connecting:
      rows.add(_connectingRow(context, ref, link, s));
    case LinkPhase.disconnected:
      if (link.pairedAddress != null) {
        rows.add(
          SteppedTile(
            leading: SteppedLeadCircle(
              color: const Color(0xFF4A90D9),
              child: Icon(
                Icons.watch_off_rounded,
                size: 22 * s,
                color: Colors.white,
              ),
            ),
            title: '未连接 ${link.pairedName ?? ''}',
            subtitle: '点此连接设备',
            trailing: Icon(
              Icons.chevron_right_rounded,
              size: 22 * s,
              color: Colors.white.withValues(alpha: 0.38),
            ),
            onTap: ref.read(linkControllerProvider.notifier).retry,
          ),
        );
        rows.add(
          SteppedTile(
            leading: SteppedLeadCircle(
              color: const Color(0xFF5FA97C),
              child: Icon(
                Icons.swap_horiz_rounded,
                size: 22 * s,
                color: Colors.white,
              ),
            ),
            title: '更换设备',
            subtitle: '连接到另一台手机',
            trailing: Icon(
              Icons.chevron_right_rounded,
              size: 22 * s,
              color: Colors.white.withValues(alpha: 0.38),
            ),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const PairView())),
          ),
        );
      } else {
        rows.add(
          SteppedTile(
            leading: SteppedLeadCircle(
              color: const Color(0xFFFF4D6E),
              child: Icon(
                Icons.watch_rounded,
                size: 22 * s,
                color: Colors.white,
              ),
            ),
            title: '选择设备',
            subtitle: '点击配对连接手机',
            trailing: Icon(
              Icons.chevron_right_rounded,
              size: 22 * s,
              color: Colors.white.withValues(alpha: 0.38),
            ),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => const PairView())),
          ),
        );
      }
  }
  return rows;
}

Widget _toLinkModeRow(BuildContext context, WidgetRef ref, double s) {
  return SteppedTile(
    leading: SteppedLeadCircle(
      color: const Color(0xFF3DB98A),
      child: Icon(Icons.watch_rounded, size: 22 * s, color: Colors.white),
    ),
    title: '切换到联动模式',
    subtitle: '轻量联动 · 保存后重启生效',
    trailing: Icon(
      Icons.chevron_right_rounded,
      size: 22 * s,
      color: Colors.white.withValues(alpha: 0.38),
    ),
    onTap: () => _switchToLinkMode(context, ref),
  );
}

Future<void> _switchToLinkMode(BuildContext context, WidgetRef ref) async {
  final ok = await showFullConfirm(
    context,
    title: '切换到联动模式',
    message:
        '将进入轻量联动模式。该模式更省电、常驻后台，手机一播放即可'
        '推送到手表；独立播放功能需在联动页切换回来。',
    okLabel: '立即切换',
  );
  if (ok != true || !context.mounted) return;
  await ref.read(appModeProvider.notifier).change(appModeLink);
}

Widget _connectedRow(BuildContext context, LinkState link, double s) {
  return SteppedTile(
    leading: SteppedLeadCircle(
      color: const Color(0xFF3DB98A),
      child: Icon(Icons.watch_rounded, size: 22 * s, color: Colors.white),
    ),
    title: '已连接 ${link.pairedName ?? ''}',
    subtitle: link.viaCloud ? '云中继 · 点击进入设备管理' : '蓝牙连接 · 点击进入设备管理',
    trailing: Icon(
      Icons.chevron_right_rounded,
      size: 22 * s,
      color: Colors.white.withValues(alpha: 0.38),
    ),
    onTap: () => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const LinkDevicePage())),
  );
}

Widget _connectingRow(
  BuildContext context,
  WidgetRef ref,
  LinkState link,
  double s,
) {
  final controller = ref.read(linkControllerProvider.notifier);
  return SteppedPill(
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: 3 * s),
      child: Row(
        children: [
          SizedBox(
            width: 20 * s,
            height: 20 * s,
            child: CircularProgressIndicator(strokeWidth: 2 * s),
          ),
          SizedBox(width: 12 * s),
          Expanded(
            child: Text(
              '正在连接 ${link.pairedName ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14 * s),
            ),
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
      ),
    ),
  );
}

class LinkDevicePage extends ConsumerWidget {
  const LinkDevicePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final link = ref.watch(linkControllerProvider);
    final controller = ref.read(linkControllerProvider.notifier);
    final accent = const Color(0xFFFF4D6E);
    final rows = <Widget>[
      SteppedTile(
        leading: SteppedLeadCircle(
          color: const Color(0xFF3DB98A),
          child: Icon(Icons.watch_rounded, size: 22 * s, color: Colors.white),
        ),
        title: '已连接 ${link.pairedName ?? ''}',
        subtitle: link.viaCloud ? '云中继连接' : '蓝牙连接',
      ),
      SteppedTile(
        leading: SteppedLeadCircle(
          color: const Color(0xFF4A90D9),
          child: Icon(
            Icons.play_circle_rounded,
            size: 22 * s,
            color: Colors.white,
          ),
        ),
        title: '播放控制',
        subtitle: '远程控制手机播放',
        trailing: Icon(
          Icons.chevron_right_rounded,
          size: 22 * s,
          color: Colors.white.withValues(alpha: 0.38),
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const WatchControllerPage()),
        ),
      ),
      SteppedTile(
        leading: SteppedLeadCircle(
          color: accent,
          child: Icon(
            Icons.link_off_rounded,
            size: 22 * s,
            color: Colors.white,
          ),
        ),
        title: '断开连接',
        subtitle: '停止联动并回到未连接',
        trailing: Icon(
          Icons.chevron_right_rounded,
          size: 22 * s,
          color: Colors.white.withValues(alpha: 0.38),
        ),
        onTap: () {
          controller.disconnectManually();
          Navigator.of(context).maybePop();
        },
      ),
      SteppedTile(
        leading: SteppedLeadCircle(
          color: const Color(0xFF5FA97C),
          child: Icon(
            Icons.swap_horiz_rounded,
            size: 22 * s,
            color: Colors.white,
          ),
        ),
        title: '更换设备',
        subtitle: '连接到另一台手机',
        trailing: Icon(
          Icons.chevron_right_rounded,
          size: 22 * s,
          color: Colors.white.withValues(alpha: 0.38),
        ),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const PairView())),
      ),
    ];
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            SteppedListView(
              header: const PageTitleHeader('联动'),
              headerExtent: 46,
              itemCount: rows.length,
              itemBuilder: (context, i) => rows[i],
            ),
            Positioned(top: 2 * s, left: 2 * s, child: _backChip(s)),
          ],
        ),
      ),
    );
  }
}

Widget _switchRow({
  required double s,
  required String title,
  required String subtitle,
  required bool value,
  required ValueChanged<bool> onChanged,
}) {
  return SteppedPill(
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: 3 * s),
      child: Row(
        children: [
          Padding(
            padding: EdgeInsets.only(left: 4 * s),
            child: SteppedLeadCircle(
              color: const Color(0xFFFF4D6E),
              child: Icon(
                Icons.sync_alt_rounded,
                size: 20 * s,
                color: Colors.white,
              ),
            ),
          ),
          SizedBox(width: 12 * s),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16 * s,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 2 * s),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5 * s,
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 48 * s,
            child: Switch(
              value: value,
              activeThumbColor: const Color(0xFFFF4D6E),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    ),
  );
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
          child: Icon(
            Icons.arrow_back_rounded,
            size: 18 * s,
            color: Colors.white.withValues(alpha: 0.85),
          ),
        ),
      ),
    ),
  );
}
