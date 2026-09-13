import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../plugin/plugin_models.dart';
import '../../plugin/plugin_provider.dart';
import '../../plugin/plugin_subscriptions.dart';
import '../../plugin/plugin_updates.dart';

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
        final c = TextEditingController();
        return AlertDialog(
          title: const Text('添加插件', style: TextStyle(fontSize: 15)),
          content: TextField(
            controller: c,
            autofocus: true,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              hintText: '插件脚本/订阅 URL',
              isDense: true,
            ),
            keyboardType: TextInputType.url,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消', style: TextStyle(fontSize: 13)),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, c.text.trim()),
              child: const Text('安装', style: TextStyle(fontSize: 13)),
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
    final list = ref.watch(pluginManagerProvider);
    final sources = list.sources;
    final updateCount = sources.where((s) => s.updateAvailable).length;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // 顶栏：返回 + 标题 + 检测更新 + 添加。
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                children: [
                  const BackButton(),
                  const SizedBox(width: 2),
                  Text('插件管理',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white.withValues(alpha: 0.9))),
                  const Spacer(),
                  IconButton(
                    tooltip: '检测全部更新',
                    onPressed: _checking ? null : _checkAllUpdates,
                    icon: _checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.sync_rounded, size: 20),
                  ),
                  IconButton(
                    tooltip: '添加插件',
                    onPressed: _addPlugin,
                    icon: const Icon(Icons.add_circle_outline_rounded, size: 22),
                  ),
                ],
              ),
            ),
            if (updateCount > 0)
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, bottom: 4),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonal(
                    onPressed: _updateAll,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFF4D6E),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                    ),
                    child: Text('一键更新 $updateCount 个插件',
                        style: const TextStyle(fontSize: 12)),
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
                            fontSize: 12,
                            height: 1.8,
                            color: Colors.white.withValues(alpha: 0.4)),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 2),
                      itemCount: sources.length,
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
                      itemBuilder: (context, i) {
                        final s = sources[i];
                        return _pluginTile(s);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pluginTile(PluginSource s) {
    final hasUpdate = s.updateAvailable;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: Color(0xFF4A90D9),
          shape: BoxShape.circle,
        ),
        child: Text(
          s.name.isEmpty ? '?' : s.name.characters.first.toUpperCase(),
          style: const TextStyle(
              fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
        ),
      ),
      title: Text(
        s.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: hasUpdate ? const Color(0xFFFF6B81) : Colors.white,
        ),
      ),
      subtitle: Text(
        hasUpdate ? '有更新 v${s.version} → 检测到新版本' : 'v${s.version}',
        style: TextStyle(
          fontSize: 11,
          color: hasUpdate
              ? const Color(0xFFFF6B81)
              : Colors.white.withValues(alpha: 0.45),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasUpdate)
            _updating.contains(s.id)
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : TextButton(
                    onPressed: () => _updateOne(s),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 30),
                    ),
                    child: const Text('更新',
                        style: TextStyle(
                            fontSize: 12, color: Color(0xFFFF6B81))),
                  ),
          Switch(
            value: s.enabled,
            activeThumbColor: const Color(0xFFFF4D6E),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (v) =>
                ref.read(pluginManagerProvider.notifier).toggleEnabled(s.id),
          ),
          IconButton(
            tooltip: '删除',
            icon: Icon(Icons.delete_outline_rounded,
                size: 18, color: Colors.white.withValues(alpha: 0.5)),
            onPressed: () =>
                ref.read(pluginManagerProvider.notifier).remove(s.id),
          ),
        ],
      ),
    );
  }
}
