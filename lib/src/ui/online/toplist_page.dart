import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../plugin/plugin_catalog.dart';
import '../../plugin/plugin_models.dart';
import '../../plugin/plugin_provider.dart';
import '../../plugin/plugin_search.dart';
import '../../player/player_provider.dart';
import '../local/local_music_hub.dart';

/// 音源榜单：已启用插件的 getTopLists 聚合（与桌面端 MF 协议同源）。
/// 首页 = 榜单列表；点进 = 榜单曲目，点歌整榜入队起播。
class TopListPage extends ConsumerStatefulWidget {
  const TopListPage({super.key});

  @override
  ConsumerState<TopListPage> createState() => _TopListPageState();
}

class _TopListPageState extends ConsumerState<TopListPage> {
  bool _loading = true;
  String? _error;
  List<(PluginSource, MfSheetItem)> _entries = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final engine = await ref.read(pluginEngineProvider.future);
      final sources = await engine.store.loadSources();
      final enabled = sources.where((s) => s.enabled).toList();
      if (enabled.isEmpty) throw '尚未安装插件，去插件管理添加';
      final catalog = PluginCatalogService(engine, enabled);

      // 并行拉取各插件榜单（分类展平已在 getTopLists 内处理），逐插件隔离失败。
      final merged = <(PluginSource, MfSheetItem)>[];
      await Future.wait([
        for (final s in enabled)
          () async {
            try {
              if (!await catalog.supportsTopLists(s)) return;
              final lists = await catalog.getTopLists(s);
              for (final it in lists) {
                merged.add((s, it));
              }
            } catch (_) {
              /* 单插件失败不影响其他 */
            }
          }(),
      ]);
      if (!mounted) return;
      setState(() {
        _entries = merged;
        _loading = false;
        if (merged.isEmpty) _error = '当前插件均不支持榜单';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                children: [
                  const BackButton(),
                  const SizedBox(width: 2),
                  Text('音源榜单',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white.withValues(alpha: 0.9))),
                  const Spacer(),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: _loading ? null : _load,
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      ),
                    )
                  : _error != null
                      ? Center(
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.7,
                                color:
                                    Colors.white.withValues(alpha: 0.5)),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 2),
                          itemCount: _entries.length,
                          separatorBuilder: (_, _) => Divider(
                              height: 1,
                              color:
                                  Colors.white.withValues(alpha: 0.06)),
                          itemBuilder: (context, i) {
                            final (src, it) = _entries[i];
                            return ListTile(
                              dense: true,
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              leading: _SheetCover(url: it.coverUrl),
                              title: Text(
                                it.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                              subtitle: Text(
                                src.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.white
                                        .withValues(alpha: 0.45)),
                              ),
                              trailing: Icon(Icons.chevron_right_rounded,
                                  size: 18,
                                  color: Colors.white
                                      .withValues(alpha: 0.35)),
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => TopListDetailPage(
                                      source: src, item: it),
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 榜单曲目页：getTopListDetail 拉取，点歌整榜入队起播。
class TopListDetailPage extends ConsumerStatefulWidget {
  const TopListDetailPage({super.key, required this.source, required this.item});

  final PluginSource source;
  final MfSheetItem item;

  @override
  ConsumerState<TopListDetailPage> createState() => _TopListDetailPageState();
}

class _TopListDetailPageState extends ConsumerState<TopListDetailPage> {
  bool _loading = true;
  String? _error;
  List<PluginSearchResult> _songs = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final engine = await ref.read(pluginEngineProvider.future);
      final catalog = PluginCatalogService(engine, [widget.source]);
      final songs = await catalog
          .getTopListDetail(widget.source, widget.item.raw);
      if (!mounted) return;
      setState(() {
        _songs = songs;
        _loading = false;
        if (songs.isEmpty) _error = '榜单为空';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '加载失败：$e';
        });
      }
    }
  }

  /// 点歌：整榜转播放队列，从点击项起播。
  Future<void> _play(int index) async {
    final engine = await ref.read(pluginEngineProvider.future);
    final service = PluginSearchService(engine, [widget.source]);
    final items =
        _songs.map((r) => service.toQueueItem(widget.source, r)).toList();
    await ref.read(playerProvider.notifier).playQueue(items, startIndex: index);
    if (!mounted) return;
    ref.read(localHubPageProvider.notifier).state = 1;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cover = widget.item.coverUrl;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                children: [
                  const BackButton(),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 34,
                    height: 34,
                    child: ClipOval(child: _SheetCover(url: cover)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      ),
                    )
                  : _error != null
                      ? Center(
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.white.withValues(alpha: 0.5)),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 2),
                          itemCount: _songs.length,
                          separatorBuilder: (_, _) => Divider(
                              height: 1,
                              color: Colors.white.withValues(alpha: 0.06)),
                          itemBuilder: (context, i) {
                            final r = _songs[i];
                            return ListTile(
                              dense: true,
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              leading: SizedBox(
                                width: 20,
                                child: Text(
                                  '${i + 1}',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: i < 3
                                          ? const Color(0xFFFF6B81)
                                          : Colors.white
                                              .withValues(alpha: 0.4)),
                                ),
                              ),
                              title: Text(
                                r.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                              subtitle: Text(
                                r.singer,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.white
                                        .withValues(alpha: 0.45)),
                              ),
                              onTap: () => _play(i),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetCover extends StatelessWidget {
  const _SheetCover({this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final u = url;
    final w = (u != null && u.isNotEmpty)
        ? (u.startsWith('http')
            ? Image.network(u,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const _SheetIcon())
            : Image.file(File(u),
                fit: BoxFit.cover, errorBuilder: (_, _, _) => const _SheetIcon()))
        : const _SheetIcon();
    return SizedBox(width: 36, height: 36, child: w);
  }
}

class _SheetIcon extends StatelessWidget {
  const _SheetIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white.withValues(alpha: 0.08),
      child: Icon(Icons.leaderboard_rounded,
          size: 18, color: Colors.white.withValues(alpha: 0.5)),
    );
  }
}
