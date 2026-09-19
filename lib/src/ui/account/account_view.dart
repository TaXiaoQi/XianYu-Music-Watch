import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/watch_fit.dart';
import '../../auth/auth_provider.dart';
import '../../player/listen_stats.dart';
import '../../sync/sync_provider.dart';
import '../common/full_dialog.dart';

class AccountView extends ConsumerStatefulWidget {
  const AccountView({super.key});

  @override
  ConsumerState<AccountView> createState() => _AccountViewState();
}

class _AccountViewState extends ConsumerState<AccountView> {
  bool _passwordMode = false;

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final auth = ref.watch(authProvider);

    if (auth.sessionExpired) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!ref.read(authProvider).sessionExpired) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('登录已过期，请重新登录'),
            duration: Duration(seconds: 2),
          ),
        );
        ref.read(authProvider.notifier).consumeSessionExpired();
      });
    }

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.symmetric(horizontal: 22 * s, vertical: 6 * s),
          children: [
            Row(
              children: [
                const BackButton(),
                SizedBox(width: 4 * s),
                Text(
                  '账号',
                  style: TextStyle(
                    fontSize: 15 * s,
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ),
            SizedBox(height: 10 * s),
            if (auth.isLoggedIn)
              _profile(auth.user!, s)
            else ...[
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _passwordMode
                    ? const _PasswordLoginForm(key: ValueKey('pwd'))
                    : _QrLoginPanel(key: const ValueKey('qr'), auth: auth),
              ),
              SizedBox(height: 8 * s),
              TextButton(
                onPressed: () => setState(() => _passwordMode = !_passwordMode),
                child: Text(
                  _passwordMode ? '使用扫码登录' : '使用密码登录',
                  style: TextStyle(fontSize: 12 * s, color: Color(0xFFFF8FA3)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _profile(AuthUser user, double s) {
    final avatar = _AvatarImage.of(user.avatar);
    return Column(
      children: [
        CircleAvatar(
          radius: 30 * s,
          backgroundColor: const Color(0xFFFF4D6E),
          backgroundImage: avatar,
          child: avatar == null
              ? Icon(Icons.person_rounded, size: 30 * s, color: Colors.white)
              : null,
        ),
        SizedBox(height: 10 * s),
        Text(
          user.nickname.isNotEmpty ? user.nickname : user.username,
          style: TextStyle(fontSize: 16 * s, fontWeight: FontWeight.w700),
        ),
        SizedBox(height: 2 * s),
        Text(
          '弦予号 ${user.ciyuanxiId ?? user.username}',
          style: TextStyle(
            fontSize: 11 * s,
            color: Colors.white.withValues(alpha: 0.55),
          ),
        ),
        if (user.email.isNotEmpty)
          Text(
            user.email,
            style: TextStyle(
              fontSize: 11 * s,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
        SizedBox(height: 16 * s),
        const _ListenStatsCard(),
        SizedBox(height: 10 * s),
        const _SyncCard(),
        SizedBox(height: 14 * s),
        OutlinedButton.icon(
          onPressed: () async {
            await ref.read(authProvider.notifier).logout();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已退出登录'),
                  duration: Duration(seconds: 1),
                ),
              );
            }
          },
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFFF4D6E),
            side: const BorderSide(color: Color(0xFFFF4D6E)),
            padding: EdgeInsets.symmetric(horizontal: 22 * s, vertical: 8 * s),
          ),
          icon: Icon(Icons.logout_rounded, size: 16 * s),
          label: Text('退出登录', style: TextStyle(fontSize: 13 * s)),
        ),
        TextButton(
          onPressed: _showDeleteAccountGuide,
          child: Text(
            '注销账号',
            style: TextStyle(
              fontSize: 11 * s,
              color: Colors.white.withValues(alpha: 0.45),
            ),
          ),
        ),
      ],
    );
  }

  void _showDeleteAccountGuide() {
    showFullConfirm(
      context,
      title: '注销账号',
      message:
          '注销需密码和邮箱验证码双重确认，请到手机端或桌面端操作：\n\n手机端 · 账号页 → 注销账号\n桌面端 · 账号设置 → 注销账号',
      okLabel: '知道了',
      okOnly: true,
    );
  }
}

class _ListenStatsCard extends ConsumerStatefulWidget {
  const _ListenStatsCard();

  @override
  ConsumerState<_ListenStatsCard> createState() => _ListenStatsCardState();
}

class _ListenStatsCardState extends ConsumerState<_ListenStatsCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(listenStatsProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final stats = ref.watch(listenStatsProvider);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 10 * s),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12 * s),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.graphic_eq_rounded,
                size: 15 * s,
                color: const Color(0xFFFF8FA3),
              ),
              SizedBox(width: 6 * s),
              Text(
                '听歌时长',
                style: TextStyle(fontSize: 13 * s, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          SizedBox(height: 8 * s),
          Row(
            children: [
              _statItem('今日', formatListenDuration(stats.displayDaily), s),
              _statItem('本周', formatListenDuration(stats.displayWeekly), s),
              _statItem('累计', formatListenDuration(stats.displayTotal), s),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statItem(String label, String value, double s) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.5 * s,
              fontWeight: FontWeight.w700,
              color: Colors.white.withValues(alpha: 0.92),
            ),
          ),
          SizedBox(height: 2 * s),
          Text(
            label,
            style: TextStyle(
              fontSize: 10 * s,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncCard extends ConsumerWidget {
  const _SyncCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.watchScale();
    final sync = ref.watch(syncProvider);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(12 * s, 8 * s, 12 * s, 12 * s),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12 * s),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.cloud_sync_rounded,
                size: 15 * s,
                color: const Color(0xFFFF8FA3),
              ),
              SizedBox(width: 6 * s),
              Text(
                '云同步',
                style: TextStyle(fontSize: 13 * s, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                '自动同步',
                style: TextStyle(
                  fontSize: 11 * s,
                  color: Colors.white.withValues(alpha: 0.55),
                ),
              ),
              SizedBox(
                height: 32 * s,
                width: 52 * s,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Switch(
                    value: sync.autoSync,
                    activeThumbColor: const Color(0xFFFF4D6E),
                    onChanged: (v) =>
                        ref.read(syncProvider.notifier).setAutoSync(v),
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: [
              if (sync.syncing) ...[
                SizedBox(
                  width: 12 * s,
                  height: 12 * s,
                  child: CircularProgressIndicator(
                    strokeWidth: 2 * s,
                    color: const Color(0xFFFF8FA3),
                  ),
                ),
                SizedBox(width: 6 * s),
                Text(
                  '同步中…',
                  style: TextStyle(
                    fontSize: 11 * s,
                    color: const Color(0xFFFF8FA3),
                  ),
                ),
              ] else
                Expanded(
                  child: Text(
                    sync.lastSyncAt == null
                        ? '尚未同步'
                        : '上次同步 ${_fmtTime(sync.lastSyncAt!)}',
                    style: TextStyle(
                      fontSize: 11 * s,
                      color: Colors.white.withValues(alpha: 0.55),
                    ),
                  ),
                ),
            ],
          ),
          if (sync.error != null) ...[
            SizedBox(height: 4 * s),
            Text(
              sync.error!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10 * s,
                color: const Color(0xFFFF6B81),
              ),
            ),
          ] else if (sync.lastSummary.isNotEmpty) ...[
            SizedBox(height: 4 * s),
            Text(
              sync.lastSummary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10 * s,
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ),
          ],
          SizedBox(height: 10 * s),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 34 * s,
                  child: FilledButton.tonalIcon(
                    onPressed: sync.syncing
                        ? null
                        : () => ref.read(syncProvider.notifier).syncDownload(),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.10),
                      foregroundColor: const Color(0xFFFF8FA3),
                      padding: EdgeInsets.symmetric(horizontal: 6 * s),
                    ),
                    icon: Icon(Icons.cloud_download_rounded, size: 15 * s),
                    label: Text('手动下载', style: TextStyle(fontSize: 11 * s)),
                  ),
                ),
              ),
              SizedBox(width: 8 * s),
              Expanded(
                child: SizedBox(
                  height: 34 * s,
                  child: FilledButton.tonalIcon(
                    onPressed: sync.syncing
                        ? null
                        : () => ref.read(syncProvider.notifier).syncUpload(),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.10),
                      foregroundColor: const Color(0xFFFF8FA3),
                      padding: EdgeInsets.symmetric(horizontal: 6 * s),
                    ),
                    icon: Icon(Icons.cloud_upload_rounded, size: 15 * s),
                    label: Text('手动上传', style: TextStyle(fontSize: 11 * s)),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 6 * s),
          Text(
            '自动同步：登录后全量一次，之后每小时上传一次',
            style: TextStyle(
              fontSize: 9.5 * s,
              color: Colors.white.withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
    );
  }
}

