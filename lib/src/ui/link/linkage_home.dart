import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_mode.dart';
import '../../core/watch_fit.dart';
import '../common/full_dialog.dart';
import '../common/stepped_list.dart';
import '../controller/watch_controller_page.dart';
import 'link_page.dart';

/// 联动模式主首页：三页横移（功能 → 播放 → 歌词），复刻网易云手表形态。
///
/// 低占用、常驻后台（手机播放即可实时推送）；最左「功能」页收纳唯一
/// 入口「启动独立模式」：二次确认 → 写模式字段 → 原生杀掉重启进完整
/// 独立服务。根路由返回（鸿蒙侧滑/安卓左缘条）→ 先翻回上一页，最左页
/// 才退后台驻留（重开秒回、联动会话不断），见 WatchControllerPage。
class LinkageHome extends ConsumerStatefulWidget {
  const LinkageHome({super.key});

  @override
  ConsumerState<LinkageHome> createState() => _LinkageHomeState();
}

class _LinkageHomeState extends ConsumerState<LinkageHome> {
  /// 启动独立模式：二次确认 → 热切换（落盘 + 补初始化，不重启进程，
  /// 自动回到完整独立服务首页）。
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

  /// 最左「功能」页：设备联动入口 + 启动独立模式。
  Widget _functionPage({required bool Function() isCurrent}) {
    final s = context.watchScale();
    return Container(
      color: const Color(0xFF0C0C0F),
      child: SafeArea(
        child: SteppedListView(
          header: const PageTitleHeader('设备联动'),
          headerExtent: 46,
          // 表冠门禁：仅功能页为 PageView 当前页时才响应表冠滚动。
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
    // 根路由返回语义（翻页/退后台）由 WatchControllerPage 统一承接
    // （isRootHome: true）：鸿蒙旧表侧滑返回被系统抢占时经 popRoute 到
    // 那里的 PopScope，转成「非最左页先翻回上一页，最左页才退后台」，
    // 修掉「往右滑直接退到表盘、功能页永远进不去」的问题。
    return WatchControllerPage(
      isRootHome: true,
      frontBuilder: ({required isCurrent}) => _functionPage(isCurrent: isCurrent),
    );
  }
}