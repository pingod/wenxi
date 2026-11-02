import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart' as hashes;
import '../../core/json.dart';
import '../http.dart';
import 'codecs.dart';
import 'engine.dart';
import 'rule.dart';
import 'site_protection.dart';
import 'workflow_expression.dart';

class WorkflowSchema {
  static const capabilities = [
    'dynamicRequests',
    'polling',
    'conditions',
    'functions',
    'integer512',
    'hash',
    'hmac',
    'aesCbc',
    'rsaEncrypt',
    'text',
    'sse',
    'scopedHeaders',
  ];
  static void validate(Json rule) {
    Never bad(String message) => ParserRule.invalid(message);
    final functions = rule['functions'] ?? <String, dynamic>{};
    if (functions is! Map || functions.length > 32) bad('规则函数配置无效');
    for (final name in functions.keys) {
      if (name is! String ||
          !RegExp(r'^[a-z][a-z0-9_]{0,31}$').hasMatch(name)) {
        bad('规则函数名无效');
      }
    }
    final credentials = rule['requestHeaders'] ?? [];
    if (credentials is! List ||
        credentials.length > 2 ||
        credentials.any((v) => !{'Cookie', 'Authorization'}.contains(v))) {
      bad('规则会话请求头无效');
    }
    if (credentials.isNotEmpty) {
      final hosts = rule['requestCredentialHosts'];
      if (hosts is! List ||
          hosts.isEmpty ||
          hosts.length > 8 ||
          hosts.any((h) => !(rule['allowedHosts'] as List).contains(h))) {
        bad('会话请求头必须限定原站域名');
      }
    }
    int nodes = 0;
    void expression(dynamic value, int depth) {
      if (++nodes > 12000 || depth > 40) bad('规则表达式过于复杂');
      if (value is String && utf8.encode(value).length > 16384) bad('规则文本过长');
      if (value is List) {
        for (final v in value) {
          expression(v, depth + 1);
        }
      }
      if (value is! Map) return;
      if (value.containsKey(r'$ref')) {
        final ref = value[r'$ref'];
        if (value.length != 1 ||
            ref is! String ||
            !RegExp(
              r'^(input|steps|secret|device|item|last|page|args|acc|index|clock|attempt|response|responses)(?:\.[A-Za-z0-9_-]+){0,16}$',
            ).hasMatch(ref)) {
          bad('规则引用路径无效');
        }
        return;
      }
      if (value.containsKey(r'$op') &&
          (!{
                ...ParserRule.operations,
                ...WorkflowExpression.extraOperations,
              }.contains(value[r'$op']) ||
              value['args'] is! List ||
              (value['args'] as List).length > 20)) {
        bad('规则表达式不受支持');
      }
      for (final entry in value.entries) {
        if (entry.key.toString().startsWith(r'$') && entry.key != r'$op') {
          bad('规则字段无效');
        }
        expression(entry.value, depth + 1);
      }
    }

    for (final name in ['list', 'download']) {
      final op = rule.obj('operations').obj(name), steps = op['steps'];
      if (steps is! List ||
          steps.isEmpty ||
          steps.length > 24 ||
          op['result'] is! Map) {
        bad('流程缺少步骤或结果映射');
      }
      _range(op['timeout'] ?? 120, 1, 300);
      _range(op['maxRequests'] ?? 80, 1, 120);
      final ids = <String>{};
      for (final value in steps) {
        if (value is! Map) bad('流程步骤无效');
        final step = asJson(value), type = step.str('type', 'request');
        if (!RegExp(r'^[a-z][a-z0-9_]{0,31}$').hasMatch(step.str('id')) ||
            !ids.add(step.str('id'))) {
          bad('流程步骤编号无效或重复');
        }
        if (!{'request', 'value', 'delay'}.contains(type)) bad('流程步骤类型不受支持');
        if (type == 'value' && !step.containsKey('value') ||
            type == 'delay' && !step.containsKey('milliseconds')) {
          bad('流程步骤缺少参数');
        }
        if (type != 'request') continue;
        if (!{'GET', 'POST'}.contains(step['method']) ||
            step['url'] is! String && step['url'] is! Map) {
          bad('流程请求格式无效');
        }
        if (step['url'] is String) {
          ParserRule.endpoint(
            step.str('url'),
            (rule['allowedHosts'] as List).cast<String>(),
          );
        }
        if (!{
              'json',
              'form',
              'checkrand',
              'kdown_csrf',
              'kdown_download',
            }.contains(step['codec'] ?? 'json') ||
            !{
              'json',
              'text',
              'sse',
              'kdown',
            }.contains(step['decode'] ?? 'json')) {
          bad('流程编码不受支持');
        }
        if (step['method'] == 'GET' && step.str('codec', 'json') != 'json') {
          bad('GET 请求不能使用请求体算法');
        }
        _range(step['timeout'] ?? 30, 1, 60);
        if (step['headers'] != null && step['headers'] is! Map) bad('流程请求头无效');
        for (final entry in step.obj('headers').entries) {
          if (!RegExp(r'^[A-Za-z0-9-]{1,60}$').hasMatch(entry.key) ||
              ParserRule.forbiddenHeaders.contains(entry.key.toLowerCase()) &&
                  !credentials.any(
                    (h) =>
                        h.toString().toLowerCase() == entry.key.toLowerCase(),
                  )) {
            bad('流程请求头未经声明');
          }
        }
        if (step.containsKey('poll')) {
          final poll = step['poll'];
          if (step['method'] != 'GET' ||
              poll is! Map ||
              !poll.containsKey('until')) {
            bad('仅 GET 查询步骤支持轮询');
          }
          _range(poll['maxAttempts'] ?? 60, 1, 100);
          _range(poll['intervalMs'] ?? 1500, 250, 10000);
        }
        final errors = step['errors'] ?? [];
        if (errors is! List || errors.length > 32) bad('流程错误判断无效');
        for (final error in errors) {
          if (error is! Map ||
              !error.containsKey('when') ||
              !ParserRule.errorCodes.contains(error['code'])) {
            bad('流程错误判断无效');
          }
        }
        final caught = step['onError'] ?? [];
        if (caught is! List ||
            caught.length > 8 ||
            caught.any(
              (c) => !{
                ...ParserRule.errorCodes,
                'RULE_NETWORK',
                'RULE_RESPONSE',
                'RULE_REDIRECT',
              }.contains(c),
            )) {
          bad('备用流程错误条件无效');
        }
      }
      if (op.containsKey('pagination')) {
        if (name != 'list' || op['pagination'] is! Map) bad('分页只能用于列表');
        _range(op.obj('pagination')['maxPages'] ?? 20, 1, 50);
      }
    }
    expression(functions, 0);
    expression(rule['operations'], 0);
  }

