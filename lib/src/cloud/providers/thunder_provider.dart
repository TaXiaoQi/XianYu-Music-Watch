// 迅雷云盘 provider（网页版 pan.xunlei.com client 参数 + 账密接口）。
//
// 2026-10-16 迁移：X App 参数（thunderx + BuildCustomUserAgent 定制串）
// 与网页版用户表按 client 维度隔离（X 参数对网页版账号报 not_found(5)），
// 全量换网页版 client 参数；UA 换浏览器串（手机端同款网页通道，风控
// 形态一致）。手表无 WebView，保留账密直调（迅雷侧可能触发安全验证
// review，报错文案如实透传）。
// 域名实测：OpenList 的 xluser-ssl.xunleix.com 证书已过期，X 的 v1
// 接口已迁回老域名 xluser-ssl.xunlei.com。
// cred 额外存 deviceId/ua 供 Rust 业务构建请求头（deviceId = 32hex）。
//
// XCloud 架构（与 PikPak 同构）；业务（列目录/分享/转存/直链）经
// cloud_remote 桥转发内嵌 Rust（rust/src/cloud/thunder.rs）。

import '../cloud_http.dart';
import '../cloud_provider.dart';
import '../cloud_remote.dart';
import '../cloud_types.dart';
import 'http_login_support.dart';

class ThunderProvider extends CloudProvider {
  const ThunderProvider();

  // 网页版 client（pan.xunlei.com）：用户表按 client 维度隔离。
  static const _clientId = 'Xqp0kJBXWhwaTpB6';
  static const _clientSecret = 'Xqp0kC5LIQcyGSdKPYSzshgLKHxo';
  static const _clientVersion = '1.93.10';
  static const _xlUser = 'https://xluser-ssl.xunlei.com/v1';

  @override
  String get id => 'thunder';

  @override
  String get displayName => '迅雷云盘';

  @override
  String get rootPath => '';

  @override
  CloudLoginKind get loginKind => CloudLoginKind.httpPassword;

  @override
  Duration get directLinkTtl => const Duration(minutes: 30);

  @override
  List<CloudLoginField> get loginFields => const [
        CloudLoginField(key: 'username', label: '手机号 / 邮箱'),
        CloudLoginField(key: 'password', label: '密码', obscure: true),
      ];

  /// 基础请求头（五件套；UA 用浏览器串，与 Rust 端 BROWSER_UA 同源）。
  Map<String, String> _baseHeaders(String deviceId) => {
        'User-Agent': CloudProvider.desktopWebviewUa,
        'Accept': 'application/json;charset=UTF-8',
        'x-device-id': deviceId,
        'x-client-id': _clientId,
        'x-client-version': _clientVersion,
      };

  // 服务端错误透传：登录失败时 HTTP 非 2xx + {error, error_code,
  // error_description}。gRPC details 形态（error_description 是
  // client_id:... meta:{...} 串）按关键值映射人话，其余截断透传。
  static String _serverErrMsg(CloudHttpResponse r) {
    final code = (r.json['error_code'] ?? '').toString();
    final desc = (r.json['error_description'] ?? r.json['error'] ?? '').toString();
    if (desc.contains('result:"review"')) {
      return '触发迅雷安全验证，请稍后再试（可尝试切换网络）';
    }
    if (code == '4022' || desc.contains('invalid_account_or_password')) {
      return '账号或密码错误';
    }
    if (desc.isNotEmpty) {
      final s = desc.length > 120 ? '${desc.substring(0, 120)}…' : desc;
      return code.isEmpty ? s : '$s($code)';
    }
    return '服务异常(${r.status})';
  }

  // ── 登录 ──────────────────────────────────────────────

  @override
  Future<CloudAccount> loginWithFields(Map<String, String> fields) async {
    final username = (fields['username'] ?? '').trim();
    final password = fields['password'] ?? '';
    if (username.isEmpty || password.isEmpty) {
      throw const CloudException('请填写账号和密码');
    }
    HttpLoginGate.instance.ensureAllowed(id);
    HttpLoginGate.instance.recordAttempt(id);
    try {
      final deviceId = md5Hex('$username$password');
      final headers = _baseHeaders(deviceId);
      // 账号标识 meta 必须用 username 键：服务端 signin 校验要求
      // meta 与 username 强一致，phone_number/email 键会被服务端
      // 加 +86 等归一化导致 4002 captcha_invalid（实测）。
      // 1) captcha/init 预取验证码 token（登录期 meta 只带账号标识）。
      final init = await cloudPostJson(
        '$_xlUser/shield/captcha/init',
        body: {
          'action': 'POST:/v1/auth/signin',
          'captcha_token': '',
          'client_id': _clientId,
          'device_id': deviceId,
          'meta': {'username': username},
        },
        headers: headers,
      );
      if (!init.isOk) {
        HttpLoginGate.instance.recordFailure(id);
        throw CloudException('人机验证获取失败: ${_serverErrMsg(init)}');
      }
      final captchaToken = (init.json['captcha_token'] ?? '').toString();
      if (captchaToken.isEmpty) {
        HttpLoginGate.instance.recordFailure(id);
        // url 非空 = 需要人工验证。
        throw const CloudException('需要人机验证，请稍后再试');
      }
      // 2) auth/signin（密码明文，参考实现如此）。
      final resp = await cloudPostJson(
        '$_xlUser/auth/signin',
        body: {
          'captcha_token': captchaToken,
          'client_id': _clientId,
          'client_secret': _clientSecret,
          'username': username,
          'password': password,
        },
        headers: headers,
      );
      if (!resp.isOk) {
        HttpLoginGate.instance.recordFailure(id);
        throw CloudException(_serverErrMsg(resp));
      }
      final accessToken = (resp.json['access_token'] ?? '').toString();
      final refreshToken = (resp.json['refresh_token'] ?? '').toString();
      if (accessToken.isEmpty) {
        HttpLoginGate.instance.recordFailure(id);
        throw CloudException(
            (resp.json['error_description'] ?? resp.json['error'] ?? '账号或密码错误')
                .toString());
      }
      final userId = (resp.json['sub'] ?? resp.json['user_id'] ?? '')
          .toString();
      HttpLoginGate.instance.recordSuccess(id);
      return CloudAccount(
        provider: id,
        accountId: userId.isEmpty ? md5Hex(username).substring(0, 12) : userId,
        nickname: username,
        cred: {
          'accessToken': accessToken,
          'refreshToken': refreshToken,
          'userId': userId,
          'deviceId': deviceId,
          'ua': CloudProvider.desktopWebviewUa,
        },
        boundAt: DateTime.now(),
      );
    } on CloudException {
      rethrow;
    } catch (_) {
      HttpLoginGate.instance.recordFailure(id);
      throw const CloudException('登录失败，请稍后再试');
    }
  }

  // ── 业务（rust 桥转发）─────────────────────────────────

  @override
  Future<bool> validate(Map<String, String> cred) => rustValidate(id, cred);

  @override
  Future<CloudListResult> listDir(
    Map<String, String> cred,
    String path, {
    String? cursor,
  }) =>
      rustListDir(id, cred, path, cursor: cursor);

  @override
  Future<CloudShareParse> parseShareLink(String url, String? pwd) =>
      rustParseShare(id, url, pwd);

  @override
  Future<List<CloudFile>> transferShareFiles(
    Map<String, String> cred,
    CloudShareParse share,
  ) =>
      rustTransferShare(id, cred, share);

  @override
  Future<CloudDirectLink> getDirectLink(
          Map<String, String> cred, CloudFile file) =>
      rustDirectLink(id, cred, file);
}
