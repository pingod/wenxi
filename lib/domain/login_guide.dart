import 'dart:convert';

import 'auth.dart';
import 'models.dart';
import 'web_tokens.dart';

/// Where a platform keeps the credentials the manual login page accepts.
enum LoginCredentialSource {
  /// Session cookies, copied from the browser's DevTools.
  cookie,

  /// A JSON value kept in the site's Local Storage.
  storage,

  /// A single token string (session token, personal access token, authorToken).
  token,
}

/// Instructions for logging in with the system browser on a platform that has
/// no embedded web view.
///
/// The manual page opens [url] in the system browser and tells the user exactly
/// where the browser keeps the credential. [extract] then turns whatever the
/// user copied back into the value the existing login flow already validates,
/// so the cookie and token rules stay in one place ([LoginCredentials]).
class LoginGuide {
  const LoginGuide(
    this.platform, {
    required this.url,
    required this.source,
    this.storageKey = '',
  });

  final CloudPlatform platform;
  final String url;
  final LoginCredentialSource source;

  /// Local Storage key that holds the credential, when the site keeps one.
  final String storageKey;

  String get title => '在浏览器里登录${platform.shortName}';

  List<String> get steps {
    final name = platform.shortName;
    if (platform == CloudPlatform.github) {
      return const [
        '点击「打开令牌页面」在浏览器中打开 GitHub 设置',
        '创建个人访问令牌，勾选 repo（或按需勾选 Contents 读写权限）',
        '复制生成的令牌，回到本页粘贴到下方输入框',
      ];
    }
    if (platform == CloudPlatform.ctfile) {
      return const [
        '点击「打开官网」，在浏览器中登录城通网盘',
        '进入「开放接口登录密钥管理」页面',
        '复制其中的 Session Token，回到本页粘贴到下方输入框',
      ];
    }
    switch (source) {
      case LoginCredentialSource.cookie:
        return [
          '点击「打开官网」，在系统浏览器里登录$name',
          '登录后按 F12 打开开发者工具，切换到 Application（应用）→ Cookies，选中该网站',
          '在表格中按 Ctrl+A 全选后 Ctrl+C；也可以在 Network 面板复制任意请求里的 Cookie 请求头',
          '回到本页，凭据会出现在剪贴板提示里，点击「填入」再「验证并保存」',
        ];
      case LoginCredentialSource.storage:
        return [
          '点击「打开官网」，在系统浏览器里登录$name',
          '登录后按 F12 → Application（应用）→ Local Storage，选中该网站',
          '找到 $storageKey，复制它的值（一整段 JSON）',
          '回到本页，凭据会出现在剪贴板提示里，点击「填入」再「验证并保存」',
        ];
      case LoginCredentialSource.token:
        return [
          '点击「打开官网」，在系统浏览器里登录$name',
          '登录后按 F12 → Application（应用）→ Local Storage，选中该网站',
          '复制 $storageKey 的值（令牌字符串）',
          '回到本页，凭据会出现在剪贴板提示里，点击「填入」再「验证并保存」',
        ];
    }
  }

  /// The guide for [platform], or null when the platform is not reachable from
  /// a browser at all.
  static LoginGuide? forPlatform(CloudPlatform platform) {
    if (platform == CloudPlatform.github) {
      return const LoginGuide(
        CloudPlatform.github,
        url: 'https://github.com/settings/tokens',
        source: LoginCredentialSource.token,
      );
    }
    // 城通 keeps the session token behind its own key management page rather
    // than in a cookie or the site's storage.
    if (platform == CloudPlatform.ctfile) {
      return const LoginGuide(
        CloudPlatform.ctfile,
        url: 'https://www.ctfile.com/',
        source: LoginCredentialSource.token,
      );
    }
    final target = WebLoginTarget.targets[platform];
    if (target == null) return null;
    final source = platform == CloudPlatform.pan123
        ? LoginCredentialSource.token
        : WebTokens.supports(platform)
        ? LoginCredentialSource.storage
        : LoginCredentialSource.cookie;
    return LoginGuide(
      platform,
      url: target.url,
      source: source,
      storageKey: target.localStorageKey ?? '',
    );
  }

