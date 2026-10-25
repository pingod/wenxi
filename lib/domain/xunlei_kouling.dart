import '../core/json.dart';

/// Request and response helpers for Xunlei share commands.
class XunleiKouling {
  static const jumpApi =
      'https://api-shoulei-ssl.xunlei.com/xlppc.searcher.api/jump';
  static const origin = 'https://sl-m-ssl.xunlei.com';
  static const referer = '$origin/';
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/108.0.5359.215 Safari/537.36 '
      'TBC/1.3.3.999 Thunder/12.4.4.3740';
  static const _decorations = '「」『』【】《》〈〉“”‘’"\'`()（）[]{}<>.,，。;；:：!！?？、|';
  static final _shareId = RegExp(
    r'https?://pan\.xunlei\.com/s/([A-Za-z0-9_-]+)',
    caseSensitive: false,
  );
  static final _password = RegExp(
    r'[?&]pwd=([A-Za-z0-9]+)',
    caseSensitive: false,
  );

  static String normalize(String value) {
    var normalized = value.trim();
    while (normalized.isNotEmpty && _decorations.contains(normalized[0])) {
      normalized = normalized.substring(1).trimLeft();
    }
    while (normalized.isNotEmpty &&
        _decorations.contains(normalized[normalized.length - 1])) {
      normalized = normalized.substring(0, normalized.length - 1).trimRight();
    }
    return normalized;
  }

  static String jumpUrl(String keyword) {
    final encoded = Uri.encodeQueryComponent(keyword);
    return '$jumpApi?noredirect=1&t=20&wd=$encoded&tn=15007414_5_dg'
        '&src=lm&ls=sm3016480&lm_extend=ctype:31';
  }

  static String? shareUrlFromLocation(String? location) {
    final value = location?.trim();
    if (value == null || value.isEmpty) return null;
    final id = _shareId.firstMatch(value)?[1];
    if (id == null) return null;
    final password = _password.firstMatch(value)?[1];
    return Uri(
      scheme: 'https',
      host: 'pan.xunlei.com',
      path: '/s/$id',
      queryParameters: password == null ? null : {'pwd': password},
    ).toString();
  }

  static String? shareUrlFromResponse(int status, Json json) {
    if (status < 200 || status >= 300) {
      throw AppException('迅雷口令解析失败（HTTP $status）');
    }
    final type = json.obj('ext').str('kouling_type');
    final url = shareUrlFromLocation(json.str('location'));
    if (type != 'share_page' || url == null) {
      throw const AppException('该迅雷口令没有对应的网盘分享');
    }
    return url;
  }
}
