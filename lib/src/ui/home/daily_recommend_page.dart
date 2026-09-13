import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../home/daily_recommend.dart';
import '../account/account_view.dart';
import '../local/local_music_hub.dart';
import '../online/plugin_manage_page.dart';

/// 每日推荐页：服务端算法下发 + 已启用插件搜索执行（与移动端/桌面端同源）。
/// 未登录引导扫码登录；无已启用插件引导去插件管理；点歌整批入队起播。
class DailyRecommendPage extends ConsumerWidget {
  const DailyRecommendPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dailyRecommendProvider);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // 顶栏：返回 + 标题 + 换一批。
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                children: [
                  const BackButton(),
                  const SizedBox(width: 2),
                  Text('每日推荐',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white.withValues(alpha: 0.9))),
                  const Spacer(),
                  IconButton(
                    tooltip: '换一批',
                    onPressed: () =>
                        ref.read(dailyRecommendProvider.notifier).refresh(),
                    icon: const Icon(Icons.casino_rounded, size: 20),
                  ),
                ],
              ),
            ),
            Expanded(
              child: async.when(
                loading: () => const Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                ),
                error: (e, _) => _EmptyView(
                  icon: Icons.cloud_off_rounded,
                  text: '每日推荐获取失败\n$e',
                  actionLabel: '重试',
                  onAction: () =>
                      ref.invalidate(dailyRecommendProvider),
                ),
                data: (st) {
                  if (!st.loggedIn) {
                    return _EmptyView(
                      icon: Icons.lock_rounded,
                      text: '登录后解锁每日推荐\n基于你的听歌记录，每天为你量身定制',
                      actionLabel: '去登录',
                      onAction: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const AccountView()),
                      ),
                    );
                  }
                  if (st.items.isEmpty) {
                    return _EmptyView(
                      icon: Icons.extension_off_rounded,
                      text: '没有可用插件，无法生成推荐',
                      actionLabel: '去插件管理',
                      onAction: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const PluginManagePage()),
                      ),
                    );
                  }
                  return _RecommendList(items: st.items);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecommendList extends ConsumerWidget {
  const _RecommendList({required this.items});

  final List<DailyRecommendItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final it = items[i];
        final cover = it.coverUrl;
        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: ClipOval(
            child: SizedBox(
              width: 36,
              height: 36,
              child: (cover != null && cover.isNotEmpty)
                  ? (cover.startsWith('http')
                      ? Image.network(cover,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const _SongIcon())
                      : Image.file(File(cover),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const _SongIcon()))
                  : const _SongIcon(),
            ),
          ),
          title: Text(
            it.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
          subtitle: Text(
            it.reason.isNotEmpty ? '${it.artist} · ${it.reason}' : it.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 10, color: Colors.white.withValues(alpha: 0.45)),
          ),
          onTap: () async {
            await ref.read(dailyRecommendProvider.notifier).play(i);
            if (!context.mounted) return;
            // 与本地/在线点歌一致：回到 hub 并落在播放页。
            ref.read(localHubPageProvider.notifier).state = 1;
            Navigator.of(context).pop();
          },
        );
      },
    );
  }
}

class _SongIcon extends StatelessWidget {
  const _SongIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white.withValues(alpha: 0.08),
      child: Icon(Icons.music_note_rounded,
          size: 18, color: Colors.white.withValues(alpha: 0.5)),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: Colors.white.withValues(alpha: 0.35)),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12,
                height: 1.7,
                color: Colors.white.withValues(alpha: 0.55)),
          ),
          if (actionLabel != null) ...[
            const SizedBox(height: 14),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFF4D6E),
                minimumSize: const Size(0, 36),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              ),
              child: Text(actionLabel!,
                  style: const TextStyle(fontSize: 13)),
            ),
          ],
        ],
      ),
    );
  }
}
