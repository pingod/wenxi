import 'dart:convert';
import 'dart:math';
import '../../core/json.dart';
import '../../domain/models.dart';
import '../../domain/web_tokens.dart';
import '../http.dart';
import 'wopan.dart';

class WopanSmsChallenge {
  const WopanSmsChallenge(this.mobile);
  final String mobile;
}

/// Uses the official H5 client's SMS endpoints without opening a web page.
class WopanSmsLogin {
  WopanSmsLogin(this.http, {int Function()? now})
    : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  final JsonHttp http;
  final int Function() now;

  static bool validMobile(String value) =>
      RegExp(r'^1[0-9]{10}$').hasMatch(value.trim());

  Future<Json> _post(String path, Json body, {bool sending = false}) async {
    RequestScope.checkpoint();
    // Neither sending a text message nor submitting a code may be replayed.
    final response = await http.mutationRequest(
      'POST',
      '${WopanProtocol.origin}/api-user/$path',
      body: jsonEncode(body),
      headers: WopanProtocol.webHeaders(now()),
      contentType: 'application/json; charset=utf-8',
      followRedirects: false,
    );
    RequestScope.checkpoint();
    require(response.status != 429, '验证码请求过于频繁，请稍后重试');
    final failure = sending
        ? '联通短信发送失败，请稍后重试或切换网页登录'
        : '联通短信登录失败，请检查验证码或切换网页登录';
    require(response.successful, failure);
    Json data;
    try {
      data = response.json;
    } on AppException {
      throw AppException(failure);
    }
    final rsp = data.obj('RSP');
    require(
      (data.str('STATUS').isEmpty || data.str('STATUS') == '200') &&
          rsp.str('RSP_CODE') == '0000',
      sending ? failure : '短信验证码错误、已过期或登录受限，请重新获取验证码或切换网页登录',
    );
    return rsp;
  }

  Future<WopanSmsChallenge> sendSms(String mobile) async {
    mobile = mobile.trim();
    require(validMobile(mobile), '请输入正确的手机号');
    await _post('sendMessageCodeBase', {
      'func': 'app_send',
      'clientId': WopanProtocol.webClientId,
      'param': WopanProtocol.encrypt(
        {'operateType': '1', 'phone': mobile},
        'api-user',
        '',
        client: WopanProtocol.webClientId,
      ),
    }, sending: true);
    return WopanSmsChallenge(mobile);
  }

  Future<Credential> sms(WopanSmsChallenge challenge, String code) async {
    require(validMobile(challenge.mobile), '请输入正确的手机号');
    code = code.trim();
    require(RegExp(r'^[0-9]{6}$').hasMatch(code), '请输入6位短信验证码');
    final rsp = await _post('dispatcher', {
      'header': WopanProtocol.header(
        'api-user',
        'LoginByMobileV2',
        now(),
        100000 + Random.secure().nextInt(89999),
      ),
      'body': {
        'clientId': WopanProtocol.webClientId,
        'param': WopanProtocol.encrypt(
          {
            'clientSecret': WopanProtocol.webClientSecret,
            'phone': challenge.mobile,
            'smsCode': code,
          },
          'api-user',
          '',
          client: WopanProtocol.webClientId,
        ),
      },
    });
    final tokens = WopanProtocol.decode(
      rsp['DATA'],
      'api-user',
      '',
      client: WopanProtocol.webClientId,
    );
    final fields = WebTokens.fields(CloudPlatform.wopan, jsonEncode(tokens));
    require(
      WebTokens.validToken(fields['accessToken'] ?? '') &&
          WebTokens.validToken(fields['refreshToken'] ?? ''),
      '联通云盘未返回有效登录凭据，请重试或切换网页登录',
    );
    final seconds = tokens.integer('expires_in', tokens.integer('expiresIn'));
    return Credential('联通云盘', {
      ...fields,
      'clientId': WopanProtocol.webClientId,
      'username': challenge.mobile,
      if (!fields.containsKey('expiresAt') && seconds > 0)
        'expiresAt': '${now() + seconds * 1000}',
    }, updatedAt: now());
  }
}
