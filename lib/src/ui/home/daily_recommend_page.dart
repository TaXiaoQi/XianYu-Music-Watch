import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/watch_fit.dart';
import '../../home/daily_recommend.dart';
import '../../i18n/i18n.dart';
import '../account/account_view.dart';
import '../common/stepped_list.dart';
import '../local/local_music_hub.dart';
import '../online/plugin_manage_page.dart';

class DailyRecommendPage extends ConsumerWidget {
  const DailyRecommendPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dailyRecommendProvider);
    final s = context.watchScale();

    final headerRow = PageTitleHeader(
      tr('每日推荐'),
      showBack: true,
      trailing: IconButton(
        tooltip: tr('换一批'),
        onPressed: () => ref.read(dailyRecommendProvider.notifier).refresh(),
        icon: Icon(Icons.casino_rounded, size: 20 * s),
      ),
    );
    Widget stateBody(Widget child) => Column(
      children: [
        headerRow,
        Expanded(child: child),
      ],
    );

    return Scaffold(
      body: SafeArea(
        child: async.when(
          loading: () => stateBody(
            Center(
              child: SizedBox(
                width: 26 * s,
                height: 26 * s,
                child: CircularProgressIndicator(strokeWidth: 2.4 * s),
              ),
            ),
          ),
          error: (e, _) => stateBody(
            _EmptyView(
              icon: Icons.cloud_off_rounded,
              text: '$e',
              actionLabel: tr('重试'),
              onAction: () => ref.invalidate(dailyRecommendProvider),
            ),
          ),
          data: (st) {
            if (!st.loggedIn) {
              return stateBody(
                _EmptyView(
                  icon: Icons.lock_rounded,
                  text: tr('登录后解锁每日推荐\n基于你的听歌记录，每天为你量身定制'),
                  actionLabel: tr('去登录'),
                  onAction: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AccountView(),
                    ),
                  ),
                ),
              );
            }
            if (st.items.isEmpty) {
              return stateBody(
                _EmptyView(
                  icon: Icons.extension_off_rounded,
                  text: tr('没有可用插件，无法生成推荐'),
                  actionLabel: tr('去插件管理'),
                  onAction: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const PluginManagePage(),
                    ),
                  ),
                ),
              );
            }
            return _RecommendList(items: st.items, header: headerRow);
          },
        ),
      ),
    );
  }
}

class _RecommendList extends ConsumerWidget {
  const _RecommendList({required this.items, required this.header});

  final List<DailyRecommendItem> items;
  final Widget header;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    return SteppedListView(
      header: header,
      itemCount: items.length,
      itemBuilder: (context, i) {
        final it = items[i];
        final cover = it.coverUrl;
        return SteppedTile(
          leading: ClipOval(
            child: SizedBox(
              width: 44 * s,
              height: 44 * s,
              child: (cover != null && cover.isNotEmpty)
                  ? (cover.startsWith('http')
                        ? Image.network(
                            cover,
                            fit: BoxFit.cover,
                            cacheWidth: 96,
                            errorBuilder: (_, _, _) => const _SongIcon(),
                          )
                        : Image.file(
                            File(cover),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const _SongIcon(),
                          ))
                  : const _SongIcon(),
            ),
          ),
          title: it.title,
          subtitle: it.reason.isNotEmpty
              ? '${it.artist} · ${it.reason}'
              : it.artist,
          onTap: () async {
            await ref.read(dailyRecommendProvider.notifier).play(i);
            if (!context.mounted) return;
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
    final s = context.watchScale();
    return Container(
      color: Colors.white.withValues(alpha: 0.08),
      child: Icon(
        Icons.music_note_rounded,
        size: 18 * s,
        color: Colors.white.withValues(alpha: 0.5),
      ),
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
    final s = context.watchScale();
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40 * s, color: Colors.white.withValues(alpha: 0.35)),
          SizedBox(height: 10 * s),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12 * s,
              height: 1.7,
              color: Colors.white.withValues(alpha: 0.55),
            ),
          ),
          if (actionLabel != null) ...[
            SizedBox(height: 14 * s),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFF4D6E),
                minimumSize: Size(0, 36 * s),
                padding: EdgeInsets.symmetric(
                  horizontal: 20 * s,
                  vertical: 6 * s,
                ),
              ),
              child: Text(actionLabel!, style: TextStyle(fontSize: 13 * s)),
            ),
          ],
        ],
      ),
    );
  }
}
