import 'dart:convert';
import '../../core/json.dart';
import '../../domain/models.dart';
import '../../domain/public_share_route.dart';
import 'workflow.dart';

class ParserRuleError extends AppException {
  const ParserRuleError(this.code, super.message);
  final String code;
  bool get suggestsRuleUpdate => const {
    'RULE_RESPONSE',
    'RULE_REDIRECT',
    'RULE_PAGINATION',
    'RULE_DOWNLOAD_URL',
    'RULE_CHANGED',
  }.contains(code);
}

class ParserRule {
  ParserRule._(this.json);
  final Json json;
  static const engine = 4;
  static const operations = {
    'coalesce',
    'string',
    'int',
    'concat',
    'eq',
    'not',
    'and',
    'or',
    'contains',
    'startsWith',
    'first',
    'map',
    'if',
    'list',
    'hostMatches',
    'cookieMerge',
  };
  static const errorCodes = {
    'password_rejected',
    'share_rejected',
    'quota_exhausted',
    'interaction_required',
    'upstream_unavailable',
  };
  static final _id = RegExp(r'^[a-z][a-z0-9_-]{1,63}$');
  static final _host = RegExp(
    r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
  );
  static const forbiddenHeaders = {
    'authorization',
    'proxy-authorization',
    'cookie',
    'host',
    'connection',
    'content-length',
    'transfer-encoding',
  };
  String get siteId => json.str('siteId');
  String get name => json.str('name');
  CloudPlatform get platform =>
      CloudPlatform.fromKey(json.str('platform', 'baidu'))!;
  String get deviceGroup => json.str('deviceGroup').ifEmpty(siteId);
  bool get runsOnServer => json.obj('execution').str('type') == 'server';
  Duration get shareTimeout => Duration(
    seconds: runsOnServer
        ? 390
        : json['engine'] == 4
        ? operation('list').integer('timeout', 120) + 30
        : 90,
  );
  bool get requiresPassword => !runsOnServer && json['authMode'] != 'none';
  bool requiresPasswordFor(String operation) =>
      requiresPassword &&
      !(operation == 'list' && json['passwordStage'] == 'download');
  List<String> get allowedHosts =>
      (json['allowedHosts'] as List).cast<String>();
  List<String> get downloadHosts =>
      (json['downloadHosts'] as List).cast<String>();
  Json operation(String name) => json.obj('operations').obj(name);

  static Never invalid(String message) =>
      throw ParserRuleError('INVALID_RULE', message);
  static bool validHost(String value) =>
      value.length <= 253 &&
      _host.hasMatch(value) &&
      !RegExp(r'\.(?:local|localhost|internal|test|invalid)$').hasMatch(value);

  static void endpoint(String value, List<String> hosts) {
    final uri = Uri.tryParse(value);
    if (value.length > 2048 ||
        RegExp(r'[\s\x00-\x1f\x7f\\]').hasMatch(value) ||
        uri == null ||
        uri.scheme != 'https' ||
        !hosts.contains(uri.host) ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.port != 443) {
      invalid('解析规则请求地址不在允许范围内');
    }
  }

