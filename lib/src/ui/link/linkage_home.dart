import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_mode.dart';
import '../../core/watch_fit.dart';
import '../common/full_dialog.dart';
import '../common/stepped_list.dart';
import '../controller/watch_controller_page.dart';
import 'link_page.dart';

class LinkageHome extends ConsumerStatefulWidget {
  const LinkageHome({super.key});

  @override
  ConsumerState<LinkageHome> createState() => _LinkageHomeState();
}

class _LinkageHomeState extends ConsumerState<LinkageHome> {
  Future<void> _toStandalone() async {
    final ok = await showFullConfirm(
      context,
      title: '切换到独立模式',
      message: '将停止联动并进入完整的独立音乐服务。当前手机联动会话会被'
          '中断。',
      okLabel: '立即切换',
    );
    if (ok != true || !mounted) return;
    await ref.read(appModeProvider.notifier).change(appModeStandalone);
  }

  Widget _functionPage({required bool Function() isCurrent}) {
    final s = context.watchScale();
    return Container(
      color: const Color(0xFF0C0C0F),
      child: SafeArea(
        child: SteppedListView(
          header: const PageTitleHeader('联动'),
          headerExtent: 46,
          rotaryGuard: isCurrent,
          itemCount: 2,
          itemBuilder: (context, i) {
            if (i == 0) return const LinkEntryTile();
            return SteppedTile(
              leading: SteppedLeadCircle(
                color: const Color(0xFFFF4D6E),
                child: Icon(Icons.rocket_launch_rounded,
                    size: 22 * s, color: Colors.white),
              ),
              title: '启动独立模式',
              subtitle: '完整独立播放 · 需重启生效',
              trailing: Icon(
                Icons.chevron_right_rounded,
                size: 22 * s,
                color: Colors.white.withValues(alpha: 0.38),
              ),
              onTap: _toStandalone,
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WatchControllerPage(
      isRootHome: true,
      frontBuilder: ({required isCurrent}) => _functionPage(isCurrent: isCurrent),
    );
  }
}