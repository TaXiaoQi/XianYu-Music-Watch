import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../auth/auth_provider.dart';
import '../../sync/sync_provider.dart';

/// 账号页：未登录 → 默认扫码登录（桌面端同款 generate_tv_login_code，
/// 手机 App 扫码确认），可切弦予号密码登录；已登录 → 资料展示 + 退出。
class AccountView extends ConsumerStatefulWidget {
  const AccountView({super.key});

  @override
  ConsumerState<AccountView> createState() => _AccountViewState();
}

class _AccountViewState extends ConsumerState<AccountView> {
  bool _passwordMode = false;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    // 会话失效提示（token 被服务端判过期）。
    if (auth.sessionExpired) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('登录已过期，请重新登录'), duration: Duration(seconds: 2)),
        );
        ref.read(authProvider.notifier).consumeSessionExpired();
      });
    }

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
          children: [
            Row(
              children: [
                const BackButton(),
                const SizedBox(width: 4),
                Text('账号',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.white.withValues(alpha: 0.9))),
              ],
            ),
            const SizedBox(height: 10),
            if (auth.isLoggedIn)
              _profile(auth.user!)
            else ...[
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: _passwordMode
                    ? const _PasswordLoginForm(key: ValueKey('pwd'))
                    : _QrLoginPanel(key: const ValueKey('qr'), auth: auth),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () =>
                    setState(() => _passwordMode = !_passwordMode),
                child: Text(
                  _passwordMode ? '使用扫码登录' : '使用密码登录',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFFF8FA3)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _profile(AuthUser user) {
    final avatar = _AvatarImage.of(user.avatar);
    return Column(
      children: [
        CircleAvatar(
          radius: 30,
          backgroundColor: const Color(0xFFFF4D6E),
          backgroundImage: avatar,
          child: avatar == null
              ? const Icon(Icons.person_rounded, size: 30, color: Colors.white)
              : null,
        ),
        const SizedBox(height: 10),
        Text(user.nickname.isNotEmpty ? user.nickname : user.username,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text('弦予号 ${user.ciyuanxiId ?? user.username}',
            style: TextStyle(
                fontSize: 11, color: Colors.white.withValues(alpha: 0.55))),
        if (user.email.isNotEmpty)
          Text(user.email,
              style: TextStyle(
                  fontSize: 11, color: Colors.white.withValues(alpha: 0.4))),
        const SizedBox(height: 16),
        const _SyncCard(),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: () async {
            await ref.read(authProvider.notifier).logout();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已退出登录'), duration: Duration(seconds: 1)),
              );
            }
          },
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFFF4D6E),
            side: const BorderSide(color: Color(0xFFFF4D6E)),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
          ),
          icon: const Icon(Icons.logout_rounded, size: 16),
          label: const Text('退出登录', style: TextStyle(fontSize: 13)),
        ),
        TextButton(
          onPressed: _showDeleteAccountGuide,
          child: Text('注销账号',
              style: TextStyle(
                  fontSize: 11, color: Colors.white.withValues(alpha: 0.45))),
        ),
      ],
    );
  }

  /// 注销引导：需要密码+邮箱验证码双重确认，腕上端输入不便，指到手机/桌面端。
  void _showDeleteAccountGuide() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('注销账号',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: const Text(
          '注销需密码和邮箱验证码双重确认，请到手机端或桌面端操作：\n\n手机端 · 账号页 → 注销账号\n桌面端 · 账号设置 → 注销账号',
          style: TextStyle(fontSize: 12, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了',
                style: TextStyle(color: Color(0xFFFF8FA3))),
          ),
        ],
      ),
    );
  }
}

/// 云同步卡：状态 + 自动同步开关 + 手动下载/上传（对齐移动端账号页语义）。
class _SyncCard extends ConsumerWidget {
  const _SyncCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_sync_rounded,
                  size: 15, color: Color(0xFFFF8FA3)),
              const SizedBox(width: 6),
              const Text('云同步',
                  style:
                      TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('自动同步',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.55))),
              SizedBox(
                height: 32,
                width: 52,
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
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Color(0xFFFF8FA3)),
                ),
                const SizedBox(width: 6),
                const Text('同步中…',
                    style:
                        TextStyle(fontSize: 11, color: Color(0xFFFF8FA3))),
              ] else
                Expanded(
                  child: Text(
                    sync.lastSyncAt == null
                        ? '尚未同步'
                        : '上次同步 ${_fmtTime(sync.lastSyncAt!)}',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.55)),
                  ),
                ),
            ],
          ),
          if (sync.error != null) ...[
            const SizedBox(height: 4),
            Text(sync.error!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 10, color: Color(0xFFFF6B81))),
          ] else if (sync.lastSummary.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(sync.lastSummary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 10,
                    color: Colors.white.withValues(alpha: 0.4))),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: FilledButton.tonalIcon(
                    onPressed: sync.syncing
                        ? null
                        : () => ref.read(syncProvider.notifier).syncDownload(),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.10),
                      foregroundColor: const Color(0xFFFF8FA3),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    icon: const Icon(Icons.cloud_download_rounded, size: 15),
                    label:
                        const Text('手动下载', style: TextStyle(fontSize: 11)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: FilledButton.tonalIcon(
                    onPressed: sync.syncing
                        ? null
                        : () => ref.read(syncProvider.notifier).syncUpload(),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.10),
                      foregroundColor: const Color(0xFFFF8FA3),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    icon: const Icon(Icons.cloud_upload_rounded, size: 15),
                    label:
                        const Text('手动上传', style: TextStyle(fontSize: 11)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('自动同步：登录后全量一次，之后每小时上传一次',
              style: TextStyle(
                  fontSize: 9.5,
                  color: Colors.white.withValues(alpha: 0.35))),
        ],
      ),
    );
  }
}

