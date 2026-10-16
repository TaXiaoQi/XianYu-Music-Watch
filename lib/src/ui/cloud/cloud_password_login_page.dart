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

/// 账密登录页（httpPassword 范式，与移动端 cloud_password_login_page
/// 同构）。
///
/// 表单按 provider.loginFields 动态渲染；命中风控（要求设备短信
/// 二次校验）时弹窗收码续登。
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
    } on CloudSmsRequiredException catch (e) {
      // 风控要求设备短信二次校验：provider 已自动发码，弹窗收码续登。
      if (!mounted) return;
      setState(() => _submitting = false);
      await _promptSmsCode(e.username);
    } catch (e) {
      AppLog.warn('cloud', '${_provider.id} 账密登录失败: $e');
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e is CloudException ? e.message : tr('登录失败，请重试');
      });
    }
  }

  /// 验证码输入弹窗，确认后提交设备二次校验完成绑定。
  Future<void> _promptSmsCode(String username) async {
    final s = context.watchScale();
    final codeCtrl = TextEditingController();
    String? code;
    try {
      code = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF232326),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16 * s),
          ),
          title: Text(
            tr('输入短信验证码'),
            style: TextStyle(fontSize: 14 * s, fontWeight: FontWeight.w700),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('检测到新设备登录，验证码已发送至 {username}',
                    {'username': username}),
                style: TextStyle(
                  fontSize: 11.5 * s,
                  height: 1.4,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
              SizedBox(height: 10 * s),
              TextField(
                controller: codeCtrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                style: TextStyle(fontSize: 14 * s, letterSpacing: 2 * s),
                decoration: InputDecoration(
                  hintText: tr('短信验证码'),
                  counterText: '',
                  isDense: true,
                  focusedBorder: const UnderlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFFFF4D6E)),
                  ),
                ),
                onSubmitted: (v) => Navigator.of(ctx).pop(v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(
                tr('取消'),
                style: TextStyle(
                  fontSize: 12 * s,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(codeCtrl.text.trim()),
              child: Text(
                tr('确定'),
                style: TextStyle(
                  fontSize: 12 * s,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFFFF4D6E),
                ),
              ),
            ),
          ],
        ),
      );
    } finally {
      codeCtrl.dispose();
    }
    if (code == null || code.isEmpty || !mounted) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final account = await _provider.submitSmsCode(username, code);
      await CloudCredentialsStore.instance.saveAccount(account);
      if (!mounted) return;
      _toast(tr('绑定成功'));
      Navigator.of(context).pop();
    } catch (e) {
      AppLog.warn('cloud', '${_provider.id} 验证码校验失败: $e');
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

  /// 输入框行：胶囊底 + 无边框输入框。
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
            ],
          ),
        ),
      ),
    );
  }
}
