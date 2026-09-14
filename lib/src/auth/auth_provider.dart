import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/db_path.dart';
import '../rust/api.dart' as rust;

/// 账号 API 默认基地址与签名密钥（与移动端一致，Rust 侧签名请求）。
const defaultAuthBaseUrl = 'https://api.xianyumusic.cn/api';
const defaultAuthApiSecret =
    'bf027fedb4d1b4f969c10495f12f17042bf0de02de128200';

/// 已登录用户信息（服务端 user 对象的腕上子集）。
class AuthUser {
  final String id;
  final String username;
  final String nickname;
  final String email;
  final String? avatar;
  final String? ciyuanxiId;
  final String role;

  const AuthUser({
    required this.id,
    required this.username,
    required this.nickname,
    required this.email,
    this.avatar,
    this.ciyuanxiId,
    required this.role,
  });

  factory AuthUser.fromJson(Map<String, dynamic> j) => AuthUser(
        id: (j['id'] ?? '').toString(),
        username: (j['username'] ?? '').toString(),
        nickname: (j['nickname'] ?? '').toString(),
        email: (j['email'] ?? '').toString(),
        avatar: j['avatar']?.toString(),
        ciyuanxiId: j['ciyuanxi_id']?.toString() ?? j['ciyuanxiId']?.toString(),
        role: (j['role'] ?? 'user').toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'nickname': nickname,
        'email': email,
        'avatar': avatar,
        'ciyuanxi_id': ciyuanxiId,
        'role': role,
      };
}

/// 账号状态。
class AuthState {
  final AuthUser? user;
  final bool loading;
  final String? error;

  /// 服务端标记登录态失效（清理后引导重新登录）。
  final bool sessionExpired;

  const AuthState({
    this.user,
    this.loading = false,
    this.error,
    this.sessionExpired = false,
  });

  bool get isLoggedIn => user != null;

  AuthState copyWith({
    AuthUser? user,
    bool? loading,
    String? error,
    bool clearError = false,
    bool? sessionExpired,
  }) =>
      AuthState(
        user: user ?? this.user,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        sessionExpired: sessionExpired ?? this.sessionExpired,
      );
}

class AuthException implements Exception {
  final String message;
  /// 服务端业务码（200 之外的失败码），0 表示非 HTTP 业务错误
  /// （本地构造/网络异常）。供扫码轮询区分「服务端明确判死」与瞬时故障。
  final int code;
  AuthException(this.message, {this.code = 0});
  @override
  String toString() => message;
}

/// 人机验证题目（服务端内置算术题，与移动端/桌面端 get_captcha 一致）。
class HumanCaptcha {
  final String captchaId;
  final String question;
  const HumanCaptcha({required this.captchaId, required this.question});

  factory HumanCaptcha.fromJson(Map<String, dynamic> j) => HumanCaptcha(
        captchaId: (j['captcha_id'] ?? '').toString(),
        question: (j['question'] ?? '').toString(),
      );
}

/// 人机验证配置（服务端下发，与移动端 email_get_captcha_config 一致）。
class HumanCaptchaConfig {
  final bool enabled;

  /// 'off' / 'turnstile' / 'hcaptcha'。
  final String provider;
  final String siteKey;
  const HumanCaptchaConfig({
    this.enabled = false,
    this.provider = 'off',
    this.siteKey = '',
  });

  /// 第三方验证组件（Turnstile/hCaptcha）是否启用。
  /// 启用时腕上端无法渲染 WebView 组件，引导走扫码登录。
  bool get isProviderEnabled => enabled && siteKey.isNotEmpty && provider != 'off';
}

/// 人机验证结果载荷（算术题：id+答案；第三方：token）。
class HumanCaptchaPayload {
  final String captchaId;
  final String captchaAnswer;
  final String providerToken;
  final String provider;
  const HumanCaptchaPayload({
    this.captchaId = '',
    this.captchaAnswer = '',
    this.providerToken = '',
    this.provider = '',
  });

  bool get isProviderToken => providerToken.isNotEmpty;

  /// 并入登录请求体的 captcha 字段（与桌面端 withCaptcha 一致）。
  Map<String, dynamic> toBodyFields() => isProviderToken
      ? {
          'captcha_token': providerToken,
          'turnstile_token': providerToken,
          'captcha_provider': provider,
        }
      : {
          'captcha_id': captchaId,
          'captcha_answer': captchaAnswer,
        };
}

