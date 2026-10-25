import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/parser_rules/hub.dart';
import 'package:asterlink/data/parser_rules/password_web_flow.dart';
import 'package:asterlink/data/parser_rules/rule.dart';
import 'package:asterlink/data/providers/baidu_public_parser.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'baidu_public_parser_support.dart';
import 'support.dart';

final passwordWebFixture = asJson(
  jsonDecode(
    File('test/fixtures/parser_rules/password-web.json').readAsStringSync(),
  ),
);
final passwordWebNow = DateTime.utc(2026, 10, 18, 12);
final passwordWebUcFixture = asJson(
  jsonDecode(
    File('test/fixtures/parser_rules/password-web-uc.json').readAsStringSync(),
  ),
);

class PasswordWebTestHub extends ParserRuleHub {
  PasswordWebTestHub({
    required super.store,
    required super.http,
    super.passwordDocumentHttp,
    super.clock,
    Json? fixture,
  }) : super(
         directory: Directory('password-web-test'),
         url: 'https://hub.example',
         apiKey: 'fixture',
         publicKey: (fixture ?? passwordWebFixture).str('publicKey'),
       ) {
    fixtureSites = ParserBundle.verify(
      (fixture ?? passwordWebFixture).obj('envelope'),
      publicKey,
      now: passwordWebNow,
    ).sites;
  }
  late List<ParserSite> fixtureSites;
  @override
  List<ParserSite> get sites => fixtureSites;
  @override
  Future<bool> refresh({bool force = false}) async => false;
  @override
  Future<void> ensurePublicParsing(CloudPlatform platform) async {}
  @override
  Future<ParserSite?> forNewShare({
    String? siteId,
    CloudPlatform platform = CloudPlatform.baidu,
  }) async => fixtureSites.first;
  @override
  Future<ParserSite> snapshot(String bundleId, String siteId) async =>
      fixtureSites.first;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final config = passwordWebFixture.obj('flow');
  final flow = ParserPasswordWebFlow.fromJson(config);

  test('PHP signed browser recipe is verified and tampering is rejected', () {
    final envelope = passwordWebFixture.obj('envelope');
    final bundle = ParserBundle.verify(
      envelope,
      passwordWebFixture.str('publicKey'),
      now: passwordWebNow,
    );
    expect(
      bundle.sites.single.passwordPrompt.webFlow!.fingerprint,
      flow.fingerprint,
    );
    final tampered = asJson(
      jsonDecode(utf8.decode(base64Decode(envelope.str('payload')))),
    );
    (((tampered['rules'] as List).single as Map)['passwordPrompt']
            as Map)['webFlow']['script'] =
        'return 123;';
    expect(
      () => ParserBundle.verify(
        {
          ...envelope,
          'payload': base64Encode(utf8.encode(jsonEncode(tampered))),
        },
        passwordWebFixture.str('publicKey'),
        now: passwordWebNow,
      ),
      throwsA(isA<AppException>()),
    );
  });

  test('Only explicitly declared HTTPS page origins can be read', () {
    expect(flow.allows(Uri.parse('https://mmhq.dg22.top/result?step=3')), true);
    for (final url in [
      'http://mmhq.dg22.top/',
      'https://evil.example/',
      'https://sub.mmhq.dg22.top/',
      'https://mmhq.dg22.top:8443/',
      'https://user@mmhq.dg22.top/',
      'file:///etc/passwd',
      'about:blank',
    ]) {
      expect(flow.allows(Uri.parse(url)), false, reason: url);
    }
  });

  test('Invalid and excessive browser recipes are rejected', () {
    for (final change in <Json>[
      {'url': 'http://mmhq.dg22.top/'},
      {'url': 'https://other.example/'},
      {'url': 'https://mmhq.dg22.top/#fragment'},
      {
        'allowedHosts': ['*.dg22.top'],
      },
      {
        'allowedHosts': ['127.0.0.1'],
      },
      {'script': ''},
      {'script': 'x' * 24001},
      {'timeoutSeconds': 601},
      {'pollIntervalMs': 0},
      {'cacheSeconds': 86401},
      {'schema': 2},
      {'timeoutSeconds': '300'},
      {'firstPassword': 'bad\nvalue'},
      {'firstPasswordSource': 'arbitraryUrl'},
      {'sharePassword': 'true'},
      {'userAgent': 'bad\r\nHeader: value'},
    ]) {
      expect(
        () => ParserPasswordWebFlow.fromJson({...config, ...change}),
        throwsA(anything),
      );
    }
  });