  factory ParserRule.fromJson(Json raw) {
    // Detach the caller's mutable map; the selected snapshot stays immutable.
    final rule = asJson(jsonDecode(jsonEncode(raw)));
    if (utf8.encode(jsonEncode(rule)).length > 60000 ||
        rule['schema'] != 1 ||
        !{1, 2, 3, 4}.contains(rule['engine'])) {
      invalid('解析规则需要新版 App 或格式不正确');
    }
    final platform = CloudPlatform.fromKey(rule.str('platform', 'baidu'));
    if (!PublicShareRoute.platforms.contains(platform) ||
        (rule['engine'] as int) < 3 && platform != CloudPlatform.baidu ||
        rule.containsKey('deviceGroup') &&
            !_id.hasMatch(rule.str('deviceGroup')) ||
        rule.containsKey('passwordStage') &&
            ((rule['engine'] as int) < 3 ||
                !{'all', 'download'}.contains(rule['passwordStage']))) {
      invalid('解析规则网盘或密码阶段配置无效');
    }
    if (!_id.hasMatch(rule.str('siteId')) ||
        rule['name'] is! String ||
        rule.str('name').trim().isEmpty ||
        rule.str('name').runes.length > 60) {
      invalid('解析规则站点信息无效');
    }
    for (final field in ['allowedHosts', 'downloadHosts']) {
      final hosts = rule[field];
      if (hosts is! List ||
          hosts.isEmpty ||
          hosts.length > 16 ||
          hosts.any((host) => host is! String || !validHost(host))) {
        invalid('解析规则必须声明有效的请求域名');
      }
    }
    final downloadUa = rule['downloadUserAgent'];
    if (downloadUa != null && !validHeader(downloadUa, limit: 1024)) {
      invalid('解析规则下载参数无效');
    }
    if (rule.containsKey('downloadHeaders')) {
      final headers = rule['downloadHeaders'];
      if ((rule['engine'] as int) < 3 ||
          headers is! List ||
          headers.length > 2 ||
          headers.any((h) => !{'Cookie', 'Referer'}.contains(h))) {
        invalid('解析下载请求头配置无效');
      }
      if (headers.contains('Cookie')) {
        final hosts = rule['downloadCredentialHosts'];
        if (hosts is! List ||
            hosts.isEmpty ||
            hosts.length > 8 ||
            hosts.any(
              (h) =>
                  h is! String ||
                  !validHost(h) ||
                  !(rule['downloadHosts'] as List).contains(h),
            )) {
          invalid('下载凭据必须限定接收域名');
        }
      }
    }
    if (rule['engine'] == 4) {
      if (rule.containsKey('execution') ||
          !{null, 'none', 'password'}.contains(rule['authMode'])) {
        invalid('v4 流程必须由 App 本地执行');
      }
      WorkflowSchema.validate(rule);
      return ParserRule._(rule);
    }
    if (rule['engine'] == 2 || rule.containsKey('execution')) {
      final execution = rule.obj('execution');
      if (execution.str('type') != 'server' ||
          !_id.hasMatch(execution.str('adapter')) ||
          rule['authMode'] != 'none' ||
          rule.containsKey('operations') ||
          execution['options'] is! Map) {
        invalid('后台解析规则格式不正确');
      }
      // The App uses only the hub job protocol. Upstream options are never executed here.
      return ParserRule._(rule);
    }
    if (rule.containsKey('authMode') &&
        rule['authMode'] != 'password' &&
        !(rule['engine'] == 3 && rule['authMode'] == 'none')) {
      invalid('客户端规则不能执行后台操作');
    }
    for (final name in ['list', 'download']) {
      final op = rule.obj('operations').obj(name);
      final steps = op['steps'];
      if (steps is! List ||
          steps.isEmpty ||
          steps.length > 8 ||
          op['result'] is! Map) {
        invalid('解析规则缺少列表或下载步骤');
      }
      final seen = <String>{};
      for (final value in steps) {
        if (value is! Map) invalid('解析步骤格式错误');
        final step = asJson(value);
        if (!RegExp(r'^[a-z][a-z0-9_]{0,31}$').hasMatch(step.str('id')) ||
            !seen.add(step.str('id')) ||
            !{'GET', 'POST'}.contains(step['method']) ||
            step['url'] is! String) {
          invalid('解析请求步骤无效');
        }
        endpoint(
          step.str('url'),
          (rule['allowedHosts'] as List).cast<String>(),
        );
        if (!{
              'json',
              'form',
              'checkrand',
              'kdown_csrf',
              'kdown_download',
            }.contains(step['codec'] ?? 'json') ||
            !{'json', 'text', 'kdown'}.contains(step['decode'] ?? 'json')) {
          invalid('解析规则需要新版算法支持');
        }
        if (step['method'] == 'GET' && (step['codec'] ?? 'json') != 'json') {
          invalid('解析 GET 请求不能使用请求体算法');
        }
        final headers = step['headers'];
        if (headers != null && headers is! Map) invalid('解析请求头无效');
        for (final entry in step.obj('headers').entries) {
          if (!RegExp(r'^[A-Za-z0-9-]{1,60}$').hasMatch(entry.key) ||
              forbiddenHeaders.contains(entry.key.toLowerCase()) ||
              entry.value is String && !validHeader(entry.value)) {
            invalid('解析规则不能设置账号凭据或连接控制请求头');
          }
        }
        if (step.containsKey('optional') &&
            (step['optional'] is! bool ||
                step['optional'] == true &&
                    (step['method'] != 'GET' || step['decode'] != 'text'))) {
          invalid('仅公钥文本读取步骤可以忽略失败');
        }
        final timeout = step['timeout'] ?? 15;
        if (timeout is! int || timeout < 1 || timeout > 60) invalid('解析超时设置无效');
        final errors = step['errors'] ?? [];
        if (errors is! List || errors.length > 32) invalid('解析错误规则无效');
        for (final item in errors) {
          final error = asJson(item);
          if (!error.containsKey('when') ||
              !errorCodes.contains(error['code'])) {
            invalid('解析错误判断无效');
          }
        }
      }
      if (op.containsKey('pagination')) {
        final p = op.obj('pagination');
        final max = p['maxPages'] ?? 20;
        if (name != 'list' ||
            op['pagination'] is! Map ||
            max is! int ||
            max < 1 ||
            max > 20) {
          invalid('解析分页设置无效');
        }
      }
    }
    var nodes = 0;
    void expression(dynamic value, int depth) {
      if (++nodes > 6000 || depth > 20) invalid('解析规则过于复杂');
      if (value is String &&
          (utf8.encode(value).length > 8192 ||
              RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]').hasMatch(value))) {
        invalid('解析规则文本无效');
      }
      if (value is List) {
        for (final item in value) {
          expression(item, depth + 1);
        }
      } else if (value is Map) {
        if (value.containsKey(r'$ref')) {
          final ref = value[r'$ref'];
          if (value.length != 1 ||
              ref is! String ||
              !RegExp(
                r'^(input|steps|secret|device|item|last|page)(?:\.[A-Za-z0-9_-]+){0,16}$',
              ).hasMatch(ref)) {
            invalid('解析规则引用路径无效');
          }
          return;
        }
        if (value.containsKey(r'$op') &&
            (!operations.contains(value[r'$op']) ||
                rule['engine'] != 3 &&
                    {'hostMatches', 'cookieMerge'}.contains(value[r'$op']) ||
                value['args'] is! List ||
                (value['args'] as List).length > 20)) {
          invalid('解析规则表达式不受支持');
        }
        for (final entry in value.entries) {
          if (entry.key.toString().startsWith(r'$') && entry.key != r'$op') {
            invalid('解析规则字段不受支持');
          }
          expression(entry.value, depth + 1);
        }
      }
    }

    expression(rule['operations'], 0);
    return ParserRule._(rule);
  }