/// 腕上精简账号控制器：弦予号密码登录 / 凭证持久化（Rust auth 目录）/
/// 通用带签名请求（后续云同步预留）。验证码/注册/资料编辑等重交互仍在手机端。
class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier(this._ref) : super(const AuthState());

  /// 人机验证配置缓存（配置, 获取时间），10 分钟有效期，对齐移动端。
  static (HumanCaptchaConfig, DateTime)? _captchaConfigCache;

  final Ref _ref;
  final Random _rand = Random();
  String? _token;

  AuthState get currentState => state;

  Future<String> _dataDir() => _ref.read(appDataDirProvider.future);

  Future<String> _deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('deviceId');
    if (id == null || id.isEmpty) {
      final sb = StringBuffer();
      for (var i = 0; i < 16; i++) {
        sb.write('0123456789abcdef'[_rand.nextInt(16)]);
      }
      id = sb.toString();
      await prefs.setString('deviceId', id);
    }
    return id;
  }

  /// 启动时配置基地址/密钥并加载已存凭证。
  Future<void> init() async {
    try {
      final dir = await _dataDir();
      await rust.authSetBaseUrl(dataDir: dir, baseUrl: defaultAuthBaseUrl);
      await rust.authSetApiSecret(dataDir: dir, apiSecret: defaultAuthApiSecret);
      final credsJson = await rust.authGetCredentials(dataDir: dir);
      if (credsJson.trim().isNotEmpty && credsJson != 'null') {
        final j = jsonDecode(credsJson) as Map<String, dynamic>;
        _token = (j['token'] as String?) ?? '';
        final userJson = j['user'];
        if (userJson is Map<String, dynamic>) {
          state = AuthState(user: AuthUser.fromJson(userJson));
        }
      }
    } catch (_) {
      // 无凭证或初始化失败，保持未登录。
    }
  }

  /// 发送带签名的账号请求，校验 code===200 并返回 data。
  Future<Map<String, dynamic>> requestAction(
      String action, Map<String, dynamic> body) async {
    final dir = await _dataDir();
    final finalBody = Map<String, dynamic>.from(body);
    final token = _token;
    if (token != null && token.isNotEmpty && !finalBody.containsKey('token')) {
      finalBody['token'] = token;
    }
    final res = await rust.authAuthedRequest(
      dataDir: dir,
      action: action,
      bodyJson: jsonEncode(finalBody),
    );
    final j = jsonDecode(res) as Map<String, dynamic>;
    final code = (j['code'] as num?)?.toInt() ?? -1;
    final msg = (j['msg'] as String?) ?? '';
    if (code == 401 &&
        const ['登录状态已失效', '登录已过期', '登录状态与账号不匹配'].any(msg.contains)) {
      await _clearLocalAuth();
      state = const AuthState(sessionExpired: true);
    }
    if (code != 200) {
      throw AuthException(
        msg.isNotEmpty ? msg : '请求失败（code $code）',
        code: code,
      );
    }
    return (j['data'] as Map<String, dynamic>?) ?? const {};
  }

  /// 服务端 user 字段 → [AuthUser]（兼容 user_id/id、avatar_url/avatar 双命名，
  /// 扫码轮询与登录返回体共用）。
  static AuthUser mapUser(Map<String, dynamic> j) => AuthUser(
        id: (j['user_id'] ?? j['id'] ?? '').toString(),
        username: (j['username'] ?? '').toString(),
        nickname: ((j['nickname'] ?? '') as String).isNotEmpty
            ? (j['nickname'] ?? '').toString()
            : (j['username'] ?? '').toString(),
        email: (j['email'] ?? '').toString(),
        avatar: (j['avatar_url'] ?? j['avatar'])?.toString(),
        ciyuanxiId: j['ciyuanxi_id']?.toString() ?? j['ciyuanxiId']?.toString(),
        role: (j['role'] ?? 'user').toString(),
      );

  /// 弦予号 + 密码登录（成功即持久化凭证并更新状态）。
  /// 服务端开启人机验证时必须携带 [captcha]（算术题答案或第三方 token）。
  Future<void> login({
    required String ciyuanxiId,
    required String password,
    HumanCaptchaPayload? captcha,
  }) async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final data = await requestAction('user_login', {
        'ciyuanxi_id': ciyuanxiId.trim(),
        'password': password,
        'device_id': await _deviceId(),
        if (captcha != null) ...captcha.toBodyFields(),
      });
      final token = data['token'];
      if (token == null || token.toString().isEmpty) {
        throw AuthException('登录响应无效');
      }
      _token = token.toString();
      final user = AuthNotifier.mapUser(
        (data['user'] as Map<String, dynamic>?) ?? data,
      );
      state = AuthState(user: user);
      await _persist(token.toString(), user);
    } on AuthException catch (e) {
      state = state.copyWith(loading: false, error: e.message);
    } catch (e) {
      state = state.copyWith(loading: false, error: '登录失败：$e');
    }
  }

  /// 表单侧本地校验错误（不触发 loading，与登录请求错误共用 error 槽）。
  void setFormError(String msg) {
    state = state.copyWith(error: msg);
  }

  /// 获取一次性人机验证题（算术题，purpose=auth）。
  Future<HumanCaptcha> fetchCaptcha() async {
    final data = await requestAction('get_captcha', {'purpose': 'auth'});
    return HumanCaptcha.fromJson(data);
  }

  /// 获取服务端人机验证配置（10 分钟缓存，对齐移动端）。
  /// 失败时保留旧缓存（若有），避免网络抖动误降级为算术题。
  Future<HumanCaptchaConfig> fetchCaptchaConfig() async {
    final cached = _captchaConfigCache;
    if (cached != null &&
        DateTime.now().difference(cached.$2) < const Duration(minutes: 10)) {
      return cached.$1;
    }
    try {
      final data = await requestAction('email_get_captcha_config', {});
      final cfg = HumanCaptchaConfig(
        enabled: (data['enabled'] == true) &&
            (data['site_key'] ?? '').toString().isNotEmpty,
        provider: (data['provider'] ?? 'off').toString(),
        siteKey: (data['site_key'] ?? '').toString(),
      );
      _captchaConfigCache = (cfg, DateTime.now());
      return cfg;
    } catch (_) {
      if (cached != null) return cached.$1;
      return const HumanCaptchaConfig();
    }
  }

  /// 预校验算术题答案（不消费验证码，真实登录时服务端再校验）。
  /// 第三方 token 模式跳过（服务端在登录请求中直验）。
  Future<void> verifyCaptcha(HumanCaptchaPayload payload) async {
    if (payload.isProviderToken) return;
    await requestAction('verify_captcha', {
      'purpose': 'auth',
      'captcha_id': payload.captchaId,
      'captcha_answer': payload.captchaAnswer,
    });
  }

  Future<void> _persist(String token, AuthUser user) async {
    final dir = await _dataDir();
    await rust.authSaveCredentials(
      dataDir: dir,
      token: token,
      userJson: jsonEncode(user.toJson()),
    );
  }

  /// 扫码登录（桌面端同款）：生成二维码内容。免签接口 generate_tv_login_code。
  /// 返回 (code, expireSeconds)；location 尽力而为取 IP 归属地，失败回退「手表」。
  Future<(String, int)> createQrLogin() async {
    final location = await _ipLocation();
    final data = await requestAction('generate_tv_login_code', {
      'device_id': await _deviceId(),
      'location': location,
    });
    final code = (data['code'] ?? '').toString();
    if (code.isEmpty) throw AuthException('二维码内容为空');
    final expire = (data['expire_seconds'] as num?)?.toInt() ?? 300;
    return (code, expire);
  }

  /// 轮询扫码状态：pending / scanned / logged_in（收尾登录态）/ invalid。
  /// 返回登录后的用户（成功时），其余情况返回 null；[outStatus] 供 UI 展示。
  Future<AuthUser?> pollQrLogin({
    required String code,
    void Function(String status)? onStatus,
  }) async {
    try {
      final data = await requestAction('poll_tv_login_status', {
        'code': code,
        'device_id': await _deviceId(),
      });
      final status = (data['status'] ?? 'pending').toString();
      onStatus?.call(status);
      if (status == 'logged_in') {
        final token = (data['token'] ?? '').toString();
        if (token.isEmpty) throw AuthException('登录响应无效');
        _token = token;
        final user = AuthNotifier.mapUser(data);
        state = AuthState(user: user);
        await _persist(token, user);
        return user;
      }
    } on AuthException catch (e) {
      // 对齐桌面端语义：仅服务端明确判死（404 二维码无效/设备不匹配、
      // 403 账号禁用）才结束轮询；限流 429、5xx、网络抖动均为瞬时故障，
      // 保持 pending 由下个周期重试，避免误报「二维码已过期」。
      if (e.code == 404 || e.code == 403) {
        onStatus?.call('invalid');
      }
    } catch (_) {
      // 网络抖动：视为继续 pending。
    }
    return null;
  }

  /// IP 归属地（供手机确认页展示「被扫码设备位置」），2.5s 超时回退。
  Future<String> _ipLocation() async {
    try {
      final res = await HttpClient()
          .getUrl(Uri.parse('https://ipapi.co/json/'))
          .then((r) => r.close())
          .timeout(const Duration(milliseconds: 2500));
      if (res.statusCode == 200) {
        final body = await res.transform(utf8.decoder).join();
        final j = jsonDecode(body) as Map<String, dynamic>;
        final parts = [
          j['city'],
          j['region'],
          j['country_name'],
        ].whereType<String>().where((s) => s.isNotEmpty).toList();
        if (parts.isNotEmpty) return parts.join(' ');
      }
    } catch (_) {}
    return '手表';
  }

  /// 退出登录：清本地凭证 + Rust auth 目录凭证。
  Future<void> logout() async {
    await _clearLocalAuth();
    state = const AuthState();
  }

  /// UI 展示完会话失效弹窗后调用。
  void consumeSessionExpired() {
    if (state.sessionExpired) state = const AuthState();
  }

  Future<void> _clearLocalAuth() async {
    _token = null;
    try {
      await rust.authClearCredentials(dataDir: await _dataDir());
    } catch (_) {}
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (ref) => AuthNotifier(ref),
);
