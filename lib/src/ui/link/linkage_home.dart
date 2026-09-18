import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
/// 独立服务。左滑返回 → moveTaskToBack 退后台驻留（重开秒回、联动会话
/// 不断，与独立模式主页行为一致）。
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
    // 根路由左滑返回：无可弹页时退后台驻留（应用保持存活、重开秒回）。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          const MethodChannel('xianyu/system_nav')
              .invokeMethod('moveTaskToBack')
              // 失败绝不退出：左滑根路由只应退后台驻留，若 moveToBackground
              // 不可用就静默留在前台（此前 catchError 退化 SystemNavigator.pop
              // 直接 finish，观感即「左滑退出应用」）。
              .catchError((_) {});
        }
      },
      child: WatchControllerPage(
        frontBuilder: ({required isCurrent}) => _functionPage(isCurrent: isCurrent),
      ),
    );
  }
}