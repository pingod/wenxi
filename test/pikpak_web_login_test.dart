import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/providers/pikpak.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/pikpak_web_login.dart';
import 'support.dart';

const platform = CloudPlatform.pikpak;
const access = 'fixture-browser-access-token-123456';
const refresh = 'fixture-browser-refresh-token-123456';
const captcha = 'fixture-browser-captcha-token-123456';
const device = '0123456789abcdef0123456789abcdef';

Credential webCredential({bool expired = false}) => LoginCredentials.candidate(
  platform,
  jsonEncode({
    'access_token': access,
    'refresh_token': refresh,
    'captcha_token': captcha,
    'client_id': PikPakWebLogin.clientId,
    'device_id': device,
    'sub': 'browser-user',
    if (expired) 'expires_at': '2000-01-01T00:00:00Z',
  }),
  null,
);

void main() {
  test(
    'Browser capture retains web client and device without old account fields',
    () {
      final raw = LoginCredentials.fromBrowser(
        platform,
        storage: {
          'access_token': access,
          'refresh_token': refresh,
          'captcha_token': captcha,
          'client_id': PikPakWebLogin.clientId,
          'device_id': device,
          'sub': 'browser-user',
        },
      );
      final candidate = LoginCredentials.candidate(
        platform,
        raw,
        Credential('old', {
          'username': 'previous',
          'password': 'old-secret',
          'deviceId': 'old-device',
        }),
      );
      expect(candidate.field('clientId'), PikPakWebLogin.clientId);
      expect(candidate.field('deviceId'), device);
      expect(candidate.field('userId'), 'browser-user');
      expect(candidate.field('captchaToken'), captcha);
      expect(candidate.field('refreshToken'), refresh);
      expect(candidate.field('password'), isEmpty);
      expect(candidate.field('username'), isEmpty);
    },
  );

  test('Only the official drive origins can return browser credentials', () {
    final target = WebLoginTarget.targets[platform]!;
    expect(target.localStorageKey, PikPakWebLogin.storageKey);
    for (final origin in ['https://mypikpak.com', 'https://www.mypikpak.com']) {
      expect(target.canReadLocalStorage('$origin/drive/all'), isTrue);
    }
    for (final url in [
      'https://mypikpak.com.invalid/',
      'https://user.mypikpak.com/',
      'https://mypikpak.com:444/',
      'http://mypikpak.com/',
      'https://user@mypikpak.com/',
    ]) {
      expect(target.canReadLocalStorage(url), isFalse);
    }
  });

  test(
    'Web refresh and profile validation keep the browser client identity',
    () async {
      final store = Vault(StateStore.memory());
      final http = FakeHttp((request) {
        expect(request.headers['X-Client-Id'], PikPakWebLogin.clientId);
        expect(request.headers['X-Device-Id'], device);
        expect(request.headers['User-Agent'], WebLoginTarget.desktopUserAgent);
        switch (request.uri.path) {
          case '/v1/auth/token':
            expect(request.json['client_id'], PikPakWebLogin.clientId);
            expect(request.json.containsKey('client_secret'), isFalse);
            expect(request.json['refresh_token'], refresh);
            return jsonResponse({
              'access_token': 'fixture-renewed-browser-access-token',
              'expires_in': 3600,
              'sub': 'browser-user',
            });
          case '/v1/user/me':
            expect(
              request.headers['Authorization'],
              'Bearer fixture-renewed-browser-access-token',
            );
            expect(request.headers['X-Captcha-Token'], captcha);
            return jsonResponse({'sub': 'browser-user', 'name': '网页账号'});
          case '/drive/v1/about':
            return jsonResponse({
              'quota': {'usage': '100', 'limit': '200'},
            });
        }
        throw StateError('unexpected path');
      });
      final result = await PikPakConnector(
        http,
        store,
      ).authenticate(webCredential(expired: true));
      expect(result.account.nickname, '网页账号');
      expect(result.account.total, 200);
      expect(result.credential.field('refreshToken'), refresh);
      expect(result.credential.field('clientId'), PikPakWebLogin.clientId);
      expect(result.credential.field('deviceId'), device);
      expect(store.credential(platform), isNull);
      expect(
        http.calls.where((call) => call.uri.path == '/v1/auth/token').length,
        1,
      );
    },
  );

  test(
    'A web session renews captcha using its web profile and a valid callback',
    () async {
      final store = Vault(StateStore.memory());
      var profileReads = 0;
      final http = FakeHttp((request) {
        expect(request.headers['X-Client-Id'], PikPakWebLogin.clientId);
        expect(request.headers['X-Device-Id'], device);
        switch (request.uri.path) {
          case '/v1/user/me':
            if (++profileReads == 1) {
              return jsonResponse({'error': 'captcha_required'});
            }
            expect(
              request.headers['X-Captcha-Token'],
              'fixture-renewed-browser-captcha',
            );
            return jsonResponse({'sub': 'browser-user', 'name': '网页账号'});
          case '/v1/shield/captcha/init':
            expect(request.json['client_id'], PikPakWebLogin.clientId);
            expect(request.json['captcha_token'], captcha);
            expect(
              request.json['redirect_uri'],
              'https://mypikpak.com/loading',
            );
            expect(
              request.json.obj('meta').str('package_name'),
              'mypikpak.com',
            );
            expect(request.json.obj('meta').str('client_version'), '2.0.0');
            expect(request.json.obj('meta').str('user_id'), 'browser-user');
            // Calculated independently using the current official frontend data.
            expect(
              request.json.obj('meta').str('captcha_sign'),
              '1.fe00726c4527bde4746914749a5bb2de',
            );
            return jsonResponse({
              'captcha_token': 'fixture-renewed-browser-captcha',
            });
          case '/drive/v1/about':
            return jsonResponse({
              'quota': {'usage': '100', 'limit': '200'},
            });
        }
        throw StateError('unexpected path');
      });
      final result = await PikPakConnector(
        http,
        store,
      ).authenticate(webCredential());
      expect(
        result.credential.field('captchaToken'),
        'fixture-renewed-browser-captcha',
      );
      expect(profileReads, 2);
    },
  );

  test(
    'A mismatching server account cannot be saved as the captured web account',
    () async {
      final store = Vault(StateStore.memory());
      final http = FakeHttp(
        (_) => jsonResponse({'sub': 'different-user', 'name': 'wrong'}),
      );
      await expectLater(
        PikPakConnector(http, store).authenticate(webCredential()),
        throwsA(isA<AppException>()),
      );
      expect(store.credential(platform), isNull);
      expect(http.calls.length, 1);
    },
  );
}