  static void _range(dynamic n, int min, int max) {
    if (n is! int || n < min || n > max) ParserRule.invalid('流程时间或次数限制无效');
  }
}

class WorkflowEngine {
  WorkflowEngine(
    this.http, {
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  }) : now = now ?? DateTime.now,
       delay = delay ?? Future<void>.delayed;
  final JsonHttp http;
  final DateTime Function() now;
  final Future<void> Function(Duration) delay;
  final List<Json> trace = [];
  static dynamic decode(String codec, String text) {
    if (codec == 'json') return WorkflowExpression.decodeJson(text);
    if (codec != 'sse') return ParserRuleCodecs.decode(codec, text);
    final events = <dynamic>[];
    for (final frame in text.replaceAll('\r\n', '\n').split('\n\n')) {
      final data = frame
          .split('\n')
          .where((l) => l.startsWith('data:'))
          .map((l) => l.substring(5).trimLeft())
          .join('\n');
      if (data.isEmpty || data == '[DONE]') continue;
      if (events.length >= 2000) {
        throw const ParserRuleError('RULE_RESPONSE', '事件流过大');
      }
      events.add(WorkflowExpression.decodeJson(data));
    }
    return {'events': events, 'last': events.lastOrNull};
  }

  Future<Json> execute(
    ParserRule rule,
    String operation,
    Json input, {
    required String password,
    required String device,
  }) async {
    if (!{'list', 'download'}.contains(operation)) {
      throw const ParserRuleError('INVALID_OPERATION', '解析操作无效');
    }
    final op = rule.operation(operation),
        expr = WorkflowExpression(rule.json.obj('functions'));
    expr.remaining = 500000;
    final budget = Stopwatch()..start(), started = now();
    final seconds = op.integer('timeout', 120),
        maxRequests = op.integer('maxRequests', 80);
    var requests = 0;
    trace.clear();
    final scope = <String, dynamic>{
      'input': input,
      'secret': {'password': password},
      'device': {
        'id': device,
        'fingerprint': hashes.sha256.convert(utf8.encode(device)).toString(),
      },
      'steps': <String, dynamic>{},
      'responses': <String, dynamic>{},
    };
    void checkpoint() {
      RequestScope.checkpoint();
      if (budget.elapsedMilliseconds >= seconds * 1000) {
        throw const ParserRuleError('RULE_BUDGET', '原站处理超时，请稍后重试');
      }
      scope['clock'] = {
        'nowMs': now().millisecondsSinceEpoch,
        'elapsedMs': now().difference(started).inMilliseconds,
      };
    }

    Future<void> pause(int ms) async {
      if (ms < 0 || ms > 10000) {
        throw const ParserRuleError('RULE_BUDGET', '流程等待时间无效');
      }
      checkpoint();
      final remaining = seconds * 1000 - budget.elapsedMilliseconds;
      if (ms >= remaining) {
        throw const ParserRuleError('RULE_BUDGET', '原站处理超时，请稍后重试');
      }
      await RequestScope.cancellable(delay(Duration(milliseconds: ms)));
      checkpoint();
    }

    final paging = op.obj('pagination'), files = <Json>[], seen = <String>{};
    final pages = op.containsKey('pagination')
        ? paging.integer('maxPages', 20)
        : 1;
    dynamic cursor = paging['initialCursor'] ?? '', previousCursor;
    for (var page = 1; page <= pages; page++) {
      scope['page'] = {'number': page, 'cursor': cursor};
      for (final step in op.list('steps')) {
        checkpoint();
        final id = step.str('id'), stepStarted = budget.elapsedMilliseconds;
        if (step.containsKey('when') &&
            expr.eval(step['when'], scope) != true) {
          (scope['steps'] as Json).putIfAbsent(id, () => null);
          continue;
        }
        final type = step.str('type', 'request');
        if (type == 'value') {
          (scope['steps'] as Json)[id] = expr.eval(step['value'], scope);
          continue;
        }
        if (type == 'delay') {
          await pause(
            WorkflowExpression.integer(
              expr.eval(step['milliseconds'], scope),
            ).toInt(),
          );
          (scope['steps'] as Json)[id] = scope['clock'];
          continue;
        }
        final poll = step.obj('poll');
        final attempts = step.containsKey('poll')
            ? poll.integer('maxAttempts', 60)
            : 1;
        try {
          for (var attempt = 1; attempt <= attempts; attempt++) {
            checkpoint();
            scope['attempt'] = attempt;
            if (++requests > maxRequests) {
              throw const ParserRuleError('RULE_BUDGET', '解析请求次数达到限制');
            }
            final rawUrl = expr.eval(step['url'], scope);
            if (rawUrl is! String) {
              throw const ParserRuleError('RULE_RESPONSE', '规则请求地址无效');
            }
            var url = rawUrl;
            final parameters = asJson(expr.eval(step['query'] ?? {}, scope));
            if (parameters.isNotEmpty) url = query(url, parameters);
            ParserRule.endpoint(url, rule.allowedHosts);
            final headers = <String, String>{};
            for (final entry in asJson(
              expr.eval(step['headers'] ?? {}, scope),
            ).entries) {
              if (!ParserRule.validHeader(entry.value)) {
                throw const ParserRuleError('RULE_HEADER', '规则请求头无效');
              }
              if ({
                    'cookie',
                    'authorization',
                  }.contains(entry.key.toLowerCase()) &&
                  !(rule.json['requestCredentialHosts'] as List? ?? [])
                      .contains(Uri.parse(url).host)) {
                throw const ParserRuleError('RULE_HEADER', '会话凭据与原站域名不匹配');
              }
              headers[entry.key] = entry.value;
            }
            final codec = step.str('codec', 'json');
            final body = step.str('method') == 'GET'
                ? null
                : asJson(expr.eval(step['body'] ?? {}, scope));
            final (payload, extra) = ParserRuleCodecs.encode(
              codec,
              body,
              asJson(expr.eval(step['options'] ?? {}, scope)),
              device,
            );
            headers.addAll(extra);
            if (!headers.keys.any((key) => key.toLowerCase() == 'user-agent')) {
              headers['User-Agent'] = 'Dart/3.13 (dart:io)';
            }
            final requestScope = RequestScope();
            HttpResult response;
            try {
              response =
                  await RequestScope.cancellable(
                    requestScope.run(
                      () => http.mutationRequest(
                        step.str('method'),
                        url,
                        body: payload == null
                            ? null
                            : codec == 'form'
                            ? form(payload)
                            : jsonEncode(payload),
                        headers: headers,
                        followRedirects: false,
                        contentType: ParserRuleCodecs.requestContentType(
                          codec,
                          headers,
                        ),
                      ),
                    ),
                  ).timeout(
                    Duration(
                      milliseconds: (step.integer('timeout', 30) * 1000).clamp(
                        1,
                        seconds * 1000 - budget.elapsedMilliseconds,
                      ),
                    ),
                    onTimeout: () =>
                        throw const ParserRuleError('RULE_NETWORK', '解析站响应超时'),
                  );
            } finally {
              requestScope.cancel();
            }
            checkpoint();
            ParserSiteProtection.check(
              response,
              url: url,
              siteId: rule.siteId,
              operation: operation,
              step: id,
            );
            if (response.status == 429) {
              throw const ParserRuleError('quota_exhausted', '原站额度或频率受限');
            }
            if (response.status >= 500) {
              throw const ParserRuleError('upstream_unavailable', '原站暂时不可用');
            }
            if (response.status >= 300 && response.status < 400) {
              throw const ParserRuleError('RULE_REDIRECT', '原站接口已跳转，请更新规则');
            }
            if (utf8.encode(response.body).length > 1048576) {
              throw const ParserRuleError('RULE_RESPONSE', '原站响应过大');
            }
            final data = decode(step.str('decode', 'json'), response.body);
            (scope['steps'] as Json)[id] = data;
            scope['last'] = data;
            scope['response'] = {
              'status': response.status,
              'headers': response.headers,
            };
            (scope['responses'] as Json)[id] = scope['response'];
            for (final error in step.list('errors')) {
              if (expr.eval(error['when'], scope) == true) {
                throw ParserRuleError(
                  error.str('code'),
                  ParserRuleEngine.errorMessage(error.str('code')),
                );
              }
            }
            if (!response.successful ||
                step.containsKey('success') &&
                    expr.eval(step['success'], scope) != true) {
              throw const ParserRuleError('RULE_RESPONSE', '原站响应与规则不一致');
            }
            trace.add({
              'step': id,
              'attempt': attempt,
              'status': response.status,
              'elapsedMs': budget.elapsedMilliseconds - stepStarted,
            });
            if (!step.containsKey('poll') ||
                expr.eval(poll['until'], scope) == true) {
              break;
            }
            if (attempt == attempts) {
              throw const ParserRuleError('RULE_BUDGET', '原站任务等待超时，请稍后重试');
            }
            await pause(poll.integer('intervalMs', 1500));
          }
        } catch (error) {
          checkpoint();
          final failure = error is ParserRuleError
              ? error
              : error is HttpRequestFailure
              ? const ParserRuleError('RULE_NETWORK', '解析站连接失败')
              : const ParserRuleError('RULE_RESPONSE', '原站响应无法读取');
          if ((step['onError'] as List? ?? []).contains(failure.code)) {
            (scope['steps'] as Json)[id] = {
              'failed': true,
              'code': failure.code,
            };
          } else {
            throw failure;
          }
        }
      }
      checkpoint();
      final result = asJson(expr.eval(op['result'], scope));
      rule.validateResult(operation, result, input);
      if (operation == 'download') return result;
      var added = 0;
      for (final file in result.list('list')) {
        if (seen.add(file.str('fs_id'))) {
          files.add(file);
          added++;
        }
      }
      if (files.length > 10000) {
        throw const ParserRuleError('RULE_BUDGET', '分享文件过多');
      }
      if (!op.containsKey('pagination') ||
          expr.eval(paging['hasMore'] ?? false, scope) != true) {
        return {...result, 'list': files};
      }
      cursor = expr.eval(paging['nextCursor'], scope);
      if (added == 0 ||
          page == pages ||
          cursor != null && cursor == previousCursor) {
        throw const ParserRuleError('RULE_PAGINATION', '分页未完成');
      }
      previousCursor = cursor;
    }
    throw const ParserRuleError('RULE_PAGINATION', '分页未完成');
  }
}
