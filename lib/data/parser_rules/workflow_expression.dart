import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as hashes;
import 'package:pointycastle/export.dart';
import '../../core/crypto_box.dart';
import '../../core/json.dart';
import '../../core/login_crypto.dart';
import 'rule.dart';

/// Portable v4 expressions. Functions are signed data, with no host-code eval.
class WorkflowExpression extends RuleExpression {
  WorkflowExpression(this.functions);
  final Json functions;
  static const extraOperations = {
    'call',
    'reduce',
    'filter',
    'get',
    'merge',
    'length',
    'isList',
    'isMap',
    'add',
    'sub',
    'mul',
    'div',
    'mod',
    'bitAnd',
    'bitOr',
    'bitXor',
    'shl',
    'shr',
    'lt',
    'le',
    'gt',
    'ge',
    'min',
    'max',
    'toRadix',
    'bytes',
    'utf8',
    'base64',
    'unbase64',
    'hex',
    'unhex',
    'urlEncode',
    'urlDecode',
    'jsonEncode',
    'jsonDecode',
    'hash',
    'hmac',
    'randomHex',
    'trim',
    'lower',
    'upper',
    'split',
    'join',
    'replace',
    'slice',
    'match',
    'aesCbc',
    'rsaEncrypt',
  };
  static Never bad([String message = '解析规则计算参数无效']) =>
      throw ParserRuleError('RULE_EXPRESSION', message);
  static BigInt integer(dynamic value) {
    final s = RuleExpression.text(value);
    if (s.length > 160 ||
        !RegExp(r'^-?(?:[0-9]+|0x[0-9a-fA-F]+)$').hasMatch(s)) {
      bad();
    }
    final n = BigInt.tryParse(s);
    if (n == null || n.abs().bitLength > 512) bad();
    return n;
  }

  static dynamic number(BigInt n) {
    if (n.abs().bitLength > 512) bad('解析规则整数超出计算范围');
    return n.abs() <= BigInt.from(9007199254740991) ? n.toInt() : n.toString();
  }

