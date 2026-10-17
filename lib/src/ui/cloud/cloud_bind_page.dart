import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wearable_rotary/wearable_rotary.dart';

import '../../cloud/cloud_credentials_store.dart';
import '../../cloud/cloud_provider.dart';
import '../../cloud/cloud_registry.dart';
import '../../cloud/cloud_types.dart';
import '../../core/watch_fit.dart';
import '../../i18n/i18n.dart';
import '../common/full_dialog.dart';
import 'cloud_browser_page.dart';
import 'cloud_link_import_page.dart';
import 'cloud_password_login_page.dart';
import 'cloud_qrcode_login_page.dart';

/// 网盘绑定页：支持网盘列表 + 已绑定账号管理（与移动端 cloud_bind_page
/// 同构，手表小屏排布）。
///
/// WebView 范式盘（阿里/微云/139）本地无 WebView，不提供绑定入口，
/// 提示去手机端绑定，凭据经弦予账号云同步拉取；百度/夸克/UC 已改原生
/// 扫码，可直接在腕上端绑定。
/// 绑定入口按 [CloudProvider.loginKind] 路由到对应登录页，不做盘名硬编码。
class CloudBindPage extends ConsumerStatefulWidget {
  const CloudBindPage({super.key});

  @override
  ConsumerState<CloudBindPage> createState() => _CloudBindPageState();
}

class _CloudBindPageState extends ConsumerState<CloudBindPage> {
  Map<String, List<CloudAccount>> _accounts = const {};
  bool _loading = true;

  final ScrollController _scroll = ScrollController();
  StreamSubscription<RotaryEvent>? _rotarySub;
  double _rotaryAcc = 0;

