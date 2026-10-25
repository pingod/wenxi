import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/parser_rules/hub.dart';
import 'package:asterlink/data/sources/catalog.dart';
import 'package:asterlink/data/sources/package.dart';
import 'package:asterlink/data/sources/service.dart';
import 'package:asterlink/domain/models.dart';
import 'source_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('PHP signed catalog carries three unrelated dynamic source types', () {
    final c = SourceCatalog.verify(
      sourceEnvelope(),
      sourcePublicKey,
      sourceTestNow,
    );
    expect(c.releases.map((r) => r.package.id), [
      'json_library',
      'html_library',
      'signed_library',
    ]);
    expect(c.releases.every((r) => r.package.compatible), true);
    for (final name in ['catalog-wrong-purpose', 'catalog-bad-hash']) {
      expect(
        () => SourceCatalog.verify(
          sourceEnvelope(name),
          sourcePublicKey,
          sourceTestNow,
        ),
        throwsA(isA<SourceError>()),
      );
    }
    final damaged = sourceEnvelope(),
        bytes = base64Decode(damaged.str('payload'))..[100] ^= 1;
    expect(
      () => SourceCatalog.verify(
        {...damaged, 'payload': base64Encode(bytes)},
        sourcePublicKey,
        sourceTestNow,
      ),
      throwsA(isA<SourceError>()),
    );
    final future = SourceCatalog.verify(
      sourceEnvelope('catalog-future'),
      sourcePublicKey,
      sourceTestNow,
    );
    expect(future.releases.first.package.compatible, false);
    expect(future.releases.skip(1).every((r) => r.package.compatible), true);
    expect(
      () => SourceCatalog.verify(
        sourceEnvelope(),
        sourcePublicKey,
        sourceTestNow.add(const Duration(days: 8)),
      ),
      throwsA(isA<SourceError>()),
    );
  });

  group('Source catalog and task persistence', () {
    late Directory directory;
    late ParserRuleHub hub;
    late RemoteSources sources;
    late Json envelope;
    late DateTime now;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('asterlink-sources-');
      now = sourceTestNow;
      envelope = sourceEnvelope();
      hub = ParserRuleHub(
        store: Vault(StateStore.memory()),
        directory: directory,
        url: 'https://hub.example.com',
        apiKey: 'fixture',
        publicKey: sourcePublicKey,
      );
      sources = RemoteSources(
        hub: hub,
        directory: directory,
        clock: () => now,
        fetch: (_, _) async => envelope,
        originFetch: sourceOrigin,
      );
    });
    tearDown(() async {
      await sources.close();
      await hub.close();
      await directory.delete(recursive: true);
    });
    test(
      'Updates atomically replace an existing Windows cache and reject rollback/conflict',
      () async {
        expect(await sources.refresh(force: true), true);
        envelope = sourceEnvelope('catalog-2');
        expect(await sources.refresh(force: true), true);
        expect(sources.releases.first.version, 2);
        envelope = sourceEnvelope();
        expect(await sources.refresh(force: true), false);
        expect(sources.lastError, 'SOURCE_ROLLBACK');
        envelope = sourceEnvelope('catalog-conflict');
        expect(await sources.refresh(force: true), false);
        expect(sources.releases.first.version, 2);
        await sources.close();
        sources = RemoteSources(
          hub: hub,
          directory: directory,
          clock: () => now,
          fetch: (_, _) async => envelope,
        );
        await sources.load();
        expect(sources.releases.first.version, 2);
        expect(await sources.refresh(force: true), false);
      },
    );
    test(
      'Same revision with conflicting package contents is rejected',
      () async {
        await sources.refresh(force: true);
        envelope = sourceEnvelope('catalog-conflict');
        expect(await sources.refresh(force: true), false);
        expect(sources.releases.first.version, 1);
      },
    );
    test(
      'Expired cached catalogs keep the rollback watermark but cannot start new work',
      () async {
        await sources.refresh(force: true);
        now = now.add(const Duration(days: 8));
        expect(sources.releases, isEmpty);
        expect(sources.ready, false);
        await sources.close();
        sources = RemoteSources(
          hub: hub,
          directory: directory,
          clock: () => now,
          fetch: (_, _) async => sourceEnvelope('catalog-2'),
        );
        await sources.load();
        expect(sources.ready, false);
        expect(await sources.refresh(force: true), false);
      },
    );
    test('A response from a replaced endpoint is discarded', () async {
      await sources.close();
      final pending = Completer<Json>();
      sources = RemoteSources(
        hub: hub,
        directory: directory,
        clock: () => now,
        fetch: (url, _) => url.contains('new-hub')
            ? Future.value(sourceEnvelope('catalog-2'))
            : pending.future,
      );
      final first = sources.refresh(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      hub.updateEndpoint(Uri.parse('https://new-hub.example.com'));
      pending.complete(sourceEnvelope());
      expect(await first, false);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sources.refresh(force: true);
      expect(sources.releases.first.version, 2);
    });
    for (final sourceId in ['json_library', 'html_library', 'signed_library']) {
      test(
        '$sourceId resolves and prepares a download through native modules',
        () async {
          await sources.refresh(force: true);
          final release = sources.releases.firstWhere(
            (r) => r.package.id == sourceId,
          );
          final host = release.package.json.list('match').first.str('host');
          final session = await sources.open(release, {
            'url': 'https://$host/share/sample',
          });
          final spec = await sources.download(
            session,
            session.items.firstWhere((f) => !f.isDirectory),
          );
          expect(spec.url, startsWith('https://files.example.com/'));
          expect(spec.platform, isNull);
          expect(RemoteSources.owns(spec), true);
          expect(spec.source?['sourceId'], sourceId);
          if (sourceId == 'json_library') {
            expect(
              (await sources.list(session, next: true)).items.single.id,
              'two',
            );
            expect(
              (await sources.list(
                session,
                directory: session.items.last,
              )).items.single.id,
              'inside',
            );
            expect(
              (await sources.list(session, search: 'sample')).items.single.id,
              'found',
            );
          }
        },
        skip: !hasSourceNative,
      );
    }
    test(
      'An open v1 session still archives v1 after v2 arrives, and survives restart',
      () async {
        await sources.refresh(force: true);
        final session = await sources.open(sources.releases.first, {
          'url': jsonSourceUrl,
        });
        envelope = sourceEnvelope('catalog-2');
        await sources.refresh(force: true);
        final spec = await sources.download(session, session.items.first);
        expect(spec.url, contains('/v1-one'));
        expect(spec.source?['packageVersion'], 1);
        final roundTrip = DownloadSpec.fromJson(
          jsonDecode(jsonEncode(spec.toJson())),
        );
        await sources.close();
        sources = RemoteSources(
          hub: hub,
          directory: directory,
          clock: () => now,
          fetch: (_, _) async => envelope,
          originFetch: sourceOrigin,
        );
        final restored = await sources.refreshDownload(roundTrip);
        expect(restored.url, contains('/v1-one'));
        expect(restored.source?['packageVersion'], 1);
        envelope = sourceEnvelope('catalog-disabled');
        await sources.refresh(force: true);
        await expectLater(
          sources.refreshDownload(roundTrip),
          throwsA(
            isA<SourceError>().having((e) => e.code, 'code', 'SOURCE_DISABLED'),
          ),
        );
      },
      skip: !hasSourceNative,
    );
    test(
      'Tampered archived source packages cannot run after restart',
      () async {
        await sources.refresh(force: true);
        final session = await sources.open(sources.releases.first, {
          'url': jsonSourceUrl,
        });
        final spec = await sources.download(session, session.items.first);
        final archives = await directory
            .list(recursive: true)
            .where(
              (f) =>
                  f is File &&
                  f.path.contains('archive-') &&
                  f.path.endsWith('.json'),
            )
            .toList();
        await (archives.single as File).writeAsString('{}');
        await expectLater(
          sources.refreshDownload(spec),
          throwsA(
            isA<SourceError>().having(
              (e) => e.code,
              'code',
              'SOURCE_SIGNATURE',
            ),
          ),
        );
      },
      skip: !hasSourceNative,
    );
  });
  final actual = Platform.environment['SOURCE_TEST_EXPORT_DIR'];
  if (actual != null) {
    test(
      'App verifies the exact catalog built by the backend lifecycle test',
      () {
        final envelope = asJson(
          jsonDecode(File('$actual/catalog.json').readAsStringSync()),
        );
        final key = File('$actual/public-key.txt').readAsStringSync();
        expect(
          SourceCatalog.verify(
            envelope,
            key,
            DateTime.now(),
          ).releases.single.package.id,
          'json_library',
        );
      },
    );
  }
}
