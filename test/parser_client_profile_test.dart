import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/parser_rules/hub.dart';
import 'package:asterlink/data/parser_rules/rule.dart';
import 'package:asterlink/data/state_store.dart';
import 'support.dart';

final _fixtures = asJson(
  jsonDecode(
    File('test/fixtures/parser_rules/client-profiles.json').readAsStringSync(),
  ),
);
final _key = File(
  'test/fixtures/parser_rules/client-profiles-public-key.txt',
).readAsStringSync();
final _now = DateTime.fromMillisecondsSinceEpoch(1791936000000);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Client capability negotiation retains the v4 rule language', () {
    expect(ParserRule.engine, 4);
    expect(ParserBundle.clientRevision, 2);
    final legacy = ParserBundle.verify(
      _fixtures.obj('legacy'),
      _key,
      now: _now,
    );
    final current = ParserBundle.verify(
      _fixtures.obj('current'),
      _key,
      now: _now,
    );
    expect(legacy.sites.map((site) => site.id), ['mf_dg22']);
    expect(current.sites.map((site) => site.id), ['mf_dg22', 'dg22_uc']);
    expect(current.sites.last.rule.deviceGroup, 'mf_dg22');
    expect(
      current.sites.last.passwordPrompt.webFlow!.usesUcCommand,
      true,
    );
    expect(current.sites.last.passwordPrompt.webFlow!.sharePassword, true);
  });

  test(
    'Signed manifests requiring unknown client capabilities are rejected',
    () {
      expect(
        () => ParserBundle.verify(_fixtures.obj('future'), _key, now: _now),
        throwsA(
          isA<ParserRuleError>().having(
            (error) => error.code,
            'code',
            'RULE_SIGNATURE',
          ),
        ),
      );
      final tampered = Map<String, dynamic>.from(_fixtures.obj('current'));
      final payload = asJson(
        jsonDecode(utf8.decode(base64Decode(tampered.str('payload')))),
      );
      payload['clientRevision'] = 1;
      tampered['payload'] = base64Encode(utf8.encode(jsonEncode(payload)));
      expect(
        () => ParserBundle.verify(tampered, _key, now: _now),
        throwsA(isA<ParserRuleError>()),
      );
    },
  );

  test('Static backups give each client the matching signed channel list', () {
    final backup = _fixtures.obj('backup');
    final current = ParserBundle.verifyBackup(backup, _key, now: _now);
    expect(current.sites.map((site) => site.id), ['mf_dg22', 'dg22_uc']);
    final legacyDocument = Map<String, dynamic>.from(backup)..remove('clients');
    final legacy = ParserBundle.verifyBackup(legacyDocument, _key, now: _now);
    expect(legacy.sites.map((site) => site.id), ['mf_dg22']);
    expect(
      current.id,
      ParserBundle.verify(_fixtures.obj('current'), _key, now: _now).id,
    );
    expect(current.revision, greaterThan(legacy.revision));
  });

  test(
    'A capability upgrade keeps the old selection, device and task snapshot',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'wenxi-client-profile-',
      );
      var response = _fixtures.obj('legacy');
      final http = FakeHttp((request) {
        expect(request.headers['X-Parser-Engine'], '4');
        expect(request.headers['X-Parser-Client-Revision'], '2');
        return jsonResponse({'ok': true, 'data': response});
      });
      final hub = ParserRuleHub(
        store: Vault(StateStore.memory()),
        directory: directory,
        http: http,
        url: 'https://hub.example.com',
        apiKey: 'fixture-api-key',
        publicKey: _key,
        clock: () => _now,
      );
      addTearDown(() async {
        await hub.close();
        await directory.delete(recursive: true);
      });
      expect(await hub.refresh(force: true), true);
      final old = hub.sites.single;
      await hub.select(old.id);
      final device = await hub.device('mf_dg22');
      response = _fixtures.obj('current');
      expect(await hub.refresh(force: true), true);
      expect(hub.sites.map((site) => site.id), ['mf_dg22', 'dg22_uc']);
      expect(hub.selectedId, old.id);
      expect(await hub.device(hub.sites.last.rule.deviceGroup), device);
      expect((await hub.snapshot(old.bundleId, old.id)).bundleId, old.bundleId);
      response = _fixtures.obj('legacy');
      expect(await hub.refresh(force: true), false);
      expect(hub.sites.map((site) => site.id), ['mf_dg22', 'dg22_uc']);
    },
  );
}