  @override
  void initState() {
    super.initState();
    _rotarySub = rotaryEvents.listen(_onRotary);
    // 凭据落盘即自动刷新：登录同步后台导入绑定后，页面无需重启即跟随
    CloudCredentialsStore.instance.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    CloudCredentialsStore.instance.removeListener(_reload);
    _rotarySub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// 表冠滚动（与账号页 _onRotary 同源：顺时针=向下滚）。
  void _onRotary(RotaryEvent event) {
    if (!mounted || !_scroll.hasClients) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    final dir = event.direction == RotaryDirection.clockwise ? 1.0 : -1.0;
    final m = (event.magnitude ?? 48).clamp(0.0, 64.0).toDouble();
    if (dir * _rotaryAcc < 0) _rotaryAcc = 0;
    _rotaryAcc += dir * m;
    final delta = _rotaryAcc * 0.5;
    _rotaryAcc = 0;
    final target =
        (_scroll.offset + delta).clamp(0.0, _scroll.position.maxScrollExtent);
    if ((target - _scroll.offset).abs() < 0.5) return;
    _scroll.jumpTo(target);
  }

  Future<void> _reload() async {
    final map = <String, List<CloudAccount>>{};
    for (final p in cloudProviders) {
      map[p.id] = await CloudCredentialsStore.instance.accountsFor(p.id);
    }
    if (!mounted) return;
    setState(() {
      _accounts = map;
      _loading = false;
    });
  }

  String _kindLabel(CloudLoginKind kind) => switch (kind) {
        CloudLoginKind.webviewCookie ||
        CloudLoginKind.webviewToken =>
          tr('网页登录 · 请在手机端绑定'),
        CloudLoginKind.httpPassword => tr('账号密码'),
        CloudLoginKind.smsPassword => tr('手机号 + 验证码'),
        CloudLoginKind.qrCode => tr('扫码登录'),
      };

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  Future<void> _openLogin(CloudProvider p) async {
    final kind = p.loginKind;
    if (kind == CloudLoginKind.webviewCookie ||
        kind == CloudLoginKind.webviewToken) {
      await showFullConfirm(
        context,
        title: tr('去手机端绑定'),
        message: tr(
          '{name} 需在网页内登录，腕上端不支持。\n请在手机端绑定后，登录同一弦予账号即可同步过来。',
          {'name': p.displayName},
        ),
        okLabel: tr('知道了'),
        okOnly: true,
      );
      return;
    }
    final future = kind == CloudLoginKind.qrCode
        ? Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => CloudQrcodeLoginPage(providerId: p.id)))
        : Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => CloudPasswordLoginPage(providerId: p.id)));
    await future;
    if (!mounted) return;
    _reload();
  }

  Future<void> _unbind(CloudAccount a) async {
    final ok = await showFullConfirm(
      context,
      title: tr('解除绑定'),
      message: tr('确定要解绑 {name} 吗？', {'name': a.nickname}),
      okLabel: tr('解绑'),
    );
    if (ok != true) return;
    await CloudCredentialsStore.instance.removeAccount(a.provider, a.accountId);
    if (!mounted) return;
    _toast(tr('已解绑'));
    _reload();
  }

  void _openBrowser(CloudAccount a) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CloudBrowserPage(
        providerId: a.provider,
        accountId: a.accountId,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 10 * s, vertical: 2 * s),
              child: Row(
                children: [
                  const BackButton(),
                  SizedBox(width: 4 * s),
                  Text(
                    tr('网盘'),
                    style: TextStyle(
                      fontSize: 15 * s,
                      fontWeight: FontWeight.w700,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5 * s,
                        color: const Color(0xFFFF4D6E),
                      ),
                    )
                  : ListView(
                      controller: _scroll,
                      padding: EdgeInsets.symmetric(
                        horizontal: 14 * s,
                        vertical: 6 * s,
                      ),
                      children: [
                        _linkImportCard(s),
                        SizedBox(height: 10 * s),
                        for (final p in cloudProviders) ...[
                          _providerCard(s, p),
                          SizedBox(height: 8 * s),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _linkImportCard(double s) {
    return _card(
      s,
      InkWell(
        borderRadius: BorderRadius.circular(6 * s),
        onTap: () {
          Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => const CloudLinkImportPage(),
          ));
        },
        child: Row(
          children: [
            Icon(Icons.link_rounded, size: 18 * s, color: const Color(0xFFFF8FA3)),
            SizedBox(width: 10 * s),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('分享链接导入'),
                    style: TextStyle(
                      fontSize: 13.5 * s,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 2 * s),
                  Text(
                    tr('粘贴网盘分享链接播放或转存'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5 * s,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18 * s,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _providerCard(double s, CloudProvider p) {
    final accounts = _accounts[p.id] ?? const [];
    return _card(
      s,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.displayName,
                      style: TextStyle(
                        fontSize: 13.5 * s,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 2 * s),
                    Text(
                      accounts.isEmpty
                          ? _kindLabel(p.loginKind)
                          : tr('已绑定 {n} 个账号', {'n': '${accounts.length}'}),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5 * s,
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => _openLogin(p),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.symmetric(horizontal: 8 * s),
                  minimumSize: Size(0, 30 * s),
                ),
                child: Text(
                  accounts.isEmpty ? tr('绑定') : tr('添加账号'),
                  style: TextStyle(
                    fontSize: 12 * s,
                    color: const Color(0xFFFF8FA3),
                  ),
                ),
              ),
            ],
          ),
          for (final a in accounts) ...[
            Divider(
              height: 1,
              thickness: 0.5,
              color: Colors.white.withValues(alpha: 0.08),
            ),
            _accountRow(s, a),
          ],
        ],
      ),
    );
  }

  Widget _accountRow(double s, CloudAccount a) {
    return Padding(
      padding: EdgeInsets.only(left: 2 * s),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openBrowser(a),
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 7 * s),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.nickname.isEmpty ? a.accountId : a.nickname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5 * s),
                    ),
                    SizedBox(height: 1 * s),
                    Text(
                      a.accountId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10 * s,
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: () => _openBrowser(a),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.all(6 * s),
            constraints: BoxConstraints(minWidth: 30 * s, minHeight: 30 * s),
            icon: Icon(
              Icons.folder_open_rounded,
              size: 17 * s,
              color: Colors.white.withValues(alpha: 0.6),
            ),
            tooltip: tr('浏览网盘'),
          ),
          IconButton(
            onPressed: () => _unbind(a),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.all(6 * s),
            constraints: BoxConstraints(minWidth: 30 * s, minHeight: 30 * s),
            icon: Icon(
              Icons.link_off_rounded,
              size: 17 * s,
              color: const Color(0xFFFF6B81),
            ),
            tooltip: tr('解绑'),
          ),
        ],
      ),
    );
  }

  Widget _card(double s, Widget child) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 9 * s),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12 * s),
      ),
      child: child,
    );
  }
}
