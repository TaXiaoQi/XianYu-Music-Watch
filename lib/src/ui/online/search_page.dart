import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/watch_fit.dart';
import '../../player/player_provider.dart';
import '../../plugin/plugin_models.dart';
import '../../plugin/plugin_provider.dart';
import '../../plugin/plugin_search.dart';
import '../common/full_dialog.dart';
import '../common/stepped_list.dart';
import '../local/local_music_hub.dart';

class OnlineSearchPage extends ConsumerStatefulWidget {
  const OnlineSearchPage({super.key});

  @override
  ConsumerState<OnlineSearchPage> createState() => _OnlineSearchPageState();
}

class _OnlineSearchPageState extends ConsumerState<OnlineSearchPage> {
  final _controller = TextEditingController();
  bool _searching = false;
  bool _installing = false;
  String? _error;
  List<PluginSource> _sources = [];
  List<(PluginSource, List<PluginSearchResult>)> _results = [];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_searching) return;
    final kw = _controller.text.trim();
    if (kw.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = null;
      _results = [];
    });
    try {
      final engine = await ref.read(pluginEngineProvider.future);
      final sources = await engine.store.loadSources();
      final enabled = sources.where((s) => s.enabled).toList();
      if (enabled.isEmpty) throw '尚未安装插件，点右上角 + 添加';
      final service = PluginSearchService(engine, enabled);
      final results = await service.searchAll(kw, limit: 20);
      if (!mounted) return;
      setState(() {
        _sources = sources;
        _results = results;
        if (results.isEmpty) _error = '没有匹配结果';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _addPlugin() async {
    final url = await showFullInput(
      context,
      title: '添加插件',
      hint: '插件脚本 URL',
      okLabel: '安装',
      keyboardType: TextInputType.url,
    );
    if (url == null || url.isEmpty || !mounted) return;
    setState(() => _installing = true);
    try {
      final result = await ref
          .read(pluginManagerProvider.notifier)
          .installFromUrl(url);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.success
                ? '已安装 ${result.names.join('、')}'
                : '安装失败：${result.errors.join('；')}',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('安装失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _play(int groupIndex, int itemIndex) async {
    final engine = await ref.read(pluginEngineProvider.future);
    final service = PluginSearchService(engine, _sources);
    final items = <QueueItem>[];
    var start = 0;
    for (var gi = 0; gi < _results.length; gi++) {
      final (src, group) = _results[gi];
      if (gi == groupIndex) start = items.length + itemIndex;
      items.addAll(group.map((r) => service.toQueueItem(src, r)));
    }
    await ref.read(playerProvider.notifier).playQueue(items, startIndex: start);
    if (!mounted) return;
    ref.read(localHubPageProvider.notifier).state = 1;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Scaffold(
      appBar: AppBar(
        title: Text('搜索', style: TextStyle(fontSize: 15 * s)),
        actions: [
          IconButton(
            onPressed: _installing ? null : _addPlugin,
            icon: Icon(Icons.add_link_rounded, size: 20 * s),
            tooltip: '添加插件',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(14 * s, 4 * s, 14 * s, 8 * s),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    style: TextStyle(fontSize: 13 * s),
                    decoration: InputDecoration(
                      hintText: '搜索歌曲/歌手',
                      isDense: true,
                      prefixIcon: Icon(Icons.search_rounded, size: 18 * s),
                    ),
                  ),
                ),
                SizedBox(width: 8 * s),
                FilledButton(
                  onPressed: _searching ? null : _search,
                  child: Text(_searching ? '…' : '搜'),
                ),
              ],
            ),
          ),
          Expanded(child: _buildBody(s)),
        ],
      ),
    );
  }

  Widget _buildBody(double s) {
    if (_searching) {
      return Center(child: CircularProgressIndicator(strokeWidth: 3 * s));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(16 * s),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12 * s, color: Colors.white54),
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text(
          '输入关键词搜索在线音乐',
          style: TextStyle(fontSize: 12 * s, color: Colors.white38),
        ),
      );
    }
    final tiles = <Widget>[];
    for (var gi = 0; gi < _results.length; gi++) {
      final (src, group) = _results[gi];
      tiles.add(
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 3 * s),
            child: Text(
              src.name,
              style: TextStyle(
                fontSize: 12 * s,
                color: const Color(0xFFFF8FA3),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
      for (var ri = 0; ri < group.length; ri++) {
        final r = group[ri];
        final quality = r.types
            .map((t) => t['type'])
            .whereType<String>()
            .join('/');
        tiles.add(
          SteppedTile(
            leading: ClipOval(
              child: SizedBox(
                width: 44 * s,
                height: 44 * s,
                child: (r.img != null && r.img!.isNotEmpty)
                    ? Image.network(
                        r.img!,
                        fit: BoxFit.cover,
                        cacheWidth: 96,
                        errorBuilder: (_, _, _) => const _ResultIcon(),
                      )
                    : const _ResultIcon(),
              ),
            ),
            title: r.name,
            subtitle: quality.isEmpty ? r.singer : '${r.singer} · $quality',
            onTap: () => _play(gi, ri),
          ),
        );
      }
    }
    return SteppedListView(
      itemCount: tiles.length,
      itemBuilder: (_, i) => tiles[i],
    );
  }
}

class _ResultIcon extends StatelessWidget {
  const _ResultIcon();

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Container(
      color: const Color(0xFF1A1A1E),
      child: Icon(
        Icons.music_note_rounded,
        size: 22 * s,
        color: Colors.white.withValues(alpha: 0.35),
      ),
    );
  }
}