String _fmtTime(DateTime t) {
  String p(int v) => v.toString().padLeft(2, '0');
  return '${p(t.month)}-${p(t.day)} ${p(t.hour)}:${p(t.minute)}';
}

class _AvatarImage {
  static final Map<String, ImageProvider> _cache = {};
  static const int _maxCache = 4;

  static ImageProvider? of(String? avatar) {
    if (avatar == null || avatar.isEmpty) return null;
    final cached = _cache[avatar];
    if (cached != null) return cached;
    ImageProvider? provider;
    if (avatar.startsWith('data:image')) {
      final comma = avatar.indexOf(',');
      if (comma < 0) return null;
      try {
        provider = MemoryImage(base64Decode(avatar.substring(comma + 1)));
      } catch (_) {
        return null;
      }
    } else if (avatar.startsWith('http')) {
      provider = NetworkImage(avatar);
    } else {
      return null;
    }
    if (_cache.length >= _maxCache) _cache.remove(_cache.keys.first);
    _cache[avatar] = provider;
    return provider;
  }
}

class _PasswordLoginForm extends ConsumerStatefulWidget {
  const _PasswordLoginForm({super.key});

  @override
  ConsumerState<_PasswordLoginForm> createState() => _PasswordLoginFormState();
}

class _PasswordLoginFormState extends ConsumerState<_PasswordLoginForm> {
  final _idCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _answerCtrl = TextEditingController();