String _fmtTime(DateTime t) {
  String p(int v) => v.toString().padLeft(2, '0');
  return '${p(t.month)}-${p(t.day)} ${p(t.hour)}:${p(t.minute)}';
}

/// 头像 ImageProvider 解析（对齐移动端 UserAvatarImage）：
/// 服务端 avatar 存的是 `data:image/...;base64,...` 数据 URI（桌面端 <img> 原生
/// 支持），Flutter 的 NetworkImage 不认 data URL，必须解码字节走 MemoryImage；
/// http(s) URL 才走网络加载；空/异常返回 null 落回占位图标。
/// 按 data URL 缓存 ImageProvider（MemoryImage 以字节实例作缓存键），
/// 避免每次 build 重新解码导致闪烁。
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

/// 密码登录表单（含人机验证）：进表单先取服务端验证配置——
/// Turnstile/hCaptcha 模式腕上端无法渲染 WebView，引导扫码；
/// 算术题模式内联「题目 + 刷新 + 答案」，提交前预校验后登录。
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
      // 先预校验答案（不消费验证码），错误时刷新题目。
      if (payload != null) {
        await ref.read(authProvider.notifier).verifyCaptcha(payload);
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      ref.read(authProvider.notifier).setFormError(e.message);
      if (e.message.contains('人机验证')) await _loadCaptcha();
      return;
    }
    await ref
        .read(authProvider.notifier)
        .login(ciyuanxiId: id, password: pwd, captcha: payload);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _idCtrl,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            hintText: '弦予号',
            isDense: true,
            prefixIcon: Icon(Icons.badge_rounded, size: 18),
          ),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _pwdCtrl,
          obscureText: true,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            hintText: '密码',
            isDense: true,
            prefixIcon: Icon(Icons.lock_rounded, size: 18),
          ),
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: 10),
        // 人机验证区。
        if (_configLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Color(0xFFFF4D6E)),
              ),
            ),
          )
        else if (_providerMode) ...[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '服务端启用了网页人机验证，腕上端不支持。\n请返回使用扫码登录。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: Colors.white.withValues(alpha: 0.7)),
            ),
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  _captcha?.question ?? '验证题加载失败',
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFFF8FA3)),
                ),
              ),
              IconButton(
                onPressed: _loadCaptcha,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                tooltip: '换一题',
              ),
              SizedBox(
                width: 96,
                height: 38,
                child: TextField(
                  controller: _answerCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 14),
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
          const SizedBox(height: 6),
          Text(_captchaError!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Color(0xFFFF6B81))),
        ],
        if (auth.error != null) ...[
          const SizedBox(height: 8),
          Text(auth.error!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Color(0xFFFF6B81))),
        ],
        const SizedBox(height: 14),
        FilledButton(
          onPressed: auth.loading || _configLoading || _providerMode
              ? null
              : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFFF4D6E),
            minimumSize: const Size(0, 40),
          ),
          child: auth.loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Text('登录', style: TextStyle(fontSize: 14)),
        ),
        const SizedBox(height: 8),
        Text('没有账号？请在手机端注册',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 10, color: Colors.white.withValues(alpha: 0.35))),
      ],
    );
  }
}

/// 扫码登录面板：生成二维码 → 手机 App 扫码确认 → 2s 轮询拿凭证。
/// 状态机与桌面端一致：loading / pending / scanned / expired / error。
class _QrLoginPanel extends ConsumerStatefulWidget {
  const _QrLoginPanel({super.key, required this.auth});

  final AuthState auth;

  @override
  ConsumerState<_QrLoginPanel> createState() => _QrLoginPanelState();
}

class _QrLoginPanelState extends ConsumerState<_QrLoginPanel> {
  String? _code;
  int? _expireAtMs;
  String _status = 'loading'; // loading/pending/scanned/expired/error
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
      final (code, expireSeconds) =
          await ref.read(authProvider.notifier).createQrLogin();
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
          .pollQrLogin(code: _code!, onStatus: (s) {
        if (mounted && (s == 'scanned' || s == 'invalid')) {
          setState(() => _status = s == 'invalid' ? 'expired' : 'scanned');
        }
      });
      if (user != null && mounted) {
        t.cancel();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('登录成功，欢迎 ${user.nickname}'),
              duration: const Duration(seconds: 2)),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final hint = switch (_status) {
      'loading' => '二维码生成中…',
      'pending' => '打开手机端 弦予音乐 扫码',
      'scanned' => '已扫码，请在手机上确认登录',
      'expired' => '二维码已过期',
      _ => '二维码获取失败',
    };
    return Column(
      children: [
        // 二维码卡片（白底保证扫码对比度）。
        Container(
          width: 190,
          height: 190,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Center(
            child: switch (_status) {
              'loading' =>
                const CircularProgressIndicator(color: Color(0xFFFF4D6E)),
              'expired' || 'error' => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.qr_code_2_rounded,
                        size: 40, color: Colors.black.withValues(alpha: 0.35)),
                    const SizedBox(height: 6),
                    FilledButton.tonal(
                      onPressed: _start,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFF4D6E),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 4),
                      ),
                      child: const Text('刷新二维码',
                          style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              _ => QrImageView(
                  data: 'xianyumusic://tvlogin/$_code',
                  version: QrVersions.auto,
                  size: 168,
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                  backgroundColor: Colors.white,
                ),
            },
          ),
        ),
        const SizedBox(height: 10),
        Text(
          hint,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            color: _status == 'scanned'
                ? const Color(0xFF7EE38B)
                : Colors.white.withValues(alpha: 0.6),
          ),
        ),
        if (_status == 'error' && _error.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(_error,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10, color: Color(0xFFFF6B81))),
        ],
      ],
    );
  }
}
