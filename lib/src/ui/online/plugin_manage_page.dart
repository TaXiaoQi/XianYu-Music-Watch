import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/cloud_credentials_store.dart';
import '../../cloud/cloud_registry.dart';
import '../../core/watch_fit.dart';
import '../../i18n/i18n.dart';
import '../../plugin/cloud_source_prefs.dart';
import '../../plugin/plugin_models.dart';
import '../../plugin/plugin_provider.dart';
import '../../plugin/plugin_subscriptions.dart';
import '../../plugin/plugin_updates.dart';
import '../common/full_dialog.dart';
import '../common/press_scale.dart';
import '../common/stepped_list.dart';
import '../common/source_tag.dart';

class PluginManagePage extends ConsumerStatefulWidget {
  const PluginManagePage({super.key});

  @override
  ConsumerState<PluginManagePage> createState() => _PluginManagePageState();
}

class _PluginManagePageState extends ConsumerState<PluginManagePage> {
  bool _checking = false;
  bool _installing = false;
  // 安装中页面返回 = 取消导入（终止后台安装并静默收尾）
  bool _installCancelled = false;
  final Set<String> _updating = {};

  // 网盘伪音源行：每个已绑定网盘一条（开关/删除=解绑），腕上无排序 UI
  Map<String, int> _cloudAccountCounts = {};
  Set<String> _cloudDisabled = {};
  late final void Function() _cloudListenerReg = _onCloudStoreChanged;

