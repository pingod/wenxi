import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/parser_rules/hub.dart';
import 'package:asterlink/data/parser_rules/rule.dart';
import 'support.dart';

Json fixture(String name) => asJson(
  jsonDecode(File('test/fixtures/parser_rules/$name.json').readAsStringSync()),
);
final publicKey = File(
  'test/fixtures/parser_rules/public-key.txt',
).readAsStringSync();
final fixtureNow = DateTime.fromMillisecondsSinceEpoch(1791936000000);
Matcher errorCode(String code) =>
    isA<ParserRuleError>().having((e) => e.code, 'code', code);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'PHP static export preserves bundle identity beyond the API lifetime',
    () {
      final original = ParserBundle.verify(
        fixture('bundle-1'),
        publicKey,
        now: fixtureNow,
      );
      final backup = ParserBundle.verifyBackup(
        fixture('backup-1'),
        publicKey,
        now: fixtureNow.add(const Duration(days: 30)),
      );
      expect(backup.id, original.id);
      expect(backup.revision, original.revision);
      expect(backup.envelope, original.envelope);
      final rich = ParserBundle.verifyBackup(
        fixture('backup-rich-prompt'),
        publicKey,
        now: fixtureNow,
      );
      expect(rich.sites.single.passwordPrompt.format, 'markdown');
      expect(rich.sites.single.passwordPrompt.autoFill, false);
      final server = ParserBundle.verifyBackup(
        fixture('backup-server'),
        publicKey,
        now: fixtureNow,
      );
      expect(
        server.sites.single.rule.json.obj('execution').str('type'),
        'server',
      );
    },
  );

  test(
    'Static export rejects swapped bundles, modified claims and invalid dates',
    () {
      for (final document in [
        {...fixture('backup-1'), 'bundle': fixture('bundle-2')},
        {...fixture('backup-1'), 'schema': 2},
        {...fixture('backup-1'), 'kind': 'unrelated-backup'},
        {...fixture('backup-1'), 'attestation': fixture('bundle-1')},
      ]) {
        expect(
          () => ParserBundle.verifyBackup(document, publicKey, now: fixtureNow),
          throwsA(errorCode('RULE_BACKUP_SIGNATURE')),
        );
      }
      final changed = fixture('backup-1');
      final proof = changed.obj('attestation');
      final bytes = base64Decode(proof.str('payload'))..[12] ^= 1;
      proof['payload'] = base64Encode(bytes);
      changed['attestation'] = proof;
      expect(
        () => ParserBundle.verifyBackup(changed, publicKey, now: fixtureNow),
        throwsA(errorCode('RULE_BACKUP_SIGNATURE')),
      );
      for (final now in [
        fixtureNow.subtract(const Duration(minutes: 6)),
        fixtureNow.add(const Duration(days: 366)),
      ]) {
        expect(
          () => ParserBundle.verifyBackup(
            fixture('backup-1'),
            publicKey,
            now: now,
          ),
          throwsA(errorCode('RULE_BACKUP_SIGNATURE')),
        );
      }
      expect(
        () => ParserBundle.verify(
          fixture('backup-1'),
          publicKey,
          now: fixtureNow,
        ),
        throwsA(errorCode('RULE_SIGNATURE')),
      );
    },
  );

  group('primary and static fallback', () {
    late Directory directory;
    late Vault vault;
    late FakeHttp http;
    late ParserRuleHub hub;
    late bool primaryDown;
    late String primaryFixture;
    late HttpResult backupResponse;
    HttpResult? primaryResponse;
    FutureOr<HttpResult> Function(RecordedRequest)? backupHandler;
    late DateTime now;
    ParserRuleHub createHub() => ParserRuleHub(
      store: vault,
      directory: directory,
      http: http,
      url: 'https://hub.example.com',
      apiKey: 'fixture-private-key',
      publicKey: publicKey,
      backupUrl: 'https://gitee.com/dzys/cs/blob/master/parser-rules.json',
      clock: () => now,
    );

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('wenxi-rule-backup-');
      vault = Vault(StateStore.memory());
      primaryDown = true;
      primaryFixture = 'bundle-1';
      primaryResponse = null;
      backupResponse = jsonResponse(fixture('backup-1'));
      backupHandler = null;
      now = fixtureNow;
      http = FakeHttp((request) {
        if (request.uri.host == 'hub.example.com') {
          expect(
            request.headers['Authorization'],
            'Bearer fixture-private-key',
          );
          expect(request.uri.path, '/v1/rules');
          if (primaryDown) {
            throw const ParserRuleError('RULE_NETWORK', 'fixture outage');
          }
          return primaryResponse ??
              jsonResponse({'ok': true, 'data': fixture(primaryFixture)});
        }
        expect(request.method, 'GET');
        expect(request.body, isNull);
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(anyElement(isIn(['authorization', 'cookie', 'x-device-id']))),
        );
        expect(request.uri.toString(), isNot(contains('fixture-private-key')));
        return backupHandler?.call(request) ?? backupResponse;
      });
      hub = createHub();
    });
    tearDown(() async {
      await hub.close();
      await directory.delete(recursive: true);
    });

    test(
      'healthy primary and intentional empty manifests never read the backup',
      () async {
        primaryDown = false;
        expect(await hub.refresh(force: true), true);
        expect(http.calls, hasLength(1));
        primaryFixture = 'bundle-3';
        expect(await hub.refresh(force: true), true);
        expect(hub.hasManifest, true);
        expect(hub.sites, isEmpty);
        expect(http.calls.every((r) => r.uri.host == 'hub.example.com'), true);
      },
    );

    test(
      'first launch falls back to Gitee raw and primary recovery retains identity',
      () async {
        expect(await hub.refresh(force: true), true);
        final id = hub.sites.single.bundleId;
        expect(
          http.calls.last.uri.path,
          '/dzys/cs/raw/master/parser-rules.json',
        );
        expect(hub.lastError, isNull);
        primaryDown = false;
        expect(await hub.refresh(force: true), false);
        expect(hub.lastError, isNull);
        expect(hub.sites.single.bundleId, id);
        primaryFixture = 'bundle-2';
        expect(await hub.refresh(force: true), true);
        expect(hub.sites.single.version, 2);
        expect((await hub.snapshot(id, 'mf_dg22')).version, 1);
      },
    );

    test('HTML primary response also uses the signed backup', () async {
      primaryDown = false;
      primaryResponse = const HttpResult(200, '<html>unavailable</html>');
      expect(await hub.refresh(force: true), true);
      expect(hub.sites.single.id, 'mf_dg22');
    });

    test(
      'expired API copy works only with its valid export attestation',
      () async {
        now = fixtureNow.add(const Duration(days: 30));
        backupResponse = jsonResponse(fixture('bundle-1'));
        expect(await hub.refresh(force: true), false);
        expect(hub.hasManifest, false);
        backupResponse = jsonResponse(fixture('backup-1'));
        expect(await hub.refresh(force: true), true);
      },
    );

    test(
      'stale export cannot roll back a newer primary or resurrect withdrawn sites',
      () async {
        primaryDown = false;
        primaryFixture = 'bundle-2';
        await hub.refresh(force: true);
        primaryDown = true;
        expect(await hub.refresh(force: true), false);
        expect(hub.sites.single.version, 2);
        expect(hub.lastError, 'RULE_ROLLBACK');
        primaryDown = false;
        primaryFixture = 'bundle-3';
        await hub.refresh(force: true);
        primaryDown = true;
        await hub.refresh(force: true);
        expect(hub.sites, isEmpty);
        expect(hub.hasManifest, true);
      },
    );

    test(
      'newer export can update older cached rules and survives a full outage on restart',
      () async {
        primaryDown = false;
        await hub.refresh(force: true);
        primaryDown = true;
        backupResponse = jsonResponse(fixture('backup-2'));
        expect(await hub.refresh(force: true), true);
        expect(hub.sites.single.version, 2);
        await hub.close();
        hub = createHub();
        backupResponse = const HttpResult(404, 'not uploaded');
        expect(await hub.refresh(force: true), false);
        expect(hub.sites.single.version, 2);
      },
    );

    test(
      'Gitee content redirect uses public headers and rejects unrelated hosts',
      () async {
        backupHandler = (request) => request.uri.host == 'gitee.com'
            ? const HttpResult(302, '', {
                'location': ['https://giteeusercontent.com/parser-rules.json'],
              })
            : backupResponse;
        expect(await hub.refresh(force: true), true);
        expect(http.calls.last.uri.host, 'giteeusercontent.com');
        backupHandler = (_) => const HttpResult(302, '', {
          'location': ['https://unrelated.example.com/private'],
        });
        final calls = http.calls.length;
        expect(await hub.refresh(force: true), false);
        expect(http.calls.length, calls + 2);
        expect(hub.lastError, 'RULE_BACKUP_URL');
      },
    );

    test(
      'missing, oversized and tampered copies keep the last valid rules',
      () async {
        await hub.refresh(force: true);
        for (final invalid in [
          const HttpResult(404, 'not uploaded'),
          const HttpResult(200, '<html>login</html>'),
          HttpResult(200, 'x' * 1048577),
          jsonResponse({...fixture('backup-1'), 'bundle': fixture('bundle-2')}),
        ]) {
          backupResponse = invalid;
          expect(await hub.refresh(force: true), false);
          expect(hub.sites.single.version, 1);
          expect(hub.lastError, isNotNull);
        }
      },
    );
  });
}
