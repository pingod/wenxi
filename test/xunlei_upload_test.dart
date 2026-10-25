import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/xunlei.dart';
import 'package:asterlink/data/providers/xunlei_protocol.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:asterlink/domain/xunlei_web_login.dart';
import 'support.dart';

const _session = BrowseSession(
  platform: CloudPlatform.xunlei,
  mode: BrowseMode.personal,
  title: 'files',
  rootId: '',
);

class _Fixture {
  final vault = Vault(StateStore.memory());
  final credential = Credential('fixture', {
    'primary': 'web-access',
    'accessToken': 'web-access',
    'refreshToken': 'web-refresh',
    'clientId': XunleiWebLogin.clientId,
    'authType': 'webToken',
    'deviceId': '0123456789abcdef0123456789abcdef',
    'userId': 'fixture-user',
    'captchaToken': 'expired-captcha',
    // Older releases persisted the Android version for web credentials.
    'clientVersion': XunleiProtocol.version,
  }, updatedAt: 42);
  final bytes = Uint8List.fromList(List.generate(32769, (i) => i % 251));
  late final source = UploadFile(
    name: 'sample.bin',
    size: bytes.length,
    read: (start, end) => Stream.value(bytes.sublist(start, end)),
  );
  Future<CloudFile> upload(FakeHttp http) async {
    await vault.putCredential(CloudPlatform.xunlei, credential);
    return XunleiConnector(
      http,
      vault,
      XunleiDevices(vault),
    ).upload(_session, '', source, credential);
  }

  HttpResult uploadedTask() => jsonResponse({
    'file': {'id': 'uploaded'},
    'upload_type': 'UPLOAD_TYPE_RESUMABLE',
    'resumable': {
      'params': {
        'endpoint': 'https://storage.example',
        'bucket': 'bucket',
        'key': 'object',
        'access_key_id': 'temp-access',
        'access_key_secret': 'temp-secret',
        'security_token': 'temp-session',
      },
    },
  });
  HttpResult listed() => jsonResponse({
    'files': [
      {
        'id': 'uploaded',
        'name': source.name,
        'kind': 'drive#file',
        'size': source.size,
        'phase': 'PHASE_TYPE_COMPLETE',
      },
    ],
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Web captcha signature matches the official JavaScript signing chain',
    () {
      expect(
        XunleiProtocol.webCaptchaSign(
          '0123456789abcdef0123456789abcdef',
          '1792029600000',
        ),
        '1.e9637b7fd49bd387adeac40a3faa97a8',
      );
    },
  );

  for (final error in ['captcha_invalid', 'captcha_required']) {
    test(
      'Web upload renews $error with the web client and retries once',
      () async {
        final f = _Fixture();
        var creates = 0, uploads = 0, refreshes = 0;
        final http = FakeHttp((r) async {
          if (r.uri.path == '/v1/shield/captcha/init') {
            refreshes++;
            expect(r.json['client_id'], XunleiWebLogin.clientId);
            expect(r.json['device_id'], f.credential.field('deviceId'));
            expect(r.json['action'], 'POST:/drive/v1/files');
            expect(r.json['captcha_token'], 'expired-captcha');
            expect(r.json.obj('meta')['package_name'], 'pan.xunlei.com');
            expect(r.json.obj('meta')['client_version'], '1.93.9');
            expect(r.json.obj('meta')['user_id'], 'fixture-user');
            expect(r.json.obj('meta')['captcha_sign'], startsWith('1.'));
            expect(r.json.containsKey('redirect_uri'), isFalse);
            expect(r.headers['Origin'], 'https://pan.xunlei.com');
            return jsonResponse({'captcha_token': 'new-web-captcha'});
          }
          if (r.body is HttpUpload) {
            uploads++;
            expect(r.headers['Authorization'], startsWith('AWS4-HMAC-SHA256 '));
            expect(r.headers['X-Captcha-Token'], isNull);
            expect(
              await (r.body as HttpUpload).open().expand((b) => b).toList(),
              f.bytes,
            );
            return const HttpResult(200, '');
          }
          expect(r.uri.path, '/drive/v1/files');
          if (r.method == 'POST') {
            creates++;
            expect(r.headers['X-Client-Version'], '1.93.9');
            if (creates == 1) {
              return jsonResponse({'error': error, 'error_code': 9}, 400);
            }
            expect(r.headers['X-Captcha-Token'], 'new-web-captcha');
            return f.uploadedTask();
          }
          return f.listed();
        });
        expect((await f.upload(http)).id, 'uploaded');
        expect(creates, 2);
        expect(refreshes, 1);
        expect(uploads, 1);
        final saved = f.vault.credential(CloudPlatform.xunlei)!;
        expect(saved.field('captchaToken'), 'new-web-captcha');
        expect(saved.updatedAt, 42);
        expect(
          http.calls.where((r) => r.uri.path == '/v1/auth/token'),
          isEmpty,
        );
      },
    );
  }

  for (final mode in [
    'challenge',
    'rejected',
    'unavailable',
    'account-switch',
    'cancel',
  ]) {
    test('Web upload stops safely when captcha renewal is $mode', () async {
      final f = _Fixture(), scope = RequestScope();
      var creates = 0, refreshes = 0;
      final http = FakeHttp((r) async {
        if (r.uri.path == '/v1/shield/captcha/init') {
          refreshes++;
          if (mode == 'account-switch') {
            await f.vault.putCredential(
              CloudPlatform.xunlei,
              Credential('other', {'primary': 'other-access'}, updatedAt: 99),
            );
          }
          if (mode == 'cancel') scope.cancel();
          if (mode == 'unavailable') return const HttpResult(503, '{}');
          return jsonResponse({
            'captcha_token': 'new-web-captcha',
            if (mode == 'challenge')
              'url': 'https://xluser-ssl.xunlei.com/verify',
          });
        }
        expect(r.uri.path, '/drive/v1/files');
        expect(r.method, 'POST');
        creates++;
        return jsonResponse({'error': 'captcha_invalid'}, 400);
      });
      await expectLater(
        scope.run(() => f.upload(http)),
        throwsA(isA<AppException>()),
      );
      expect(refreshes, 1);
      expect(creates, mode == 'rejected' ? 2 : 1);
      final saved = f.vault.credential(CloudPlatform.xunlei)!;
      expect(
        saved.primary,
        mode == 'account-switch' ? 'other-access' : 'web-access',
      );
      if (mode != 'account-switch') {
        expect(saved.field('autoLoginBlocked'), isEmpty);
      }
      if (mode == 'challenge') {
        expect(saved.field('captchaToken'), 'expired-captcha');
      }
    });
  }
}
