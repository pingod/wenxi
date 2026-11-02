import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:pointycastle/export.dart';
import '../../core/crypto_box.dart';
import '../../core/json.dart';
import '../../core/login_crypto.dart';
import 'rule.dart';

class ParserRuleCodecs {
  static String requestContentType(String codec, Map<String, String> headers) {
    var value = codec == 'form'
        ? 'application/x-www-form-urlencoded'
        : 'application/json;charset=utf-8';
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'content-type') value = entry.value;
    }
    return value;
  }

  static String _hex(int length) => CryptoBox.random(
    length,
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  static String _md5(String value) =>
      hashes.md5.convert(utf8.encode(value)).toString();
  static Uint8List rc4(List<int> data, String key) {
    final bytes = utf8.encode(key);
    if (bytes.isEmpty) {
      throw const ParserRuleError('RULE_ALGORITHM', '解析算法参数缺失');
    }
    final state = List.generate(256, (i) => i);
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + state[i] + bytes[i % bytes.length]) & 255;
      final old = state[i];
      state[i] = state[j];
      state[j] = old;
    }
    var i = 0;
    j = 0;
    final out = Uint8List(data.length);
    for (var n = 0; n < data.length; n++) {
      i = (i + 1) & 255;
      j = (j + state[i]) & 255;
      final old = state[i];
      state[i] = state[j];
      state[j] = old;
      out[n] = data[n] ^ state[(state[i] + state[j]) & 255];
    }
    return out;
  }

  static (Json?, Map<String, String>) encode(
    String codec,
    Json? body,
    Json options,
    String device,
  ) {
    if (codec == 'json' || codec == 'form') return (body, {});
    if (body == null) throw const ParserRuleError('RULE_BODY', '解析请求体缺失');
    if (codec == 'checkrand') {
      final clean = {...body}
        ..remove('rand1')
        ..remove('rand2')
        ..remove('rand3');
      final rand = _hex(16);
      return (
        {
          ...clean,
          'rand1': hashes.sha1
              .convert(utf8.encode(jsonEncode(clean)))
              .toString(),
          'rand2': rand,
          'rand3': hashes.sha1.convert(utf8.encode(rand)).toString(),
        },
        {},
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch, nonce = _hex(6);
    if (codec == 'kdown_csrf') {
      final password = options.str('password', 'csrf');
      final text = '$now#$password#${jsonEncode(body)}#$nonce';
      var hash = 0;
      for (final byte in utf8.encode(text)) {
        hash = (hash * 31 + byte) & 0xffffffff;
      }
      if (hash >= 0x80000000) hash -= 0x100000000;
      return (
        {'data': body, 'password': password, 'timestamp': now, 'nonce': nonce},
        {'X-Sign': hash.abs().toRadixString(16)},
      );
    }
    if (codec != 'kdown_download') {
      throw const ParserRuleError('RULE_ALGORITHM', '解析规则需要新版算法');
    }
    final password = body.str('password'), csrf = options.str('csrf');
    if (password.isEmpty || csrf.isEmpty) {
      throw const ParserRuleError('interaction_required', '解析密码或会话校验缺失');
    }
    final fp = hashes.sha256
        .convert(
          utf8.encode(
            '${options.str('fingerprintSeed', 'KDown_2024_Seed')}|$device',
          ),
        )
        .toString();
    final plain = utf8.encode(jsonEncode(body)), key = utf8.encode(password);
    final encrypted = base64Encode(
      List.generate(plain.length, (i) => plain[i] ^ key[i % key.length]),
    );
    final request = <String, dynamic>{
      'encrypted': encrypted,
      'password': password,
      'timestamp': now,
      'fingerprint': fp,
      'csrf_token': csrf,
      'nonce': nonce,
      'signature': _md5('$now#$password#$encrypted#$nonce#$fp#$csrf'),
    };
    final second = now ~/ 1000;
    final extra = {
      for (final field in ['uk', 'shareid', 'surl', 'size'])
        if (body.containsKey(field)) field: body[field],
    };
    final base = {'ts': second, 'fp': fp, 'dev': device};
    final session = jsonEncode({
      ...base,
      'sk': body['sekey'] ?? '',
      'ex': extra,
    });
    final cc = utf8.encode(jsonEncode({...base, 'cc': device, 'ex': extra}));
    Uint8List? cipher;
    final blob = options.str('publicKeyBlob');
    if (blob.isNotEmpty && blob.length < 16384) {
      try {
        final pem = utf8.decode(
          rc4(
            base64Decode(blob.trim()),
            options.str('rsaBlobKey', 'a12b2c3d4e5f678901234567890abcdef'),
          ),
        );
        if (pem.trim().startsWith('-----BEGIN PUBLIC KEY-----')) {
          final key = LoginRsa(pem).key;
          final random = FortunaRandom()
            ..seed(KeyParameter(CryptoBox.random(32)));
          final rsa = OAEPEncoding.withSHA1(RSAEngine())
            ..init(
              true,
              ParametersWithRandom(
                PublicKeyParameter<RSAPublicKey>(key),
                random,
              ),
            );
          cipher = rsa.process(Uint8List.fromList(cc));
        }
      } catch (_) {
        // The public client protocol defines an RC4 header when its RSA key is unavailable.
      }
    }
    cipher ??= rc4(cc, options.str('ccKey', 'KDOWN_PUBLIC_CC_KEY_2024'));
    String envelope(List<int> value) =>
        '${base64Encode(value)}|TIMESTAMP|$second|NONCE|${_hex(4)}';
    return (
      request,
      {
        'X-Sign': _md5('$now#$password#$encrypted#$nonce'),
        'X-Session-Pub': envelope(
          rc4(
            utf8.encode(session),
            options.str('sessionKey', 'KDOWN_PUBLIC_SESSION_KEY_2024'),
          ),
        ),
        'X-CC-Pub': envelope(cipher),
      },
    );
  }

  static dynamic decode(String codec, String text) {
    if (codec == 'text') return text;
    if (codec == 'json') return jsonDecode(text);
    if (codec != 'kdown') {
      throw const ParserRuleError('RULE_ALGORITHM', '响应算法不受支持');
    }
    var plain = text.trim();
    if (plain.contains('|TIMESTAMP|')) {
      final parts = plain.split('|TIMESTAMP|');
      if (parts.length != 2 ||
          !RegExp(r'^[0-9]{10,13}$').hasMatch(parts[1]) ||
          parts[0].length < 60 ||
          plain.length > 1048576) {
        throw const ParserRuleError('RULE_RESPONSE', '解析响应格式异常');
      }
      final encoded = parts[0], timestamp = parts[1];
      final length = encoded.length - 16, first = length ~/ 4;
      final second = ((length + 8) * 3) ~/ 4;
      final hints =
          encoded.substring(first, first + 8) +
          encoded.substring(second, second + 8);
      final b64 =
          encoded.substring(0, first) +
          encoded.substring(first + 8, second) +
          encoded.substring(second + 8);
      if (!RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(b64)) {
        throw const ParserRuleError('RULE_RESPONSE', '解析响应编码异常');
      }
      final data = base64Decode(b64);
      if (data.length < 32 || data.length % 16 != 0) {
        throw const ParserRuleError('RULE_RESPONSE', '解析响应长度异常');
      }
      final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
        ..init(
          Pbkdf2Parameters(Uint8List.fromList(utf8.encode(hints)), 10000, 32),
        );
      final key = derivator.process(
        Uint8List.fromList(utf8.encode('${hints}KDown_${timestamp}_V3')),
      );
      final aes = CBCBlockCipher(AESEngine())
        ..init(false, ParametersWithIV(KeyParameter(key), data.sublist(0, 16)));
      final result = Uint8List(data.length - 16);
      for (var offset = 16; offset < data.length; offset += 16) {
        aes.processBlock(data, offset, result, offset - 16);
      }
      final pad = result.last;
      if (pad < 1 ||
          pad > 16 ||
          !result.skip(result.length - pad).every((v) => v == pad)) {
        throw const ParserRuleError('RULE_RESPONSE', '解析响应校验失败');
      }
      plain = utf8.decode(result.sublist(0, result.length - pad));
    }
    dynamic decoded = plain;
    for (var pass = 0; pass < 2 && decoded is String; pass++) {
      decoded = jsonDecode(decoded);
    }
    if (decoded is! Map) {
      throw const ParserRuleError('RULE_RESPONSE', '解析响应不是有效对象');
    }
    return decoded;
  }
}
