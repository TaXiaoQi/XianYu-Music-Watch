import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/watch_fit.dart';
import '../../plugin/plugin_models.dart';
import '../../plugin/plugin_provider.dart';
import '../../plugin/plugin_subscriptions.dart';
import '../../plugin/plugin_updates.dart';
import '../common/stepped_list.dart';

/// 插件管理页：已安装列表（启用开关/删除）+ 检测全部更新（有更新标红，
/// 对齐桌面端/移动端 updatePluginSource 标记逻辑）+ 单插件更新/全部更新。
class PluginManagePage extends ConsumerStatefulWidget {
  const PluginManagePage({super.key});

  @override
  ConsumerState<PluginManagePage> createState() => _PluginManagePageState();
}

class _PluginManagePageState extends ConsumerState<PluginManagePage> {
  bool _checking = false;
  final Set<String> _updating = {};

  Future<PluginUpdateService> _updateService() async {
    final engine = await ref.read(pluginEngineProvider.future);
    return PluginUpdateService(
      engine,
      ref.read(pluginManagerProvider.notifier),
      subscriptionsReader: () => ref.read(pluginSubscriptionsProvider),
    );
  }

  /// 检测全部：结果回写持久化，列表据 updateAvailable 标红。
  Future<void> _checkAllUpdates() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final service = await _updateService();
      final manager = ref.read(pluginManagerProvider.notifier);
      final sources = ref.read(pluginManagerProvider).sources;
      final results = await service.checkAll();
      if (!mounted) return;
      for (final s in sources) {
        final r = results[s.id];
        await manager.setUpdateAvailable(s.id, r?.hasUpdate ?? false);
      }
      final count = results.values.where((r) => r.hasUpdate).length;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(count > 0 ? '发现 $count 个插件可更新' : '所有插件均为最新版本'),
        duration: const Duration(seconds: 2),
      ));
      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('检查更新失败：$e'), duration: const Duration(seconds: 2)),
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _updateOne(PluginSource s) async {
    if (_updating.contains(s.id)) return;
    setState(() => _updating.add(s.id));
    try {
      final service = await _updateService();
      final r = await service.checkPluginUpdate(s);
      if (r == null || !r.hasUpdate) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已经是最新版本'), duration: Duration(seconds: 1)),
          );
        }
        await ref
            .read(pluginManagerProvider.notifier)
            .setUpdateAvailable(s.id, false);
        return;
      }
      final outcome = await service.performPluginUpdate(s, r);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(outcome.message), duration: const Duration(seconds: 2)),
      );
      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('更新失败：$e'), duration: const Duration(seconds: 2)),
        );
      }
    } finally {
      if (mounted) setState(() => _updating.remove(s.id));
    }
  }

  /// 一键更新所有已标记有更新的插件。
  Future<void> _updateAll() async {
    final sources =
        ref.read(pluginManagerProvider).sources.where((s) => s.updateAvailable);
    if (sources.isEmpty) return;
    for (final s in sources) {
      await _updateOne(s);
    }
  }

  Future<void> _addPlugin() async {
    final url = await showDialog<String>(
      context: context,
      builder: (context) {
        final s = context.watchScale(); // 屏径等比缩放
        final c = TextEditingController();
        return AlertDialog(
          title: Text('添加插件', style: TextStyle(fontSize: 15 * s)),
          content: TextField(
            controller: c,
            autofocus: true,
            style: TextStyle(fontSize: 13 * s),
            decoration: const InputDecoration(
              hintText: '插件脚本/订阅 URL',
              isDense: true,
            ),
            keyboardType: TextInputType.url,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('取消', style: TextStyle(fontSize: 13 * s)),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, c.text.trim()),
              child: Text('安装', style: TextStyle(fontSize: 13 * s)),
            ),
          ],
        );
      },
    );
    if (url == null || url.isEmpty || !mounted) return;
    try {
      final result =
          await ref.read(pluginManagerProvider.notifier).installFromUrl(url);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.success
                ? '已安装 ${result.names.join('、')}'
                : '安装失败：${result.errors.join('；')}',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('安装失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale(); // 屏径等比缩放
    final list = ref.watch(pluginManagerProvider);
    final sources = list.sources;
    final updateCount = sources.where((s) => s.updateAvailable).length;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // 顶栏：返回 + 标题 + 检测更新 + 添加。
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 4 * s, vertical: 2 * s),
              child: Row(
                children: [
                  const BackButton(),
                  SizedBox(width: 2 * s),
                  Text('插件管理',
                      style: TextStyle(
                          fontSize: 15 * s,
                          fontWeight: FontWeight.w700,
                          color: Colors.white.withValues(alpha: 0.9))),
                  const Spacer(),
                  IconButton(
                    tooltip: '检测全部更新',
                    onPressed: _checking ? null : _checkAllUpdates,
                    icon: _checking
                        ? SizedBox(
                            width: 16 * s,
                            height: 16 * s,
                            child:
                                CircularProgressIndicator(strokeWidth: 2 * s))
                        : Icon(Icons.sync_rounded, size: 20 * s),
                  ),
                  IconButton(
                    tooltip: '添加插件',
                    onPressed: _addPlugin,
                    icon: Icon(Icons.add_circle_outline_rounded, size: 22 * s),
                  ),
                ],
              ),
            ),
            if (updateCount > 0)
              Padding(
                padding:
                    EdgeInsets.only(left: 16 * s, right: 16 * s, bottom: 4 * s),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonal(
                    onPressed: _updateAll,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFF4D6E),
                      foregroundColor: Colors.white,
                      minimumSize: Size(0, 34 * s),
                      padding: EdgeInsets.symmetric(vertical: 6 * s),
                    ),
                    child: Text('一键更新 $updateCount 个插件',
                        style: TextStyle(fontSize: 12 * s)),
                  ),
                ),
              ),
            Expanded(
              child: sources.isEmpty
                  ? Center(
                      child: Text(
                        '暂无插件\n点右上角 + 添加在线音源',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12 * s,
                            height: 1.8,
                            color: Colors.white.withValues(alpha: 0.4)),
                      ),
                    )
                  : SteppedListView(
                      itemCount: sources.length,
                      // 局部变量改名为 src，避免遮蔽缩放系数 s。
                      itemBuilder: (context, i) => _pluginTile(sources[i], s: s),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pluginTile(PluginSource src, {required double s}) {
    // s：屏径等比缩放系数，由调用处传入。
    final hasUpdate = src.updateAvailable;
    return SteppedPill(
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 14 * s),
      leading: Container(
        width: 44 * s,
        height: 44 * s,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: Color(0xFF4A90D9),
          shape: BoxShape.circle,
        ),
        child: Text(
          src.name.isEmpty ? '?' : src.name.characters.first.toUpperCase(),
          style: TextStyle(
              fontSize: 18 * s,
              fontWeight: FontWeight.w700,
              color: Colors.white),
        ),
      ),
      title: Text(
        src.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 15 * s,
          fontWeight: FontWeight.w600,
          color: hasUpdate ? const Color(0xFFFF6B81) : Colors.white,
        ),
      ),
      subtitle: Text(
        hasUpdate ? '有更新 v${src.version} → 检测到新版本' : 'v${src.version}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11.5 * s,
          color: hasUpdate
              ? const Color(0xFFFF6B81)
              : Colors.white.withValues(alpha: 0.45),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasUpdate)
            _updating.contains(src.id)
                ? SizedBox(
                    width: 16 * s,
                    height: 16 * s,
                    child: CircularProgressIndicator(strokeWidth: 2 * s))
                : TextButton(
                    onPressed: () => _updateOne(src),
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.symmetric(horizontal: 6 * s),
                      minimumSize: Size(0, 30 * s),
                    ),
                    child: Text('更新',
                        style: TextStyle(
                            fontSize: 12 * s, color: const Color(0xFFFF6B81))),
                  ),
          Switch(
            value: src.enabled,
            activeThumbColor: const Color(0xFFFF4D6E),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (v) =>
                ref.read(pluginManagerProvider.notifier).toggleEnabled(src.id),
          ),
          IconButton(
            tooltip: '删除',
            icon: Icon(Icons.delete_outline_rounded,
                size: 20 * s, color: Colors.white.withValues(alpha: 0.5)),
            onPressed: () =>
                ref.read(pluginManagerProvider.notifier).remove(src.id),
          ),
        ],
      ),
      ),
    );
  }
}
