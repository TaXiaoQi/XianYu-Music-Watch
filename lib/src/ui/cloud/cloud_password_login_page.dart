import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/cloud_credentials_store.dart';
import '../../cloud/cloud_provider.dart';
import '../../cloud/cloud_registry.dart';
import '../../cloud/cloud_types.dart';
import '../../core/application_logger.dart';
import '../../core/watch_fit.dart';
import '../../i18n/i18n.dart';
import '../common/stepped_list.dart';

/// 账密 / 短信登录页（httpPassword / smsPassword 范式，与移动端
/// cloud_password_login_page 同构）。
///
/// 表单按 provider.loginFields 动态渲染；发送验证码按钮仅出现在
/// isSmsCode 字段上，倒计时内禁用。
class CloudPasswordLoginPage extends ConsumerStatefulWidget {
  const CloudPasswordLoginPage({super.key, required this.providerId});

  final String providerId;

  @override
  ConsumerState<CloudPasswordLoginPage> createState() =>
      _CloudPasswordLoginPageState();
}

class _CloudPasswordLoginPageState
    extends ConsumerState<CloudPasswordLoginPage> {
  late final CloudProvider _provider;
  final Map<String, TextEditingController> _ctrls = {};
  bool _submitting = false;
  bool _sendingSms = false;
  int _smsCooldown = 0;
  Timer? _cooldownTimer;
  String? _error;

  @override
  void initState() {
    super.initState();
    _provider = cloudProviderById(widget.providerId)!;
    for (final f in _provider.loginFields) {
      _ctrls[f.key] = TextEditingController();
    }
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> get _fields => {
        for (final e in _ctrls.entries) e.key: e.value.text.trim(),
      };

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 1)),
    );
  }

  Future<void> _sendSms() async {
    if (_sendingSms || _smsCooldown > 0) return;
    setState(() => _sendingSms = true);
    try {
      await _provider.sendLoginSms(_fields);
      if (!mounted) return;
      _toast(tr('验证码已发送'));
      setState(() => _smsCooldown = 60);
      _cooldownTimer?.cancel();
      _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {
          if (--_smsCooldown <= 0) {
            _smsCooldown = 0;
            _cooldownTimer?.cancel();
          }
        });
      });
    } catch (e) {
      AppLog.warn('cloud', '${_provider.id} 发送验证码失败: $e');
      if (!mounted) return;
      _toast(e is CloudException ? e.message : tr('验证码发送失败'));
    } finally {
      if (mounted) setState(() => _sendingSms = false);
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final fields = _fields;
    if (fields.values.any((v) => v.isEmpty)) {
      setState(() => _error = tr('请填写完整'));
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final account = await _provider.loginWithFields(fields);
      await CloudCredentialsStore.instance.saveAccount(account);
      if (!mounted) return;
      _toast(tr('绑定成功'));
      Navigator.of(context).pop();
    } catch (e) {
      AppLog.warn('cloud', '${_provider.id} 账密登录失败: $e');
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e is CloudException ? e.message : tr('登录失败，请重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watchScale();
    final rows = <Widget>[
      SizedBox(
        width: double.infinity,
        child: Text(
          tr('登录{name}后即可播放网盘内的音乐', {'name': _provider.displayName}),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11 * s,
            height: 1.4,
            color: Colors.white.withValues(alpha: 0.6),
          ),
        ),
      ),
    ];

    for (final f in _provider.loginFields) {
      rows.add(_fieldPill(s, f));
    }

    if (_error != null) {
      rows.add(
        SizedBox(
          width: double.infinity,
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11 * s, color: const Color(0xFFFF6B81)),
          ),
        ),
      );
    }

    rows.add(
      SizedBox(
        width: double.infinity,
        height: double.infinity,
        child: SteppedPill(
          color: const Color(0xFFFF4D6E),
          onTap: _submitting ? null : _submit,
          child: Center(
            child: _submitting
                ? SizedBox(
                    width: 18 * s,
                    height: 18 * s,
                    child: CircularProgressIndicator(
                      strokeWidth: 2 * s,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    tr('登录并绑定'),
                    style: TextStyle(
                      fontSize: 14 * s,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ),
      ),
    );

    return SteppedListView(
      header: PageTitleHeader(_provider.displayName, showBack: true),
      itemCount: rows.length,
      itemBuilder: (context, i) => rows[i],
    );
  }

  /// 输入框行：胶囊底 + 前置圆图标 + 无边框输入框（短信字段带发送按钮）。
  Widget _fieldPill(double s, CloudLoginField f) {
    return SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: SteppedPill(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 2 * s),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrls[f.key],
                  obscureText: f.obscure,
                  autocorrect: false,
                  enableSuggestions: !f.obscure,
                  keyboardType: f.isPhone
                      ? TextInputType.phone
                      : (f.obscure
                          ? TextInputType.visiblePassword
                          : TextInputType.text),
                  style: TextStyle(fontSize: 13.5 * s),
                  decoration: InputDecoration(
                    hintText: tr(f.label),
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(
                      vertical: 8 * s,
                      horizontal: 2 * s,
                    ),
                  ),
                ),
              ),
              if (f.isSmsCode)
                TextButton(
                  onPressed:
                      (_sendingSms || _smsCooldown > 0) ? null : _sendSms,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.symmetric(horizontal: 6 * s),
                    minimumSize: Size(0, 30 * s),
                  ),
                  child: Text(
                    _smsCooldown > 0
                        ? tr('{s} 秒', {'s': '$_smsCooldown'})
                        : tr('发送验证码'),
                    style: TextStyle(
                      fontSize: 11 * s,
                      color: _smsCooldown > 0
                          ? Colors.white.withValues(alpha: 0.4)
                          : const Color(0xFFFF8FA3),
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
