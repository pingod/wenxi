import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/resource_search_api.dart';

void main() {
  test('real HTTP stream delivers batches before completion', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final finish = Completer<void>();
    final requested = <String>[];
    server.listen((request) async {
      request.response.bufferOutput = false;
      requested.add(request.uri.path);
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write(
        'data: ${jsonEncode({
          'type': 'update',
          'results': [
            {'title': '电子书', 'url': 'https://pan.quark.cn/s/books', 'password': 'aB12'},
          ],
        })}\n\n',
      );
      await request.response.flush();
      await finish.future;
      request.response.write(
        'data: ${jsonEncode({
          'type': 'complete',
          'results': [
            {'title': '电子书', 'url': 'https://pan.quark.cn/s/books', 'password': 'aB12'},
          ],
        })}\n\n',
      );
      await request.response.close();
    });
    final http = DioJsonHttp(
      client: Dio(BaseOptions(validateStatus: (_) => true)),
    );
    final api = HttpResourceSearchApi(
      http,
      endpoint: 'http://127.0.0.1:${server.port}',
    );
    final token = CancelToken();
    final batches = <bool>[];
    try {
      await for (final batch
          in api.search('电子书', token).timeout(const Duration(seconds: 5))) {
        batches.add(batch.complete);
        expect(batch.items.single.password, 'aB12');
        if (!batch.complete) finish.complete();
      }
      expect(batches, [false, true]);
      expect(requested, ['/api/v1/search/stream']);
    } finally {
      if (!finish.isCompleted) finish.complete();
      token.cancel();
      http.dio.close(force: true);
      await server.close(force: true).timeout(const Duration(seconds: 3));
    }
  });

  test(
    'unsupported SSE falls back once to the ordinary JSON endpoint',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        if (request.uri.path.endsWith('/stream')) {
          request.response.statusCode = 404;
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'success': true,
              'results': [
                {
                  'title': '资料',
                  'url': 'https://pan.quark.cn/s/fallback',
                  'password': '1234',
                },
              ],
            }),
          );
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
      final token = CancelToken();
      try {
        final batch = await api
            .search('资料', token)
            .single
            .timeout(const Duration(seconds: 5));
        expect(batch.complete, isTrue);
        expect(batch.items.single.password, '1234');
        expect(paths, ['/api/v1/search/stream', '/api/v1/search']);
      } finally {
        token.cancel();
        http.dio.close(force: true);
        await server.close(force: true);
      }
    },
  );

  test('HTTP rate limit is shown without retrying another endpoint', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.statusCode = 429;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"success":false,"message":"频率限制"}');
      await request.response.close();
    });
    final http = DioJsonHttp(
      client: Dio(BaseOptions(validateStatus: (_) => true)),
    );
    final api = HttpResourceSearchApi(
      http,
      endpoint: 'http://127.0.0.1:${server.port}',
    );
    final token = CancelToken();
    try {
      await expectLater(
        api.search('资料', token).toList(),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('频繁'),
          ),
        ),
      );
      expect(requests, 1);
    } finally {
      token.cancel();
      http.dio.close(force: true);
      await server.close(force: true);
    }
  });
}