  static bool validHeader(dynamic value, {int limit = 16000}) =>
      value is String &&
      utf8.encode(value).length <= limit &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

  bool permitsDownload(String value) {
    final uri = Uri.tryParse(value);
    return value.length <= 16000 &&
        !RegExp(r'[\s\x00-\x1f\x7f\\]').hasMatch(value) &&
        uri != null &&
        {'http', 'https'}.contains(uri.scheme) &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment &&
        {80, 443}.contains(uri.port) &&
        downloadHosts.any(
          (host) => uri.host == host || uri.host.endsWith('.$host'),
        );
  }

  void validateResult(String operation, Json result, Json input) {
    if (operation == 'list') {
      final list = result['list'];
      if (list is! List || list.length > 10000) {
        throw const ParserRuleError('RULE_RESPONSE', '解析规则未返回文件列表');
      }
      for (final entry in list) {
        final file = asJson(entry);
        if (file.str('fs_id').isEmpty ||
            file.str('server_filename').isEmpty ||
            file.integer('isdir') == 1 && !file.str('path').startsWith('/')) {
          throw const ParserRuleError('RULE_RESPONSE', '解析文件信息不完整');
        }
        if (file['extra'] != null &&
            (file['extra'] is! Map ||
                utf8.encode(jsonEncode(file['extra'])).length > 16384)) {
          throw const ParserRuleError('RULE_RESPONSE', '文件取链参数过大');
        }
      }
      if (utf8.encode(jsonEncode(result['state'] ?? {})).length > 8192) {
        throw const ParserRuleError('RULE_RESPONSE', '解析分享状态信息过大');
      }
    } else {
      if (result.str('fs_id') != input.obj('file').str('fs_id')) {
        throw const ParserRuleError('RULE_FILE_MISMATCH', '解析返回的文件不一致，请重新解析');
      }
      final urls = result['urls'];
      if (urls is! List ||
          urls.length > 32 ||
          !urls.whereType<String>().any(permitsDownload)) {
        throw const ParserRuleError('RULE_DOWNLOAD_URL', '解析站未返回有效下载地址');
      }
      if (!validHeader(result['ua'] ?? '', limit: 1024)) {
        throw const ParserRuleError('RULE_HEADER', '解析站返回的下载参数无效');
      }
      downloadHeaders(result);
      if (result.obj('headers').str('Cookie').isNotEmpty) {
        final hosts = (json['downloadCredentialHosts'] as List).cast<String>();
        for (final url in urls.whereType<String>().where(permitsDownload)) {
          final host = Uri.parse(url).host;
          if (!hosts.any((h) => host == h || host.endsWith('.$h'))) {
            throw const ParserRuleError('RULE_HEADER', '下载凭据与文件地址不匹配');
          }
        }
      }
    }
  }

