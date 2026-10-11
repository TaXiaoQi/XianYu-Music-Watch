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
import '../../player/player_provider.dart';

/// 网盘浏览页：目录浏览 + 点播音频文件（手表小屏排布）。
///
/// 路径语义各盘不同（fid / 真实路径 / folderId），导航键取
/// 「条目 path 非空且不等于当前目录时用 path，否则用 id」——覆盖
/// path 型盘（百度）与 id 型盘（其余）两种声明。
class CloudBrowserPage extends ConsumerStatefulWidget {
  const CloudBrowserPage({super.key, required this.providerId, this.accountId});

  final String providerId;

  /// 指定账号 id；缺省取该盘第一个已绑定账号。
  final String? accountId;

  @override
  ConsumerState<CloudBrowserPage> createState() => _CloudBrowserPageState();
}

class _Crumb {
  const _Crumb(this.path, this.name);
  final String path;
  final String name;
}

class _CloudBrowserPageState extends ConsumerState<CloudBrowserPage> {
  late final CloudProvider _provider;
  List<CloudAccount> _accounts = const [];
  String? _accountId;
  bool _noAccount = false;

  final List<_Crumb> _stack = [];
  List<CloudFile> _files = const [];
  String? _cursor;
  bool _loading = true;
  bool _appending = false;

  final ScrollController _scroll = ScrollController();
  StreamSubscription<RotaryEvent>? _rotarySub;
  double _rotaryAcc = 0;

  @override
  void initState() {
    super.initState();
    _provider = cloudProviderById(widget.providerId)!;
    _rotarySub = rotaryEvents.listen(_onRotary);
    _init();
  }