  test('UC UA follows the actual engine and masks never become passwords', () {
    expect(
      flow.resolveUserAgent('Mozilla/5.0 Chrome/142.0.7444.7 Safari/537.36'),
      contains('Chrome/142.0.7444.7 UCBrowser/'),
    );
    for (final password in ['', '••••••', '○●* ·', 'bad\nvalue', 'x' * 513]) {
      expect(
        ParserPasswordWebResult.read({
          'status': 'success',
          'password': password,
        }).status,
        'waiting',
      );
    }
    expect(
      ParserPasswordWebResult.read({
        'status': 'success',
        'password': '  中文 Aa-7!  ',
      }).password,
      '  中文 Aa-7!  ',
    );
    expect(ParserPasswordWebResult.read('{bad json').status, 'error');
  });

  test('Android UC mode preserves the native device, platform and engine', () {
    const native =
        'Mozilla/5.0 (Linux; Android 16; Pixel 9 Build/TEST; wv) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
        'Chrome/141.0.7390.111 Mobile Safari/537.36';
    final agent = flow.resolveUserAgent(native)!;
    expect(agent.replaceAll(' UCBrowser/18.10.4.1530', ''), native);
    expect(flow.resolveUserAgent(agent), agent);
    const unknownEngine = 'Mozilla/5.0 (Linux; Android 14; device)';
    expect(
      flow.resolveUserAgent(unknownEngine),
      '$unknownEngine UCBrowser/18.10.4.1530',
    );
  });

  test('A blocked page exposes only its fixed code and a validated Ray ID', () {
    final blocked = ParserPasswordWebResult.read({
      'status': 'error',
      'code': 'CF_BLOCKED',
      'password': 'must-not-be-captured',
      'command': 'must-not-be-resolved',
      'cfRay': '0123456789abcdef-SJC',
    });
    expect(blocked.code, 'CF_BLOCKED');
    expect(blocked.cfRay, '0123456789abcdef-SJC');
    expect(blocked.password, isEmpty);
    expect(blocked.command, isEmpty);
    for (final ray in ['token=private', 'bad\nvalue', 'x' * 33]) {
      expect(
        ParserPasswordWebResult.read({
          'status': 'error',
          'code': 'CF_BLOCKED',
          'cfRay': ray,
        }).cfRay,
        isEmpty,
      );
    }
    expect(
      ParserPasswordWebResult.read({
        'status': 'error',
        'code': 'password=private',
      }).code,
      isEmpty,
    );
  });

