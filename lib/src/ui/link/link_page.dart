import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings.dart';
import '../../core/watch_fit.dart';
import '../../link/link_provider.dart';
import '../common/stepped_list.dart';
import '../controller/watch_controller_page.dart';
import '../pair/pair_view.dart';

/// 腕上联动入口卡（功能页第一位）：副标题实时反映连接状态。
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
          subtitle = link.pairedAddress == null ? '点此配对手机' : '未连接，点此重连';
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
      title: '腕上联动',
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

/// 腕上联动二级页：开关 + 连接状态 + 操作按钮。
class LinkagePage extends ConsumerWidget {
  const LinkagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    final link = ref.watch(linkControllerProvider);
    final rows = <Widget>[
      _switchRow(
        s: s,
        title: '腕上联动',
        subtitle:
            settings.watchLinkageEnabled ? '连接手机后可远程控制播放' : '已关闭，不自动连接手机',
        value: settings.watchLinkageEnabled,
        onChanged: (v) =>
            ref.read(settingsProvider.notifier).setWatchLinkageEnabled(v),
      ),
      _linkStatusRow(context, ref, link, 64 * s, s),
      if (link.phase != LinkPhase.connecting)
        _linkActionsRow(context, ref, link, 64 * s, s),
    ];
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

/// 联动开关行（对齐设置页开关行样式）。
Widget _switchRow({
  required double s,
  required String title,
  required String subtitle,
  required bool value,
  required ValueChanged<bool> onChanged,
}) {
  return SizedBox(
    height: 64 * s,
    child: SteppedPill(
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
