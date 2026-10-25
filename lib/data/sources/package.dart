import 'dart:convert';
import '../../core/json.dart';

class SourceError extends AppException {
  const SourceError(this.code, super.message);
  final String code;
}

class SourcePackage {
  SourcePackage._(this.json);
  final Json json;
  static const capabilities = <String, int>{
    'source': 1,
    'javascript': 1,
    'http': 1,
    'html': 1,
    'crypto': 1,
    'codec': 1,
  };
  static const maxBytes = 262144;
  static final idPattern = RegExp(r'^[a-z][a-z0-9_.-]{1,63}$');
  static final _host = RegExp(
    r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
  );
  static const forbiddenHeaders = {
    'host',
    'connection',
    'content-length',
    'transfer-encoding',
    'proxy-authorization',
    'proxy-connection',
    'upgrade',
  };
  String get id => json.str('id');
  String get name => json.str('name');
  String get entry => json.str('entry');
  Json get operations => json.obj('operations');
  Json get modules => json.obj('modules');
  int get timeoutSeconds => json.integer('timeout', 120);
  Json get permissions => json.obj('permissions');
  bool get compatible => json
      .obj('requires')
      .entries
      .every((e) => (capabilities[e.key] ?? 0) >= e.value);
  bool matches(Uri uri) =>
      {'http', 'https'}.contains(uri.scheme) &&
      uri.userInfo.isEmpty &&
      json
          .list('match')
          .any(
            (m) =>
                hostMatches(uri.host, m.str('host')) &&
                uri.path.startsWith(m.str('pathPrefix', '/')) &&
                (m.str('queryKey').isEmpty ||
                    uri.queryParameters.containsKey(m.str('queryKey'))),
          );
  static bool validHost(String value) {
    final host = value.startsWith('*.') ? value.substring(2) : value;
    return host.length <= 253 &&
        _host.hasMatch(host) &&
        !RegExp(r'\.(local|localhost|internal|invalid|test)$').hasMatch(host);
  }

