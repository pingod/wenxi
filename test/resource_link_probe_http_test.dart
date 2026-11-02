import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/resource_link_checks.dart';
import 'package:asterlink/data/resource_link_probe.dart';
import 'resource_link_check_support.dart';

Future<void> _server(
  Future<void> Function(HttpRequest) respond,
  Future<void> Function(LocalResourceLinkCheckApi, List<Uri>) action, {
  Duration timeout = const Duration(seconds: 16),
  Duration requestTimeout = const Duration(seconds: 6),
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final originals = <Uri>[];
  server.listen((request) async {
    try {
      await respond(request);
    } on SocketException catch (_) {
      // Cancellation closes the peer socket while the fixture is responding.
    } on HttpException catch (_) {}
  });
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final original = options.uri;
        originals.add(original);
        options.path = original
            .replace(scheme: 'http', host: '127.0.0.1', port: server.port)
            .toString();
        handler.next(options);
      },
    ),
  );
  final api = LocalResourceLinkCheckApi(
    http: DioJsonHttp(client: dio),
    timeout: timeout,
    requestTimeout: requestTimeout,
  );
  try {
    await action(api, originals);
  } finally {
    api.dispose();
    dio.close(force: true);
    await server.close(force: true).timeout(const Duration(seconds: 3));
  }
}

void main() {
  test(
    'real HTTP posts only a public share code then reads one result from the official host',
    () async {
      final paths = <String>[], methods = <String>[];
      final bodies = <String>[];
      final authHeaders = <String?>[];
      await _server(
        (request) async {
          paths.add(request.uri.path);
          methods.add(request.method);
          bodies.add(await utf8.decoder.bind(request).join());
          authHeaders.add(request.headers.value('authorization'));
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'code': 0,
              'data': paths.length == 1
                  ? {'stoken': 'anonymous-token'}
                  : {
                      'list': [
                        {'fid': 'file1'},
                      ],
                    },
            }),
          );
          await request.response.close();
        },
        (api, originals) async {
          final result = await api.check(
            probeHit('book1', password: 'aB12'),
            CancelToken(),
          );
          expect(result.state, ResourceLinkState.valid);
          expect(paths, [
            '/1/clouddrive/share/sharepage/token',
            '/1/clouddrive/share/sharepage/detail',
          ]);
          expect(methods, ['POST', 'GET']);
          expect(jsonDecode(bodies.first), {
            'pwd_id': 'book1',
            'passcode': 'aB12',
            'support_visit_limit_private_share': true,
          });
          expect(
            originals.map((uri) => uri.host),
            everyElement('drive-pc.quark.cn'),
          );
          expect(originals.last.queryParameters['_size'], '1');
          expect(authHeaders, everyElement(isNull));
        },
      );
    },
  );

  test('HTTP 429 is reported once without automatic retries', () async {
    await _server(
      (request) async {
        request.response.statusCode = 429;
        request.response.write('{}');
        await request.response.close();
      },
      (api, originals) async {
        await expectLater(
          api.check(probeHit('limited'), CancelToken()),
          throwsA(isA<ResourceLinkCheckLimited>()),
        );
        expect(originals, hasLength(1));
      },
    );
  });

  test('cancelling before a probe sends no request', () async {
    await _server((request) => request.response.close(), (
      api,
      originals,
    ) async {
      final cancel = CancelToken()..cancel();
      await expectLater(
        api.check(probeHit('cancelled'), cancel),
        throwsA(isA<Exception>()),
      );
      expect(originals, isEmpty);
    });
  });

  test(
    'cancellation aborts an in-flight connection instead of waiting for its response',
    () async {
      final received = Completer<void>(), release = Completer<void>();
      await _server(
        (request) async {
          received.complete();
          await release.future;
          request.response.write('{"code":0,"data":{"stoken":"late-token"}}');
          await request.response.close();
        },
        (api, originals) async {
          final cancel = CancelToken();
          final result = api.check(probeHit('cancelled'), cancel);
          final assertion = expectLater(result, throwsA(isA<Exception>()));
          try {
            await received.future.timeout(const Duration(seconds: 3));
            cancel.cancel();
            await assertion.timeout(const Duration(seconds: 2));
            expect(originals, hasLength(1));
          } finally {
            release.complete();
          }
        },
      );
    },
  );

  test(
    'total deadline cancels a stalled response stream after the token request succeeds',
    () async {
      final release = Completer<void>();
      await _server(
        (request) async {
          request.response.headers.contentType = ContentType.json;
          if (request.uri.path.endsWith('/token')) {
            request.response.write(
              '{"code":0,"data":{"stoken":"public-token"}}',
            );
          } else {
            request.response.bufferOutput = false;
            request.response.write('{"code":0,"data":{"list":[');
            await request.response.flush();
            await release.future;
            request.response.write('{"fid":"late-file"}]}}');
          }
          await request.response.close();
        },
        (api, originals) async {
          final watch = Stopwatch()..start();
          try {
            await expectLater(
              api.check(probeHit('slow'), CancelToken()),
              throwsA(isA<Exception>()),
            ).timeout(const Duration(seconds: 2));
            expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
            expect(originals, hasLength(2));
          } finally {
            release.complete();
          }
        },
        timeout: const Duration(milliseconds: 400),
        requestTimeout: const Duration(seconds: 5),
      );
    },
  );

  test(
    'per-request deadline also aborts stalled headers without a retry',
    () async {
      final release = Completer<void>();
      await _server(
        (request) async {
          await release.future;
          await request.response.close();
        },
        (api, originals) async {
          try {
            await expectLater(
              api.check(probeHit('slow'), CancelToken()),
              throwsA(isA<Exception>()),
            ).timeout(const Duration(seconds: 2));
            expect(originals, hasLength(1));
          } finally {
            release.complete();
          }
        },
        requestTimeout: const Duration(milliseconds: 120),
      );
    },
  );

  test(
    'oversized and malformed responses are rejected without a second request',
    () async {
      for (final body in [
        '<html>分享网盘</html>',
        jsonEncode({
          'code': 0,
          'data': {'stoken': 'x' * (128 * 1024)},
        }),
      ]) {
        await _server(
          (request) async {
            request.response.write(body);
            await request.response.close();
          },
          (api, originals) async {
            await expectLater(
              api.check(probeHit('badresponse'), CancelToken()),
              throwsA(isA<Exception>()),
            );
            expect(originals, hasLength(1));
          },
        );
      }
    },
  );
}
