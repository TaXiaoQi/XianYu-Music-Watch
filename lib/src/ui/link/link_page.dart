import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_mode.dart';
import '../../core/settings.dart';
import '../../core/watch_fit.dart';
import '../../link/link_provider.dart';
import '../common/full_dialog.dart';
import '../common/stepped_list.dart';
import '../controller/watch_controller_page.dart';
import '../pair/pair_view.dart';

/// 设备联动入口卡（功能页第一位）：副标题实时反映连接状态。
/// 初次配对只能由手表发起——把入口放到最显眼的位置，避免
/// 「手机点了播放、手表没反应」的困惑。
class LinkEntryTile extends ConsumerWidget {
  const LinkEntryTile({super.key});

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
      title: '设备联动',
      subtitle: subtitle,
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 22 * s,
        color: Colors.white.withValues(alpha: 0.38),
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const LinkagePage()),
      ),
    );
  }
}

/// 设备联动二级页：顶部居中表头 + 开关 + 设备连接/已连接分流。
/// 连接态只保留一行「已连接 xx」，点击进设备页；底下仨操作
/// （播放控制/断开/更换设备）收纳进设备页，不再悬浮在列表底部。
class LinkagePage extends ConsumerWidget {
  const LinkagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    final link = ref.watch(linkControllerProvider);
    // 独立模式下此页多一行「切换到联动模式」（设置里已移除该入口，
    // 切换统一收进设备联动页）。
    final isStandalone =
        ref.watch(appModeProvider).valueOrNull == appModeStandalone;
    final rows = <Widget>[
      _switchRow(
        s: s,
        title: '设备联动',
        subtitle:
            settings.watchLinkageEnabled ? '连接手机后可远程控制播放' : '已关闭，不自动连接手机',
        value: settings.watchLinkageEnabled,
        onChanged: (v) =>
            ref.read(settingsProvider.notifier).setWatchLinkageEnabled(v),
      ),
      if (isStandalone) _toLinkModeRow(context, s),
      ..._linkRows(context, ref, link, s),
    ];
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            SteppedListView(
              header: const PageTitleHeader('设备联动'),
              headerExtent: 46,
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

/// 按连接阶段生成设备行：
/// 已连接 → 单行「已连接 xx」（点击进设备页，仨操作在此页内）；
/// 未连接但有设备 → 点行即重连；从未配对 → 点行进选择页。
List<Widget> _linkRows(
    BuildContext context, WidgetRef ref, LinkState link, double s) {
  final rows = <Widget>[];
  switch (link.phase) {
    case LinkPhase.connected:
      rows.add(_connectedRow(context, link, s));
    case LinkPhase.connecting:
      rows.add(_connectingRow(context, ref, link, s));
    case LinkPhase.disconnected:
      if (link.pairedAddress != null) {
        // 没链接但有设备：点击就是连接设备。
        rows.add(SteppedTile(
          leading: SteppedLeadCircle(
            color: const Color(0xFF4A90D9),
            child: Icon(Icons.watch_off_rounded,
                size: 22 * s, color: Colors.white),
          ),
          title: '未连接 ${link.pairedName ?? ''}',
          subtitle: '点此连接设备',
          trailing: Icon(Icons.chevron_right_rounded,
              size: 22 * s, color: Colors.white.withValues(alpha: 0.38)),
          onTap: ref.read(linkControllerProvider.notifier).retry,
        ));
        rows.add(SteppedTile(
          leading: SteppedLeadCircle(
            color: const Color(0xFF5FA97C),
            child: Icon(Icons.swap_horiz_rounded, size: 22 * s, color: Colors.white),
          ),
          title: '更换设备',
          subtitle: '连接到另一台手机',
          trailing: Icon(Icons.chevron_right_rounded,
              size: 22 * s, color: Colors.white.withValues(alpha: 0.38)),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const PairView()),
          ),
        ));
      } else {
        // 从未配对：点行进设备选择（仅手表可发起配对）。
        rows.add(SteppedTile(
          leading: SteppedLeadCircle(
            color: const Color(0xFFFF4D6E),
            child: Icon(Icons.watch_rounded, size: 22 * s, color: Colors.white),
          ),
          title: '选择设备',
          subtitle: '点击配对连接手机',
          trailing: Icon(Icons.chevron_right_rounded,
              size: 22 * s, color: Colors.white.withValues(alpha: 0.38)),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const PairView()),
          ),
        ));
      }
  }
  return rows;
}

