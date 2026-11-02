import 'dart:convert';
import 'dart:typed_data';
import '../http.dart';
import 'password_web_flow.dart';
import 'rule.dart';

/// A one-use, public main document fetched for a blocked Android WebView.
/// Its HTTPS URL stays the browser origin. Frames, scripts, POSTs and all
/// verification exchanges continue through the browser itself.
class ParserPasswordDocument {
  ParserPasswordDocument._(this.url, this.data, this.headers);
  final String url;
  final Uint8List data;
  final Map<String, String> headers;

  bool matches(Uri uri, {required bool mainFrame, required String method}) =>
      mainFrame && method == 'GET' && uri.toString() == url;

  static Future<ParserPasswordDocument> load(
    ParserPasswordWebFlow flow,
    JsonHttp http,
    String userAgent,
  ) async {
    RequestScope.checkpoint();
    final uri = Uri.parse(flow.url);
    if (!flow.allows(uri) || userAgent.isEmpty) {
      throw const ParserRuleError('RULE_BROWSER', '网页兼容加载参数无效');
    }
    final response = await RequestScope.cancellable(
      http.request(
        'GET',
        flow.url,
        headers: {
          'User-Agent': userAgent,
          'Accept': 'text/html,application/xhtml+xml',
          'Accept-Language': 'zh-CN,zh;q=0.9',
          'Origin': uri.origin,
        },
        followRedirects: false,
      ),
    );
    RequestScope.checkpoint();
    final values = <String, List<String>>{
      for (final entry in response.headers.entries)
        entry.key.toLowerCase(): entry.value,
    };
    final type = values['content-type']?.firstOrNull?.toLowerCase() ?? '';
    // This fallback is for a public, cookie-free HTML bootstrap only. It cannot
    // relocate a challenge session or manufacture a redirect under another URL.
    if (response.status != 200 ||
        type.split(';').first.trim() != 'text/html' ||
        values.containsKey('set-cookie') ||
        values.containsKey('cf-mitigated') ||
        RegExp(
          r'charset\s*=\s*["\x27]?(?!utf-8\b|utf8\b)[\w-]+',
        ).hasMatch(type)) {
      throw const ParserRuleError('RULE_BROWSER', '兼容加载未能打开页面，请使用浏览器打开');
    }
    final data = utf8.encode(response.body);
    if (data.length > 1048576) {
      throw const ParserRuleError('RULE_RESPONSE', '网页响应过大，请使用浏览器打开');
    }
    final headers = <String, String>{
      for (final entry in values.entries)
        if (!{
          'content-length',
          'content-encoding',
          'transfer-encoding',
          'connection',
          'keep-alive',
          'proxy-authenticate',
          'proxy-authorization',
          'te',
          'trailer',
          'upgrade',
          'content-type',
        }.contains(entry.key))
          entry.key: entry.value.join(', '),
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
    };
    return ParserPasswordDocument._(flow.url, data, headers);
  }
}