  @override
  void dispose() {
    _rotarySub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// 表冠滚动（顺时针=向下滚）。
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

  Future<void> _init() async {
    final accounts =
        await CloudCredentialsStore.instance.accountsFor(_provider.id);
    if (!mounted) return;
    if (accounts.isEmpty) {
      setState(() {
        _noAccount = true;
        _loading = false;
      });
      return;
    }
    final id = widget.accountId ?? accounts.first.accountId;
    // 传入账号已解绑时回退第一个
    final valid =
        accounts.any((a) => a.accountId == id) ? id : accounts.first.accountId;
    setState(() {
      _accounts = accounts;
      _accountId = valid;
      _stack
        ..clear()
        ..add(_Crumb(_provider.rootPath, tr('全部文件')));
    });
    _load();
  }

  Future<Map<String, String>> _cred() async {
    final id = _accountId;
    if (id != null) {
      final cred =
          await CloudCredentialsStore.instance.credFor(_provider.id, id);
      if (cred != null) return cred;
    }
    final sole = await CloudCredentialsStore.instance.soleCredFor(_provider.id);
    return sole ?? const {};
  }

  /// 进入子目录：path 型盘条目携带绝对路径，id 型盘回退用 id。
  void _enter(CloudFile dir) {
    final cur = _stack.last.path;
    final next = (dir.path != null && dir.path!.isNotEmpty && dir.path != cur)
        ? dir.path!
        : dir.id;
    setState(() => _stack.add(_Crumb(next, dir.name)));
    _load();
  }

  void _jumpTo(int index) {
    if (index == _stack.length - 1) return;
    setState(() => _stack.removeRange(index + 1, _stack.length));
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (more && (_cursor == null || _appending)) return;
    final path = _stack.last.path;
    if (!mounted) return;
    setState(() {
      if (more) {
        _appending = true;
      } else {
        _loading = true;
        _files = const [];
        _cursor = null;
      }
    });
    try {
      final cred = await _cred();
      final r = await _provider.listDir(cred, path,
          cursor: more ? _cursor : null);
      if (!mounted || _stack.isEmpty || _stack.last.path != path) return;
      setState(() {
        _files = more ? [..._files, ...r.files] : r.files;
        _cursor = r.nextCursor;
        _loading = false;
        _appending = false;
      });
    } catch (e) {
      if (!mounted || _stack.isEmpty || _stack.last.path != path) return;
      setState(() {
        _loading = false;
        _appending = false;
      });
      _toast(e is CloudException ? e.message : tr('目录加载失败'));
    }
  }

  Future<void> _switchAccount(String id) async {
    if (id == _accountId) return;
    setState(() {
      _accountId = id;
      _stack
        ..clear()
        ..add(_Crumb(_provider.rootPath, tr('全部文件')));
    });
    _load();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  String _sizeText(int size) {
    if (size <= 0) return '';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(0)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(size / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  Future<void> _play(CloudFile f) async {
    CloudAccount? account;
    for (final a in _accounts) {
      if (a.accountId == _accountId) {
        account = a;
        break;
      }
    }
    if (account == null) {
      _toast(tr('网盘账号未绑定或已失效'));
      return;
    }
    final ctx = CloudPlayContext(
      provider: _provider.id,
      accountId: account.accountId,
      file: f,
    );
    await ref
        .read(playerProvider.notifier)
        .playQueue(
            [cloudPlayQueueItem(ctx, artist: _provider.displayName)],
            startIndex: 0);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Padding(
                  padding:
                      EdgeInsets.symmetric(horizontal: 10 * s, vertical: 2 * s),
                  child: Row(
                    children: [
                      const BackButton(),
                      SizedBox(width: 4 * s),
                      Expanded(
                        child: Text(
                          _provider.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15 * s,
                            fontWeight: FontWeight.w700,
                            color: Colors.white.withValues(alpha: 0.9),
                          ),
                        ),
                      ),
                      if (_accounts.length > 1)
                        IconButton(
                          onPressed: _pickAccount,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.all(6 * s),
                          constraints: BoxConstraints(
                              minWidth: 32 * s, minHeight: 32 * s),
                          icon: Icon(
                            Icons.switch_account_rounded,
                            size: 19 * s,
                            color: const Color(0xFFFF8FA3),
                          ),
                          tooltip: tr('切换账号'),
                        ),
                    ],
                  ),
                ),
                _breadcrumb(s),
                Expanded(child: _list(s)),
              ],
            ),
            if (_noAccount) _noAccountView(s),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAccount() async {
    final picked = await showFullPicker<String>(
      context,
      title: tr('切换账号'),
      options: [
        for (final a in _accounts)
          (
            a.accountId,
            a.nickname.isEmpty ? a.accountId : a.nickname,
          ),
      ],
      current: _accountId,
    );
    if (picked != null) _switchAccount(picked);
  }

  Widget _breadcrumb(double s) {
    return SizedBox(
      height: 26 * s,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: 14 * s),
        shrinkWrap: true,
        children: [
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < _stack.length; i++) ...[
                  if (i > 0)
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 13 * s,
                      color: Colors.white.withValues(alpha: 0.4),
                    ),
                  GestureDetector(
                    onTap: () => _jumpTo(i),
                    child: Text(
                      _stack[i].name,
                      style: TextStyle(
                        fontSize: 11.5 * s,
                        fontWeight: i == _stack.length - 1
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: i == _stack.length - 1
                            ? Colors.white.withValues(alpha: 0.9)
                            : const Color(0xFFFF8FA3),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(double s) {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2.5 * s,
          color: const Color(0xFFFF4D6E),
        ),
      );
    }
    if (_files.isEmpty) {
      return Center(
        child: Text(
          tr('空目录'),
          style: TextStyle(
            fontSize: 12.5 * s,
            color: Colors.white.withValues(alpha: 0.5),
          ),
        ),
      );
    }
    final dirs = _files.where((f) => f.isDir).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final audio = _files.where((f) => !f.isDir && f.isAudio).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final others = _files.where((f) => !f.isDir && !f.isAudio).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final ordered = [...dirs, ...audio, ...others];

    return ListView.builder(
      controller: _scroll,
      padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 4 * s),
      itemCount: ordered.length + (_cursor != null ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= ordered.length) {
          return InkWell(
            borderRadius: BorderRadius.circular(8 * s),
            onTap: _appending ? null : () => _load(more: true),
            child: SizedBox(
              height: 40 * s,
              child: Center(
                child: _appending
                    ? SizedBox(
                        width: 15 * s,
                        height: 15 * s,
                        child: CircularProgressIndicator(
                            strokeWidth: 2 * s, color: const Color(0xFFFF4D6E)),
                      )
                    : Text(
                        tr('加载更多'),
                        style: TextStyle(
                          fontSize: 12 * s,
                          color: const Color(0xFFFF8FA3),
                        ),
                      ),
              ),
            ),
          );
        }
        final f = ordered[i];
        final playable = f.isDir || f.isAudio;
        return InkWell(
          borderRadius: BorderRadius.circular(8 * s),
          onTap: () {
            if (f.isDir) {
              _enter(f);
            } else if (f.isAudio) {
              _play(f);
            }
          },
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 6 * s, vertical: 7 * s),
            child: Row(
              children: [
                Icon(
                  f.isDir
                      ? Icons.folder_rounded
                      : (f.isAudio
                          ? Icons.music_note_rounded
                          : Icons.insert_drive_file_rounded),
                  size: 18 * s,
                  color: f.isDir
                      ? const Color(0xFFFF8FA3)
                      : (f.isAudio
                          ? const Color(0xFFFF8FA3)
                          : Colors.white.withValues(alpha: 0.35)),
                ),
                SizedBox(width: 9 * s),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        f.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5 * s,
                          color: playable
                              ? Colors.white.withValues(alpha: 0.9)
                              : Colors.white.withValues(alpha: 0.4),
                        ),
                      ),
                      if (!f.isDir && f.size > 0) ...[
                        SizedBox(height: 1 * s),
                        Text(
                          _sizeText(f.size),
                          style: TextStyle(
                            fontSize: 9.5 * s,
                            color: Colors.white.withValues(alpha: 0.45),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!f.isDir && f.isAudio)
                  Icon(
                    Icons.play_circle_outline_rounded,
                    size: 17 * s,
                    color: const Color(0xFFFF8FA3),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _noAccountView(double s) {
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xFF101014).withValues(alpha: 0.96),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 36 * s,
                color: Colors.white.withValues(alpha: 0.4),
              ),
              SizedBox(height: 10 * s),
              Text(
                tr('尚未绑定{name}', {'name': _provider.displayName}),
                style: TextStyle(
                  fontSize: 12.5 * s,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
              SizedBox(height: 12 * s),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.symmetric(horizontal: 14 * s),
                  minimumSize: Size(0, 32 * s),
                ),
                child: Text(
                  tr('返回'),
                  style: TextStyle(
                    fontSize: 12.5 * s,
                    color: const Color(0xFFFF8FA3),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
