import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

import '../core/application_logger.dart';

abstract class PluginUserVarCrypto {
  static List<int> _key(String ciyuanxiId) =>
      sha256.convert(utf8.encode(ciyuanxiId)).bytes;

  static Map<String, dynamic>? encrypt(
      String ciyuanxiId, Map<String, String> values) {
    try {
      final key = enc.Key(Uint8List.fromList(_key(ciyuanxiId)));
      final iv = enc.IV.fromSecureRandom(16);
      final encrypter =
          enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));
      final ct = encrypter.encrypt(jsonEncode(values), iv: iv);
      return {'iv': iv.base64, 'data': ct.base64};
    } catch (e) {
      AppLog.warn('plugin', '加密用户变量失败: $e');
      return null;
    }
  }

  static Map<String, String>? decrypt(
      String ciyuanxiId, Map<String, dynamic>? block) {
    if (block == null) return null;
    try {
      final ivB64 = block['iv'] as String?;
      final dataB64 = block['data'] as String?;
      if (ivB64 == null || dataB64 == null) return null;
      final key = enc.Key(Uint8List.fromList(_key(ciyuanxiId)));
      final iv = enc.IV.fromBase64(ivB64);
      final encrypter =
          enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));
      final pt = encrypter.decrypt(enc.Encrypted.fromBase64(dataB64), iv: iv);
      final json = jsonDecode(pt);
      if (json is Map) {
        return json.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
      }
    } catch (_) {
      // 解析兜底：密钥不匹配或数据损坏时按无变量处理
    }
    return null;
  }
}