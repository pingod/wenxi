import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/download_network_policy.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

final _policy = DownloadNetworkPolicy.fromJson({
  'hosts': ['origin.example.com', 'cdn.example.com', '*.files.example.com'],
  'schemes': ['https'],
  'ports': [443],
});

class _RedirectAdapter implements HttpClientAdapter {
  final calls = <RequestOptions>[];
  bool closed = false, forbidden = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    calls.add(options);
    if (calls.length <= 2) {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': [
            forbidden
                ? 'https://outside.example.com/file'
                : calls.length == 1
                ? 'https://cdn.example.com/file'
                : 'https://origin.example.com/final',
          ],
        },
      );
    }
    return ResponseBody.fromString(
      'x',
      206,
      headers: {
        'content-range': ['bytes 0-0/4'],
        'content-length': ['1'],
      },
    );
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }
}

void main() {
  test('Source downloads never downgrade an HTTPS redirect to HTTP', () {
    expect(
      () => DownloadNetworkPolicy.redirectedHeaders(
        Uri.parse('https://origin.example.com/file'),
        Uri.parse('http://cdn.example.com/file'),
        {'Cookie': 'fixture'},
      ),
      throwsA(isA<DownloadNetworkPolicyException>()),
    );
  });
  test(
    'Source download policy survives task persistence and rejects unapproved URLs',
    () {
      final spec = DownloadSpec(
        url: 'https://origin.example.com/file',
        fileName: 'file',
        networkPolicy: _policy,
      );
      final copy = DownloadSpec.fromJson(
        spec.copyWith(relativePath: 'folder').toJson(),
      );
      expect(copy.networkPolicy!.toJson(), _policy.toJson());
      expect(
        _policy.checkedUrl('https://a.files.example.com/file').host,
        'a.files.example.com',
      );
      for (final url in [
        'http://origin.example.com/file',
        'https://origin.example.com:8443/file',
        'https://files.example.com/file',
        'https://origin.example.com.evil.org/file',
        'https://user:pass@origin.example.com/file',
        'https://127.0.0.1/file',
      ]) {
        expect(
          () => _policy.checkedUrl(url),
          throwsA(isA<DownloadNetworkPolicyException>()),
        );
      }
    },
  );

  test(
    'Private and reserved DNS addresses are excluded from source downloads',
    () {
      for (final address in [
        '127.0.0.1',
        '10.1.2.3',
        '172.16.0.1',
        '192.168.1.1',
        '169.254.169.254',
        '100.64.0.1',
        '198.18.0.1',
        '192.0.2.1',
        '224.0.0.1',
        '::1',
        'fc00::1',
        'fe80::1',
        '2001:db8::1',
        '2002::1',
      ]) {
        expect(
          DownloadNetworkPolicy.publicAddress(InternetAddress(address)),
          false,
          reason: address,
        );
      }
      expect(
        DownloadNetworkPolicy.publicAddress(InternetAddress('8.8.8.8')),
        true,
      );
      expect(
        DownloadNetworkPolicy.publicAddress(
          InternetAddress('2606:4700:4700::1111'),
        ),
        true,
      );
    },
  );

  test(
    'Download redirects strip credentials without restoring them on a later hop',
    () async {
      final adapter = _RedirectAdapter();
      final http = TransferHttp(
        restrictedClientFactory: (_) =>
            Dio(BaseOptions(validateStatus: (_) => true))
              ..httpClientAdapter = adapter,
      );
      final result = await http.probeDownload(
        DownloadSpec(
          url: 'https://origin.example.com/file',
          fileName: 'file',
          networkPolicy: _policy,
          headers: {
            'Authorization': 'fixture-token',
            'Cookie': 'fixture=1',
            'X-Token': 'fixture',
            'Referer': 'https://origin.example.com/private',
            'User-Agent': 'source-agent',
          },
        ),
      );
      expect(result.identity.total, 4);
      expect(adapter.calls, hasLength(3));
      expect(adapter.calls.first.headers['Authorization'], 'fixture-token');
      for (final call in adapter.calls.skip(1)) {
        expect(
          call.headers.keys.map((key) => key.toLowerCase()),
          isNot(
            anyOf(
              contains('authorization'),
              contains('cookie'),
              contains('x-token'),
              contains('referer'),
            ),
          ),
        );
        expect(call.headers['User-Agent'], 'source-agent');
        expect(call.headers['Range'], 'bytes=0-0');
      }
      await Future<void>.delayed(Duration.zero);
      expect(adapter.closed, true);
    },
  );

  test(
    'An out-of-policy redirect never reaches the next HTTP request',
    () async {
      final adapter = _RedirectAdapter()..forbidden = true;
      final http = TransferHttp(
        restrictedClientFactory: (_) =>
            Dio(BaseOptions(validateStatus: (_) => true))
              ..httpClientAdapter = adapter,
      );
      await expectLater(
        http.probeDownload(
          DownloadSpec(
            url: 'https://origin.example.com/file',
            fileName: 'file',
            networkPolicy: _policy,
          ),
        ),
        throwsA(isA<DownloadNetworkPolicyException>()),
      );
      expect(adapter.calls, hasLength(1));
      expect(adapter.closed, true);
    },
  );

  test(
    'A source task cannot start on a native component without network policy support',
    () async {
      final directory = await Directory.systemTemp.createTemp('source-policy-');
      final store = StateStore.memory({}), native = FakeNative();
      final engine = GopeedEngine(
        native,
        store,
        Vault(store),
        directory,
        directory,
      );
      try {
        await expectLater(
          engine.begin({
            'id': 'source-policy',
            'url': 'https://origin.example.com/file',
            'networkPolicy': _policy.toJson(),
          }),
          throwsA(isA<Exception>()),
        );
        expect(native.begins, isEmpty);
      } finally {
        await engine.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
