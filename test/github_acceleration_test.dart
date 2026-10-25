import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/download_network_policy.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/github_acceleration.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

class _ProxyProbe extends TransferHttp {
  final urls = <String>[];
  Future<void> Function()? duringProbe;

  @override
  Future<Probe> probe(String url, Map<String, String> headers) async {
    urls.add(url);
    await duringProbe?.call();
    return const Probe(RemoteIdentity(4, '"github-file"', null), false);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const raw = 'https://raw.githubusercontent.com/sample/repo/main/file.txt';
  const release = 'https://github.com/sample/repo/releases/download/v1/app.exe';
  const proxy = GitHubAcceleration(mode: 'gh-proxy.com');

  test(
    'New installs and legacy direct settings enable the default proxy once',
    () {
      expect(const AppSettings().githubAcceleration.mode, 'gh-proxy.com');
      expect(
        AppSettings.fromJson({}).githubAcceleration.urlFor(raw),
        'https://gh-proxy.com/$raw',
      );
      final migrated = AppSettings.fromJson({
        'githubAcceleration': {
          'mode': 'direct',
          'customUrl': 'https://mirror.example/prefix/',
        },
      });
      expect(migrated.githubAcceleration.mode, 'gh-proxy.com');
      expect(
        migrated.githubAcceleration.customUrl,
        'https://mirror.example/prefix/',
      );
      final disabled = migrated.update({
        'githubAcceleration': {
          ...migrated.githubAcceleration.toJson(),
          'mode': 'direct',
        },
      });
      final restored = AppSettings.fromJson(disabled.toJson());
      expect(restored.githubAcceleration.urlFor(raw), raw);
      expect(
        restored.update({'threads': 12}).githubAcceleration.mode,
        'direct',
      );
      expect(
        restored.githubAcceleration.customUrl,
        'https://mirror.example/prefix/',
      );
    },
  );

  test(
    'Existing preset and custom selections survive migration, saving and switching',
    () {
      for (final mode in GitHubAcceleration.presets.keys) {
        expect(
          AppSettings.fromJson({
            'githubAcceleration': {'mode': mode},
          }).githubAcceleration.mode,
          mode,
        );
      }
      final settings = const AppSettings().update({
        'githubAcceleration': {
          'mode': 'custom',
          'customUrl': 'mirror.example/prefix',
        },
      });
      final restored = AppSettings.fromJson(settings.toJson());
      expect(
        restored.githubAcceleration.urlFor(raw),
        'https://mirror.example/prefix/$raw',
      );
      final disabled = restored.update({
        'githubAcceleration': {
          ...restored.githubAcceleration.toJson(),
          'mode': 'direct',
        },
      });
      expect(disabled.githubAcceleration.urlFor(raw), raw);
      expect(
        disabled.githubAcceleration.customUrl,
        'https://mirror.example/prefix/',
      );
      expect(
        AppSettings.fromJson({
          'githubAcceleration': {
            'mode': 'custom',
            'customUrl': 'https://user:secret@proxy.example/',
          },
        }).githubAcceleration.mode,
        'direct',
      );
    },
  );

  test(
    'Custom prefixes accept paths but reject embedded credentials and URLs',
    () {
      expect(
        GitHubAcceleration.normalizePrefix('  https://proxy.example:8443/gh  '),
        'https://proxy.example:8443/gh/',
      );
      for (final invalid in [
        '',
        'ftp://proxy.example/',
        'https://user:secret@proxy.example/',
        'https://proxy.example/?token=secret',
        'https://proxy.example/#section',
        'https://proxy.example/https://github.com/sample/repo',
        'https://proxy.example/\nInjected: value',
      ]) {
        expect(
          () => GitHubAcceleration.normalizePrefix(invalid),
          throwsA(isA<AppException>()),
        );
      }
    },
  );

  test(
    'Public files and release assets use the proxy without double wrapping',
    () {
      for (final url in [
        raw,
        release,
        'https://github.com/sample/repo/releases/latest/download/app.exe',
        'https://github.com/sample/repo/archive/refs/heads/main.zip',
        'https://codeload.github.com/sample/repo/zip/refs/heads/main',
      ]) {
        final accelerated = proxy.urlFor(url);
        expect(accelerated, 'https://gh-proxy.com/$url');
        expect(proxy.urlFor(accelerated), accelerated);
      }
    },
  );

  test(
    'Credentials, private signed URLs, API calls and unrelated domains stay direct',
    () {
      for (final headers in [
        {'Authorization': 'Bearer private'},
        {'cOoKiE': 'session=private'},
        {'Proxy-Authorization': 'Basic private'},
        {'X-Token': 'private'},
        {'Referer': 'https://github.com/private?token=private'},
      ]) {
        expect(proxy.urlFor(raw, headers), raw);
      }
      for (final url in [
        '$raw?token=private',
        '$release?signature=private',
        'https://release-assets.githubusercontent.com/private?jwt=private',
        'https://api.github.com/repos/sample/repo/git/blobs/sha',
        'https://github.com.evil.example/sample/repo/releases/download/v1/app.exe',
        'https://user:private@raw.githubusercontent.com/sample/repo/main/file.txt',
      ]) {
        expect(proxy.urlFor(url), url);
      }
    },
  );

  test(
    'Signed source network permissions are retained without redirecting to a proxy',
    () {
      final policy = DownloadNetworkPolicy.fromJson({
        'hosts': ['raw.githubusercontent.com'],
        'schemes': ['https'],
        'ports': [443],
      });
      final spec = DownloadSpec(
        url: raw,
        fileName: 'file.txt',
        networkPolicy: policy,
      );
      expect(proxy.apply(spec), same(spec));
      expect(proxy.apply(spec).networkPolicy, same(policy));
    },
  );

  test(
    'Downloads default to a proxy and resume respects changing or disabling it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'aster-github-proxy-',
      );
      final store = StateStore.memory();
      final native = FakeNative()..finish = false;
      final http = _ProxyProbe();
      final manager = DownloadManager(
        store: store,
        engine: GopeedEngine(
          native,
          store,
          Vault(store),
          Directory(p.join(directory.path, 'engine')),
          Directory(p.join(directory.path, 'cache')),
        ),
        files: FakeFiles(Directory(p.join(directory.path, 'saved'))),
        cleanups: CleanupOutbox(store, FakeHttp()),
        http: http,
        refreshSource: (spec) async => spec,
      );
      try {
        await manager.initialize();
        http.duringProbe = () => store.put('settings', {
          'githubAcceleration': const GitHubAcceleration(
            mode: 'ghproxy.net',
          ).toJson(),
        });
        final id = await manager.enqueue(
          const DownloadSpec(
            url: release,
            fileName: 'app.exe',
            expectedSize: 4,
            appUpdateKey: 'fixture-update',
          ),
        );
        await until(() => native.begins.isNotEmpty);
        expect(http.urls.single, 'https://gh-proxy.com/$release');
        expect(native.begins.single.str('url'), http.urls.single);
        expect(manager.task(id)!.spec.url, release);
        expect(manager.task(id)!.spec.appUpdateKey, 'fixture-update');
        await manager.pause(id);
        http.duringProbe = null;
        await manager.resume(id);
        await until(() => native.begins.length == 2);
        expect(http.urls.last, 'https://ghproxy.net/$release');
        expect(native.begins.last.str('url'), http.urls.last);
        expect(manager.task(id)!.spec.url, release);
        await manager.pause(id);
        await store.put(
          'settings',
          const AppSettings(
            githubAcceleration: GitHubAcceleration(mode: 'direct'),
          ).toJson(),
        );
        await manager.resume(id);
        await until(() => native.begins.length == 3);
        expect(http.urls.last, release);
        expect(native.begins.last.str('url'), release);
        await manager.pause(id);
        expect(store.data.list('tasks').single.obj('spec').str('url'), release);
      } finally {
        await manager.close();
        manager.dispose();
        http.dio.close(force: true);
        store.dispose();
        expect(
          p.isWithin(
            Directory.systemTemp.absolute.path,
            directory.absolute.path,
          ),
          isTrue,
        );
        await directory.delete(recursive: true);
      }
    },
  );
}
