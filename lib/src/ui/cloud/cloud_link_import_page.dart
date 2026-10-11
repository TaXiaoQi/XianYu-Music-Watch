import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/cloud_credentials_store.dart';
import '../../cloud/cloud_provider.dart';
import '../../cloud/cloud_registry.dart';
import '../../cloud/cloud_types.dart';
import '../../cloud/share_link_parser.dart';
import '../../core/watch_fit.dart';
import '../../i18n/i18n.dart';
import '../common/stepped_list.dart';
import '../../player/player_provider.dart';

/// 分享链接导入页：粘贴链接 → 识别盘 → 解析文件列表 → 播放/转存播放。
///
/// directPlayable 盘（蓝奏/139/夸克等）免转存直链点播；其余盘走
/// transferShareFiles 转存后按我的网盘直链播放（未绑定引导先绑定）。
class CloudLinkImportPage extends ConsumerStatefulWidget {
  const CloudLinkImportPage({super.key});

  @override
  ConsumerState<CloudLinkImportPage> createState() =>
      _CloudLinkImportPageState();
}

class _CloudLinkImportPageState extends ConsumerState<CloudLinkImportPage> {
  final _urlCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  bool _parsing = false;
  bool _transferring = false;
  CloudProvider? _provider;
  CloudShareParse? _share;

  @override
  void initState() {
    super.initState();
    _readClipboard();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _pwdCtrl.dispose();
    super.dispose();
  }

