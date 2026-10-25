import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/parser_rules/hub.dart';
import 'package:asterlink/data/remote_control_service.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/remote_control.dart';
import 'remote_control_support.dart';
import 'support.dart';

final _now = DateTime.fromMillisecondsSinceEpoch(1791936000000);
final _publicKey = File(
  'test/fixtures/parser_rules/public-key.txt',
).readAsStringSync();
Json _fixture(int version) => asJson(
  jsonDecode(
    File('test/fixtures/parser_rules/bundle-$version.json').readAsStringSync(),
  ),
);
Json _control(String url, {int revision = 1}) => {
  ...controlJson(revision: revision, androidBuild: 200),
  'parserHub': {'url': url},
};
HttpResult _rules(int version) =>
    jsonResponse({'ok': true, 'data': _fixture(version)});
HttpResult _password(String value, int version) => jsonResponse({
  'ok': true,
  'data': {'password': value, 'version': version, 'cacheFor': 300},
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Control accepts service ports and paths and preserves older publications',
    () {
      final document = RemoteControlDocument.parse(
        _control('http://127.0.0.1:5173/parser/'),
      );
      expect(document.issues, isEmpty);
      expect(
        document.config.parserHubUrl.toString(),
        'http://127.0.0.1:5173/parser',
      );
      expect(document.validSections, contains('parserHub'));
      final restored = RemoteControlConfig.fromJson(document.config.toJson());
      expect(restored.parserHubUrl, document.config.parserHubUrl);
      final older = RemoteControlDocument.parse(
        controlJson(revision: 0),
        previous: restored,
      );
      expect(older.config.parserHubUrl, restored.parserHubUrl);
      final changed = RemoteControlDocument.parse(
        _control('https://next.example.test/new/base', revision: 0),
        previous: restored,
      );
      expect(
        changed.config.parserHubUrl.toString(),
        'https://next.example.test/new/base',
      );
      expect(
        RemoteControlConfig.fromJson(<String, dynamic>{}).parserHubUrl,
        isNull,
      );
    },
  );

  test(
    'An invalid address retains its previous value without breaking updates',
    () {
      final previous = RemoteControlConfig.fromJson(
        _control('https://old.example.test'),
      );
      for (final invalid in <Object?>[
        null,
        'https://example.test',
        {},
        {'url': ''},
        {'url': 123},
        {'url': 'ftp://example.test'},
        {'url': 'http://user:password@example.test'},
        {'url': 'http://example.test?token=secret'},
        {'url': 'http://example.test#fragment'},
        {'url': 'http://example.test:0'},
        {'url': 'http://example.test:65536'},
        {'url': 'http://example.test/with space'},
        {'url': 'http://example.test\\path'},
      ]) {
        final parsed = RemoteControlDocument.parse({
          ...controlJson(androidBuild: 300),
          'parserHub': invalid,
        }, previous: previous);
        expect(parsed.config.parserHubUrl, previous.parserHubUrl);
        expect(parsed.config.updates['android']!.build, 300);
        expect(parsed.issues.single.section, 'parserHub');
        expect(ControlConfigIssue.isKnownPath(parsed.issues.single.path), true);
      }
    },
  );

  group('dynamic hub and local state', () {
    late Directory directory;
    late StateStore store;
    late Vault vault;
    late ParserRuleHub hub;
    late FakeHttp http;
    late DateTime now;
    FutureOr<HttpResult> Function(RecordedRequest)? respond;
    ParserRuleHub createHub({
      String url = 'https://old.example.test',
      String? key,
    }) => ParserRuleHub(
      store: vault,
      directory: directory,
      http: http,
      url: url,
      apiKey: 'endpoint-test-key',
      publicKey: key ?? _publicKey,
      clock: () => now,
    );
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('wenxi-hub-endpoint-');
      store = StateStore.memory();
      vault = Vault(store);
      now = _now;
      respond = null;
      http = FakeHttp((request) => respond?.call(request) ?? _rules(1));
      hub = createHub();
    });
    tearDown(() async {
      await hub.close();
      await directory.delete(recursive: true);
    });

    test(
      'Changing only address retains archived rules and selection after restart',
      () async {
        expect(await hub.refresh(force: true), true);
        final original = hub.sites.single;
        await hub.select(original.id);
        await hub.preferPublic(CloudPlatform.uc, true);
        final device = await hub.device(original.id);
        expect(
          hub.updateEndpoint(Uri.parse('http://next.example.test:8766/api/')),
          true,
        );
        respond = (request) {
          expect(request.url, 'http://next.example.test:8766/api/v1/rules');
          expect(request.headers['Authorization'], 'Bearer endpoint-test-key');
          return _rules(2);
        };
        expect(await hub.refresh(), true);
        expect(hub.sites.single.version, 2);
        expect((await hub.snapshot(original.bundleId, original.id)).version, 1);
        expect(await hub.device(original.id), device);
        expect(hub.updateEndpoint(null), false);
        expect(
          hub.updateEndpoint(Uri.parse('http://next.example.test:8766/api')),
          false,
        );
        await hub.close();
        hub = createHub(url: 'https://third.example.test/another');
        final requests = http.calls.length;
        expect((await hub.forNewShare())!.version, 2);
        expect((await hub.snapshot(original.bundleId, original.id)).version, 1);
        expect(hub.selectedId, original.id);
        expect(hub.publicPreferred(CloudPlatform.uc), true);
        expect(await hub.device(original.id), device);
        expect(http.calls.length, requests);
      },
    );

    test(
      'Legacy URL-based archives and preferences survive without the old build URL',
      () async {
        await hub.close();
        final legacy = sha256
            .convert(utf8.encode('https://legacy.example.test|$_publicKey'))
            .toString()
            .substring(0, 24);
        final prefix = 'parserHub.$legacy';
        final archived = Directory('${directory.path}/parser-rules/$legacy');
        await archived.create(recursive: true);
        late ParserBundle current;
        late ParserBundle original;
        for (final version in [1, 2]) {
          final bundle = ParserBundle.verify(
            _fixture(version),
            _publicKey,
            now: now,
          );
          await File(
            '${archived.path}/${bundle.id}.json',
          ).writeAsString(jsonEncode(bundle.envelope));
          if (version == 1) original = bundle;
          current = bundle;
        }
        await vault.putSecret(
          '$prefix.current',
          jsonEncode({'id': current.id, 'revision': current.revision}),
        );
        await vault.putSecret('$prefix.selected', current.sites.single.id);
        await vault.putSecret('$prefix.public.${CloudPlatform.uc.key}', 'true');
        final device = 'wenxi_${'a' * 32}';
        await vault.putSecret('$prefix.device.mf_dg22', device);
        await vault.putSecret(
          '$prefix.password.mf_dg22',
          jsonEncode({
            'value': 'cached-fixture-password',
            'version': 1,
            'expiresAt': now
                .add(const Duration(minutes: 5))
                .millisecondsSinceEpoch,
          }),
        );
        hub = createHub(url: 'https://new-address.example.test');
        expect((await hub.forNewShare())!.version, 2);
        expect((await hub.snapshot(original.id, 'mf_dg22')).version, 1);
        expect(await hub.device('mf_dg22'), device);
        expect(hub.publicPreferred(CloudPlatform.uc), true);
        expect(
          (await hub.password('mf_dg22')).value,
          'cached-fixture-password',
        );
        expect(http.calls, isEmpty);
        await hub.preferPublic(CloudPlatform.uc, false);
        expect(hub.publicPreferred(CloudPlatform.uc), false);
        expect(
          await File('${archived.path}/${original.id}.json').exists(),
          true,
        );
        await hub.close();
        hub = createHub(
          url: 'https://new-address.example.test',
          key: 'unrelated signing identity',
        );
        respond = (_) => throw const AppException('fixture unavailable');
        await hub.refresh(force: true);
        expect(hub.hasManifest, false);
        expect(hub.publicPreferred(CloudPlatform.uc), false);
        expect(await hub.device('mf_dg22'), isNot(device));
      },
    );

    test(
      'Late manifest from the old endpoint cannot replace a newer response',
      () async {
        final entered = Completer<void>();
        final old = Completer<HttpResult>();
        respond = (request) {
          if (request.uri.host == 'old.example.test') {
            if (!entered.isCompleted) entered.complete();
            return old.future;
          }
          return _rules(2);
        };
        final stale = hub.refresh(force: true);
        await entered.future;
        hub.updateEndpoint(Uri.parse('https://new.example.test'));
        expect(await hub.refresh(), true);
        old.complete(_rules(3));
        expect(await stale, false);
        expect(hub.sites.single.version, 2);
        expect(hub.lastError, isNull);
        await hub.close();
        hub = createHub(url: 'https://new.example.test');
        expect((await hub.forNewShare())!.version, 2);
      },
    );

    test(
      'An old password response cannot poison or release the new pending read',
      () async {
        final enteredOld = Completer<void>(), enteredNew = Completer<void>();
        final old = Completer<HttpResult>(), next = Completer<HttpResult>();
        respond = (request) {
          if (request.uri.host == 'old.example.test') {
            if (!enteredOld.isCompleted) enteredOld.complete();
            return old.future;
          }
          if (!enteredNew.isCompleted) enteredNew.complete();
          return next.future;
        };
        final stale = hub.password('mf_dg22', force: true);
        final rejected = expectLater(stale, throwsA(isA<AppException>()));
        await enteredOld.future;
        hub.updateEndpoint(Uri.parse('https://new.example.test'));
        final first = hub.password('mf_dg22', force: true);
        await enteredNew.future;
        old.complete(_password('stale-password', 99));
        await rejected;
        final joined = hub.password('mf_dg22', force: true);
        next.complete(_password('new-password', 1));
        expect((await first).value, 'new-password');
        expect((await joined).value, 'new-password');
        expect((await hub.password('mf_dg22')).value, 'new-password');
        expect(http.calls, hasLength(2));
      },
    );

    test(
      'Changing the endpoint during initial cache loading does not leak cancellation',
      () async {
        final old = hub.refresh();
        hub.updateEndpoint(Uri.parse('https://new.example.test'));
        expect(await old, false);
        expect(await hub.refresh(), true);
        expect(
          http.calls.every((call) => call.uri.host == 'new.example.test'),
          true,
        );
      },
    );

    test(
      'Clock correction permits manifest and recovery refresh instead of freezing them',
      () async {
        await hub.refresh();
        now = now.subtract(const Duration(hours: 2));
        await hub.refresh();
        expect(http.calls, hasLength(2));
        await hub.refreshAfterFailure();
        now = now.subtract(const Duration(hours: 1));
        await hub.refreshAfterFailure();
        expect(http.calls, hasLength(4));
      },
    );

    test(
      'App applies cached and live control before requests; failures keep the latest address',
      () async {
        await store.put(
          RemoteControlService.cacheKey,
          controlCache(
            _control('https://cached.example.test/service'),
            fetched: now,
          )[RemoteControlService.cacheKey],
        );
        final fetcher = FakeControlFetcher(
          _control('http://new.example.test:7788/base'),
        );
        final services = AppServices(
          store: store,
          dataDirectory: directory,
          cacheDirectory: Directory('${directory.path}/cache'),
          transport: FakeNative(),
          files: FakeFiles(Directory('${directory.path}/saved')),
          http: FakeHttp(),
          platformFeatures: false,
          controlUrl: controlEndpoint,
          controlEnabled: true,
          controlFetcher: fetcher,
          parserRuleHub: hub,
          clock: () => now,
        );
        try {
          expect(hub.url, 'https://cached.example.test/service');
          await hub.refresh();
          expect(http.calls.single.uri.host, 'cached.example.test');
          expect(
            await services.control.refresh(force: true),
            ControlRefreshResult.success,
          );
          expect(hub.url, 'http://new.example.test:7788/base');
          await hub.refresh();
          expect(
            http.calls.last.url,
            'http://new.example.test:7788/base/v1/rules',
          );
          fetcher.text = jsonEncode(controlJson());
          await services.control.refresh(force: true);
          expect(hub.url, 'http://new.example.test:7788/base');
          fetcher.text = jsonEncode(_control('file:///invalid'));
          expect(
            await services.control.refresh(force: true),
            ControlRefreshResult.partial,
          );
          expect(hub.url, 'http://new.example.test:7788/base');
          fetcher.respond = (_) =>
              throw const SocketException('fixture offline');
          expect(
            await services.control.refresh(force: true),
            ControlRefreshResult.failed,
          );
          expect(hub.url, 'http://new.example.test:7788/base');
          await services.control.flushCache();
          final reopened = RemoteControlService(
            store,
            platform: 'android',
            currentBuild: 170,
            configUrl: controlEndpoint,
            enabled: true,
            fetcher: FakeControlFetcher(),
            clock: () => now.add(const Duration(days: 30)),
          );
          try {
            expect(
              reopened.config.parserHubUrl.toString(),
              'http://new.example.test:7788/base',
            );
            expect(reopened.errorForSection('parserHub'), isNotNull);
          } finally {
            reopened.close();
          }
        } finally {
          await services.close();
        }
      },
    );
  });
}
