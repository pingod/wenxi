import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../core/crypto_box.dart';
import '../../core/json.dart';
import '../../core/operation_progress.dart';
import '../http.dart';
import 'rule.dart';

typedef ParserHubRequest =
    Future<Json> Function(
      String path, {
      Json? body,
      Map<String, String> headers,
    });

class ParserServerClient {
  ParserServerClient({
    required this.request,
    required this.device,
    this.pause = RequestScope.wait,
  });
  final ParserHubRequest request;
  final Future<String> Function(String) device;
  final Future<void> Function(Duration) pause;

  static String _nonce(int size) => CryptoBox.random(
    size,
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  static String hash(ParserRule rule) =>
      sha256.convert(utf8.encode(jsonEncode(rule.json))).toString();
  static String message(String code) => switch (code) {
    'UPSTREAM_DISABLED' => '原站未开放此业务或当前出口无权限，请切换其他通道',
    'interaction_required' => '该通道需要网页验证，请使用网页解析或切换通道',
    'quota_exhausted' => '该通道额度或请求频率受限，请稍后重试或切换通道',
    'share_rejected' => '分享链接或提取码无效，请确认分享仍可访问',
    'WORKER_OFFLINE' => '后台解析服务暂不可用，请稍后重试或切换通道',
    'JOB_BUSY' => '已有解析任务正在等待，请稍后重试',
    'JOB_TIMEOUT' => '后台解析等待超时，请稍后重新解析',
    'JOB_CANCELLED' => '解析任务已取消',
    'JOB_EXPIRED' => '解析结果已过期，请重新解析分享后下载',
    'JOB_NOT_FOUND' => '解析任务已失效，请重新解析分享',
    'JOB_NOT_READY' => '解析尚未完成，请重新打开分享',
    'RULE_CHANGED' => '解析规则已有更新，请重新解析分享',
    'RULE_FILE_MISMATCH' => '解析返回的文件不一致，请重新解析',
    'RULE_DOWNLOAD_URL' || 'RULE_RESPONSE' => '原站返回内容已变化，请切换通道或稍后重试',
    'SESSION_REJECTED' => '解析会话已失效，请重新解析',
    _ => '该通道暂未完成解析，请稍后重试或切换通道',
  };

  Json _ticket(Json state, String ruleHash) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(state.str('jobId')) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(state.str('capability')) ||
        state.str('ruleHash') != ruleHash) {
      throw const ParserRuleError('JOB_NOT_FOUND', '分享解析状态已失效，请重新解析');
    }
    return state;
  }

  Future<Json> _retry(Future<Json> Function() action) async {
    for (var attempt = 0; ; attempt++) {
      RequestScope.checkpoint();
      try {
        return await action();
      } catch (error) {
        final retryable =
            error is HttpRequestFailure && error.retryable ||
            error is ParserRuleError &&
                {'HUB_UNAVAILABLE', 'RULE_NETWORK'}.contains(error.code);
        if (!retryable || attempt >= 1) rethrow;
        await pause(const Duration(milliseconds: 700));
      }
    }
  }

  Future<void> _cancel(Json state) async {
    final scope = RequestScope();
    try {
      await scope
          .run(
            () => request(
              '/v1/parser/jobs/${state.str('jobId')}/cancel',
              body: {},
              headers: {'X-Parser-Job-Key': state.str('capability')},
            ),
            inheritGuard: false,
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      /* Server-side expiry also bounds interrupted clients. */
    } finally {
      scope.cancel();
    }
  }

  Future<Json> execute(
    ParserRule rule,
    int version,
    String operation,
    Json input,
  ) async {
    if (!rule.runsOnServer || !{'list', 'download'}.contains(operation)) {
      throw const ParserRuleError('INVALID_OPERATION', '后台解析操作无效');
    }
    final ruleHash = hash(rule);
    final previous = input.obj('state');
    if (operation == 'download') {
      final state = _ticket(previous, ruleHash);
      final result = await _retry(
        () => request(
          '/v1/parser/jobs/${state.str('jobId')}/download',
          body: {
            'fileId': input.obj('file').str('fs_id'),
            'ruleHash': ruleHash,
          },
          headers: {'X-Parser-Job-Key': state.str('capability')},
        ),
      );
      rule.validateResult(operation, result, input);
      if (result.str('name').isNotEmpty &&
          result.str('name') != input.obj('file').str('server_filename')) {
        throw const ParserRuleError(
          'RULE_FILE_MISMATCH',
          '解析文件名与所选文件不一致，请重新解析',
        );
      }
      return result;
    }
    if (input.str('dir').isNotEmpty && input.str('dir') != '/') {
      throw const ParserRuleError('RULE_RESPONSE', '此通道返回平铺文件列表，请返回分享根目录');
    }
    return OperationProgress.step(OperationStage.serverParse, () async {
      final budget = Stopwatch()..start();
      Json? ticket, status;
      var abandon = false, completed = false;
      final ownsJob = previous.isEmpty;
      try {
        if (ownsJob) {
          final idempotency = _nonce(16), capability = _nonce(32);
          final deviceId = await device(rule.siteId);
          final createScope = RequestScope();
          // Keep creation alive just long enough to receive its id and cancel it if the UI left.
          final creation = createScope.run(() async {
            final created = await _retry(
              () => request(
                '/v1/parser/jobs',
                body: {
                  'siteId': rule.siteId,
                  'version': version,
                  'ruleHash': ruleHash,
                  'deviceId': deviceId,
                  'capability': capability,
                  'input': {'url': input.str('url'), 'pwd': input.str('pwd')},
                },
                headers: {'Idempotency-Key': idempotency},
              ),
            );
            ticket = _ticket({
              'jobId': created.str('id'),
              'capability': capability,
              'ruleHash': ruleHash,
            }, ruleHash);
            if (abandon) unawaited(_cancel(ticket!));
            return created;
          }, inheritGuard: false);
          status = await RequestScope.cancellable(creation);
        } else {
          ticket = _ticket(previous, ruleHash);
        }
        while (true) {
          RequestScope.checkpoint();
          if (budget.elapsed > const Duration(seconds: 365)) {
            throw const ParserRuleError('JOB_TIMEOUT', '后台解析等待超时，请稍后重新解析');
          }
          status ??= await _retry(
            () => request(
              '/v1/parser/jobs/${ticket!.str('jobId')}',
              headers: {'X-Parser-Job-Key': ticket!.str('capability')},
            ),
          );
          if (status.str('id') != ticket!.str('jobId') ||
              status.str('siteId') != rule.siteId ||
              status.str('ruleHash') != ruleHash) {
            throw const ParserRuleError('RULE_FILE_MISMATCH', '后台返回了不匹配的解析任务');
          }
          final state = status.str('status');
          if (state == 'succeeded') {
            final result = <String, dynamic>{
              'list': status['list'],
              'state': ticket,
            };
            rule.validateResult('list', result, input);
            completed = true;
            return result;
          }
          if (!{'queued', 'running'}.contains(state)) {
            final code = switch (state) {
              'expired' => 'JOB_EXPIRED',
              'cancelled' => 'JOB_CANCELLED',
              _ =>
                status.obj('error').str('code').ifEmpty('upstream_unavailable'),
            };
            throw ParserRuleError(code, message(code));
          }
          final stage = switch (status.str('stage')) {
            'queue' => OperationStage.parserQueue,
            'session' || 'verify' => OperationStage.verifyShare,
            'file_list' => OperationStage.readFiles,
            'batch_download' || 'done' => OperationStage.downloadLink,
            _ => OperationStage.serverParse,
          };
          final position = status.obj('progress').integer('position');
          OperationProgress.reportServerStage(
            stage,
            queuePosition: position > 0 ? position : null,
          );
          await pause(
            Duration(
              milliseconds: status
                  .integer('pollAfterMs', 1500)
                  .clamp(1000, 5000),
            ),
          );
          status = null;
        }
      } finally {
        abandon = true;
        if (ownsJob && !completed && ticket != null) {
          unawaited(_cancel(ticket!));
        }
      }
    });
  }
}
