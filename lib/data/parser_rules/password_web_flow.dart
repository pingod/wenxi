import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../core/json.dart';
import 'rule.dart';

/// A signed site recipe executed only in its own, visible browser page.
class ParserPasswordWebFlow {
  ParserPasswordWebFlow._(this.json);

  final Json json;
  static const maxScriptBytes = 24000;
  String get url => json.str('url');
  List<String> get allowedHosts => List<String>.from(json['allowedHosts']);
  String get firstPassword => json.str('firstPassword');
  bool get usesUcCommand => json.str('firstPasswordSource') == 'ucCommand';
  bool get sharePassword => json.boolean('sharePassword');
  String get userAgent => json.str('userAgent');
  String get script => json.str('script');
  Duration get interval =>
      Duration(milliseconds: json.integer('pollIntervalMs'));
  Duration get timeout => Duration(seconds: json.integer('timeoutSeconds'));
  Duration get cacheDuration => Duration(seconds: json.integer('cacheSeconds'));
  String get fingerprint =>
      sha256.convert(utf8.encode(jsonEncode(json))).toString();

  factory ParserPasswordWebFlow.fromJson(Object? raw) {
    Never bad() => throw const FormatException('网页取密规则格式不正确');
    if (raw is! Map<String, dynamic> || raw['schema'] != 1) bad();
    final hosts = raw['allowedHosts'];
    if (hosts is! List ||
        hosts.isEmpty ||
        hosts.length > 8 ||
        hosts.any((host) => host is! String || !ParserRule.validHost(host)) ||
        hosts.toSet().length != hosts.length) {
      bad();
    }
    String text(String key, int limit, [String fallback = '']) {
      final value = raw[key] ?? fallback;
      if (value is! String ||
          utf8.encode(value).length > limit ||
          RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(value)) {
        bad();
      }
      return value;
    }

    int number(String key, int fallback, int min, int max) {
      final value = raw[key] ?? fallback;
      if (value is! int || value < min || value > max) bad();
      return value;
    }

    final url = text('url', 2048);
    ParserRule.endpoint(url, hosts.cast<String>());
    final script = text('script', maxScriptBytes);
    if (script.trim().isEmpty) bad();
    final ua = text('userAgent', 1024, 'default');
    final first = text('firstPassword', 512);
    final source = text('firstPasswordSource', 32, 'fixed');
    final share = raw['sharePassword'] ?? false;
    if (!{'fixed', 'ucCommand'}.contains(source) || share is! bool) bad();
    if (RegExp(r'[\r\n\t]').hasMatch(ua) ||
        RegExp(r'[\r\n\t]').hasMatch(first)) {
      bad();
    }
    return ParserPasswordWebFlow._(
      Map.unmodifiable({
        'schema': 1,
        'url': url,
        'allowedHosts': List<String>.unmodifiable(hosts.cast<String>()),
        'firstPassword': first,
        'firstPasswordSource': source,
        'sharePassword': share,
        'userAgent': ua,
        'script': script,
        'pollIntervalMs': number('pollIntervalMs', 800, 500, 5000),
        'timeoutSeconds': number('timeoutSeconds', 300, 30, 600),
        'cacheSeconds': number('cacheSeconds', 86400, 60, 86400),
      }),
    );
  }

  bool allows(Uri? uri) =>
      uri != null &&
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      allowedHosts.contains(uri.host);

  String? resolveUserAgent(String nativeAgent) {
    if (userAgent.isEmpty || userAgent == 'default') return null;
    if (userAgent != 'uc') return userAgent;
    // Android's platform, device and WebView engine must stay consistent with
    // the actual browser. Only add the marker required by this site's UC mode.
    if (RegExp(r'\bAndroid\b').hasMatch(nativeAgent)) {
      if (nativeAgent.contains('UCBrowser/')) return nativeAgent;
      final engine = RegExp(r'(?:Chrome|Chromium)/[0-9.]+');
      if (!engine.hasMatch(nativeAgent)) {
        return '$nativeAgent UCBrowser/18.10.4.1530';
      }
      return nativeAgent.replaceFirstMapped(
        engine,
        (match) => '${match[0]} UCBrowser/18.10.4.1530',
      );
    }
    final chrome = RegExp(
      r'(?:Chrome|Chromium)/([0-9.]+)',
    ).firstMatch(nativeAgent)?.group(1);
    // Preserve the installed engine's version instead of claiming a fixed one.
    if (chrome == null) return '$nativeAgent UCBrowser/18.10.4.1530';
    return 'Mozilla/5.0 (Linux; U; Android 12; zh-CN) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
        'Chrome/$chrome UCBrowser/18.10.4.1530 Mobile Safari/537.36';
  }