  bool _configLoading = true;
  bool _providerMode = false;
  HumanCaptcha? _captcha;
  String? _captchaError;

  @override
  void initState() {
    super.initState();
    _loadCaptcha();
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _pwdCtrl.dispose();
    _answerCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCaptcha() async {
    setState(() {
      _configLoading = true;
      _captchaError = null;
    });
    try {
      final notifier = ref.read(authProvider.notifier);
      final cfg = await notifier.fetchCaptchaConfig();
      if (!mounted) return;
      if (cfg.isProviderEnabled) {
        setState(() {
          _providerMode = true;
          _configLoading = false;
        });
        return;
      }
      final c = await notifier.fetchCaptcha();
      if (!mounted) return;
      setState(() {
        _captcha = c;
        _configLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _captcha = null;
        _configLoading = false;
        _captchaError = '验证题加载失败，请稍后重试';
      });
    }
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final id = _idCtrl.text.trim();
    final pwd = _pwdCtrl.text;
    if (id.isEmpty || pwd.isEmpty) {
      ref.read(authProvider.notifier).setFormError('请输入弦予号和密码');
      return;
    }
    final captcha = _captcha;
    HumanCaptchaPayload? payload;
    if (captcha != null && captcha.captchaId.isNotEmpty) {
      final answer = _answerCtrl.text.trim();
      if (answer.isEmpty) {
        ref.read(authProvider.notifier).setFormError('请输入验证答案');
        return;
      }
      payload = HumanCaptchaPayload(
        captchaId: captcha.captchaId,
        captchaAnswer: answer,
      );
    }
    try {
      if (payload != null) {
        await ref.read(authProvider.notifier).verifyCaptcha(payload);
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      ref.read(authProvider.notifier).setFormError(e.message);
      if (e.message.contains('人机验证')) await _loadCaptcha();
      return;
    }
    if (!mounted) return;
    await ref
        .read(authProvider.notifier)
        .login(ciyuanxiId: id, password: pwd, captcha: payload);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final auth = ref.watch(authProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _idCtrl,
          style: TextStyle(fontSize: 13 * s),
          decoration: InputDecoration(
            hintText: '弦予号',
            isDense: true,
            prefixIcon: Icon(Icons.badge_rounded, size: 18 * s),
          ),
          textInputAction: TextInputAction.next,
        ),
        SizedBox(height: 10 * s),
        TextField(
          controller: _pwdCtrl,
          obscureText: true,
          style: TextStyle(fontSize: 13 * s),
          decoration: InputDecoration(
            hintText: '密码',
            isDense: true,
            prefixIcon: Icon(Icons.lock_rounded, size: 18 * s),
          ),
          textInputAction: TextInputAction.done,
        ),
        SizedBox(height: 10 * s),
        if (_configLoading)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 10 * s),
            child: Center(
              child: SizedBox(
                width: 16 * s,
                height: 16 * s,
                child: CircularProgressIndicator(
                  strokeWidth: 2 * s,
                  color: const Color(0xFFFF4D6E),
                ),
              ),
            ),
          )
        else if (_providerMode) ...[
          Container(
            padding: EdgeInsets.all(10 * s),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10 * s),
            ),
            child: Text(
              '服务端启用了网页人机验证，腕上端不支持。\n请返回使用扫码登录。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11 * s,
                height: 1.4,
                color: Colors.white.withValues(alpha: 0.7),
              ),
            ),
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  _captcha?.question ?? '验证题加载失败',
                  style: TextStyle(
                    fontSize: 14 * s,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFFFF8FA3),
                  ),
                ),
              ),
              IconButton(
                onPressed: _loadCaptcha,
                icon: Icon(Icons.refresh_rounded, size: 18 * s),
                tooltip: '换一题',
              ),
              SizedBox(
                width: 96 * s,
                height: 38 * s,
                child: TextField(
                  controller: _answerCtrl,
                  keyboardType: TextInputType.number,
                  style: TextStyle(fontSize: 14 * s),
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                    hintText: '答案',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
            ],
          ),
        ],
        if (_captchaError != null) ...[
          SizedBox(height: 6 * s),
          Text(
            _captchaError!,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11 * s, color: const Color(0xFFFF6B81)),
          ),
        ],
        if (auth.error != null) ...[
          SizedBox(height: 8 * s),
          Text(
            auth.error!,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11 * s, color: const Color(0xFFFF6B81)),
          ),
        ],
        SizedBox(height: 14 * s),
        FilledButton(
          onPressed: auth.loading || _configLoading || _providerMode
              ? null
              : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFFF4D6E),
            minimumSize: Size(0, 40 * s),
          ),
          child: auth.loading
              ? SizedBox(
                  width: 18 * s,
                  height: 18 * s,
                  child: CircularProgressIndicator(
                    strokeWidth: 2 * s,
                    color: Colors.white,
                  ),
                )
              : Text('登录', style: TextStyle(fontSize: 14 * s)),
        ),
        SizedBox(height: 8 * s),
        Text(
          '没有账号？请在手机端注册',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10 * s,
            color: Colors.white.withValues(alpha: 0.35),
          ),
        ),
      ],
    );
  }
}

