import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/sources/host.dart';
import 'package:asterlink/data/sources/package.dart';
import 'package:asterlink/data/sources/runtime.dart';
import 'source_runtime_test.dart' show sourceFixture;
import 'source_support.dart' show hasSourceNative;

void main() {
  test('Host rejects private, loopback, mapped and non-routable targets', () {
    for (final ip in [
      '127.0.0.1',
      '10.0.0.1',
      '192.168.1.1',
      '172.16.0.1',
      '169.254.169.254',
      '100.64.0.1',
      '0.0.0.0',
      '::1',
      'fc00::1',
      'fe80::1',
      '::ffff:127.0.0.1',
      '2001:db8::1',
    ]) {
      expect(SourceHost.publicAddress(InternetAddress(ip)), false, reason: ip);
    }
    for (final ip in ['8.8.8.8', '1.1.1.1', '2606:4700:4700::1111']) {
      expect(SourceHost.publicAddress(InternetAddress(ip)), true);
    }
  });
  test('Host methods, domains and header names require declarations', () async {
    final package = SourcePackage.fromJson(
      sourceFixture('export function resolve(){}'),
    );
    expect(
      () => package.checkedUrl('https://example.com@elsewhere.com'),
      throwsA(isA<SourceError>()),
    );
    expect(
      () => package.checkedUrl('https://example.com:5000'),
      throwsA(isA<SourceError>()),
    );
    expect(
      () => package.checkedHeaders({'X-Sign': 'one', 'x-sign': 'two'}),
      throwsA(isA<SourceError>()),
    );
    await expectLater(
      SourceHost.request(package, {
        'url': 'https://example.com/x',
        'method': 'DELETE',
      }),
      throwsA(isA<SourceError>()),
    );
    await expectLater(
      SourceHost(package).call('filesystem', {}),
      throwsA(isA<SourceError>()),
    );
  });
  group('HTTP wire behavior', () {
    late HttpServer server;
    late SourcePackage source;
    final recorded = <Json>[];
    HttpClient client() =>
        HttpClient()
          ..connectionFactory = (uri, _, _) =>
              Socket.startConnect(InternetAddress.loopbackIPv4, server.port);
    Future<Json> fetch(Json options) => SourceHost.request(source, {
      'url': 'http://origin.example.com/echo',
      ...options,
    }, clientFactory: client);
    setUp(() async {
      recorded.clear();
      final raw = sourceFixture('export function resolve(){}');
      raw['permissions'] = {
        'hosts': ['origin.example.com', 'cdn.example.net'],
        'downloadHosts': ['files.example.com'],
        'schemes': ['http'],
        'methods': ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS'],
        'headers': ['X-Sign', 'Cookie', 'Content-Type'],
      };
      source = SourcePackage.fromJson(raw);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final body = await request.fold<List<int>>([], (a, b) => a..addAll(b));
        recorded.add({
          'method': request.method,
          'host': request.headers.host,
          'body': body,
          'contentType': request.headers.value('content-type'),
          'cookie': request.headers.value('cookie'),
          'sign': request.headers.value('x-sign'),
        });
        switch (request.uri.path) {
          case '/redirect':
            request.response.statusCode = 302;
            request.response.headers.set(
              'Location',
              'http://cdn.example.net/echo',
            );
          case '/bad-redirect':
            request.response.statusCode = 302;
            request.response.headers.set(
              'Location',
              'http://other.example.org/echo',
            );
          case '/large':
            request.response.add(List.filled(524289, 65));
          case '/gbk':
            request.response.headers.set(
              'Content-Type',
              'text/plain;charset=gbk',
            );
            request.response.add([0xd6, 0xd0, 0xce, 0xc4]);
          case '/binary':
            request.response.headers.set(
              'Content-Type',
              'application/octet-stream;charset=gb18030',
            );
            request.response.add([0, 255, 128, 1]);
          default:
            request.response.write('ok');
        }
        await request.response.close();
      });
    });
    tearDown(() async {
      await server.close(force: true);
    });
    test(
      'All declared methods execute and request bodies preserve content types',
      () async {
        for (final method in [
          'GET',
          'POST',
          'PUT',
          'PATCH',
          'DELETE',
          'HEAD',
          'OPTIONS',
        ]) {
          expect((await fetch({'method': method})).integer('status'), 200);
        }
        await fetch({
          'method': 'PUT',
          'encoding': 'json',
          'body': {'文本': 'a b'},
        });
        expect(jsonDecode(utf8.decode(recorded.last['body'].cast<int>())), {
          '文本': 'a b',
        });
        await fetch({
          'method': 'POST',
          'encoding': 'form',
          'body': {'q': 'a & 中'},
        });
        expect(
          Uri.splitQueryString(utf8.decode(recorded.last['body'].cast<int>())),
          {'q': 'a & 中'},
        );
        await fetch({
          'method': 'PATCH',
          'encoding': 'text',
          'headers': {'Content-Type': 'application/graphql'},
          'body': 'query { test }',
        });
        expect(recorded.last['contentType'], 'application/graphql');
        await fetch({
          'method': 'POST',
          'encoding': 'base64',
          'body': base64Encode([0, 255, 1]),
        });
        expect(recorded.last['body'], [0, 255, 1]);
      },
    );
    test(
      'Multipart encodes fields and binary file parts with a matching boundary',
      () async {
        await fetch({
          'method': 'POST',
          'encoding': 'multipart',
          'body': {
            'fields': {'caption': '中文内容'},
            'files': [
              {
                'name': 'part',
                'fileName': 'a.bin',
                'base64': base64Encode([0, 1, 2, 255]),
              },
            ],
          },
        });
        final type = ContentType.parse(recorded.last.str('contentType'));
        final bytes = (recorded.last['body'] as List).cast<int>();
        final wire = latin1.decode(bytes);
        expect(type.mimeType, 'multipart/form-data');
        expect(wire, startsWith('--${type.parameters['boundary']}\r\n'));
        expect(wire, contains('filename="a.bin"'));
        expect(bytes, containsAllInOrder([0, 1, 2, 255]));
        await expectLater(
          fetch({
            'method': 'POST',
            'encoding': 'multipart',
            'body': {
              'files': [
                {'name': 'bad\r\nHeader', 'fileName': 'a', 'base64': ''},
              ],
            },
          }),
          throwsA(isA<SourceError>()),
        );
      },
    );
    test('Cross-origin redirects drop credential and custom headers', () async {
      await fetch({
        'url': 'http://origin.example.com/redirect',
        'redirects': true,
        'headers': {'Cookie': 'test-cookie', 'X-Sign': 'test-token'},
      });
      expect(recorded, hasLength(2));
      expect(recorded.first['sign'], 'test-token');
      expect(recorded.last['sign'], isNull);
      expect(recorded.last['cookie'], isNull);
      await expectLater(
        fetch({
          'url': 'http://origin.example.com/bad-redirect',
          'redirects': true,
        }),
        throwsA(isA<SourceError>()),
      );
    });
    test(
      'Large responses are bounded, GBK decodes and binary avoids charset decoding',
      () async {
        await expectLater(
          fetch({'url': 'http://origin.example.com/large'}),
          throwsA(
            isA<SourceError>().having((e) => e.code, 'code', 'SOURCE_RESPONSE'),
          ),
        );
        expect(
          (await fetch({'url': 'http://origin.example.com/gbk'})).str('text'),
          '中文',
        );
        expect(
          (await fetch({
            'url': 'http://origin.example.com/binary',
            'binary': true,
          })).str('base64'),
          base64Encode([0, 255, 128, 1]),
        );
        await expectLater(
          fetch({'url': 'http://origin.example.com/binary'}),
          throwsA(
            isA<SourceError>().having((e) => e.code, 'code', 'SOURCE_CHARSET'),
          ),
        );
      },
    );
  });
  test(
    'The whole-operation deadline also terminates an unresolved host request',
    () async {
      final raw = sourceFixture(
        "export async function resolve(input,api){return await api.request({url:'https://example.com/share/a'});}",
      )..['timeout'] = 1;
      final package = SourcePackage.fromJson(raw), pending = Completer<Json>();
      final host = SourceHost(package, fetch: (_, _) => pending.future),
          clock = Stopwatch()..start();
      await expectLater(
        const SourceRuntime().run(package, 'resolve', {}, host.call),
        throwsA(
          isA<SourceError>().having((e) => e.code, 'code', 'SOURCE_TIMEOUT'),
        ),
      );
      expect(clock.elapsedMilliseconds, lessThan(2500));
    },
    skip: !hasSourceNative,
  );
  test('Cancelling CPU work leaves the caller responsive', () async {
    final package = SourcePackage.fromJson(
      sourceFixture('export function resolve(){while(true){}}'),
    );
    final scope = RequestScope(), clock = Stopwatch()..start();
    final task = scope.run(
      () => const SourceRuntime().run(
        package,
        'resolve',
        {},
        SourceHost(package).call,
      ),
    );
    final check = expectLater(task, throwsA(isA<AppException>()));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    scope.cancel();
    await check;
    expect(clock.elapsedMilliseconds, lessThan(1500));
  }, skip: !hasSourceNative);
}
