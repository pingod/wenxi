import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/parser_rules/hub.dart';
import 'package:asterlink/data/parser_rules/rule.dart';
import 'package:asterlink/data/parser_rules/workflow.dart';
import 'package:asterlink/data/parser_rules/workflow_expression.dart';

Json fixture(String name) => asJson(
  jsonDecode(File('test/fixtures/parser_rules/$name.json').readAsStringSync()),
);
Matcher code(String value) =>
    isA<ParserRuleError>().having((e) => e.code, 'code', value);
Json clone(Json value) => asJson(jsonDecode(jsonEncode(value)));

class WorkflowHttp extends JsonHttp {
  WorkflowHttp(this.handler);
  final HttpResult Function(
    String method,
    Uri uri,
    Json body,
    Map<String, String> headers,
  )
  handler;
  final calls = <String>[];
  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) async {
    calls.add('$method ${Uri.parse(url).path}');
    return handler(
      method,
      Uri.parse(url),
      body is String ? asJson(jsonDecode(body)) : {},
      headers,
    );
  }
}

HttpResult response(Json data, [int status = 200]) =>
    HttpResult(status, jsonEncode(data));
Json simpleRule() => clone({
  'schema': 1,
  'engine': 4,
  'siteId': 'workflow_test',
  'platform': 'baidu',
  'name': '测试',
  'authMode': 'none',
  'allowedHosts': ['api.example.com'],
  'downloadHosts': ['files.example.com'],
  'operations': {
    'list': {
      'steps': [
        {'id': 'load', 'method': 'GET', 'url': 'https://api.example.com/list'},
      ],
      'result': {
        'list': {r'$ref': 'last.files'},
      },
    },
    'download': {
      'steps': [
        {'id': 'link', 'method': 'GET', 'url': 'https://api.example.com/link'},
      ],
      'result': {
        'fs_id': {r'$ref': 'input.file.fs_id'},
        'urls': [
          {r'$ref': 'last.url'},
        ],
      },
    },
  },
});
Json file() => {
  'fs_id': 'file_1',
  'server_filename': 'sample.zip',
  'size': 12,
  'isdir': 0,
  'path': '/sample.zip',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final data = fixture('workflow-v4');
  for (final vector in data.list('vectors')) {
    test(vector.str('name'), () {
      final expr = WorkflowExpression(data.obj('functions'));
      expect(
        expr.eval(vector['expr'], vector.obj('scope')),
        vector['expected'],
      );
    });
  }
  test('v4 presets execute locally and contain no server adapter', () {
    for (final value in data.obj('rules').values) {
      final rule = ParserRule.fromJson(asJson(value));
      expect(rule.runsOnServer, false);
      expect(rule.requiresPassword, false);
    }
  });
  test('v4 respects a lowercase user-agent supplied by a rule', () async {
    final raw = simpleRule();
    raw['operations']['list']['steps'][0]['headers'] = {
      'user-agent': 'fixture-browser',
    };
    final http = WorkflowHttp((method, uri, body, headers) {
      expect(headers['user-agent'], 'fixture-browser');
      expect(
        headers.keys.where((key) => key.toLowerCase() == 'user-agent'),
        hasLength(1),
      );
      return response({
        'files': [file()],
      });
    });
    await WorkflowEngine(http).execute(
      ParserRule.fromJson(raw),
      'list',
      {},
      password: '',
      device: 'fixture',
    );
  });
  test(
    'RSA public encryption produces a full modulus block and rejects invalid sizes',
    () {
      final public = utf8.decode(
        base64Decode(
          File(
            'test/fixtures/parser_rules/workflow-public-key.txt',
          ).readAsStringSync(),
        ),
      );
      final result = WorkflowExpression({}).eval({
        r'$op': 'rsaEncrypt',
        'args': ['中文 signature', public],
      }, {});
      expect(base64Decode(result as String).length, 256);
      expect(
        () => WorkflowExpression({}).eval({
          r'$op': 'toRadix',
          'args': [1, '18446744073709551632'],
        }, {}),
        throwsA(code('RULE_EXPRESSION')),
      );
    },
  );
  test('real PHP v4 signatures and extended backup verify in App', () {
    final key = File(
      'test/fixtures/parser_rules/workflow-public-key.txt',
    ).readAsStringSync();
    final now = DateTime.utc(2026, 10, 17, 5);
    final bundle = ParserBundle.verify(
      fixture('bundle-workflow'),
      key,
      now: now,
    );
    expect(bundle.sites.length, 2);
    expect(bundle.revision, 400);
    final backup = fixture('backup-workflow');
    expect(
      ParserBundle.verifyBackup(
        {
          ...backup,
          'engines': {'4': backup},
        },
        key,
        now: now,
      ).id,
      bundle.id,
    );
    final altered = clone(fixture('bundle-workflow'));
    final payload = base64Decode(altered.str('payload'))..[100] ^= 1;
    altered['payload'] = base64Encode(payload);
    expect(
      () => ParserBundle.verify(altered, key, now: now),
      throwsA(code('RULE_SIGNATURE')),
    );
  });
  test(
    'Quark workflow submits once, polls dynamic path and fetches selected file',
    () async {
      var polls = 0, downloads = 0;
      final http = WorkflowHttp((method, uri, body, headers) {
        expect(uri.host, 'file.mdx.wang');
        if (uri.path == '/api/q/task') {
          return response({'error': 0, 'token': 'job_1'});
        }
        if (uri.path == '/api/q/task/job_1') {
          return response({
            'error': 0,
            'done': ++polls == 2,
            'phase': polls == 2 ? 'done' : 'queued',
          });
        }
        if (uri.path == '/api/dl2/files') {
          return response({
            'error': 0,
            'files': [
              {
                'fid': 'f1',
                'name': 'sample.zip',
                'rel': 'folder/sample.zip',
                'size': 12,
              },
            ],
          });
        }
        expect(uri.path, '/api/dl2/link');
        expect(body, {'token': 'job_1', 'fid': 'f1'});
        downloads++;
        return response({
          'error': 0,
          'url': 'https://dl.pds.quark.cn/file',
          'puus': 'test_cookie',
        });
      });
      final rule = ParserRule.fromJson(data.obj('rules').obj('mdx_quark'));
      final engine = WorkflowEngine(http, delay: (_) async {});
      final list = await engine.execute(
        rule,
        'list',
        {'url': 'https://pan.quark.cn/s/example', 'pwd': ''},
        password: '',
        device: 'device',
      );
      expect(polls, 2);
      expect(downloads, 0);
      expect(list.list('list').single.str('path'), '/folder/sample.zip');
      final download = await engine.execute(
        rule,
        'download',
        {'file': list.list('list').single, 'state': list['state']},
        password: '',
        device: 'device',
      );
      expect(download.obj('headers').str('Cookie'), '__puus=test_cookie');
      expect(downloads, 1);
      expect(http.calls.where((c) => c == 'POST /api/q/task').length, 1);
    },
  );
  for (final hasSecret in [false, true]) {
    test('Baidu website route works with issued secret=$hasSecret', () async {
      final clock = DateTime.utc(2026, 10, 17, 5);
      var submitted = 0;
      final http = WorkflowHttp((method, uri, body, headers) {
        switch (uri.path) {
          case '/api/session':
            return response({
              'error': 0,
              'token': 'session_token',
              'attest': true,
              'attestMinDwell': 2500,
              if (hasSecret) 'secret': 'test_secret',
              if (hasSecret) 'nonce': 'test_nonce',
            });
          case '/api/fallback/status':
            expect(headers['x-session-token'], 'session_token');
            expect(
              uri.queryParameters['link'],
              'https://pan.baidu.com/s/1example?pwd=abcd',
            );
            return response({'error': 0, 'fallbackMode': true});
          case '/api/pandl/submit':
            expect(headers['x-session-token'], 'session_token');
            expect(
              headers['x-client-sign'],
              hasSecret
                  ? '7cdb227edcb15fed1fd9ac39'
                  : 'd1ccb3af14e47b2eb994e5e6',
            );
            expect(
              body.str('link'),
              'https://pan.baidu.com/s/1example?pwd=abcd',
            );
            submitted++;
            return response({
              'error': 0,
              'token': 'download_token',
              'done': true,
            });
          case '/api/pandl/files':
            return response({
              'error': 0,
              'files': [
                {
                  'fsid': 'f1',
                  'name': 'file.zip',
                  'rel': 'file.zip',
                  'size': 12,
                },
              ],
              'ua': 'test UA',
            });
          default:
            fail('Unexpected request');
        }
      });
      final engine = WorkflowEngine(
        http,
        now: () => clock,
        delay: (d) async {
          fail('Website route must not wait for fixed fingerprint attestation');
        },
      );
      final list = await engine.execute(
        ParserRule.fromJson(data.obj('rules').obj('mdx_convert')),
        'list',
        {'surl': '1example', 'pwd': 'abcd'},
        password: '',
        device: 'device',
      );
      expect(submitted, 1);
      expect(list.obj('state').str('token'), 'download_token');
      expect(http.calls, [
        'GET /api/session',
        'GET /api/fallback/status',
        'POST /api/pandl/submit',
        'GET /api/pandl/files',
      ]);
    });
  }
  test(
    'Baidu route reports a real interaction requirement without retrying it',
    () async {
      final http = WorkflowHttp((method, uri, body, headers) {
        return switch (uri.path) {
          '/api/session' => response({'error': 0, 'token': 'session'}),
          '/api/fallback/status' => response({
            'error': 0,
            'fallbackMode': true,
          }),
          '/api/pandl/submit' => response({'error': 1, 'msg': '需要完成人机验证'}, 403),
          _ => throw StateError('Unexpected request: ${uri.path}'),
        };
      });
      await expectLater(
        WorkflowEngine(http).execute(
          ParserRule.fromJson(data.obj('rules').obj('mdx_convert')),
          'list',
          {'surl': '1example', 'pwd': ''},
          password: '',
          device: 'device',
        ),
        throwsA(code('interaction_required')),
      );
      expect(http.calls, [
        'GET /api/session',
        'GET /api/fallback/status',
        'POST /api/pandl/submit',
      ]);
    },
  );
  test(
    'Baidu conversion preserves file identity and resolves the current temporary ID',
    () async {
      var submitted = 0, fileReads = 0, downloads = 0;
      final http = WorkflowHttp((method, uri, body, headers) {
        switch (uri.path) {
          case '/api/session':
            return response({
              'error': 0,
              'token': 'session',
              'secret': 'secret',
            });
          case '/api/fallback/status':
            return response({'error': 0, 'fallbackMode': true});
          case '/api/pandl/submit':
            return response({'error': 0, 'token': 'task_${++submitted}'});
          case '/api/pandl/files':
            expect(uri.queryParameters['token'], 'task_$submitted');
            fileReads++;
            return response({
              'error': 0,
              'files': [
                {
                  'fsid': 1000 + fileReads,
                  'name': '文件.zip',
                  'rel': submitted == 1 ? 'folder/文件.zip' : '/folder/文件.zip',
                  'size': '12',
                },
                {
                  'fsid': 2000 + fileReads,
                  'name': '文件.zip',
                  'rel': 'other/文件.zip',
                  'size': 12,
                },
              ],
              'ua': 'download UA',
            });
          case '/api/pandl/link':
            expect(method, 'POST');
            expect(fileReads, 3);
            expect(body, {'token': 'task_2', 'fsid': 1003});
            downloads++;
            return response({
              'error': 0,
              'url': 'https://d.pcs.baidu.com/file',
            });
          default:
            fail('Unexpected request: ${uri.path}');
        }
      });
      final rule = ParserRule.fromJson(data.obj('rules').obj('mdx_convert'));
      final engine = WorkflowEngine(http);
      Future<Json> list() => engine.execute(
        rule,
        'list',
        {'surl': '1example', 'pwd': 'abcd'},
        password: '',
        device: 'device',
      );
      final first = await list();
      final second = await list();
      final selected = first.list('list').first;
      expect(submitted, 2);
      expect(selected.str('path'), '/folder/文件.zip');
      expect(selected.str('fs_id'), matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(second.list('list').first.str('fs_id'), selected.str('fs_id'));
      expect(
        first.list('list').last.str('fs_id'),
        isNot(selected.str('fs_id')),
      );
      final download = await engine.execute(
        rule,
        'download',
        {'file': selected, 'state': second['state']},
        password: '',
        device: 'device',
      );
      expect(download.str('fs_id'), selected.str('fs_id'));
      expect(download.str('ua'), 'download UA');
      expect(downloads, 1);
    },
  );
  for (final change in [
    'missing',
    'duplicate',
    'renamed',
    'resized',
    'moved',
  ]) {
    test('Baidu conversion refuses a $change selected file', () async {
      final original = <String, dynamic>{
        'fsid': 1001,
        'name': 'sample.zip',
        'rel': 'folder/sample.zip',
        'size': 12,
      };
      var currentFiles = <Json>[original];
      final http = WorkflowHttp((method, uri, body, headers) {
        switch (uri.path) {
          case '/api/session':
            return response({
              'error': 0,
              'token': 'session',
              'secret': 'secret',
            });
          case '/api/fallback/status':
            return response({'error': 0, 'fallbackMode': true});
          case '/api/pandl/submit':
            return response({'error': 0, 'token': 'task'});
          case '/api/pandl/files':
            return response({'error': 0, 'files': currentFiles});
          default:
            fail('Must not request a download link for an ambiguous file');
        }
      });
      final rule = ParserRule.fromJson(data.obj('rules').obj('mdx_convert'));
      final engine = WorkflowEngine(http);
      final list = await engine.execute(
        rule,
        'list',
        {'surl': '1example', 'pwd': ''},
        password: '',
        device: 'device',
      );
      currentFiles = switch (change) {
        'missing' => [],
        'duplicate' => [
          original,
          {...original, 'fsid': 1002},
        ],
        'renamed' => [
          {...original, 'name': 'renamed.zip'},
        ],
        'resized' => [
          {...original, 'size': 13},
        ],
        'moved' => [
          {...original, 'rel': 'elsewhere/sample.zip'},
        ],
        _ => throw StateError('Unexpected case'),
      };
      await expectLater(
        engine.execute(
          rule,
          'download',
          {'file': list.list('list').single, 'state': list['state']},
          password: '',
          device: 'device',
        ),
        throwsA(code('share_rejected')),
      );
      expect(http.calls.where((c) => c == 'POST /api/pandl/link'), isEmpty);
    });
  }
  test('dynamic domains are checked before issuing a request', () async {
    final json = simpleRule();
    json['operations']['list']['steps'][0]['url'] = {r'$ref': 'input.url'};
    final http = WorkflowHttp(
      (_, _, _, _) => throw StateError('Must not request'),
    );
    await expectLater(
      WorkflowEngine(http).execute(
        ParserRule.fromJson(json),
        'list',
        {'url': 'https://evil.example.net/'},
        password: '',
        device: 'd',
      ),
      throwsA(code('INVALID_RULE')),
    );
    expect(http.calls, isEmpty);
  });
  test(
    'polling never repeats POST and has an explicit attempt limit',
    () async {
      final json = simpleRule();
      json['operations']['list']['steps'][0]['poll'] = {
        'until': false,
        'maxAttempts': 2,
        'intervalMs': 250,
      };
      final http = WorkflowHttp((_, _, _, _) => response({'files': []}));
      await expectLater(
        WorkflowEngine(http, delay: (_) async {}).execute(
          ParserRule.fromJson(json),
          'list',
          {},
          password: '',
          device: 'd',
        ),
        throwsA(code('RULE_BUDGET')),
      );
      expect(http.calls.length, 2);
      json['operations']['list']['steps'][0]['method'] = 'POST';
      expect(() => ParserRule.fromJson(json), throwsA(code('INVALID_RULE')));
    },
  );
  test(
    'explicit fallback catches a failed response without retrying the first request',
    () async {
      final json = simpleRule();
      json['operations']['list']['steps'] = [
        {
          'id': 'primary',
          'method': 'GET',
          'url': 'https://api.example.com/primary',
          'onError': ['RULE_RESPONSE'],
        },
        {
          'id': 'backup',
          'method': 'GET',
          'url': 'https://api.example.com/backup',
          'when': {r'$ref': 'steps.primary.failed'},
        },
      ];
      final http = WorkflowHttp(
        (_, uri, _, _) => uri.path == '/primary'
            ? const HttpResult(200, 'invalid JSON')
            : response({
                'files': [file()],
              }),
      );
      final result = await WorkflowEngine(http).execute(
        ParserRule.fromJson(json),
        'list',
        {},
        password: '',
        device: 'd',
      );
      expect(result.list('list').length, 1);
      expect(http.calls.length, 2);
    },
  );
  test(
    'response headers can supply an isolated declared origin session',
    () async {
      final json = simpleRule();
      json['requestHeaders'] = ['Cookie'];
      json['requestCredentialHosts'] = ['api.example.com'];
      json['operations']['list']['steps'] = [
        {
          'id': 'session',
          'method': 'GET',
          'url': 'https://api.example.com/session',
        },
        {
          'id': 'files',
          'method': 'GET',
          'url': 'https://api.example.com/files',
          'headers': {
            'Cookie': {r'$ref': 'responses.session.headers.x-cookie.0'},
          },
        },
      ];
      final http = WorkflowHttp((_, uri, _, headers) {
        if (uri.path == '/session') {
          return const HttpResult(200, '{}', {
            'x-cookie': ['session=opaque'],
          });
        }
        expect(headers['Cookie'], 'session=opaque');
        return response({
          'files': [file()],
        });
      });
      await WorkflowEngine(http).execute(
        ParserRule.fromJson(json),
        'list',
        {},
        password: '',
        device: 'd',
      );
      json.remove('requestHeaders');
      expect(() => ParserRule.fromJson(json), throwsA(code('INVALID_RULE')));
    },
  );
  test('cancellation stops waiting and prevents the next poll', () async {
    final json = simpleRule();
    json['operations']['list']['steps'][0]['poll'] = {
      'until': false,
      'intervalMs': 250,
    };
    final scope = RequestScope();
    final waiting = Completer<void>();
    final http = WorkflowHttp((_, _, _, _) => response({'files': []}));
    final engine = WorkflowEngine(
      http,
      delay: (_) {
        waiting.complete();
        return Completer<void>().future;
      },
    );
    final future = scope.run(
      () => engine.execute(
        ParserRule.fromJson(json),
        'list',
        {},
        password: '',
        device: 'd',
      ),
    );
    final expectation = expectLater(
      future,
      throwsA(
        isA<AppException>().having((e) => e.message, 'message', contains('取消')),
      ),
    );
    await waiting.future;
    scope.cancel();
    await expectation;
    expect(http.calls.length, 1);
  });
  test('SSE decoding supports CRLF, multi-line data and terminal markers', () {
    expect(
      WorkflowEngine.decode(
        'sse',
        'data: {"step":\r\ndata: "done"}\r\n\r\ndata: [DONE]\n\n',
      ),
      {
        'events': [
          {'step': 'done'},
        ],
        'last': {'step': 'done'},
      },
    );
  });
  test('JSON nesting is bounded without counting braces in quoted text', () {
    expect(WorkflowExpression.decodeJson(jsonEncode({'text': '["\\' * 100})), {
      'text': '["\\' * 100,
    });
    expect(WorkflowExpression.decodeJson('${'[' * 47}0${']' * 47}'), isList);
    expect(
      () => WorkflowExpression.decodeJson('${'[' * 48}0${']' * 48}'),
      throwsFormatException,
    );
    expect(
      WorkflowExpression({}).eval({
        r'$op': 'slice',
        'args': ['hello', 1, '999999999999999999999'],
      }, {}),
      'ello',
    );
  });
  test(
    'Pagination retains session once, aggregates pages and rejects a stuck cursor',
    () async {
      final json = simpleRule();
      final op = json['operations']['list'] as Json;
      op['steps'] = [
        {
          'id': 'session',
          'method': 'POST',
          'url': 'https://api.example.com/session',
          'when': {
            r'$op': 'eq',
            'args': [
              {r'$ref': 'page.number'},
              1,
            ],
          },
        },
        {
          'id': 'files',
          'method': 'GET',
          'url': 'https://api.example.com/files',
          'query': {
            'page': {r'$ref': 'page.number'},
            'session': {r'$ref': 'steps.session.token'},
          },
        },
      ];
      op['pagination'] = {
        'maxPages': 3,
        'hasMore': {r'$ref': 'last.more'},
        'nextCursor': {r'$ref': 'last.cursor'},
      };
      final http = WorkflowHttp((_, uri, _, _) {
        if (uri.path == '/session') return response({'token': 'one-session'});
        expect(uri.queryParameters['session'], 'one-session');
        final page = int.parse(uri.queryParameters['page']!);
        return response({
          'files': [
            {...file(), 'fs_id': 'file_$page'},
          ],
          'more': page < 3,
          'cursor': 'next-$page',
        });
      });
      final result = await WorkflowEngine(http).execute(
        ParserRule.fromJson(json),
        'list',
        {},
        password: '',
        device: 'd',
      );
      expect(result.list('list').length, 3);
      expect(http.calls.where((call) => call == 'POST /session').length, 1);
      op['pagination']['nextCursor'] = 'stuck';
      await expectLater(
        WorkflowEngine(http).execute(
          ParserRule.fromJson(json),
          'list',
          {},
          password: '',
          device: 'd',
        ),
        throwsA(code('RULE_PAGINATION')),
      );
    },
  );
  test(
    'recursive functions and oversized arithmetic fail within the computation budget',
    () {
      final expr = WorkflowExpression({
        'loop': {
          r'$op': 'call',
          'args': ['loop'],
        },
      });
      expect(
        () => expr.eval({
          r'$op': 'call',
          'args': ['loop'],
        }, {}),
        throwsA(code('RULE_BUDGET')),
      );
      expect(
        () => WorkflowExpression({}).eval({
          r'$op': 'shl',
          'args': [1, 600],
        }, {}),
        throwsA(code('RULE_EXPRESSION')),
      );
      expect(
        () => WorkflowExpression.integer((-(BigInt.one << 512)).toString()),
        throwsA(code('RULE_EXPRESSION')),
      );
    },
  );
}
