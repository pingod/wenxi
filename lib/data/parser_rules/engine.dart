import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart' as hashes;
import '../../core/json.dart';
import '../http.dart';
import 'codecs.dart';
import 'rule.dart';
import 'site_protection.dart';
import 'workflow.dart';

class ParserRuleEngine {
  ParserRuleEngine(this.http);
  final JsonHttp http;

  Future<Json> execute(
    ParserRule rule,
    String operation,
    Json input, {
    required String password,
    required String device,
  }) async {
    if (rule.json['engine'] == 4) {
      return WorkflowEngine(
        http,
      ).execute(rule, operation, input, password: password, device: device);
    }
    if (rule.runsOnServer) {
      throw const ParserRuleError(
        'SERVER_EXECUTION_REQUIRED',
        '此通道需要通过后台解析任务执行',
      );
    }
    if (!{'list', 'download'}.contains(operation)) {
      throw const ParserRuleError('INVALID_OPERATION', '解析操作无效');
    }
    final op = rule.operation(operation), evaluator = RuleExpression();
    final budget = Stopwatch()..start();
    final files = <Json>[], seen = <String>{};
    var requests = 0;
    final paging = op.obj('pagination');
    final pages = op.containsKey('pagination')
        ? paging.integer('maxPages', 20)
        : 1;
    dynamic cursor = paging['initialCursor'] ?? '', lastCursor;
    for (var page = 1; page <= pages; page++) {
      final scope = <String, dynamic>{
        'input': input,
        'secret': {'password': password},
        'device': {
          'id': device,
          'fingerprint': hashes.sha256.convert(utf8.encode(device)).toString(),
        },
        'steps': <String, dynamic>{},
        'page': {'number': page, 'cursor': cursor},
      };
      for (final step in op.list('steps')) {
        RequestScope.checkpoint();
        try {
          if (step.containsKey('when') &&
              evaluator.eval(step['when'], scope) != true) {
            (scope['steps'] as Json)[step.str('id')] = null;
            continue;
          }
          if (++requests > 40 || budget.elapsed.inSeconds >= 60) {
            throw const ParserRuleError('RULE_BUDGET', '解析请求超过时间或次数限制');
          }
          var url = step.str('url');
          final parameters = asJson(evaluator.eval(step['query'] ?? {}, scope));
          if (parameters.isNotEmpty) url = query(url, parameters);
          ParserRule.endpoint(url, rule.allowedHosts);
          final headers = <String, String>{};
          for (final entry in asJson(
            evaluator.eval(step['headers'] ?? {}, scope),
          ).entries) {
            if (!ParserRule.validHeader(entry.value)) {
              throw const ParserRuleError('RULE_HEADER', '解析请求头无效');
            }
            headers[entry.key] = entry.value as String;
          }
          final codec = step.str('codec', 'json');
          final body = step.str('method') == 'GET'
              ? null
              : asJson(evaluator.eval(step['body'] ?? {}, scope));
          final (payload, extra) = ParserRuleCodecs.encode(
            codec,
            body,
            asJson(evaluator.eval(step['options'] ?? {}, scope)),
            device,
          );
          headers.addAll(extra);
          if (!headers.keys.any((key) => key.toLowerCase() == 'user-agent')) {
            headers['User-Agent'] = 'Dart/3.13 (dart:io)';
          }
          if (!headers.keys.any((key) => key.toLowerCase() == 'accept')) {
            headers['Accept'] = 'application/json';
          }
          final stepScope = RequestScope();
          HttpResult response;
          try {
            response =
                await RequestScope.cancellable(
                  stepScope.run(
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
                    seconds: step
                        .integer('timeout', 15)
                        .clamp(1, 60 - budget.elapsed.inSeconds),
                  ),
                  onTimeout: () {
                    throw const ParserRuleError('RULE_NETWORK', '解析站响应超时');
                  },
                );
          } finally {
            stepScope.cancel();
          }
          RequestScope.checkpoint();
          ParserSiteProtection.check(
            response,
            url: url,
            siteId: rule.siteId,
            operation: operation,
            step: step.str('id'),
          );
          if (response.status == 429) {
            throw ParserRuleError(
              'quota_exhausted',
              errorMessage('quota_exhausted'),
            );
          }
          if (response.status >= 500) {
            throw ParserRuleError(
              'upstream_unavailable',
              errorMessage('upstream_unavailable'),
            );
          }
          if (response.status >= 300 && response.status < 400) {
            throw const ParserRuleError('RULE_REDIRECT', '解析接口已跳转，需要更新规则');
          }
          if (utf8.encode(response.body).length > 1048576) {
            throw const ParserRuleError('RULE_RESPONSE', '解析站响应过大');
          }
          final data = ParserRuleCodecs.decode(
            step.str('decode', 'json'),
            response.body,
          );
          (scope['steps'] as Json)[step.str('id')] = data;
          scope['last'] = data;
          for (final error in step.list('errors')) {
            if (evaluator.eval(error['when'], scope) == true) {
              throw ParserRuleError(
                error.str('code'),
                errorMessage(error.str('code')),
              );
            }
          }
          if (!response.successful ||
              step.containsKey('success') &&
                  evaluator.eval(step['success'], scope) != true) {
            throw const ParserRuleError(
              'RULE_RESPONSE',
              '解析站响应与规则不一致，请稍后重试或切换通道',
            );
          }
        } catch (error) {
          RequestScope.checkpoint();
          if (step.boolean('optional')) {
            (scope['steps'] as Json)[step.str('id')] = null;
            continue;
          }
          if (error is ParserRuleError) rethrow;
          if (error is HttpRequestFailure) {
            throw const ParserRuleError('RULE_NETWORK', '解析站连接失败，请稍后重试');
          }
          throw const ParserRuleError('RULE_RESPONSE', '解析站响应无法读取，请更新规则或切换通道');
        }
      }
      final result = asJson(evaluator.eval(op['result'], scope));
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
        throw const ParserRuleError('RULE_BUDGET', '分享目录文件过多，请缩小范围');
      }
      final more =
          op.containsKey('pagination') &&
          evaluator.eval(paging['hasMore'] ?? false, scope) == true;
      if (!more) return {...result, 'list': files};
      cursor = evaluator.eval(paging['nextCursor'], scope);
      if (added == 0 ||
          page == pages ||
          cursor != null && cursor == lastCursor) {
        throw const ParserRuleError('RULE_PAGINATION', '分页读取未完成，请更新规则或缩小范围');
      }
      lastCursor = cursor;
    }
    throw const ParserRuleError('RULE_PAGINATION', '分页读取未完成');
  }

  static String errorMessage(String code) => switch (code) {
    'password_rejected' => '解析密码已更新，请补充当前密码',
    'share_rejected' => '分享链接或提取码无效',
    'quota_exhausted' => '当前解析通道额度或频率受限，请稍后重试',
    'interaction_required' => '解析站要求额外验证，请切换通道或使用账号下载',
    _ => '当前解析通道暂时不可用，请稍后重试',
  };
}
