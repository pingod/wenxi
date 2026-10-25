import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/c139.dart' show C139Protocol;
import 'package:asterlink/data/providers/wopan.dart' show WopanProtocol;
import 'package:asterlink/data/resource_link_checks.dart';
import 'package:asterlink/data/resource_link_probe.dart';
import 'resource_link_check_support.dart';
import 'support.dart';

HttpResult _quark(Object data) =>
    jsonResponse({'status': 200, 'code': 0, 'data': data});
HttpResult _data(Object data) => jsonResponse({'code': 0, 'data': data});

Future<(ResourceLinkHealth, FakeHttp)> _probe(
  String url,
  List<HttpResult> responses, {
  String password = 'aB12',
}) async {
  var next = 0;
  final http = FakeHttp((_) {
    expect(
      next,
      lessThan(responses.length),
      reason: 'unexpected extra request',
    );
    return responses[next++];
  });
  final api = LocalResourceLinkCheckApi(
    http: http,
    clock: () => DateTime(2026, 10, 22, 16, 30),
  );
  try {
    final result = await api.check(
      probeHit('sample', url: url, password: password),
      CancelToken(),
    );
    expect(next, responses.length);
    expect(result.checkedAt, DateTime(2026, 10, 22, 16, 30));
    for (final call in http.calls) {
      expect(call.uri.scheme, 'https');
      expect(
        call.headers.keys.map((h) => h.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(call.url, isNot(contains('/api/v1/link/check')));
      expect(call.uri.host, isNot('111.91.22.90'));
    }
    return (result, http);
  } finally {
    api.dispose();
  }
}

void main() {
  for (final (name, url, responses) in <(String, String, List<HttpResult>)>[
    (
      'Quark',
      'https://pan.quark.cn/s/book1',
      [
        _quark({'stoken': 'public-stoken'}),
        _quark({
          'list': [
            {'fid': 'f1'},
          ],
        }),
      ],
    ),
    (
      'UC',
      'https://drive.uc.cn/s/book2',
      [
        _quark({'stoken': 'public-stoken'}),
        _quark({
          'list': [
            {'fid': 'f1'},
          ],
        }),
      ],
    ),
    (
      'Baidu',
      'https://pan.baidu.com/s/1book3',
      [
        jsonResponse({'errno': 0, 'randsk': 'public%2Fkey'}),
        jsonResponse({
          'errno': 0,
          'list': [
            {'fs_id': 123},
          ],
        }),
      ],
    ),
    (
      'Aliyun',
      'https://www.alipan.com/s/abc123',
      [
        jsonResponse({'share_token': 'public-token'}),
        jsonResponse({
          'items': [
            {'file_id': 'f1'},
          ],
        }),
      ],
    ),
    (
      'Aliyun fast transfer',
      'https://www.alipan.com/t/abc123',
      [
        jsonResponse({
          'share_id': 'abc123',
          'preview_file_list': [
            {'file_id': 'f1'},
          ],
        }),
      ],
    ),
    (
      '123',
      'https://www.123pan.com/s/abcdef-123',
      [
        _data({
          'InfoList': [
            {'FileId': 123},
          ],
          'Expired': false,
          'HasPwd': true,
        }),
      ],
    ),
    (
      'Tianyi',
      'https://cloud.189.cn/t/abcdef',
      [
        jsonResponse({'fileId': '100', 'fileName': '资料', 'needAccessCode': 1}),
        jsonResponse({'shareId': '200'}),
      ],
    ),
    (
      '115',
      'https://115cdn.com/s/book115',
      [
        jsonResponse({
          'state': true,
          'data': {
            'list': [
              {'fid': 'f1'},
            ],
          },
        }),
      ],
    ),
    (
      'Guangya',
      'https://www.guangyapan.com/s/book1',
      [
        _data({'accessToken': 'public-token'}),
        _data({
          'files': [
            {'fileId': 'f1'},
          ],
        }),
      ],
    ),
    (
      'Xunlei',
      'https://pan.xunlei.com/s/book1',
      [
        jsonResponse({
          'share_status': 'OK',
          'files': [
            {'id': 'f1'},
          ],
        }),
      ],
    ),
  ]) {
    test(
      '$name reads public share metadata/files directly from the netdisk',
      () async {
        final (health, http) = await _probe(url, responses);
        expect(health.state, ResourceLinkState.valid);
        expect(
          http.calls.map((c) => c.url).join(' '),
          isNot(matches(r'/save|/transfer/|/download|search/open')),
        );
        if (name == 'Quark' || name == 'UC') {
          expect(http.calls.first.json['passcode'], 'aB12');
          expect(
            http.calls.last.uri.queryParameters['stoken'],
            'public-stoken',
          );
        }
        if (name == 'Baidu') {
          expect(
            Uri.splitQueryString(http.calls.first.body as String)['pwd'],
            'aB12',
          );
          expect(http.calls.last.headers['Cookie'], 'BDCLND=public%2Fkey');
        }
        if (name == '123') {
          expect(http.calls.single.uri.queryParameters['SharePwd'], 'aB12');
        }
        if (name == 'Tianyi') {
          expect(http.calls.last.uri.queryParameters['accessCode'], 'aB12');
        }
        if (name == 'Guangya') expect(http.calls.first.json['code'], 'aB12');
      },
    );
  }

  test(
    'mobile cloud uses the existing anonymous wire protocol and checks actual file entries',
    () async {
      final payload = {
        'resultCode': '0',
        'data': {
          'getOutLinkInfoResp': {
            'coLst': [
              {'coID': 'f1'},
            ],
            'caLst': [],
          },
        },
      };
      final (health, http) = await _probe(
        'https://yun.139.com/shareweb/#/w/i/book139',
        [HttpResult(200, C139Protocol.encrypt(jsonEncode(payload)))],
      );
      expect(health.state, ResourceLinkState.valid);
      final body = asJson(
        jsonDecode(C139Protocol.decrypt(http.calls.single.body as String)),
      ).obj('getOutLinkInfoReq');
      expect(body['linkID'], 'book139');
      expect(body['passwd'], 'aB12');
      expect(body['account'], '');
      expect(body['eNum'], 1);
    },
  );

  test(
    'Unicom resolves only official short links, reads the share and does not log in',
    () async {
      final (health, http) = await _probe('https://pan.wo.cn/s/short', [
        const HttpResult(302, '', {
          'location': [
            'https://panservice.mail.wo.cn/h5/wocloudshare/#/share?shareId=long&clientId=1001000021',
          ],
        }),
        jsonResponse({
          'STATUS': '200',
          'RSP': {
            'RSP_CODE': '0000',
            'DATA': [
              {'id': 'f1'},
            ],
          },
        }),
      ]);
      expect(health.state, ResourceLinkState.valid);
      expect(http.calls.first.uri.host, 'panservice.mail.wo.cn');
      final body = http.calls.last.json.obj('body');
      final param = asJson(
        WopanProtocol.decodeValue(body['param'], 'api-user', ''),
      );
      expect(param, {'shareId': 'long', 'shareCode': 'aB12'});
      expect(http.calls.last.uri.path, '/wohome/dispatcher');
    },
  );

  test(
    'Unicom does not follow redirects to another host or nonstandard port',
    () async {
      for (final target in [
        'https://example.com/share',
        'https://pan.wo.cn:444/share',
        'file:///tmp/share',
      ]) {
        final (health, http) = await _probe('https://pan.wo.cn/s/short', [
          HttpResult(302, '', {
            'location': [target],
          }),
        ]);
        expect(health.state, ResourceLinkState.unknown);
        expect(http.calls, hasLength(1));
      }
    },
  );

  for (final (name, url, responses, state, password)
      in <(String, String, List<HttpResult>, ResourceLinkState, String)>[
        (
          'Quark missing code',
          'https://pan.quark.cn/s/book1',
          [
            jsonResponse({'code': 41008}),
          ],
          ResourceLinkState.locked,
          '',
        ),
        (
          'Quark cancelled share',
          'https://pan.quark.cn/s/book1',
          [
            jsonResponse({'code': 41001, 'message': '分享已被取消'}),
          ],
          ResourceLinkState.invalid,
          '',
        ),
        (
          'Quark missing token',
          'https://pan.quark.cn/s/book1',
          [_quark({})],
          ResourceLinkState.unknown,
          '',
        ),
        (
          'Quark unknown error',
          'https://pan.quark.cn/s/book1',
          [
            jsonResponse({'code': 99999, 'message': '服务器繁忙'}),
          ],
          ResourceLinkState.unknown,
          '',
        ),
        (
          'Quark empty files',
          'https://pan.quark.cn/s/book1',
          [
            _quark({'stoken': 'token'}),
            _quark({'list': []}),
          ],
          ResourceLinkState.invalid,
          '',
        ),
        (
          'Quark missing files',
          'https://pan.quark.cn/s/book1',
          [
            _quark({'stoken': 'token'}),
            _quark({}),
          ],
          ResourceLinkState.unknown,
          '',
        ),
        (
          'Quark invalid entries',
          'https://pan.quark.cn/s/book1',
          [
            _quark({'stoken': 'token'}),
            _quark({
              'list': [{}],
            }),
          ],
          ResourceLinkState.unknown,
          '',
        ),
        (
          'Quark captcha with password error text',
          'https://pan.quark.cn/s/book1',
          [
            jsonResponse({'code': 41008, 'message': '提取码验证需要验证码'}),
          ],
          ResourceLinkState.unknown,
          '',
        ),
        (
          'Baidu extraction code',
          'https://pan.baidu.com/s/1book3',
          [
            jsonResponse({'errno': -9}),
          ],
          ResourceLinkState.locked,
          '',
        ),
        (
          'Baidu login restriction',
          'https://pan.baidu.com/s/1book3',
          [
            jsonResponse({'errno': -6, 'errmsg': '请先登录'}),
          ],
          ResourceLinkState.unknown,
          '',
        ),
        (
          'Baidu wrong code',
          'https://pan.baidu.com/s/1book3',
          [
            jsonResponse({'errno': -12}),
          ],
          ResourceLinkState.locked,
          'bad1',
        ),
        (
          'Aliyun missing share',
          'https://www.alipan.com/s/abc123',
          [
            jsonResponse({'code': 'ShareLink.NotFound'}),
          ],
          ResourceLinkState.invalid,
          '',
        ),
        (
          'Aliyun wrong password',
          'https://www.alipan.com/s/abc123',
          [
            jsonResponse({'code': 'ShareLink.PwdNotMatch'}),
          ],
          ResourceLinkState.locked,
          'bad1',
        ),
        (
          'Aliyun expired access token',
          'https://www.alipan.com/s/abc123',
          [
            jsonResponse({'code': 'AccessToken.Expired'}),
          ],
          ResourceLinkState.unknown,
          '',
        ),
        (
          '123 empty content',
          'https://www.123pan.com/s/abcdef-123',
          [
            _data({'InfoList': []}),
          ],
          ResourceLinkState.invalid,
          '',
        ),
        (
          '123 expired share',
          'https://www.123pan.com/s/abcdef-123',
          [
            _data({'Expired': true}),
          ],
          ResourceLinkState.invalid,
          '',
        ),
        (
          '123 requires password',
          'https://www.123pan.com/s/abcdef-123',
          [
            _data({'HasPwd': '1'}),
          ],
          ResourceLinkState.locked,
          '',
        ),
        (
          '123 wrong password',
          'https://www.123pan.com/s/abcdef-123',
          [
            jsonResponse({'code': 5103, 'message': '提取码错误'}),
          ],
          ResourceLinkState.locked,
          'bad1',
        ),
        (
          'Tianyi public share has a misleading needAccessCode flag',
          'https://cloud.189.cn/t/faERBfyiymum',
          [
            jsonResponse({
              'res_code': 0,
              'shareId': '12355115983046',
              'fileId': '324761192180020670',
              'fileName': '熊出没之重启未来 (2025)',
              'shareType': 1,
              'needAccessCode': 1,
            }),
          ],
          ResourceLinkState.valid,
          '',
        ),
        (
          'Tianyi rejected share',
          'https://cloud.189.cn/t/iuYju2iAzIja',
          [
            jsonResponse({'res_code': 'ShareAuditNotPass'}),
          ],
          ResourceLinkState.invalid,
          '',
        ),
        (
          'Tianyi requires code',
          'https://cloud.189.cn/t/abcdef',
          [
            jsonResponse({
              'fileId': '100',
              'fileName': '资料',
              'needAccessCode': 1,
            }),
          ],
          ResourceLinkState.locked,
          '',
        ),
        (
          'Tianyi expired share',
          'https://cloud.189.cn/t/abcdef',
          [
            jsonResponse({'res_code': 'ShareExpired'}),
          ],
          ResourceLinkState.invalid,
          '',
        ),
        (
          'Tianyi invalid access code',
          'https://cloud.189.cn/t/abcdef',
          [
            jsonResponse({'errorCode': 'AccessCodeError'}),
          ],
          ResourceLinkState.locked,
          '',
        ),
        (
          'Tianyi verification restriction',
          'https://cloud.189.cn/t/abcdef',
          [
            jsonResponse({'errorCode': 'InvalidVerifyCode'}),
          ],
          ResourceLinkState.unknown,
          '',
        ),
        (
          '115 requires password without requesting a login',
          'https://115cdn.com/s/book115',
          [],
          ResourceLinkState.locked,
          '',
        ),
        (
          '115 login required',
          'https://115cdn.com/s/book115',
          [
            jsonResponse({'state': false, 'errno': 99, 'error': '请先登录'}),
          ],
          ResourceLinkState.unknown,
          'aB12',
        ),
        (
          'Guangya cancelled share',
          'https://www.guangyapan.com/s/book1',
          [
            jsonResponse({'code': 200}),
          ],
          ResourceLinkState.invalid,
          '',
        ),
        (
          'Guangya incorrect password',
          'https://www.guangyapan.com/s/book1',
          [
            jsonResponse({'code': 209}),
          ],
          ResourceLinkState.locked,
          '',
        ),
        (
          'Xunlei removed share',
          'https://pan.xunlei.com/s/book1',
          [
            jsonResponse({'share_status': 'DELETED'}),
          ],
          ResourceLinkState.invalid,
          '',
        ),
        (
          'Xunlei verification required',
          'https://pan.xunlei.com/s/book1',
          [
            jsonResponse({'error': 'captcha_invalid'}),
          ],
          ResourceLinkState.unknown,
          '',
        ),
        (
          'Quark expired share credential is not an expired share',
          'https://pan.quark.cn/s/book1',
          [
            jsonResponse({'code': 99999, 'message': '分享访问令牌已过期'}),
          ],
          ResourceLinkState.unknown,
          '',
        ),
        (
          'Quark message mentioning a share that has not expired is not a dead link',
          'https://pan.quark.cn/s/book1',
          [
            jsonResponse({'code': 99999, 'message': '链接未过期，服务繁忙'}),
          ],
          ResourceLinkState.unknown,
          '',
        ),
        (
          'Quark explicit expiration takes precedence over returned files',
          'https://pan.quark.cn/s/book1',
          [
            _quark({'stoken': 'token'}),
            _quark({
              'is_expire': '1',
              'list': [
                {'fid': 'f1'},
              ],
            }),
          ],
          ResourceLinkState.invalid,
          '',
        ),
        (
          'Quark embedded error status is not a successful token',
          'https://pan.quark.cn/s/book1',
          [
            jsonResponse({
              'status': 500,
              'code': 0,
              'data': {'stoken': 'token'},
            }),
          ],
          ResourceLinkState.unknown,
          '',
        ),
        (
          'Tianyi string extraction-code flag is honored',
          'https://cloud.189.cn/t/abcdef',
          [
            jsonResponse({
              'fileId': '100',
              'fileName': '资料',
              'needAccessCode': '1',
            }),
          ],
          ResourceLinkState.locked,
          '',
        ),
        (
          'unknown 404 API response',
          'https://pan.quark.cn/s/book1',
          [jsonResponse({}, 404)],
          ResourceLinkState.unknown,
          '',
        ),
      ]) {
    test('$name is classified conservatively', () async {
      final (health, _) = await _probe(url, responses, password: password);
      expect(health.state, state);
    });
  }

  test('inline provider rate limit is propagated for queue cooldown', () async {
    final http = FakeHttp(
      (_) => jsonResponse({'code': 100011, 'message': '请求频繁'}),
    );
    final api = LocalResourceLinkCheckApi(http: http);
    addTearDown(api.dispose);
    await expectLater(
      api.check(
        probeHit('123', url: 'https://123pan.com/s/abcdef'),
        CancelToken(),
      ),
      throwsA(isA<ResourceLinkCheckLimited>()),
    );
    expect(http.calls, hasLength(1));
  });

  test(
    'unsupported shares, magnets and direct URLs never make network requests',
    () async {
      final http = FakeHttp();
      final api = LocalResourceLinkCheckApi(http: http);
      addTearDown(api.dispose);
      for (final url in [
        'https://example.com/file.zip',
        'https://www.lanzou.com/ibook123',
        'magnet:?xt=urn:btih:1234567890123456789012345678901234567890',
      ]) {
        final result = await api.check(
          probeHit('skip', url: url),
          CancelToken(),
        );
        expect(result.state, ResourceLinkState.unsupported);
      }
      expect(http.calls, isEmpty);
    },
  );

  test(
    'generic HTML, malformed JSON and WAF responses never become valid or invalid',
    () async {
      for (final response in [
        const HttpResult(200, '<html><script>提示：分享已失效</script>UC网盘分享文件</html>'),
        const HttpResult(200, '[]'),
        const HttpResult(200, '{invalid'),
        const HttpResult(403, '{"code":41001,"message":"链接已失效"}'),
        const HttpResult(500, '{"code":41001,"message":"链接已失效"}'),
      ]) {
        final http = FakeHttp((_) => response);
        final api = LocalResourceLinkCheckApi(http: http);
        try {
          await expectLater(
            api.check(probeHit('book1'), CancelToken()),
            throwsA(isA<Exception>()),
          );
          expect(http.calls, hasLength(1));
        } finally {
          api.dispose();
        }
      }
    },
  );
}