  @override
  void initState() {
    super.initState();
    CloudCredentialsStore.instance.addListener(_cloudListenerReg);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadCloudState();
    });
  }

  @override
  void dispose() {
    CloudCredentialsStore.instance.removeListener(_cloudListenerReg);
    super.dispose();
  }

  void _onCloudStoreChanged() {
    if (mounted) _loadCloudState();
  }

  Future<void> _loadCloudState() async {
    final counts = <String, int>{};
    for (final p in cloudProviders) {
      try {
        counts[p.id] =
            (await CloudCredentialsStore.instance.accountsFor(p.id)).length;
      } catch (_) {
        counts[p.id] = 0; // 单盘查询失败不影响其余
      }
    }
    final disabled = await CloudSourcePrefs.getDisabled();
    if (!mounted) return;
    setState(() {
      _cloudAccountCounts = counts;
      _cloudDisabled = disabled;
    });
  }

  Future<void> _toggleCloudSource(String providerId) async {
    final cur = _cloudDisabled.contains(providerId);
    await CloudSourcePrefs.setDisabled(providerId, !cur);
    if (!mounted) return;
    setState(() {
      if (!cur) {
        _cloudDisabled.add(providerId);
      } else {
        _cloudDisabled.remove(providerId);
      }
    });
  }

  /// 删除网盘音源（整页弹窗确认）：确认后解绑该盘全部账号
  Future<void> _removeCloudSource(String providerId) async {
    final name = cloudProviders
        .where((p) => p.id == providerId)
        .map((p) => p.displayName)
        .firstOrNull;
    final count = _cloudAccountCounts[providerId] ?? 0;
    final ok = await showFullConfirm(
      context,
      title: tr('删除网盘音源「{name}」', {'name': name ?? providerId}),
      message: tr(
        '将同时解绑其下 {n} 个已绑定的网盘账号，绑定信息将无法恢复。',
        {'n': count},
      ),
      okLabel: tr('删除'),
    );
    if (ok != true || !mounted) return;
    try {
      final accounts =
          await CloudCredentialsStore.instance.accountsFor(providerId);
      for (final account in accounts) {
        await CloudCredentialsStore.instance
            .removeAccount(providerId, account.accountId);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr(
            '已删除「{name}」音源并解绑 {n} 个账号',
            {'name': name ?? providerId, 'n': accounts.length},
          )),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('删除失败：{e}', {'e': e})),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<PluginUpdateService> _updateService() async {
    final engine = await ref.read(pluginEngineProvider.future);
    return PluginUpdateService(
      engine,
      ref.read(pluginManagerProvider.notifier),
      subscriptionsReader: () => ref.read(pluginSubscriptionsProvider),
    );
  }

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            count > 0
                ? tr('发现 {count} 个插件可更新', {'count': count})
                : tr('所有插件均为最新版本'),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('检查更新失败：{e}', {'e': e})),
            duration: const Duration(seconds: 2),
          ),
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
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('已经是最新版本')),
            duration: const Duration(seconds: 1),
          ),
        );
        await ref
            .read(pluginManagerProvider.notifier)
            .setUpdateAvailable(s.id, false);
        return;
      }
      final outcome = await service.performPluginUpdate(s, r);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(outcome.message),
          duration: const Duration(seconds: 2),
        ),
      );
      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr('更新失败：{e}', {'e': e})),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _updating.remove(s.id));
    }
  }

  Future<void> _updateAll() async {
    final sources = ref
        .read(pluginManagerProvider)
        .sources
        .where((s) => s.updateAvailable);
    if (sources.isEmpty) return;
    for (final s in sources) {
      await _updateOne(s);
    }
  }

  Future<void> _addPlugin() async {
    if (_installing) return;
    final url = await showFullInput(
      context,
      title: tr('添加插件'),
      hint: tr('插件脚本/订阅 URL'),
      okLabel: tr('安装'),
      keyboardType: TextInputType.url,
    );
    if (url == null || url.isEmpty || !mounted) return;
    _installCancelled = false;
    setState(() => _installing = true);
    try {
      final result = await ref
          .read(pluginManagerProvider.notifier)
          .installFromUrl(url, cancelled: () => _installCancelled);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.success
                ? tr('已安装 {names}', {'names': result.names.join('、')})
                : tr('安装失败：{errors}', {
                    'errors': result.errors.join('；'),
                  }),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } on PluginInstallCancelled {
      // 用户返回已取消：静默终止，不再弹失败提示
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          SnackBar(content: Text(tr('安装失败：{e}', {'e': e}))),
        );
      }
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final list = ref.watch(pluginManagerProvider);
    final sources = list.sources;
    final updateCount = sources.where((s) => s.updateAvailable).length;

    final header = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 4 * s),
          child: Row(
            children: [
              const BackButton(),
              SizedBox(width: 2 * s),
              Text(
                tr('插件管理'),
                style: TextStyle(
                  fontSize: 15 * s,
                  fontWeight: FontWeight.w700,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
              const Spacer(),
              PressableScale(
                pressScale: 0.88,
                child: IconButton(
                  tooltip: tr('检测全部更新'),
                  onPressed: _checking ? null : _checkAllUpdates,
                  icon: _checking
                      ? SizedBox(
                          width: 16 * s,
                          height: 16 * s,
                          child: CircularProgressIndicator(strokeWidth: 2 * s),
                        )
                      : Icon(Icons.sync_rounded, size: 20 * s),
                ),
              ),
              PressableScale(
                pressScale: 0.88,
                child: IconButton(
                  tooltip: tr('添加插件'),
                  onPressed: _installing ? null : _addPlugin,
                  icon: _installing
                      ? SizedBox(
                          width: 20 * s,
                          height: 20 * s,
                          child: CircularProgressIndicator(strokeWidth: 2 * s),
                        )
                      : Icon(Icons.add_circle_outline_rounded, size: 22 * s),
                ),
              ),
            ],
          ),
        ),
        if (updateCount > 0)
          Padding(
            padding: EdgeInsets.only(
              left: 16 * s,
              right: 16 * s,
              bottom: 4 * s,
            ),
            child: SizedBox(
              width: double.infinity,
              child: PressableScale(
                pressScale: 0.92,
                child: FilledButton.tonal(
                  onPressed: _updateAll,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFF4D6E),
                    foregroundColor: Colors.white,
                    minimumSize: Size(0, 34 * s),
                    padding: EdgeInsets.symmetric(vertical: 6 * s),
                  ),
                  child: Text(
                    tr('一键更新 {count} 个插件', {'count': updateCount}),
                    style: TextStyle(fontSize: 12 * s),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    // 已绑定网盘的伪音源行（未绑定不显示），追加在插件行之后
    final cloudRows = <String>[
      for (final p in cloudProviders)
        if ((_cloudAccountCounts[p.id] ?? 0) > 0) p.id,
    ];
    Widget? body;
    if (sources.isEmpty && cloudRows.isEmpty) {
      body = Column(
        children: [
          header,
          Expanded(
            child: Center(
              child: Text(
                tr('暂无插件\n点右上角 + 添加在线音源'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12 * s,
                  height: 1.8,
                  color: Colors.white.withValues(alpha: 0.4),
                ),
              ),
            ),
          ),
        ],
      );
    } else {
      body = SteppedListView(
        header: header,
        headerExtent: updateCount > 0 ? 96 : 56,
        itemCount: sources.length + cloudRows.length,
        itemBuilder: (context, i) => i < sources.length
            ? _pluginTile(sources[i], s: s)
            : _cloudTile(cloudRows[i - sources.length], s: s),
      );
    }
    // 安装中允许返回，但返回语义 = 取消导入：终止后台安装，
    // 避免页面已退安装仍在跑且无任何结果反馈（对齐移动端「返回=取消导入」）
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _installing) _installCancelled = true;
      },
      child: Scaffold(body: SafeArea(child: body)),
    );
  }

  /// 网盘伪音源行：红色云朵图标 + 网盘标签，开关 = 来源启停，删除 = 解绑（整页弹窗确认）
  Widget _cloudTile(String providerId, {required double s}) {
    final name = cloudProviders
        .where((p) => p.id == providerId)
        .map((p) => p.displayName)
        .firstOrNull;
    final displayName = name ?? providerId;
    final count = _cloudAccountCounts[providerId] ?? 0;
    final enabled = !_cloudDisabled.contains(providerId);
    final desc = enabled
        ? tr('已绑定 {n} 个账号', {'n': count})
        : tr('已关闭');
    return SteppedPill(
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 3 * s),
        leading: Container(
          width: 44 * s,
          height: 44 * s,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: Color(0xFFEC4141),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.cloud_outlined,
              size: 22 * s, color: Colors.white),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15 * s,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
            SizedBox(width: 4 * s),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: 5 * s, vertical: 1 * s),
              decoration: BoxDecoration(
                color: const Color(0xFFEC4141).withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: const Color(0xFFEC4141).withValues(alpha: 0.4),
                  width: 0.5,
                ),
              ),
              child: Text(
                tr('网盘'),
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  fontSize: 10 * s,
                  height: 1.2,
                  color: const Color(0xFFFF6B81),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        subtitle: Text(
          'v1.0.0 · 小奇 · $desc',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11.5 * s,
            color: Colors.white.withValues(alpha: 0.45),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: enabled,
              activeThumbColor: const Color(0xFFFF4D6E),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (_) => _toggleCloudSource(providerId),
            ),
            PressableScale(
              pressScale: 0.88,
              child: IconButton(
                tooltip: tr('删除'),
                icon: Icon(
                  Icons.delete_outline_rounded,
                  size: 20 * s,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
                onPressed: () => _removeCloudSource(providerId),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pluginTile(PluginSource src, {required double s}) {
    final hasUpdate = src.updateAvailable;
    final subTag =
        pluginSubTagInfo(src, ref.watch(pluginSubscriptionsProvider));
    return SteppedPill(
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 3 * s),
        leading: Container(
          width: 44 * s,
          height: 44 * s,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: src.format == PluginFormat.anime
                ? const Color(0xFFA855F7)
                : const Color(0xFF4A90D9),
            shape: BoxShape.circle,
          ),
          child: Text(
            src.name.isEmpty ? '?' : src.name.characters.first.toUpperCase(),
            style: TextStyle(
              fontSize: 18 * s,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                src.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15 * s,
                  fontWeight: FontWeight.w600,
                  color: hasUpdate ? const Color(0xFFFF6B81) : Colors.white,
                ),
              ),
            ),
            if (subTag != null) ...[
              SizedBox(width: 4 * s),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: 5 * s, vertical: 1 * s),
                decoration: BoxDecoration(
                  color: const Color(0xFFE6A23C).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: const Color(0xFFE6A23C).withValues(alpha: 0.4),
                    width: 0.5,
                  ),
                ),
                child: Text(
                  subTag.label,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    fontSize: 10 * s,
                    height: 1.2,
                    color: const Color(0xFFE6A23C),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: Text(
          hasUpdate
              ? tr('有更新 v{version} → 检测到新版本', {'version': src.version})
              : 'v${src.version}',
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
                      child: CircularProgressIndicator(strokeWidth: 2 * s),
                    )
                  : PressableScale(
                      pressScale: 0.88,
                      child: TextButton(
                        onPressed: () => _updateOne(src),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.symmetric(horizontal: 6 * s),
                          minimumSize: Size(0, 30 * s),
                        ),
                        child: Text(
                          tr('更新'),
                          style: TextStyle(
                            fontSize: 12 * s,
                            color: const Color(0xFFFF6B81),
                          ),
                        ),
                      ),
                    ),
            Switch(
              value: src.enabled,
              activeThumbColor: const Color(0xFFFF4D6E),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (v) => ref
                  .read(pluginManagerProvider.notifier)
                  .toggleEnabled(src.id),
            ),
            PressableScale(
              pressScale: 0.88,
              child: IconButton(
                tooltip: tr('删除'),
                icon: Icon(
                  Icons.delete_outline_rounded,
                  size: 20 * s,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
                onPressed: () =>
                    ref.read(pluginManagerProvider.notifier).remove(src.id),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
