import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/db_path.dart';
import '../rust/api.dart' as rust;

const defaultAuthBaseUrl = 'https://api.xianyumusic.cn/api';
const defaultAuthApiSecret = 'bf027fedb4d1b4f969c10495f12f17042bf0de02de128200';

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

class AuthState {
  final AuthUser? user;
  final bool loading;
  final String? error;

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
  }) => AuthState(
    user: user ?? this.user,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
    sessionExpired: sessionExpired ?? this.sessionExpired,
  );
}

class AuthException implements Exception {
  final String message;
  final int code;
  AuthException(this.message, {this.code = 0});
  @override
  String toString() => message;
}

class HumanCaptcha {
  final String captchaId;
  final String question;
  const HumanCaptcha({required this.captchaId, required this.question});

  factory HumanCaptcha.fromJson(Map<String, dynamic> j) => HumanCaptcha(
    captchaId: (j['captcha_id'] ?? '').toString(),
    question: (j['question'] ?? '').toString(),
  );
}

class HumanCaptchaConfig {
  final bool enabled;

  final String provider;
  final String siteKey;
  const HumanCaptchaConfig({
    this.enabled = false,
    this.provider = 'off',
    this.siteKey = '',
  });

  bool get isProviderEnabled =>
      enabled && siteKey.isNotEmpty && provider != 'off';
}

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

  Map<String, dynamic> toBodyFields() => isProviderToken
      ? {
          'captcha_token': providerToken,
          'turnstile_token': providerToken,
          'captcha_provider': provider,
        }
      : {'captcha_id': captchaId, 'captcha_answer': captchaAnswer};
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier(this._ref) : super(const AuthState());

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

  Future<void> init() async {
    try {
      final dir = await _dataDir();
      await rust.authSetBaseUrl(dataDir: dir, baseUrl: defaultAuthBaseUrl);
      await rust.authSetApiSecret(
        dataDir: dir,
        apiSecret: defaultAuthApiSecret,
      );
      final credsJson = await rust.authGetCredentials(dataDir: dir);
      if (credsJson.trim().isNotEmpty && credsJson != 'null') {
        final j = jsonDecode(credsJson) as Map<String, dynamic>;
        _token = (j['token'] as String?) ?? '';
        final userJson = j['user'];
        if (userJson is Map<String, dynamic>) {
          state = AuthState(user: AuthUser.fromJson(userJson));
        }
      }
    } catch (_) {}
  }

  Future<Map<String, dynamic>> requestAction(
    String action,
    Map<String, dynamic> body,
  ) async {
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

  static AuthUser mapUser(Map<String, dynamic> j) {
    final nickname = (j['nickname'] ?? '').toString();
    return AuthUser(
      id: (j['user_id'] ?? j['id'] ?? '').toString(),
      username: (j['username'] ?? '').toString(),
      nickname: nickname.isNotEmpty
          ? nickname
          : (j['username'] ?? '').toString(),
      email: (j['email'] ?? '').toString(),
      avatar: (j['avatar_url'] ?? j['avatar'])?.toString(),
      ciyuanxiId: j['ciyuanxi_id']?.toString() ?? j['ciyuanxiId']?.toString(),
      role: (j['role'] ?? 'user').toString(),
    );
  }

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

  void setFormError(String msg) {
    state = state.copyWith(error: msg);
  }

  Future<HumanCaptcha> fetchCaptcha() async {
    final data = await requestAction('get_captcha', {'purpose': 'auth'});
    return HumanCaptcha.fromJson(data);
  }

  Future<HumanCaptchaConfig> fetchCaptchaConfig() async {
    final cached = _captchaConfigCache;
    if (cached != null &&
        DateTime.now().difference(cached.$2) < const Duration(minutes: 10)) {
      return cached.$1;
    }
    try {
      final data = await requestAction('email_get_captcha_config', {});
      final cfg = HumanCaptchaConfig(
        enabled:
            (data['enabled'] == true) &&
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
      if (e.code == 404 || e.code == 403) {
        onStatus?.call('invalid');
      }
    } catch (_) {}
    return null;
  }

  Future<String> _ipLocation() async {
    final client = HttpClient();
    try {
      final res = await client
          .getUrl(Uri.parse('https://ipapi.co/json/'))
          .then((r) => r.close())
          .timeout(const Duration(milliseconds: 2500));
      if (res.statusCode == 200) {
        final body = await res
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(milliseconds: 2500));
        final j = jsonDecode(body) as Map<String, dynamic>;
        final parts = [
          j['city'],
          j['region'],
          j['country_name'],
        ].whereType<String>().where((s) => s.isNotEmpty).toList();
        if (parts.isNotEmpty) return parts.join(' ');
      }
    } catch (_) {
    } finally {
      client.close(force: true);
    }
    return '手表';
  }

  Future<void> logout() async {
    await _clearLocalAuth();
    state = const AuthState();
  }

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
