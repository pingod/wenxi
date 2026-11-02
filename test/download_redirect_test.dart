import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/download/transfer_http.dart';

class _Network extends HttpOverrides {}

void main() {
  test(
    'Download probe keeps custom UA, signed Referer and Range across CDN redirects',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final headers = <Map<String, String?>>[];
      server.listen((request) async {
        headers.add({
          for (final name in ['user-agent', 'referer', 'range'])
            name: request.headers.value(name),
        });
        if (request.uri.path != '/file') {
          await request.response.redirect(
            Uri.parse(request.uri.path == '/start' ? '/cdn' : '/file'),
          );
          return;
        }
        request.response
          ..statusCode = 206
          ..headers.set('content-range', 'bytes 0-0/1024')
          ..contentLength = 1
          ..add([42]);
        await request.response.close();
      });
      final http = TransferHttp();
      try {
        final probe = await http.probe(
          'http://127.0.0.1:${server.port}/start',
          {
            'User-Agent': 'pan.baidu.com',
            'Referer': 'https://www.aliyundrive.com/',
          },
        );
        expect(probe.identity.total, 1024);
        expect(probe.rangeSupported, isTrue);
        expect(
          headers,
          List.filled(3, {
            'user-agent': 'pan.baidu.com',
            'referer': 'https://www.aliyundrive.com/',
            'range': 'bytes=0-0',
          }),
        );
      } finally {
        http.dio.close(force: true);
        await server.close(force: true);
      }
    }, _Network()),
  );

  test(
    'Concurrent redirects retain each request UA and the Dart default',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final baseline = HttpClient();
      final defaultUa = baseline.userAgent!;
      baseline.close(force: true);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/start') {
          await request.response.redirect(Uri.parse('/file'));
          return;
        }
        request.response.write(request.headers.value('user-agent') ?? '');
        await request.response.close();
      });
      final http = TransferHttp();
      try {
        final url = 'http://127.0.0.1:${server.port}/start';
        expect(
          await Future.wait([
            http.text(url, {'User-Agent': 'pan.baidu.com'}),
            http.text(url, {'user-agent': 'quark-download-fixture'}),
            http.text(url, {}),
          ]),
          ['pan.baidu.com', 'quark-download-fixture', defaultUa],
        );
        expect(await http.text(url, {}), defaultUa);
      } finally {
        http.dio.close(force: true);
        await server.close(force: true);
      }
    }, _Network()),
  );

  test(
    'Cross-host download redirect still removes Cookie and Authorization',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final credentials = <Map<String, String?>>[];
      server.listen((request) async {
        credentials.add({
          'cookie': request.headers.value('cookie'),
          'authorization': request.headers.value('authorization'),
        });
        if (request.uri.path == '/start') {
          await request.response.redirect(Uri.parse('/same-host'));
        } else if (request.uri.path == '/same-host') {
          await request.response.redirect(
            Uri.parse('http://127.0.0.1:${server.port}/file'),
          );
        } else {
          request.response.write(request.headers.value('user-agent') ?? '');
          await request.response.close();
        }
      });
      final http = TransferHttp();
      try {
        expect(
          await http.text('http://localhost:${server.port}/start', {
            'User-Agent': 'download-fixture',
            'Cookie': 'session=fixture',
            'Authorization': 'Bearer fixture',
          }),
          'download-fixture',
        );
        expect(credentials, [
          {'cookie': 'session=fixture', 'authorization': 'Bearer fixture'},
          {'cookie': 'session=fixture', 'authorization': 'Bearer fixture'},
          {'cookie': null, 'authorization': null},
        ]);
      } finally {
        http.dio.close(force: true);
        await server.close(force: true);
      }
    }, _Network()),
  );
}