  Map<String, String> downloadHeaders(Json result) {
    final value = result['headers'];
    if (value == null) return {};
    if (value is! Map || value.length > 2) {
      throw const ParserRuleError('RULE_HEADER', '解析站返回的下载参数无效');
    }
    final allowed = json['downloadHeaders'] as List? ?? const [];
    final headers = <String, String>{};
    for (final entry in value.entries) {
      if (!allowed.contains(entry.key) ||
          !validHeader(entry.value, limit: 16384)) {
        throw const ParserRuleError('RULE_HEADER', '解析站返回了未声明的下载参数');
      }
      if ((entry.value as String).isNotEmpty) {
        headers[entry.key as String] = entry.value;
      }
    }
    return headers;
  }
}

class RuleExpression {
  int remaining = 100000;
  static bool hostMatches(dynamic value, dynamic domain) {
    final uri = Uri.tryParse(text(value));
    final host = text(domain).toLowerCase();
    return uri != null &&
        {'http', 'https'}.contains(uri.scheme) &&
        ParserRule.validHost(host) &&
        (uri.host.toLowerCase() == host ||
            uri.host.toLowerCase().endsWith('.$host'));
  }

  static String mergeCookies(dynamic account, dynamic sender, dynamic names) {
    if (!ParserRule.validHeader(text(account)) ||
        !ParserRule.validHeader(text(sender)) ||
        names is! List ||
        names.length > 32 ||
        names.any((n) => n is! String)) {
      throw const ParserRuleError('RULE_HEADER', '解析下载凭据格式无效');
    }
    final overrides = names.cast<String>().map((n) => n.toLowerCase()).toSet();
    Map<String, String> parse(dynamic value) {
      final out = <String, String>{};
      for (final entry in text(value).split(';')) {
        final part = entry.trim();
        if (part.isEmpty) continue;
        final at = part.indexOf('=');
        if (at <= 0 || at > 128) {
          throw const ParserRuleError('RULE_HEADER', '解析下载凭据格式无效');
        }
        final name = part.substring(0, at).trim();
        if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(name)) {
          throw const ParserRuleError('RULE_HEADER', '解析下载凭据格式无效');
        }
        out[name] = part.substring(at + 1);
      }
      return out;
    }