class _QrLoginPanel extends ConsumerStatefulWidget {
  const _QrLoginPanel({super.key, required this.auth});

  final AuthState auth;

  @override
  ConsumerState<_QrLoginPanel> createState() => _QrLoginPanelState();
}

class _QrLoginPanelState extends ConsumerState<_QrLoginPanel> {
  String? _code;
  int? _expireAtMs;
  String _status = 'loading';
  String _error = '';
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    _pollTimer?.cancel();
    setState(() {
      _status = 'loading';
      _code = null;
      _error = '';
    });
    try {
      final (code, expireSeconds) = await ref
          .read(authProvider.notifier)
          .createQrLogin();
      if (!mounted) return;
      setState(() {
        _code = code;
        _expireAtMs =
            DateTime.now().millisecondsSinceEpoch + expireSeconds * 1000;
        _status = 'pending';
      });
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'error';
        _error = e.toString();
      });
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
      if (!mounted || _code == null) return;
      if (DateTime.now().millisecondsSinceEpoch > (_expireAtMs ?? 0)) {
        t.cancel();
        if (mounted) setState(() => _status = 'expired');
        return;
      }
      final user = await ref
          .read(authProvider.notifier)
          .pollQrLogin(
            code: _code!,
            onStatus: (s) {
              if (mounted && (s == 'scanned' || s == 'invalid')) {
                setState(
                  () => _status = s == 'invalid' ? 'expired' : 'scanned',
                );
              }
            },
          );
      if (user != null && mounted) {
        t.cancel();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('登录成功，欢迎 ${user.nickname}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final hint = switch (_status) {
      'loading' => '二维码生成中…',
      'pending' => '打开手机端 弦予音乐 扫码',
      'scanned' => '已扫码，请在手机上确认登录',
      'expired' => '二维码已过期',
      _ => '二维码获取失败',
    };
    return Column(
      children: [
        Container(
          width: 148 * s,
          height: 148 * s,
          padding: EdgeInsets.all(8 * s),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12 * s),
          ),
          child: Center(
            child: switch (_status) {
              'loading' => CircularProgressIndicator(
                color: const Color(0xFFFF4D6E),
                strokeWidth: 2.5 * s,
              ),
              'expired' || 'error' => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.qr_code_2_rounded,
                    size: 30 * s,
                    color: Colors.black.withValues(alpha: 0.35),
                  ),
                  SizedBox(height: 5 * s),
                  FilledButton.tonal(
                    onPressed: _start,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFF4D6E),
                      foregroundColor: Colors.white,
                      minimumSize: Size(0, 28 * s),
                      padding: EdgeInsets.symmetric(
                        horizontal: 14 * s,
                        vertical: 4 * s,
                      ),
                    ),
                    child: Text('刷新二维码', style: TextStyle(fontSize: 11 * s)),
                  ),
                ],
              ),
              'scanned' => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.task_alt_rounded,
                    size: 34 * s,
                    color: const Color(0xFF34C759),
                  ),
                  SizedBox(height: 6 * s),
                  Text(
                    '已扫描',
                    style: TextStyle(
                      fontSize: 14 * s,
                      fontWeight: FontWeight.w700,
                      color: Colors.black.withValues(alpha: 0.85),
                    ),
                  ),
                  SizedBox(height: 3 * s),
                  Text(
                    '等待手机端确认登录',
                    style: TextStyle(
                      fontSize: 10.5 * s,
                      color: Colors.black.withValues(alpha: 0.45),
                    ),
                  ),
                ],
              ),
              _ => QrImageView(
                data: 'xianyumusic://tvlogin/$_code',
                version: QrVersions.auto,
                size: 132 * s,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
                backgroundColor: Colors.white,
              ),
            },
          ),
        ),
        SizedBox(height: 8 * s),
        Text(
          hint,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11.5 * s,
            color: _status == 'scanned'
                ? const Color(0xFF7EE38B)
                : Colors.white.withValues(alpha: 0.6),
          ),
        ),
        if (_status == 'error' && _error.isNotEmpty) ...[
          SizedBox(height: 3.5 * s),
          Text(
            _error,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 9.5 * s, color: const Color(0xFFFF6B81)),
          ),
        ],
      ],
    );
  }
}