  /// The credential in [text], normalised the same way manual entry normalises
  /// input, or null when nothing in the text passes the platform's rules.
  ///
  /// Clipboard contents are whatever the user happened to copy, so every
  /// candidate is validated by [LoginCredentials.normalize] instead of being
  /// trusted as-is.
  static String? extract(CloudPlatform platform, String? text) {
    if (text == null) return null;
    final value = text.trim();
    // Refuse oversized or empty clipboard data before parsing it.
    if (value.isEmpty || value.length > 64 * 1024) return null;
    for (final candidate in candidates(value, platform)) {
      try {
        return LoginCredentials.normalize(platform, candidate);
      } on Object {
        // Not this candidate; try the next shape.
      }
    }
    return null;
  }

  /// Candidate credential strings inside [text], most specific first.
  ///
  /// The whole text is tried last so a loose platform rule (123 网盘 accepts any
  /// non-empty string) cannot pick up surrounding prose from the clipboard.
  static Iterable<String> candidates(
    String text,
    CloudPlatform platform,
  ) sync* {
    final seen = <String>{};
    Iterable<String> unique(Iterable<String> values) sync* {
      for (final raw in values) {
        final value = raw.trim();
        if (value.isEmpty || value.length > 64 * 1024) continue;
        if (!_shapeOk(platform, value)) continue;
        if (seen.add(value)) yield value;
      }
    }

    // A Local Storage value copied with its surrounding JSON quotes.
    if (text.length > 2 && text.startsWith('"') && text.endsWith('"')) {
      yield* unique([_unquote(text)]);
    }

    // A JSON object copied together with the row it sat in.
    final start = text.indexOf('{'), end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      yield* unique([text.substring(start, end + 1)]);
    }

    // DevTools "Cookie" table rows: name, value, domain, path, ...
    final rows = _tableCookie(text);
    if (rows != null) yield* unique([rows]);

    yield* unique([
      text.replaceFirst(RegExp(r'^cookie\s*:', caseSensitive: false), ''),
    ]);

    // One header line from a captured request, or the token on its own line.
    yield* unique(
      const LineSplitter()
          .convert(text)
          .reversed
          .map(
            (line) => line.replaceFirst(
              RegExp(r'^\s*cookie\s*:', caseSensitive: false),
              '',
            ),
          ),
    );

    yield* unique([text]);
  }

  /// Reject candidate shapes the platform's own rule would wave through but
  /// that cannot be a real credential, such as multi-line prose.
  static bool _shapeOk(CloudPlatform platform, String value) {
    if (RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(value)) {
      return false;
    }
    if (platform == CloudPlatform.pan123) {
      return value.length >= 16 && !value.contains(RegExp(r'[\s]'));
    }
    return true;
  }

  static String _unquote(String value) {
    try {
      final decoded = jsonDecode(value);
      return decoded is String ? decoded : value;
    } on Object {
      return value.substring(1, value.length - 1);
    }
  }

  static const _tableHeadings = {'name', 'value', 'domain', 'path', '名称', '值'};

  /// Rebuild a Cookie header from tab separated rows copied out of the
  /// DevTools cookie table. Requires at least two well formed rows so a stray
  /// tab in ordinary text cannot be mistaken for credentials.
  static String? _tableCookie(String text) {
    final pairs = <String>[];
    for (final line in const LineSplitter().convert(text)) {
      final cells = line.split('\t');
      if (cells.length < 2) continue;
      final name = cells[0].trim(), value = cells[1].trim();
      if (!RegExp(r'^[A-Za-z0-9_.\-]{1,128}$').hasMatch(name)) continue;
      // Skip the table's own header row when it was copied along with the data.
      if (_tableHeadings.contains(name.toLowerCase()) &&
          _tableHeadings.contains(value.toLowerCase())) {
        continue;
      }
      if (value.isEmpty || RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value)) {
        continue;
      }
      if (pairs.any((pair) => pair.startsWith('$name='))) continue;
      pairs.add('$name=$value');
    }
    return pairs.length < 2 ? null : pairs.join('; ');
  }
}