  /// 进入页面时探测剪贴板：内容可识别为网盘分享链接则自动填充。
  Future<void> _readClipboard() async {
    try {
      final text = (await Clipboard.getData('text/plain'))?.text?.trim() ?? '';
      if (text.isEmpty || !mounted) return;
      if (parseUrlToProvider(text) != null) {
        setState(() => _urlCtrl.text = text);
      }
    } catch (_) {
      // 剪贴板不可用静默忽略。
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  Future<void> _parse() async {
    if (_parsing) return;
    final info = parseUrlToProvider(_urlCtrl.text);
    if (info == null) {
      _toast(tr('未识别的分享链接'));
      return;
    }
    final provider = cloudProviderById(info.providerId);
    if (provider == null) {
      _toast(tr('该网盘暂未支持'));
      return;
    }
    setState(() => _parsing = true);
    try {
      final pwd = _pwdCtrl.text.trim();
      final share =
          await provider.parseShareLink(info.url, pwd.isEmpty ? null : pwd);
      if (!mounted) return;
      if (share.files.isEmpty) {
        _toast(tr('分享内没有文件'));
      }
      setState(() {
        _provider = provider;
        _share = share;
        _parsing = false;
      });
    } catch (e) {
      if (!mounted) return;
      _toast(e is CloudException ? e.message : tr('分享链接解析失败'));
      setState(() => _parsing = false);
    }
  }

  Future<void> _playFile(CloudFile f) async {
    final provider = _provider;
    final share = _share;
    if (provider == null || share == null || _transferring) return;
    final accounts =
        await CloudCredentialsStore.instance.accountsFor(provider.id);

    if (share.directPlayable) {
      // 免转存直链：已绑账号用其凭据，未绑定也允许（免登录通道）。
      final ctx = CloudPlayContext(
        provider: provider.id,
        accountId: accounts.isEmpty ? '_' : accounts.first.accountId,
        file: f,
        share: share,
      );
      await ref
          .read(playerProvider.notifier)
          .playQueue(
              [cloudPlayQueueItem(ctx, artist: provider.displayName)],
              startIndex: 0);
      return;
    }

    // 需转存：必须已绑定。
    if (accounts.isEmpty) {
      if (!mounted) return;
      _toast(tr('请先绑定{name}', {'name': provider.displayName}));
      return;
    }
    final account = accounts.first;
    setState(() => _transferring = true);
    try {
      final transferred = await provider.transferShareFiles(account.cred, share);
      if (!mounted) return;
      final audioFiles = transferred.where((x) => x.isAudio).toList();
      if (audioFiles.isEmpty) {
        _toast(tr('分享内没有音频文件'));
        return;
      }
      var start = audioFiles.indexWhere((x) => x.name == f.name);
      if (start < 0) start = 0;
      final items = [
        for (final x in audioFiles)
          cloudPlayQueueItem(
            CloudPlayContext(
              provider: provider.id,
              accountId: account.accountId,
              file: x,
            ),
            artist: provider.displayName,
          ),
      ];
      await ref
          .read(playerProvider.notifier)
          .playQueue(items, startIndex: start);
    } catch (e) {
      if (!mounted) return;
      _toast(e is CloudException ? e.message : tr('转存失败，请重试'));
    } finally {
      if (mounted) setState(() => _transferring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final rows = <Widget>[
      _pill(
        s,
        TextField(
          controller: _urlCtrl,
          autocorrect: false,
          keyboardType: TextInputType.url,
          style: TextStyle(fontSize: 12.5 * s),
          decoration: InputDecoration(
            hintText: tr('粘贴网盘分享链接'),
            isDense: true,
            border: InputBorder.none,
            contentPadding:
                EdgeInsets.symmetric(vertical: 8 * s, horizontal: 2 * s),
          ),
        ),
      ),
      _pill(
        s,
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _pwdCtrl,
                autocorrect: false,
                style: TextStyle(fontSize: 12.5 * s),
                decoration: InputDecoration(
                  hintText: tr('提取码（选填）'),
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding:
                      EdgeInsets.symmetric(vertical: 8 * s, horizontal: 2 * s),
                ),
              ),
            ),
            TextButton(
              onPressed: _parsing ? null : _parse,
              style: TextButton.styleFrom(
                padding: EdgeInsets.symmetric(horizontal: 8 * s),
                minimumSize: Size(0, 30 * s),
              ),
              child: _parsing
                  ? SizedBox(
                      width: 15 * s,
                      height: 15 * s,
                      child: CircularProgressIndicator(
                        strokeWidth: 2 * s,
                        color: const Color(0xFFFF8FA3),
                      ),
                    )
                  : Text(
                      tr('解析'),
                      style: TextStyle(
                        fontSize: 12 * s,
                        color: const Color(0xFFFF8FA3),
                      ),
                    ),
            ),
          ],
        ),
      ),
      ..._resultRows(s),
    ];

    return Stack(
      children: [
        SteppedListView(
          header: PageTitleHeader(tr('分享链接导入'), showBack: true),
          itemCount: rows.length,
          itemBuilder: (context, i) => rows[i],
        ),
        if (_transferring)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black38,
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2.5 * s,
                  color: const Color(0xFFFF4D6E),
                ),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _resultRows(double s) {
    final provider = _provider;
    final share = _share;
    if (provider == null || share == null) return const [];
    return [
      SizedBox(
        width: double.infinity,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              provider.displayName,
              style: TextStyle(
                fontSize: 12.5 * s,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(width: 8 * s),
            Text(
              share.directPlayable ? tr('免转存播放') : tr('需转存后播放'),
              style: TextStyle(
                fontSize: 10.5 * s,
                color: share.directPlayable
                    ? const Color(0xFFFF8FA3)
                    : Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
      for (final f in share.files)
        _fileRow(s, f),
    ];
  }

  Widget _fileRow(double s, CloudFile f) {
    return _pill(
      s,
      Row(
        children: [
          Icon(
            f.isDir
                ? Icons.folder_rounded
                : (f.isAudio
                    ? Icons.music_note_rounded
                    : Icons.insert_drive_file_rounded),
            size: 16 * s,
            color: f.isAudio
                ? const Color(0xFFFF8FA3)
                : Colors.white.withValues(alpha: 0.4),
          ),
          SizedBox(width: 8 * s),
          Expanded(
            child: Text(
              f.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12 * s,
                color: f.isAudio
                    ? Colors.white.withValues(alpha: 0.9)
                    : Colors.white.withValues(alpha: 0.45),
              ),
            ),
          ),
          if (f.isAudio)
            Icon(
              Icons.play_circle_outline_rounded,
              size: 16 * s,
              color: const Color(0xFFFF8FA3),
            ),
        ],
      ),
      onTap: f.isAudio ? () => _playFile(f) : null,
    );
  }

  Widget _pill(double s, Widget child, {VoidCallback? onTap}) {
    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: SteppedPill(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 2 * s),
          child: Center(child: child),
        ),
      ),
    );
  }
}