    final cookies = parse(account);
    for (final entry in parse(sender).entries) {
      if (overrides.contains(entry.key.toLowerCase()) ||
          !cookies.containsKey(entry.key)) {
        cookies[entry.key] = entry.value;
      }
    }
    final result = cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
    if (!ParserRule.validHeader(result)) {
      throw const ParserRuleError('RULE_HEADER', '解析下载凭据过长');
    }
    return result;
  }

  static String text(dynamic value) =>
      value is String || value is num || value is bool ? value.toString() : '';
  static dynamic path(Json scope, String path) {
    dynamic value = scope;
    for (final part in path.split('.')) {
      if (value is Map) {
        value = value[part];
      } else if (value is List) {
        final index = int.tryParse(part);
        value = index == null || index < 0 || index >= value.length
            ? null
            : value[index];
      } else {
        return null;
      }
    }
    return value;
  }

  dynamic eval(dynamic value, Json scope, [int depth = 0]) {
    if (--remaining < 0 || depth > 24) {
      throw const ParserRuleError('RULE_BUDGET', '解析规则计算超出限制');
    }
    if (value is List) {
      return value.map((v) => eval(v, scope, depth + 1)).toList();
    }
    if (value is! Map) return value;
    if (value.containsKey(r'$ref')) {
      return path(scope, value[r'$ref'] as String);
    }
    if (!value.containsKey(r'$op')) {
      return value.map(
        (key, v) => MapEntry(key.toString(), eval(v, scope, depth + 1)),
      );
    }
    final op = value[r'$op'];
    final raw = value['args'] as List;
    dynamic at(int i) => i < raw.length ? raw[i] : null;
    if (op == 'map') {
      final items = eval(at(0), scope, depth + 1);
      if (items is! List || items.length > 10000) {
        throw const ParserRuleError('RULE_RESPONSE', '解析规则未读取到文件列表');
      }
      return items
          .map((item) => eval(at(1), {...scope, 'item': item}, depth + 1))
          .toList();
    }
    if (op == 'if') {
      return eval(
        at(eval(at(0), scope, depth + 1) == true ? 1 : 2),
        scope,
        depth + 1,
      );
    }
    final args = raw.map((v) => eval(v, scope, depth + 1)).toList();
    final dynamic a = args.firstOrNull, b = args.length > 1 ? args[1] : null;
    return switch (op) {
      'coalesce' => args.where((v) => v != null && v != '').firstOrNull,
      'string' => text(a),
      'int' =>
        a is int
            ? a
            : a is String && RegExp(r'^-?[0-9]{1,16}$').hasMatch(a)
            ? int.tryParse(a) ?? 0
            : 0,
      'concat' => args.map(text).join(),
      'eq' =>
        a is bool || b is bool || a == null || b == null
            ? a == b
            : text(a) == text(b),
      'not' => a != true,
      'and' => args.every((v) => v == true),
      'or' => args.any((v) => v == true),
      'contains' => text(b).isNotEmpty && text(a).contains(text(b)),
      'startsWith' => text(b).isNotEmpty && text(a).startsWith(text(b)),
      'hostMatches' => hostMatches(a, b),
      'cookieMerge' => mergeCookies(a, b, args.length > 2 ? args[2] : const []),
      'first' => a is List ? a.firstOrNull : null,
      'list' =>
        a is List
            ? a
            : a == null || a == ''
            ? <dynamic>[]
            : [a],
      _ => throw const ParserRuleError('RULE_ALGORITHM', '解析规则需要新版 App'),
    };
  }
}
