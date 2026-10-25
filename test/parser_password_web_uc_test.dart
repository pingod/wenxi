import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/parser_rules/hub.dart';
import 'package:asterlink/data/parser_rules/password_web_flow.dart';
import 'package:asterlink/data/providers/baidu_public_parser.dart';
import 'package:asterlink/data/state_store.dart';
import 'baidu_public_parser_support.dart';
import 'parser_password_web_test.dart'
    show PasswordWebTestHub, passwordWebNow, passwordWebUcFixture;
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PasswordWebTestHub hub;
  late FakeHttp http;
  late BaiduPublicParser parser;
  late BaiduPublicFixture fixture;
  late String serverPassword;
  late int submissions;
  late bool rejectLocal, offline;
  Completer<HttpResult>? submissionReply, metadataReply;
  const finalPassword = '网页最终解析密码-A7!';
  HttpResult ok(Json data) => jsonResponse({'ok': true, 'data': data});

  setUp(() {
    serverPassword = '';
    submissions = 0;
    rejectLocal = offline = false;
    submissionReply = metadataReply = null;
    fixture = BaiduPublicFixture();
    http = FakeHttp((r) async {
      if (r.uri.host == 'mf.dg22.top') {
        expect(r.json.str('parse_password'), finalPassword);
        if (rejectLocal) return jsonResponse({'code': 20016}, 400);
        return fixture.respond(r);
      }
      expect(r.uri.host, 'hub.example');
      expect(r.headers.containsKey('Cookie'), false);
      if (offline) throw const AppException('共享服务网络暂不可用');
      if (r.uri.path == '/v1/sites') {
        return await metadataReply?.future ??
            ok({
              'sites': [
                {'id': 'dg22_public', 'version': 2},
              ],
            });
      }
      if (r.uri.path.endsWith('/submissions')) {
        submissions++;
        expect(r.json['password'], finalPassword);
        expect(r.json.keys.toSet(), {'password', 'baseVersion'});
        expect(r.json['baseVersion'], 2);
        if (submissionReply != null) return submissionReply!.future;
        serverPassword = finalPassword;
        return ok({'status': 'accepted'});
      }
      if (r.uri.path.endsWith('/password')) {
        return ok({
          'password': serverPassword.isEmpty ? null : serverPassword,
          'version': 3,
          'cacheFor': 300,
        });
      }
      throw StateError('Unexpected route ${r.uri.path}');
    });
    hub = PasswordWebTestHub(
      store: Vault(StateStore.memory()),
      http: http,
      clock: () => passwordWebNow,
      fixture: passwordWebUcFixture,
    );
    parser = BaiduPublicParser(http, store: hub.store, hub: hub);
  });
  tearDown(() async => hub.close());
  Future<String> grant() => hub.grantLocalPassword(
    'dg22_public',
    finalPassword,
    flowFingerprint: hub.sites.single.passwordPrompt.webFlow!.fingerprint,
  );

  test(
    'Native command requests are bounded and do not become final passwords',
    () {
      final result = ParserPasswordWebResult.read({
        'status': 'ucPassword',
        'command': '当前网页口令',
        'password': '不应被捕获的访问密码',
      });
      expect(result.command, '当前网页口令');
      expect(result.password, '');
      for (final command in ['', 'x' * 2001, 'bad\u0000command', 9]) {
        expect(
          ParserPasswordWebResult.read({
            'status': 'ucPassword',
            'command': command,
          }).status,
          'error',
        );
      }
      expect(hub.sites.single.passwordPrompt.webFlow!.usesUcCommand, true);
      expect(hub.sites.single.passwordPrompt.webFlow!.sharePassword, true);
    },
  );

  test(
    'Successful local parsing automatically shares only the final password and reuses the accepted result',
    () async {
      final token = await grant();
      expect(http.calls, isEmpty);
      await parser.openShare(fixture.link, passwordGrant: token);
      await hub.shareGrantedPassword('dg22_public', token);
      expect(submissions, 1);
      expect(serverPassword, finalPassword);
      expect(http.calls.first.uri.host, 'mf.dg22.top');
      await parser.openShare(fixture.link); // No second browser flow is needed.
      await hub.shareGrantedPassword('dg22_public', token);
      expect(submissions, 1);
    },
  );

  test(
    'Rejected local parser passwords are revoked without any sharing request',
    () async {
      rejectLocal = true;
      final token = await grant();
      await expectLater(
        parser.openShare(fixture.link, passwordGrant: token),
        throwsA(isA<ParserPasswordRequired>()),
      );
      await hub.shareGrantedPassword('dg22_public', token);
      expect(submissions, 0);
      expect(http.calls.every((r) => r.uri.host == 'mf.dg22.top'), true);
      expect(hub.grantedPassword('dg22_public', token), null);
    },
  );

  test(
    'Slow or unavailable sharing never blocks parsing or removes its local password',
    () async {
      submissionReply = Completer<HttpResult>();
      final token = await grant();
      final session = await parser.openShare(
        fixture.link,
        passwordGrant: token,
      );
      expect(session.rootId, '/');
      final share = hub.shareGrantedPassword('dg22_public', token);
      await Future<void>.delayed(Duration.zero);
      expect(submissions, 1);
      submissionReply!.complete(
        const HttpResult(503, 'temporarily unavailable'),
      );
      await share;
      expect(hub.grantedPassword('dg22_public', token)!.value, finalPassword);
      await parser.openShare(fixture.link, passwordGrant: token);
      expect(
        submissions,
        1,
      ); // Backoff prevents repeated submission on every file.
    },
  );

  test(
    'Missing or unreachable shared passwords still open the local web flow',
    () async {
      await expectLater(
        parser.openShare(fixture.link),
        throwsA(isA<ParserPasswordRequired>()),
      );
      offline = true;
      await expectLater(
        parser.openShare(fixture.link),
        throwsA(isA<ParserPasswordRequired>()),
      );
      final token = await grant();
      await parser.openShare(fixture.link, passwordGrant: token);
      await hub.shareGrantedPassword('dg22_public', token);
      expect(hub.grantedPassword('dg22_public', token), isNotNull);
    },
  );

  test(
    'Revoking a receipt while metadata loads prevents submitting the password',
    () async {
      metadataReply = Completer<HttpResult>();
      final token = await grant();
      final share = hub.shareGrantedPassword('dg22_public', token);
      await Future<void>.delayed(Duration.zero);
      await hub.revokePasswordGrant(token);
      metadataReply!.complete(
        ok({
          'sites': [
            {'id': 'dg22_public', 'version': 2},
          ],
        }),
      );
      await share;
      expect(submissions, 0);
    },
  );
}
