import '../../diagnostics/app_log.dart';
import '../http.dart';
import 'rule.dart';

/// Identifies an edge protection page before a rule tries to decode its HTML
/// as API data. A Cloudflare response header alone is not evidence of a block.
class ParserSiteProtection {
  const ParserSiteProtection(this.code, this.cfRay);

  final String code, cfRay;
  String get message => code == 'CF_BLOCKED'
      ? '原站 Cloudflare 拦截了当前请求，请稍后重试或切换通道'
      : '原站 Cloudflare 要求网页验证，当前接口无法直接解析，请使用网页解析或切换通道';

  static String rayId(String value) =>
      RegExp(r'^[a-fA-F0-9]{16,32}(?:-[A-Z0-9]{2,8})?$').hasMatch(value.trim())
      ? value.trim()
      : '';

  static ParserSiteProtection? detect(HttpResult response) {
    String header(String name) {
      for (final entry in response.headers.entries) {
        if (entry.key.toLowerCase() == name) {
          return entry.value.firstOrNull ?? '';
        }
      }
      return '';
    }

    final body = response.body.length > 65536
        ? response.body.substring(0, 65536)
        : response.body;
    final lower = body.toLowerCase();
    final html =
        header('content-type').toLowerCase().contains('text/html') ||
        RegExp(
          r'^\s*(?:<!doctype\s+html|<html\b)',
          caseSensitive: false,
        ).hasMatch(body);
    final ray = rayId(header('cf-ray'));
    final edge =
        header('server').toLowerCase().contains('cloudflare') ||
        ray.isNotEmpty ||
        lower.contains('cf-error-details');
    if (html &&
        (edge || lower.contains('cloudflare')) &&
        RegExp(
          r'sorry,\s*you have been blocked',
          caseSensitive: false,
        ).hasMatch(body.replaceAll(RegExp(r'<[^>]*>'), ' '))) {
      return ParserSiteProtection('CF_BLOCKED', ray);
    }
    if (header('cf-mitigated').trim().toLowerCase() == 'challenge' ||
        html &&
            edge &&
            !response.successful &&
            (lower.contains('/cdn-cgi/challenge-platform/') ||
                lower.contains('_cf_chl_opt'))) {
      return ParserSiteProtection('CF_CHALLENGE', ray);
    }
    return null;
  }

  static void check(
    HttpResult response, {
    required String url,
    required String siteId,
    required String operation,
    required String step,
  }) {
    final protection = detect(response);
    if (protection == null) return;
    DiagnosticLog.event(
      'parser.upstream.protection',
      fields: {
        'siteId': siteId,
        'host': Uri.parse(url).host,
        'operation': operation,
        'step': step,
        'httpStatus': response.status,
        'code': protection.code,
        if (protection.cfRay.isNotEmpty) 'cfRay': protection.cfRay,
      },
    );
    throw ParserRuleError(protection.code, protection.message);
  }
}