  test(
    'The real browser script waits for verification and captures decrypted globals',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'password-web-script-',
      );
      try {
        final file = File('${directory.path}/scripts.json');
        await file.writeAsString(
          jsonEncode({
            'evaluation': flow.evaluationScript,
            'firstPassword': flow.firstPassword,
            'ucEvaluation': ParserPasswordWebFlow.fromJson(
              passwordWebUcFixture.obj('flow'),
            ).evaluation(ucCommandSupported: true),
            'ucUnsupportedEvaluation': ParserPasswordWebFlow.fromJson(
              passwordWebUcFixture.obj('flow'),
            ).evaluation(),
            'ucResolvedEvaluation':
                ParserPasswordWebFlow.fromJson(
                  passwordWebUcFixture.obj('flow'),
                ).evaluation(
                  ucCommandSupported: true,
                  ucCommand: '网页当前口令',
                  ucPassword: '动态访问密码',
                ),
            'recipe': flow.script,
          }),
        );
        final result = await Process.run('node', [
          'tool/password-web-flow.test.cjs',
          file.path,
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'Local password resumes list and download with zero password-server requests',
    () async {
      final fixture = BaiduPublicFixture();
      final http = FakeHttp((request) {
        expect(request.uri.host, 'mf.dg22.top');
        expect(request.json.str('parse_password'), '本机密码-A7!');
        return fixture.respond(request);
      });
      final hub = PasswordWebTestHub(
        store: Vault(StateStore.memory()),
        http: http,
        clock: () => passwordWebNow,
      );
      final provider = BaiduPublicParser(http, store: hub.store, hub: hub);
      expect(hub.sites.single.passwordPrompt.autoFill, true);
      await expectLater(
        provider.openShare(fixture.link),
        throwsA(isA<ParserPasswordRequired>()),
      );
      expect(http.calls, isEmpty);
      final grant = await hub.grantLocalPassword(
        'dg22_public',
        '本机密码-A7!',
        flowFingerprint: flow.fingerprint,
      );
      final session = await provider.openShare(
        fixture.link,
        passwordGrant: grant,
      );
      final items = await provider.list(session, '/');
      expect(items, isNotEmpty);
      await provider.download(
        session,
        items.firstWhere((item) => !item.isDirectory),
      );
      expect(http.calls.length, 2);
      await hub.close();
    },
  );

  test(
    'Rejected local passwords revoke their receipt without backend reports',
    () async {
      final http = FakeHttp((request) {
        expect(request.uri.host, 'mf.dg22.top');
        return jsonResponse({'code': 20016}, 400);
      });
      final hub = PasswordWebTestHub(
        store: Vault(StateStore.memory()),
        http: http,
        clock: () => passwordWebNow,
      );
      final grant = await hub.grantLocalPassword(
        'dg22_public',
        '已失效的本机密码',
        flowFingerprint: flow.fingerprint,
      );
      final provider = BaiduPublicParser(http, store: hub.store, hub: hub);
      await expectLater(
        provider.openShare(BaiduPublicFixture().link, passwordGrant: grant),
        throwsA(isA<ParserPasswordRequired>()),
      );
      expect(hub.grantedPassword('dg22_public', grant), null);
      expect(http.calls.length, 1);
      await hub.close();
    },
  );

  test(
    'A Cloudflare challenge preserves the password without sharing or reporting it',
    () async {
      final http = FakeHttp((request) {
        expect(request.uri.host, 'mf.dg22.top');
        return const HttpResult(403, '<html>Cloudflare verification</html>', {
          'content-type': ['text/html'],
          'cf-mitigated': ['challenge'],
        });
      });
      final hub = PasswordWebTestHub(
        store: Vault(StateStore.memory()),
        http: http,
        clock: () => passwordWebNow,
        fixture: passwordWebUcFixture,
      );
      addTearDown(hub.close);
      final grant = await hub.grantLocalPassword(
        'dg22_public',
        '尚未验证的本机密码',
        flowFingerprint: hub.sites.single.passwordPrompt.webFlow!.fingerprint,
      );
      final provider = BaiduPublicParser(http, store: hub.store, hub: hub);
      await expectLater(
        provider.openShare(BaiduPublicFixture().link, passwordGrant: grant),
        throwsA(
          isA<ParserRuleError>().having((e) => e.code, 'code', 'CF_CHALLENGE'),
        ),
      );
      expect(hub.grantedPassword('dg22_public', grant)?.value, '尚未验证的本机密码');
      expect(http.calls, hasLength(1));
    },
  );

  test(
    'Local receipts are site-bound, survive restart and expire at Beijing midnight',
    () async {
      var now = passwordWebNow;
      final store = StateStore.memory();
      final http = FakeHttp(
        (_) => throw StateError('No backend request expected'),
      );
      var hub = PasswordWebTestHub(
        store: Vault(store),
        http: http,
        clock: () => now,
      );
      final grant = await hub.grantLocalPassword(
        'dg22_public',
        'A-本机密码',
        flowFingerprint: flow.fingerprint,
      );
      expect(hub.grantedPassword('another_site', grant), null);
      expect(hub.grantedPassword('dg22_public', grant)!.version, -1);
      await hub.close();
      hub = PasswordWebTestHub(
        store: Vault(store),
        http: http,
        clock: () => now,
      );
      expect(hub.grantedPassword('dg22_public', grant)!.value, 'A-本机密码');
      now = DateTime.utc(2026, 10, 18, 16);
      expect(hub.grantedPassword('dg22_public', grant), null);
      await hub.close();
    },
  );

  test(
    'Recipe changes and explicit rejection invalidate local receipts',
    () async {
      final hub = PasswordWebTestHub(
        store: Vault(StateStore.memory()),
        http: FakeHttp((_) => throw StateError('Unexpected request')),
        clock: () => passwordWebNow,
      );
      final grant = await hub.grantLocalPassword(
        'dg22_public',
        '本机密码',
        flowFingerprint: flow.fingerprint,
      );
      await hub.revokePasswordGrant(grant);
      expect(hub.grantedPassword('dg22_public', grant), null);
      final stale = await hub.grantLocalPassword(
        'dg22_public',
        '本机密码',
        flowFingerprint: flow.fingerprint,
      );
      final previous = hub.fixtureSites.single;
      hub.fixtureSites = [
        ParserSite(
          bundleId: previous.bundleId,
          version: previous.version,
          rule: previous.rule,
          passwordPrompt: ParserPasswordPrompt(
            webFlow: ParserPasswordWebFlow.fromJson({
              ...config,
              'firstPassword': '新的访问密码',
            }),
          ),
        ),
      ];
      expect(hub.grantedPassword('dg22_public', stale), null);
      await expectLater(
        hub.grantLocalPassword(
          'dg22_public',
          '迟到的密码',
          flowFingerprint: flow.fingerprint,
        ),
        throwsA(isA<AppException>()),
      );
      await hub.close();
    },
  );
}
