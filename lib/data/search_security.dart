import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../core/json.dart';
import 'http.dart';

class SearchVerificationRequired extends AppException {
  const SearchVerificationRequired() : super('请完成安全验证后继续');
}

/// A random, expiring server credential. No reusable server secret is embedded.
class SearchSecurityClient {
  SearchSecurityClient(this.http, this.endpoint);
  final JsonHttp http;
  final String endpoint;
  Future<bool> Function(SearchSecurityClient client, CancelToken cancellation)?
  onVerification;
  String _token = '';
  DateTime _expires = DateTime(2000);
  Future<bool>? _pending;

  Map<String, String> get headers =>
      _token.isNotEmpty && DateTime.now().isBefore(_expires)
      ? {'X-Search-Session': _token}
      : const {};

  Future<void> ensure(CancelToken cancellation) async {
    if (cancellation.isCancelled) throw const AppException('操作已取消');
    final callback = onVerification;
    require(callback != null, '需要安全验证，请打开资源页后重试');
    _pending ??= callback!(
      this,
      cancellation,
    ).whenComplete(() => _pending = null);
    final verified = await Future.any<bool>([
      _pending!,
      cancellation.whenCancel.then((_) => false),
    ]);
    require(
      verified && !cancellation.isCancelled && headers.isNotEmpty,
      '已取消安全验证',
    );
  }

  Future<Json> challenge() async {
    final response = await http.get('$endpoint/api/security/challenge');
    require(response.body.length <= 512 * 1024, '验证码响应过大');
    return _read(response);
  }

  Future<void> verify(Json challenge, Json answer) async {
    final response = await http.mutationRequest(
      'POST',
      '$endpoint/api/security/verify',
      body: jsonEncode({
        'challenge_id': challenge.str('challenge_id'),
        ...answer,
      }),
      contentType: 'application/json; charset=utf-8',
      followRedirects: false,
    );
    require(response.body.length <= 32768, '验证响应过大');
    final value = _read(response);
    final token = value.str('token');
    final ttl = value['expires_in'];
    require(
      token.length >= 32 &&
          token.length <= 128 &&
          ttl is int &&
          ttl > 0 &&
          ttl <= 3600,
      '验证响应无效',
    );
    _token = token;
    _expires = DateTime.now().add(Duration(seconds: (ttl as int) - 5));
  }

  Json _read(HttpResult response) {
    Json value;
    try {
      value = asJson(jsonDecode(response.body));
    } catch (_) {
      throw const AppException('安全验证服务响应异常');
    }
    require(
      response.status == 200 && value['success'] == true,
      value.str('message').ifEmpty('安全验证暂时不可用，请稍后重试'),
    );
    return value;
  }
}