/// 独立模式 → 切回联动：二次确认 → 写模式字段 → 原生杀掉重启进轻量联动。
/// 入口收在设备联动页（设置里已移除同功能入口）。
Widget _toLinkModeRow(BuildContext context, double s) {
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
    onTap: () => _switchToLinkMode(context),
  );
}

Future<void> _switchToLinkMode(BuildContext context) async {
  final ok = await showFullConfirm(
    context,
    title: '切换到联动模式',
    message: '将重启应用并进入轻量联动模式。该模式更省电、常驻后台，手'
        '机一播放即可推送到手表；独立播放功能需在联动页切换回来。',
    okLabel: '重启进入',
  );
  if (ok != true || !context.mounted) return;
  await writeAppMode(appModeLink);
  const MethodChannel('xianyu/system_nav').invokeMethod('restartApp');
}

/// 已连接行：点击进入设备页（仨操作收纳在此页）。
Widget _connectedRow(BuildContext context, LinkState link, double s) {
  return SteppedTile(
    leading: SteppedLeadCircle(
      color: const Color(0xFF3DB98A),
      child:
          Icon(Icons.watch_rounded, size: 22 * s, color: Colors.white),
    ),
    title: '已连接 ${link.pairedName ?? ''}',
    subtitle: link.viaCloud ? '云中继 · 点击进入设备管理' : '蓝牙连接 · 点击进入设备管理',
    trailing: Icon(
      Icons.chevron_right_rounded,
      size: 22 * s,
      color: Colors.white.withValues(alpha: 0.38),
    ),
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const LinkDevicePage()),
    ),
  );
}

/// 连接中行：菊花 + 取消。
Widget _connectingRow(
    BuildContext context, WidgetRef ref, LinkState link, double s) {
  final controller = ref.read(linkControllerProvider.notifier);
  return SteppedPill(
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: 3 * s),
      child: Row(
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
      ),
    ),
  );
}

/// 设备页（点击「已连接」进入）：收纳播放控制/断开/更换设备三个操作，
/// 避免它们悬浮在联动页底部；顶上居中表头「设备联动」。
class LinkDevicePage extends ConsumerWidget {
  const LinkDevicePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final link = ref.watch(linkControllerProvider);
    final controller = ref.read(linkControllerProvider.notifier);
    final accent = const Color(0xFFFF4D6E);
    final rows = <Widget>[
      // 连接信息行。
      SteppedTile(
        leading: SteppedLeadCircle(
          color: const Color(0xFF3DB98A),
          child: Icon(Icons.watch_rounded, size: 22 * s, color: Colors.white),
        ),
        title: '已连接 ${link.pairedName ?? ''}',
        subtitle: link.viaCloud ? '云中继连接' : '蓝牙连接',
      ),
      // 仨操作。
      SteppedTile(
        leading: SteppedLeadCircle(
          color: const Color(0xFF4A90D9),
          child:
              Icon(Icons.play_circle_rounded, size: 22 * s, color: Colors.white),
        ),
        title: '播放控制',
        subtitle: '远程控制手机播放',
        trailing: Icon(Icons.chevron_right_rounded,
            size: 22 * s, color: Colors.white.withValues(alpha: 0.38)),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const WatchControllerPage()),
        ),
      ),
      SteppedTile(
        leading: SteppedLeadCircle(
          color: accent,
          child: Icon(Icons.link_off_rounded, size: 22 * s, color: Colors.white),
        ),
        title: '断开连接',
        subtitle: '停止联动并回到未连接',
        trailing: Icon(Icons.chevron_right_rounded,
            size: 22 * s, color: Colors.white.withValues(alpha: 0.38)),
        onTap: () {
          controller.disconnectManually();
          Navigator.of(context).maybePop();
        },
      ),
      SteppedTile(
        leading: SteppedLeadCircle(
          color: const Color(0xFF5FA97C),
          child: Icon(Icons.swap_horiz_rounded, size: 22 * s, color: Colors.white),
        ),
        title: '更换设备',
        subtitle: '连接到另一台手机',
        trailing: Icon(Icons.chevron_right_rounded,
            size: 22 * s, color: Colors.white.withValues(alpha: 0.38)),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const PairView()),
        ),
      ),
    ];
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            SteppedListView(
              header: const PageTitleHeader('设备联动'),
              headerExtent: 46,
              itemCount: rows.length,
              itemBuilder: (context, i) => rows[i],
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

/// 联动开关行（对齐设置页开关行样式）。
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