  static bool hostMatches(String host, String allowed) =>
      allowed.startsWith('*.')
      ? host.endsWith(allowed.substring(1)) && host != allowed.substring(2)
      : host == allowed;
  static Never bad([String message = '来源接入包格式无效']) =>
      throw SourceError('SOURCE_PACKAGE', message);
  factory SourcePackage.fromJson(Json raw) {
    if (utf8.encode(jsonEncode(raw)).length > maxBytes) bad('来源接入包过大');
    final j = asJson(jsonDecode(jsonEncode(raw)));
    if (j['schema'] != 1 ||
        !idPattern.hasMatch(j.str('id')) ||
        j['name'] is! String ||
        j.str('name').trim().isEmpty ||
        j.str('name').runes.length > 60) {
      bad();
    }
    final required = j['requires'];
    if (required is! Map ||
        required.isEmpty ||
        required.length > 24 ||
        required.entries.any(
          (e) =>
              e.key is! String ||
              !idPattern.hasMatch(e.key) ||
              e.value is! int ||
              e.value < 1 ||
              e.value > 1000,
        ) ||
        !required.containsKey('source') ||
        !required.containsKey('javascript')) {
      bad();
    }
    final modules = j['modules'];
    if (modules is! Map ||
        modules.isEmpty ||
        modules.length > 16 ||
        !modules.containsKey(j['entry'])) {
      bad();
    }
    for (final item in modules.entries) {
      if (item.key is! String ||
          !RegExp(
            r'^[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*\.js$',
          ).hasMatch(item.key) ||
          item.value is! String ||
          item.value.trim().isEmpty) {
        bad();
      }
    }
    final ops = j['operations'];
    if (ops is! Map ||
        !ops.containsKey('resolve') ||
        !ops.containsKey('download') ||
        ops.length > 16 ||
        ops.entries.any(
          (e) =>
              e.key is! String ||
              !idPattern.hasMatch(e.key) ||
              e.value is! String ||
              !RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]{0,63}$').hasMatch(e.value),
        )) {
      bad();
    }
    final timeout = j['timeout'] ?? 120;
    if (timeout is! int || timeout < 1 || timeout > 300) bad();
    final match = j['match'];
    if (match is! List || match.isEmpty || match.length > 16) bad();
    for (final m in match) {
      if (m is! Map ||
          m['host'] is! String ||
          !validHost(m['host']) ||
          m['pathPrefix'] != null &&
              (m['pathPrefix'] is! String ||
                  !m['pathPrefix'].startsWith('/') ||
                  m['pathPrefix'].length > 512) ||
          m['queryKey'] != null &&
              (m['queryKey'] is! String || m['queryKey'].length > 100)) {
        bad();
      }
    }
    final permissions = j['permissions'];
    if (permissions is! Map) bad();
    for (final field in ['hosts', 'downloadHosts']) {
      final hosts = permissions[field];
      if (hosts is! List ||
          hosts.isEmpty ||
          hosts.length > 32 ||
          hosts.any((h) => h is! String || !validHost(h))) {
        bad();
      }
    }
    final methods = permissions['methods'] ?? ['GET', 'POST'];
    if (methods is! List ||
        methods.isEmpty ||
        methods.any(
          (v) => !{
            'GET',
            'POST',
            'PUT',
            'PATCH',
            'DELETE',
            'HEAD',
            'OPTIONS',
          }.contains(v),
        )) {
      bad();
    }
    final schemes = permissions['schemes'] ?? ['https'];
    if (schemes is! List ||
        schemes.isEmpty ||
        schemes.any((v) => !{'http', 'https'}.contains(v))) {
      bad();
    }
    final ports = permissions['ports'] ?? [80, 443];
    if (ports is! List ||
        ports.isEmpty ||
        ports.length > 16 ||
        ports.any((v) => v is! int || v < 1 || v > 65535)) {
      bad();
    }
    final headers = permissions['headers'] ?? [];
    if (headers is! List ||
        headers.length > 32 ||
        headers.any(
          (v) =>
              v is! String ||
              !RegExp(r'^[A-Za-z0-9-]{1,64}$').hasMatch(v) ||
              forbiddenHeaders.contains(v.toLowerCase()),
        )) {
      bad();
    }
    return SourcePackage._(j);
  }
  Uri checkedUrl(String value, {bool download = false}) {
    final uri = Uri.tryParse(value);
    final hosts = permissions[download ? 'downloadHosts' : 'hosts'] as List;
    if (value.length > 16384 ||
        RegExp(r'[\x00-\x20\x7f\\]').hasMatch(value) ||
        uri == null ||
        !(permissions['schemes'] as List? ?? ['https']).contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        !(permissions['ports'] as List? ?? [80, 443]).contains(uri.port) ||
        !hosts.any((h) => hostMatches(uri.host, h))) {
      throw const SourceError('SOURCE_HOST', '来源请求地址不在声明范围内');
    }
    return uri.replace(fragment: '');
  }

  Map<String, String> checkedHeaders(dynamic raw) {
    if (raw == null) return {};
    if (raw is! Map || raw.length > 32) {
      throw const SourceError('SOURCE_HEADER', '来源请求头无效');
    }
    final allowed = (permissions['headers'] as List? ?? [])
        .map((h) => h.toString().toLowerCase())
        .toSet();
    final headers = <String, String>{};
    for (final entry in raw.entries) {
      if (entry.key is! String ||
          !allowed.contains(entry.key.toLowerCase()) ||
          forbiddenHeaders.contains(entry.key.toLowerCase()) ||
          entry.value is! String ||
          entry.value.length > 16384 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(entry.value)) {
        throw const SourceError('SOURCE_HEADER', '来源请求头未经声明或无效');
      }
      if (headers.keys.any((h) => h.toLowerCase() == entry.key.toLowerCase())) {
        throw const SourceError('SOURCE_HEADER', '来源请求头重复');
      }
      headers[entry.key] = entry.value;
    }
    return headers;
  }
}

class SourceResource {
  SourceResource._(this.json);
  final Json json;
  String get id => json.str('id');
  String get name => json.str('name');
  bool get isDirectory => json.str('kind') == 'directory';
  int get size => json.integer('size');
  factory SourceResource.fromJson(Json j) {
    if (j['id'] is! String ||
        j['name'] is! String ||
        j.str('id').isEmpty ||
        j.str('id').length > 1024 ||
        j.str('name').trim().isEmpty ||
        j.str('name').length > 512 ||
        !{'file', 'directory'}.contains(j.str('kind', 'file')) ||
        utf8.encode(jsonEncode(j)).length > 16384 ||
        (j['size'] != null && (j['size'] is! int || j.integer('size') < 0))) {
      throw const SourceError('SOURCE_RESULT', '来源返回的资源信息无效');
    }
    return SourceResource._({...j, 'kind': j.str('kind', 'file')});
  }
}