  // PHP's JSON depth 48 permits at most 47 nested arrays/objects. Check before
  // decoding so an unexpectedly deep origin response cannot exhaust the stack.
  static dynamic decodeJson(String source) {
    var nesting = 0, quoted = false, escaped = false;
    for (final unit in source.codeUnits) {
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (unit == 92) {
          escaped = true;
        } else if (unit == 34) {
          quoted = false;
        }
      } else if (unit == 34) {
        quoted = true;
      } else if (unit == 123 || unit == 91) {
        if (++nesting >= 48) {
          throw const FormatException('Workflow JSON nesting limit exceeded');
        }
      } else if (unit == 125 || unit == 93) {
        nesting--;
      }
    }
    return jsonDecode(source);
  }

  static List<int> byteList(dynamic value) {
    if (value is String) return utf8.encode(value);
    if (value is! List ||
        value.length > 65536 ||
        value.any((v) => v is! int || v < 0 || v > 255)) {
      bad();
    }
    return value.cast<int>();
  }

  static hashes.Hash digest(dynamic name) => switch (name) {
    'md5' => hashes.md5,
    'sha1' => hashes.sha1,
    'sha224' => hashes.sha224,
    'sha256' => hashes.sha256,
    'sha384' => hashes.sha384,
    'sha512' => hashes.sha512,
    _ => bad('规则使用了未支持的摘要算法'),
  };
  static String encodeComponent(String s) {
    var encoded = Uri.encodeComponent(s);
    for (final c in ["!", "'", '(', ')', '*']) {
      encoded = encoded.replaceAll(
        c,
        '%${c.codeUnitAt(0).toRadixString(16).toUpperCase()}',
      );
    }
    return encoded;
  }

  dynamic _bounded(dynamic value) {
    if (value is String && utf8.encode(value).length > 1048576 ||
        value is List && value.length > 65536 ||
        value is Map && value.length > 10000) {
      bad('解析规则中间结果过大');
    }
    return value;
  }

  @override
  dynamic eval(dynamic value, Json scope, [int depth = 0]) {
    if (value is! Map ||
        !{
          ...extraOperations,
          'and',
          'or',
          'coalesce',
        }.contains(value[r'$op'])) {
      return _bounded(super.eval(value, scope, depth));
    }
    if (--remaining < 0 || depth > 24) {
      throw const ParserRuleError('RULE_BUDGET', '解析规则计算超出限制');
    }
    final op = value[r'$op'], raw = value['args'] as List;
    dynamic at(int i) => i < raw.length ? raw[i] : null;
    dynamic evaluate(dynamic v, [Json? context]) =>
        eval(v, context ?? scope, depth + 1);
    if ({'and', 'or', 'coalesce'}.contains(op)) {
      for (final item in raw) {
        final v = evaluate(item);
        if (op == 'and' && v != true) return false;
        if (op == 'or' && v == true) return true;
        if (op == 'coalesce' && v != null && v != '') return v;
      }
      return op == 'coalesce' ? null : op == 'and';
    }
    if (op == 'call') {
      final name = evaluate(at(0));
      if (name is! String || !functions.containsKey(name)) bad('规则函数不存在');
      final args = raw.skip(1).map(evaluate).toList();
      return evaluate(functions[name], {...scope, 'args': args});
    }
    if (op == 'reduce' || op == 'filter') {
      final items = evaluate(at(0));
      if (items is! List || items.length > 65536) bad();
      dynamic acc = op == 'reduce' ? evaluate(at(1)) : null;
      final out = <dynamic>[];
      for (var i = 0; i < items.length; i++) {
        final result = evaluate(at(op == 'reduce' ? 2 : 1), {
          ...scope,
          'item': items[i],
          'index': i,
          'acc': acc,
        });
        if (op == 'reduce') {
          acc = result;
        } else if (result == true) {
          out.add(items[i]);
        }
      }
      return op == 'reduce' ? acc : out;
    }
    final args = raw.map(evaluate).toList();
    dynamic arg(int i, [dynamic fallback]) =>
        i < args.length ? args[i] : fallback;
    final a = arg(0), b = arg(1), c = arg(2);
    String text(dynamic v) => RuleExpression.text(v);
    if ({
      'add',
      'sub',
      'mul',
      'div',
      'mod',
      'bitAnd',
      'bitOr',
      'bitXor',
      'shl',
      'shr',
      'lt',
      'le',
      'gt',
      'ge',
      'min',
      'max',
      'toRadix',
    }.contains(op)) {
      final x = integer(a), y = integer(b);
      if ({'div', 'mod'}.contains(op) && y == BigInt.zero ||
          {'shl', 'shr'}.contains(op) &&
              (y < BigInt.zero || y > BigInt.from(512))) {
        bad();
      }
      if (op == 'toRadix') {
        final base = y.toInt(), width = c == null ? 0 : integer(c).toInt();
        if (base < 2 || base > 36 || width < 0 || width > 512) bad();
        return x.toRadixString(base).padLeft(width, '0');
      }
      return switch (op) {
        'lt' => x < y,
        'le' => x <= y,
        'gt' => x > y,
        'ge' => x >= y,
        'add' => number(x + y),
        'sub' => number(x - y),
        'mul' => number(x * y),
        'div' => number(x ~/ y),
        'mod' => number(x % y.abs()),
        'bitAnd' => number(x & y),
        'bitOr' => number(x | y),
        'bitXor' => number(x ^ y),
        'shl' => number(x << y.toInt()),
        'shr' => number(x >> y.toInt()),
        'min' => number(x < y ? x : y),
        'max' => number(x > y ? x : y),
        _ => bad(),
      };
    }
    dynamic result;
    switch (op) {
      case 'get':
        result = a is Map
            ? a[text(b)]
            : a is List &&
                  int.tryParse(text(b)) != null &&
                  int.parse(text(b)) >= 0
            ? a.elementAtOrNull(int.parse(text(b)))
            : null;
        result ??= c;
      case 'merge':
        final merged = <String, dynamic>{};
        for (final map in args) {
          if (map is! Map) bad();
          merged.addAll(asJson(map));
        }
        result = merged;
      case 'length':
        result = a is String
            ? a.runes.length
            : a is List || a is Map
            ? a.length
            : 0;
      case 'isList':
        result = a is List;
      case 'isMap':
        result = a is Map;
      case 'bytes':
        if (b != null && !{'utf8', 'utf16'}.contains(b)) bad();
        result = b == 'utf16' ? text(a).codeUnits : utf8.encode(text(a));
      case 'utf8':
        result = utf8.decode(byteList(a));
      case 'base64':
        result = base64Encode(byteList(a));
      case 'unbase64':
        result = base64Decode(text(a));
      case 'hex':
        result = byteList(
          a,
        ).map((v) => v.toRadixString(16).padLeft(2, '0')).join();
      case 'unhex':
        final s = text(a);
        if (s.length.isOdd ||
            s.length > 131072 ||
            !RegExp(r'^[0-9a-fA-F]*$').hasMatch(s)) {
          bad();
        }
        result = [
          for (var i = 0; i < s.length; i += 2)
            int.parse(s.substring(i, i + 2), radix: 16),
        ];
      case 'urlEncode':
        result = encodeComponent(text(a));
      case 'urlDecode':
        result = Uri.decodeComponent(text(a));
      case 'jsonEncode':
        result = jsonEncode(a);
      case 'jsonDecode':
        result = decodeJson(text(a));
      case 'hash':
        result = digest(a).convert(byteList(b)).toString();
      case 'hmac':
        result = hashes.Hmac(
          digest(a),
          byteList(c),
        ).convert(byteList(b)).toString();
      case 'aesCbc':
        final plain = byteList(b), key = byteList(c), iv = byteList(arg(3));
        if (!{'encrypt', 'decrypt'}.contains(a) ||
            !{16, 24, 32}.contains(key.length) ||
            iv.length != 16) {
          bad();
        }
        final cipher = PaddedBlockCipher('AES/CBC/PKCS7')
          ..init(
            a == 'encrypt',
            PaddedBlockCipherParameters(
              ParametersWithIV(
                KeyParameter(Uint8List.fromList(key)),
                Uint8List.fromList(iv),
              ),
              null,
            ),
          );
        result = cipher.process(Uint8List.fromList(plain)).toList();
      case 'rsaEncrypt':
        final pem = text(b);
        if (!pem.contains('-----BEGIN PUBLIC KEY-----') &&
            !pem.contains('-----BEGIN RSA PUBLIC KEY-----')) {
          bad();
        }
        result = LoginRsa(pem).encrypt(text(a));
      case 'randomHex':
        final count = integer(a).toInt();
        if (count < 1 || count > 64) bad();
        result = CryptoBox.random(
          count,
        ).map((v) => v.toRadixString(16).padLeft(2, '0')).join();
      case 'trim':
        result = text(a).trim();
      case 'lower':
        result = text(a).toLowerCase();
      case 'upper':
        result = text(a).toUpperCase();
      case 'split':
        if (text(b).isEmpty) bad();
        result = text(a).split(text(b));
      case 'join':
        if (a is! List) bad();
        result = a.map(text).join(text(b));
      case 'replace':
        if (text(b).isEmpty) bad();
        result = text(a).replaceAll(text(b), text(c));
      case 'slice':
        final values = a is List ? a : text(a).runes.toList();
        final start = integer(b).toInt().clamp(0, values.length);
        final countValue = c == null
            ? BigInt.from(values.length - start)
            : integer(c);
        if (countValue.isNegative) bad();
        final count = countValue > BigInt.from(values.length)
            ? values.length
            : countValue.toInt();
        final selected = values.sublist(
          start,
          math.min(values.length, start + count),
        );
        result = a is List
            ? selected
            : String.fromCharCodes(selected.cast<int>());
      case 'match':
        final pattern = text(b), source = text(a);
        if (pattern.length > 512 || source.length > 16384) bad();
        final match = RegExp(pattern, unicode: true).firstMatch(source);
        final group = c == null ? 0 : integer(c).toInt();
        if (group < 0 || group > 32) bad();
        result = match != null && group <= match.groupCount
            ? match.group(group) ?? ''
            : '';
      default:
        bad();
    }
    return _bounded(result);
  }
}
