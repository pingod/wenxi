import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../core/json.dart';
import '../../diagnostics/app_log.dart';
import '../http.dart';
import 'rule.dart';

/// Isolated, bounded HTTP transport. No shared Cookie jar or account headers.
class ParserRuleHttp extends JsonHttp {
  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) async {
    RequestScope.checkpoint();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    final elapsed = Stopwatch()..start();
    var phase = 'connect';
    int? status;
    StreamSubscription<dynamic>? cancellation;
    try {
      final request = await client
          .openUrl(method, Uri.parse(url))
          .timeout(const Duration(seconds: 12));
      phase = 'send';
      request.followRedirects = false;
      request.maxRedirects = 0;
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      if (contentType != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, contentType);
      }
      final token = RequestScope.current;
      cancellation = token?.whenCancel.asStream().listen(
        (_) => request.abort(),
      );
      RequestScope.checkpoint();
      if (body != null) {
        request.add(utf8.encode(body is String ? body : jsonEncode(body)));
      }
      return await (() async {
        final response = await request.close();
        phase = 'receive';
        status = response.statusCode;
        final bytes = <int>[];
        await for (final chunk in response) {
          RequestScope.checkpoint();
          if (bytes.length + chunk.length > 1048576) {
            request.abort();
            throw const ParserRuleError('RULE_RESPONSE', '解析服务响应过大');
          }
          bytes.addAll(chunk);
        }
        final resultHeaders = <String, List<String>>{};
        response.headers.forEach((key, value) => resultHeaders[key] = value);
        return HttpResult(
          response.statusCode,
          utf8.decode(bytes, allowMalformed: true),
          resultHeaders,
        );
      })().timeout(const Duration(seconds: 65));
    } on AppException {
      rethrow;
    } catch (error) {
      RequestScope.checkpoint();
      DiagnosticLog.event(
        'parser.upstream.network_failed',
        fields: {
          'host': Uri.tryParse(url)?.host,
          'method': method,
          'transport': 'dart',
          'phase': phase,
          'errorKind': _networkErrorKind(error),
          'httpStatus': ?status,
          if (error is SocketException && error.osError != null)
            'osCode': error.osError!.errorCode,
          if (error is TlsException && error.osError != null)
            'osCode': error.osError!.errorCode,
          'elapsedMs': elapsed.elapsedMilliseconds,
        },
      );
      throw const ParserRuleError('RULE_NETWORK', '解析服务连接失败，请检查网络后重试');
    } finally {
      await cancellation?.cancel();
      client.close(force: true);
    }
  }

  static String _networkErrorKind(Object error) {
    if (error is TimeoutException) return 'timeout';
    if (error is TlsException) return 'tls';
    if (error is SocketException) {
      // Classify locally; raw exception messages may contain full URLs or IPs.
      final message = error.message.toLowerCase();
      if (message.contains('host lookup') ||
          message.contains('name resolution') ||
          message.contains('nodename')) {
        return 'dns';
      }
      if (message.contains('timed out') || message.contains('timeout')) {
        return 'timeout';
      }
      if (message.contains('refused')) return 'connection_refused';
      if (message.contains('reset')) return 'connection_reset';
      return 'socket';
    }
    if (error is HttpException) return 'http';
    return 'other';
  }
}
