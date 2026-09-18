import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/watch_fit.dart';
import '../../plugin/plugin_catalog.dart';
import '../../plugin/plugin_models.dart';
import '../../plugin/plugin_provider.dart';
import '../../plugin/plugin_search.dart';
import '../../player/player_provider.dart';
import '../common/stepped_list.dart';
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
    final s = context.watchScale(); // 屏径等比缩放
    // 页面头：做进滚动内容最顶部，居中标题 + 左上角返回 + 右侧刷新
    // （One UI 式，随列表滚走，圆弧适配完整）。
    final headerRow = PageTitleHeader(
      '音源榜单',
      showBack: true,
      trailing: IconButton(
        tooltip: '刷新',
        onPressed: _loading ? null : _load,
        icon: Icon(Icons.refresh_rounded, size: 20 * s),
      ),
    );
    final body = _loading
        ? Column(children: [
            headerRow,
            Expanded(
              child: Center(
                child: SizedBox(
                  width: 26 * s,
                  height: 26 * s,
                  child: CircularProgressIndicator(strokeWidth: 2.4 * s),
                ),
              ),
            ),
          ])
        : _error != null
            ? Column(children: [
                headerRow,
                Expanded(
                  child: Center(
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12 * s,
                          height: 1.7,
                          color: Colors.white.withValues(alpha: 0.5)),
                    ),
                  ),
                ),
              ])
            : SteppedListView(
                header: headerRow,
                itemCount: _entries.length,
                itemBuilder: (context, i) {
                  final (src, it) = _entries[i];
                  return SteppedTile(
                    leading: _SheetCover(url: it.coverUrl),
                    title: it.title,
                    subtitle: src.name,
                    trailing: Icon(Icons.chevron_right_rounded,
                        size: 22 * s,
                        color: Colors.white.withValues(alpha: 0.35)),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            TopListDetailPage(source: src, item: it),
                      ),
                    ),
                  );
                },
              );
    return Scaffold(body: SafeArea(child: body));
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
    final s = context.watchScale(); // 屏径等比缩放
    // 页面头：做进滚动内容最顶部（One UI 式，随列表滚走，圆弧适配完整）。
    final headerRow = Padding(
      padding: EdgeInsets.symmetric(horizontal: 4 * s),
      child: Row(
        children: [
          const BackButton(),
          SizedBox(width: 8 * s),
          SizedBox(
            width: 34 * s,
            height: 34 * s,
            child: ClipOval(child: _SheetCover(url: cover)),
          ),
          SizedBox(width: 8 * s),
          Expanded(
            child: Text(
              widget.item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 14 * s, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    final body = _loading
        ? Column(children: [
            headerRow,
            Expanded(
              child: Center(
                child: SizedBox(
                  width: 26 * s,
                  height: 26 * s,
                  child: CircularProgressIndicator(strokeWidth: 2.4 * s),
                ),
              ),
            ),
          ])
        : _error != null
            ? Column(children: [
                headerRow,
                Expanded(
                  child: Center(
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12 * s,
                          color: Colors.white.withValues(alpha: 0.5)),
                    ),
                  ),
                ),
              ])
            : SteppedListView(
                header: headerRow,
                itemCount: _songs.length,
                itemBuilder: (context, i) {
                  final r = _songs[i];
                  return SteppedTile(
                    leading: SizedBox(
                      width: 24 * s,
                      child: Text(
                        '${i + 1}',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 15 * s,
                            fontWeight: FontWeight.w700,
                            color: i < 3
                                ? const Color(0xFFFF6B81)
                                : Colors.white.withValues(alpha: 0.4)),
                      ),
                    ),
                    title: r.name,
                    subtitle: r.singer,
                    onTap: () => _play(i),
                  );
                },
              );
    return Scaffold(body: SafeArea(child: body));
  }
}

class _SheetCover extends StatelessWidget {
  const _SheetCover({this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale(); // 屏径等比缩放
    final u = url;
    final w = (u != null && u.isNotEmpty)
        ? (u.startsWith('http')
            ? Image.network(u,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const _SheetIcon())
            : Image.file(File(u),
                fit: BoxFit.cover, errorBuilder: (_, _, _) => const _SheetIcon()))
        : const _SheetIcon();
    return SizedBox(width: 44 * s, height: 44 * s, child: w);
  }
}

class _SheetIcon extends StatelessWidget {
  const _SheetIcon();

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale(); // 屏径等比缩放
    return Container(
      color: Colors.white.withValues(alpha: 0.08),
      child: Icon(Icons.leaderboard_rounded,
          size: 18 * s, color: Colors.white.withValues(alpha: 0.5)),
    );
  }
}
