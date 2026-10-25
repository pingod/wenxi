import 'dart:async';
import 'dart:convert';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/quark_login.dart';
import 'native_login_support.dart';
import 'support.dart';

const quarkClock = 1792556400000;
QuarkCaptchaProof quarkProof({bool slider = false}) => QuarkCaptchaProof(
  {
    'captcha_data': slider ? 'fixture-slider-proof' : 'fixture-captcha-proof',
    'scene_v2': slider ? 'y9x7vx0s' : '1ml1ondj',
    'nc_scene': 'nvc_login',
    'nc_appkey': 'CF_APP_uc_usercenter',
    'nvc_appkey': 'FFFF0N0000000000ABDE',
    'redirect_uri': 'http://id.uc.cn/',
    'transmission_mode': 'pm',
    'change_uid': '0',
    'origin': '*',
    'sig': '',
    'session_id': '',
    'token': '',
    'key': '',
    'nvc_data': '',
  },
  [
    'security_session=fixture-private; Domain=uop.quark.cn; Path=/; Secure; HttpOnly',
    'captcha_device=fixture-device; Domain=.quark.cn; Path=/; Secure',
  ],
);

Map<String, String> quarkForm(RecordedRequest r) =>
    Uri.splitQueryString(r.body as String);

class QuarkLoginFixture {
  QuarkLoginFixture() {
    http = LoginHttp(respond);
  }
  late final LoginHttp http;
  bool scanned = false, expired = false;
  FutureOr<HttpResult?> Function(RecordedRequest)? override;

  Future<HttpResult> respond(RecordedRequest r) async {
    final replacement = await override?.call(r);
    if (replacement != null) return replacement;
    return switch (r.uri.path) {
      '/cas/custom/login/sendSmsCode' => jsonResponse({'status': 2000000}),
      '/cas/custom/login/commit' => jsonResponse({
        'status': 20000,
        'data': 'fixture-sms-ticket',
      }),
      '/cas/ajax/getTokenForQrcodeLogin' => HttpResult(
        200,
        jsonEncode({
          'status': 2000000,
          'data': {
            'members': {'token': 'fixture-qr-token'},
          },
        }),
        {
          'set-cookie': [
            'qr_session=fixture-qr; Domain=uop.quark.cn; Path=/; Secure',
          ],
        },
      ),
      '/cas/ajax/getServiceTicketByQrcodeToken' => jsonResponse({
        'status': expired
            ? 50004002
            : scanned
            ? 2000000
            : 50004001,
        if (scanned && !expired)
          'data': {
            'members': {'service_ticket': 'fixture-qr-ticket'},
          },
      }),
      '/account/info' => HttpResult(
        200,
        jsonEncode({
          'success': true,
          'data': {'uid': 'fixture-quark-user', 'nickname': '夸克测试账号'},
        }),
        {
          'set-cookie': [
            '__pus=fixture-quark-pus; Domain=.quark.cn; Path=/; Secure; HttpOnly',
          ],
        },
      ),
      '/1/clouddrive/config' => HttpResult(
        200,
        jsonEncode({'status': 200, 'code': 0, 'data': {}}),
        {
          'set-cookie': [
            '__puus=fixture-quark-puus==; Domain=drive-pc.quark.cn; Path=/; Secure; HttpOnly',
          ],
        },
      ),
      '/1/clouddrive/member' => jsonResponse({
        'status': 200,
        'code': 0,
        'data': {
          'nickname': '夸克测试账号',
          'use_capacity': 256,
          'total_capacity': 2048,
        },
      }),
      _ => throw StateError('Unexpected Quark request: ${r.uri.path}'),
    };
  }
}