  String get evaluationScript => evaluation();

  String evaluation({
    String ucCommand = '',
    String ucPassword = '',
    bool ucCommandSupported = false,
  }) =>
      '''
(function () {
  if (window.top !== window || location.protocol !== 'https:' ||
      (location.port && location.port !== '443') ||
      ${jsonEncode(allowedHosts)}.indexOf(location.hostname) < 0) {
    return JSON.stringify({status: 'waiting'});
  }
  try {
    var result = (function (config) {
      'use strict';
$script
    })(Object.freeze(${jsonEncode({'firstPassword': usesUcCommand ? ucPassword : firstPassword, 'firstPasswordSource': usesUcCommand ? 'ucCommand' : 'fixed', 'ucCommand': usesUcCommand ? ucCommand : '', 'ucCommandSupported': usesUcCommand && ucCommandSupported})}));
    var encoded = JSON.stringify(result || {status: 'waiting'});
    if (encoded.length <= 4096) return encoded;
  } catch (_) {}
  return JSON.stringify({status: 'error', message: '网页取密规则执行失败，请刷新规则后重试'});
})();
''';
}

class ParserPasswordWebResult {
  const ParserPasswordWebResult(
    this.status, {
    this.password = '',
    this.message = '',
    this.command = '',
    this.code = '',
    this.cfRay = '',
  });
  final String status, password, message, command, code, cfRay;

  static bool validPassword(String value) =>
      value.trim().isNotEmpty &&
      utf8.encode(value).length <= 512 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value) &&
      !RegExp(
        r'^[\s\u2022\u00b7\u2027\u25cf\u25cb*\uff65\u30fb]+$',
      ).hasMatch(value);

  static ParserPasswordWebResult read(Object? raw) {
    if (raw == null) return const ParserPasswordWebResult('waiting');
    try {
      if (raw is String) {
        if (raw.length > 4096) throw const FormatException();
        raw = jsonDecode(raw);
      }
      if (raw is! Map ||
          !{
            'waiting',
            'success',
            'error',
            'ucPassword',
          }.contains(raw['status'])) {
        throw const FormatException();
      }
      final password = raw['password'], message = raw['message'];
      final command = raw['command'];
      final blocked = raw['status'] == 'error' && raw['code'] == 'CF_BLOCKED';
      final ray = raw['cfRay'];
      if (raw['status'] == 'ucPassword' &&
          (command is! String ||
              command.trim().isEmpty ||
              command.length > 2000 ||
              RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(command))) {
        throw const FormatException();
      }
      if (raw['status'] == 'success' &&
          (password is! String || !validPassword(password))) {
        // Masked text and empty placeholders are not completed results.
        return const ParserPasswordWebResult('waiting', message: '正在等待网页提供密码…');
      }
      return ParserPasswordWebResult(
        raw['status'] as String,
        password: raw['status'] == 'success' ? password as String : '',
        command: raw['status'] == 'ucPassword' ? command as String : '',
        code: blocked ? 'CF_BLOCKED' : '',
        cfRay:
            blocked &&
                ray is String &&
                RegExp(r'^[a-fA-F0-9]{16,32}(?:-[A-Z0-9]{2,8})?$').hasMatch(ray)
            ? ray
            : '',
        message:
            message is String &&
                message.runes.length <= 200 &&
                !RegExp(r'[\x00-\x1f\x7f]').hasMatch(message)
            ? message
            : '',
      );
    } catch (_) {
      return const ParserPasswordWebResult(
        'error',
        message: '网页取密结果格式异常，请刷新规则后重试',
      );
    }
  }
}
