import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/parser_rules/password_document.dart';
import 'package:asterlink/data/parser_rules/password_web_flow.dart';
import 'package:asterlink/data/parser_rules/rule.dart';
import 'support.dart';

class _DocumentHttp extends FakeHttp {
  _DocumentHttp(super.respond);
  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) {
    expect(followRedirects, false);
    return super.request(method, url, body: body, headers: headers);
  }
}

void main() {
  final flow = ParserPasswordWebFlow.fromJson({
    'schema': 1,
    'url': 'https://password.example/',
    'allowedHosts': ['password.example'],
    'script': 'return {status:"waiting"};',
  });

  test(
    'public HTML retains origin and security headers without session data',
    () async {
      final http = _DocumentHttp(
        (_) => const HttpResult(200, '<!doctype html>取密页面', {
          'Content-Type': ['text/html; charset="UTF-8"'],
          'Content-Length': ['1'],
          'Content-Encoding': ['gzip'],
          'Transfer-Encoding': ['chunked'],
          'Connection': ['keep-alive'],
          'Cache-Control': ['public, max-age=3600'],
          'Content-Security-Policy': [
            "default-src 'self'",
            "frame-src https://challenges.cloudflare.com",
          ],
          'Referrer-Policy': ['same-origin'],
        }),
      );
      final document = await ParserPasswordDocument.load(
        flow,
        http,
        'browser-ua',
      );
      final request = http.calls.single;
      expect(request.method, 'GET');
      expect(request.url, flow.url);
      expect(request.body, null);
      expect(request.headers['User-Agent'], 'browser-ua');
      expect(request.headers['Origin'], 'https://password.example');
      expect(
        request.headers.keys.map((e) => e.toLowerCase()),
        isNot(anyOf(contains('cookie'), contains('authorization'))),
      );
      expect(utf8.decode(document.data), '<!doctype html>取密页面');
      expect(document.headers['content-type'], 'text/html; charset=utf-8');
      expect(document.headers['cache-control'], 'no-store');
      expect(
        document.headers['content-security-policy'],
        "default-src 'self', frame-src https://challenges.cloudflare.com",
      );
      expect(document.headers['referrer-policy'], 'same-origin');
      for (final key in [
        'content-length',
        'content-encoding',
        'transfer-encoding',
        'connection',
      ]) {
        expect(document.headers, isNot(contains(key)));
      }
      expect(
        document.matches(Uri.parse(flow.url), mainFrame: true, method: 'GET'),
        true,
      );
      for (final sample in [
        (flow.url, false, 'GET'),
        (flow.url, true, 'POST'),
        (flow.url, true, ''),
        ('https://password.example/?nonce=new', true, 'GET'),
        ('https://password.example/next', true, 'GET'),
        ('https://challenges.cloudflare.com/', true, 'GET'),
        ('http://password.example/', true, 'GET'),
      ]) {
        expect(
          document.matches(
            Uri.parse(sample.$1),
            mainFrame: sample.$2,
            method: sample.$3,
          ),
          false,
        );
      }
    },
  );

  test(
    'redirects, challenges, cookies and non-UTF8 documents are rejected',
    () async {
      final samples = [
        const HttpResult(302, '', {
          'content-type': ['text/html'],
          'location': ['https://other.example/'],
        }),
        const HttpResult(403, 'blocked', {
          'content-type': ['text/html'],
        }),
        const HttpResult(200, 'challenge', {
          'content-type': ['text/html'],
          'CF-Mitigated': ['challenge'],
        }),
        const HttpResult(200, 'cookie', {
          'content-type': ['text/html'],
          'Set-Cookie': ['session=secret'],
        }),
        const HttpResult(200, '{}', {
          'content-type': ['application/json'],
        }),
        const HttpResult(200, 'x', {
          'content-type': ['text/htmlx'],
        }),
        const HttpResult(200, 'x', {
          'content-type': ['text/html; charset=GBK'],
        }),
        const HttpResult(200, 'x', {
          'content-type': ['text/html; charset="utf-16"'],
        }),
      ];
      for (final response in samples) {
        final http = _DocumentHttp((_) => response);
        await expectLater(
          ParserPasswordDocument.load(flow, http, 'browser-ua'),
          throwsA(
            isA<ParserRuleError>().having(
              (e) => e.code,
              'code',
              'RULE_BROWSER',
            ),
          ),
        );
        expect(http.calls, hasLength(1));
      }
    },
  );

  test(
    'the HTML limit counts UTF8 bytes and cancellation discards late content',
    () async {
      final large = _DocumentHttp(
        (_) => HttpResult(200, '字' * 349526, {
          'content-type': ['text/html'],
        }),
      );
      await expectLater(
        ParserPasswordDocument.load(flow, large, 'browser-ua'),
        throwsA(
          isA<ParserRuleError>().having((e) => e.code, 'code', 'RULE_RESPONSE'),
        ),
      );
      final pending = Completer<HttpResult>();
      final scope = RequestScope(), http = _DocumentHttp((_) => pending.future);
      final result = scope.run(
        () => ParserPasswordDocument.load(flow, http, 'browser-ua'),
      );
      final check = expectLater(
        result,
        throwsA(
          isA<AppException>().having((e) => e.message, 'message', '请求已取消'),
        ),
      );
      scope.cancel();
      await check;
      pending.complete(
        const HttpResult(200, 'late-secret', {
          'content-type': ['text/html'],
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(http.calls, hasLength(1));
      await expectLater(
        scope.run(() => ParserPasswordDocument.load(flow, http, 'browser-ua')),
        throwsA(isA<AppException>()),
      );
      expect(http.calls, hasLength(1));
    },
  );
}
