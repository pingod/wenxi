import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/wopan.dart';
import 'package:asterlink/data/providers/wopan_login.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'native_login_support.dart';
import 'support.dart';
import 'token_cloud_support.dart';
import 'wopan_login_support.dart';

void main() {
  test(
    'SMS requests match the official H5 envelopes, encryption and headers',
    () async {
      final http = LoginHttp(wopanLoginResponse);
      final login = WopanSmsLogin(http, now: () => tokenClock);
      final challenge = await login.sendSms(' 13800000000 ');
      final credential = await login.sms(challenge, ' 123456 ');
      expect(http.calls.map((r) => r.uri.path), [
        '/api-user/sendMessageCodeBase',
        '/api-user/dispatcher',
      ]);
      final sending = http.calls.first;
      expect(sending.json.keys, unorderedEquals(['func', 'clientId', 'param']));
      expect(sending.json['func'], 'app_send');
      expect(sending.json['clientId'], '1001000035');
      expect(wopanWebParam(sending), {
        'operateType': '1',
        'phone': '13800000000',
      });
      final signingIn = http.calls.last;
      expect(
        signingIn.json.obj('body').keys,
        unorderedEquals(['clientId', 'param']),
      );
      expect(wopanWebParam(signingIn), {
        'clientSecret': 'iELf0UL07o6I8eRK',
        'phone': '13800000000',
        'smsCode': '123456',
      });
      final header = signingIn.json.obj('header');
      expect(header.str('key'), 'LoginByMobileV2');
      expect(header.integer('resTime'), tokenClock);
      expect(header.integer('reqSeq'), inInclusiveRange(100000, 189998));
      expect(header.str('channel'), 'api-user');
      expect(
        header.str('sign'),
        md5
            .convert(
              utf8.encode(
                'LoginByMobileV2$tokenClock${header['reqSeq']}api-user',
              ),
            )
            .toString(),
      );
      for (final request in http.calls) {
        expect(request.method, 'POST');
        expect(request.uri.origin, 'https://panservice.mail.wo.cn');
        expect(request.headers['Origin'], request.uri.origin);
        expect(
          request.headers['Referer'],
          '${request.uri.origin}/h5/wocloud_ai/login',
        );
        expect(request.headers['Client-Id'], '1001000035');
        expect(request.headers['X-YP-Client-Id'], '1001000035');
        expect(request.headers['clientId'], '1001000035');
        expect(request.headers['Accesstoken'], isNull);
      }
      expect(http.redirects, everyElement(isFalse));
      expect(credential.primary, refreshToken);
      expect(credential.field('accessToken'), accessToken);
      expect(credential.field('expiresAt'), '${tokenClock + 3600000}');
      expect(credential.field('clientId'), '1001000035');
      expect(credential.field('username'), '13800000000');
      expect(credential.fields.values, isNot(contains('123456')));
      expect(credential.field('clientSecret'), isEmpty);
    },
  );

  test(
    'malformed phone numbers and codes make no authentication requests',
    () async {
      final http = LoginHttp(wopanLoginResponse);
      final login = WopanSmsLogin(http);
      for (final mobile in ['123', '23800000000', '13800000000\nextra']) {
        await expectLater(login.sendSms(mobile), throwsA(isA<AppException>()));
      }
      for (final code in ['', '1234', '1234567', '12ab56']) {
        await expectLater(
          login.sms(const WopanSmsChallenge('13800000000'), code),
          throwsA(isA<AppException>()),
        );
      }
      expect(http.calls, isEmpty);
    },
  );

  test(
    'a successful login is saved only after validating its account and quota',
    () async {
      final vault = Vault(StateStore.memory());
      final http = LoginHttp(wopanLoginResponse);
      final sms = WopanSmsLogin(http, now: () => tokenClock);
      final connector = WopanConnector(http, vault, now: () => tokenClock);
      final login = AccountLoginService(vault, (_, c) => connector.account(c));
      final challenge = await sms.sendSms('13800000000');
      final result = await login.submit(
        CloudPlatform.wopan,
        (_) async => connector.authenticate(await sms.sms(challenge, '123456')),
      );
      final saved = vault.credential(CloudPlatform.wopan)!;
      expect(saved.field('userId'), 'wopan-user');
      expect(saved.field('clientId'), '1001000035');
      expect(saved.field('refreshToken'), refreshToken);
      expect(saved.fields.values, isNot(contains('123456')));
      expect(result.account.total, 2048);
      expect(result.account.used, 512);
      expect(http.calls.map((r) => r.json.obj('header').str('key')), [
        '',
        'LoginByMobileV2',
        'AppQueryUser',
        'QueryCloudUsageInfo',
      ]);
      expect(wopanWebParam(http.calls[2])['accessToken'], accessToken);
    },
  );

  test(
    'H5 credentials refresh with their own client and retain it after rotation',
    () async {
      final http = LoginHttp(wopanLoginResponse);
      final vault = Vault(StateStore.memory());
      final sms = WopanSmsLogin(http, now: () => tokenClock);
      final candidate = await sms.sms(
        const WopanSmsChallenge('13800000000'),
        '123456',
      );
      final expired = candidate.withFields({
        'expiresAt': '${tokenClock - 1000}',
      });
      await vault.putCredential(CloudPlatform.wopan, expired);
      final connector = WopanConnector(http, vault, now: () => tokenClock);
      final account = await connector.account(expired);
      final refresh = http.calls.firstWhere(
        (r) => r.json.obj('header').str('key') == 'AppRefreshToken',
      );
      expect(refresh.json.obj('body')['clientId'], '1001000035');
      expect(wopanWebParam(refresh), {
        'refreshToken': refreshToken,
        'clientSecret': 'iELf0UL07o6I8eRK',
      });
      final saved = vault.credential(CloudPlatform.wopan)!;
      expect(saved.field('clientId'), '1001000035');
      expect(saved.field('accessToken'), renewedAccess);
      expect(saved.field('refreshToken'), renewedRefresh);
      expect(saved.field('username'), '13800000000');
      expect(saved.fields.values, isNot(contains('123456')));
      expect(account.nickname, '短信登录账号');
    },
  );

  test(
    'a failed account verification never replaces the saved login',
    () async {
      final vault = await tokenVault(CloudPlatform.wopan);
      final before = vault.credential(CloudPlatform.wopan)!;
      final http = LoginHttp(
        (r) => r.json.obj('header').str('key') == 'AppQueryUser'
            ? jsonResponse({
                'STATUS': '200',
                'RSP': {'RSP_CODE': '5001'},
              })
            : wopanLoginResponse(r),
      );
      final sms = WopanSmsLogin(http, now: () => tokenClock);
      final connector = WopanConnector(http, vault, now: () => tokenClock);
      final login = AccountLoginService(vault, (_, c) => connector.account(c));
      await expectLater(
        login.submit(
          CloudPlatform.wopan,
          (_) async => connector.authenticate(
            await sms.sms(const WopanSmsChallenge('13800000000'), '123456'),
          ),
        ),
        throwsA(isA<AppException>()),
      );
      expect(vault.credential(CloudPlatform.wopan)!.sameAs(before), isTrue);
    },
  );

  test(
    'SMS failures are not retried and do not display server-supplied secrets',
    () async {
      for (final sending in [true, false]) {
        final http = LoginHttp(
          (_) => jsonResponse({
            'STATUS': '200',
            'RSP': {
              'RSP_CODE': '1001',
              'RSP_DESC': '13800000000 123456 private',
            },
          }),
        );
        final login = WopanSmsLogin(http);
        await expectLater(
          sending
              ? login.sendSms('13800000000')
              : login.sms(const WopanSmsChallenge('13800000000'), '123456'),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'safe message',
              allOf(
                isNot(contains('13800000000')),
                isNot(contains('123456')),
                isNot(contains('private')),
              ),
            ),
          ),
        );
        expect(http.calls, hasLength(1));
      }
    },
  );

  test(
    'cancelling a login rejects its late SMS response before saving',
    () async {
      final vault = await tokenVault(CloudPlatform.wopan);
      final before = vault.credential(CloudPlatform.wopan)!;
      final delayed = Completer<HttpResult>();
      RecordedRequest? held;
      final http = LoginHttp((r) {
        held = r;
        return delayed.future;
      });
      final sms = WopanSmsLogin(http, now: () => tokenClock);
      final connector = WopanConnector(http, vault, now: () => tokenClock);
      final login = AccountLoginService(vault, (_, c) => connector.account(c));
      final pending = login.submit(
        CloudPlatform.wopan,
        (_) async => connector.authenticate(
          await sms.sms(const WopanSmsChallenge('13800000000'), '123456'),
        ),
      );
      final failure = expectLater(pending, throwsA(isA<AppException>()));
      await Future<void>.delayed(Duration.zero);
      expect(held, isNotNull);
      login.invalidate(CloudPlatform.wopan);
      delayed.complete(wopanLoginResponse(held!));
      await failure;
      expect(http.calls, hasLength(1));
      expect(vault.credential(CloudPlatform.wopan)!.sameAs(before), isTrue);
    },
  );
}
