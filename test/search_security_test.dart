import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/resource_search_api.dart';
import 'package:asterlink/data/search_security.dart';
import 'package:asterlink/domain/resource_search.dart';
import 'support.dart';

void main() {
  const session = 'verified-session-token-with-at-least-32-characters';
  test(
    'plain search verifies then resumes exactly once with a short session',
    () async {
      final http = FakeHttp((call) {
        if (call.uri.path.endsWith('/challenge')) {
          return jsonResponse({
            'success': true,
            'challenge_id': 'one-use',
            'provider': 'builtin',
          });
        }
        if (call.uri.path.endsWith('/verify')) {
          expect(call.json['challenge_id'], 'one-use');
          expect(call.json['answer'], [2, 4, 6]);
          expect(JsonHttp.isReadRequest(call.method, call.url), isFalse);
          return jsonResponse({
            'success': true,
            'token': session,
            'expires_in': 1200,
          });
        }
        if (call.headers['X-Search-Session'] != session) {
          return jsonResponse({
            'success': false,
            'code': 'HUMAN_VERIFICATION_REQUIRED',
          }, 403);
        }
        return jsonResponse({
          'success': true,
          'results': [
            {'title': '资料', 'url': 'https://pan.quark.cn/s/test'},
          ],
        });
      });
      final api = HttpResourceSearchApi(http, endpoint: 'http://search.test');
      var prompts = 0;
      api.security.onVerification = (client, _) async {
        prompts++;
        await client.verify(await client.challenge(), {
          'answer': [2, 4, 6],
        });
        return true;
      };
      expect(
        (await api.search('资料', CancelToken()).single).items,
        hasLength(1),
      );
      expect(prompts, 1);
      expect(http.calls.map((c) => c.uri.path), [
        '/api/v1/search',
        '/api/security/challenge',
        '/api/security/verify',
        '/api/v1/search',
      ]);
      await api.search('资料', CancelToken()).single;
      expect(prompts, 1);
    },
  );

  test(
    'verification rejection never falls back to an unprotected search',
    () async {
      final http = FakeHttp(
        (call) => jsonResponse({
          'success': false,
          'code': 'HUMAN_VERIFICATION_REQUIRED',
        }, 403),
      );
      final api = HttpResourceSearchApi(http, endpoint: 'http://search.test');
      api.security.onVerification = (_, _) async => false;
      await expectLater(
        api.search('资料', CancelToken()).toList(),
        throwsA(isA<AppException>()),
      );
      expect(http.calls, hasLength(1));
    },
  );

  test(
    'a forbidden transfer is resumed only for explicit pre-admission verification',
    () async {
      final http = FakeHttp((call) {
        if (call.uri.path.endsWith('/verify')) {
          return jsonResponse({
            'success': true,
            'token': session,
            'expires_in': 1200,
          });
        }
        if (!call.headers.containsKey('X-Search-Session')) {
          return jsonResponse({'code': 'HUMAN_VERIFICATION_REQUIRED'}, 403);
        }
        return jsonResponse({
          'success': true,
          'data': {
            'mode': 'original',
            'url': 'https://pan.quark.cn/s/test',
            'reason': 'policy_disabled',
          },
        });
      });
      final api = HttpResourceSearchApi(http, endpoint: 'http://search.test');
      api.security.onVerification = (client, _) async {
        await client.verify(
          {'challenge_id': 'nonce'},
          {
            'answer': [1, 2, 3],
          },
        );
        return true;
      };
      final hit = ResourceSearchHit.fromRaw({
        'title': '资料',
        'url': 'https://pan.quark.cn/s/test',
        'open_ticket': 'signed-ticket',
      });
      final result = await api.open(
        hit,
        CancelToken(),
        selection: const ResourceSearchFileSelection(
          fileId: 'file',
          parentId: '',
          name: 'book.pdf',
          size: 100,
        ),
      );
      expect(result.transferred, isFalse);
      expect(
        http.calls.where((c) => c.uri.path.endsWith('/open/file')),
        hasLength(2),
      );
    },
  );

  test(
    'real SSE rejects before streaming, verifies and resumes the same endpoint',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        if (request.uri.path.endsWith('/verify')) {
          await request.drain<void>();
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({'success': true, 'token': session, 'expires_in': 1200}),
          );
        } else if (request.headers.value('X-Search-Session') != session) {
          request.response.statusCode = 403;
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"code":"HUMAN_VERIFICATION_REQUIRED"}');
        } else {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          request.response.write('data: {"type":"complete","results":[]}\n\n');
        }
        await request.response.close();
      });
      final http = DioJsonHttp(
        client: Dio(BaseOptions(validateStatus: (_) => true)),
      );
      final api = HttpResourceSearchApi(
        http,
        endpoint: 'http://127.0.0.1:${server.port}',
      );
      api.security.onVerification = (client, _) async {
        await client.verify(
          {'challenge_id': 'nonce'},
          {
            'answer': [1, 2, 3],
          },
        );
        return true;
      };
      try {
        expect(
          (await api
                  .search('资料', CancelToken())
                  .single
                  .timeout(const Duration(seconds: 5)))
              .complete,
          isTrue,
        );
        expect(paths, [
          '/api/v1/search/stream',
          '/api/security/verify',
          '/api/v1/search/stream',
        ]);
      } finally {
        http.dio.close(force: true);
        await server.close(force: true);
      }
    },
  );

  test(
    'concurrent verification requests share one dialog and cancellation stops the caller',
    () async {
      final http = FakeHttp(
        (_) => jsonResponse({
          'success': true,
          'token': session,
          'expires_in': 1200,
        }),
      );
      final client = SearchSecurityClient(http, 'http://search.test');
      final done = Completer<bool>();
      var prompts = 0;
      client.onVerification = (_, _) {
        prompts++;
        return done.future;
      };
      final first = client.ensure(CancelToken());
      final second = client.ensure(CancelToken());
      await client.verify(
        {'challenge_id': 'nonce'},
        {
          'answer': [1, 2, 3],
        },
      );
      done.complete(true);
      await Future.wait([first, second]);
      expect(prompts, 1);
      final cancelled = CancelToken()..cancel();
      await expectLater(client.ensure(cancelled), throwsA(isA<AppException>()));
      expect(prompts, 1);
    },
  );
}
