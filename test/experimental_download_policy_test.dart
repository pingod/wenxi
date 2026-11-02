import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/cookie_cloud.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/settings.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'UC guest recovery setting migrates once and preserves an explicit choice',
    () {
      expect(const AppSettings().ucGuestDirectDownload, isTrue);
      expect(
        AppSettings.fromJson({
          'ucGuestDirectDownload': false,
        }).ucGuestDirectDownload,
        isTrue,
      );
      final saved = const AppSettings(ucGuestDirectDownload: false).toJson();
      expect(AppSettings.fromJson(saved).ucGuestDirectDownload, isFalse);
      expect(AppSettings.fromJson({}).quarkGuestDirectDownload, isFalse);
    },
  );
  for (final platform in [CloudPlatform.quark, CloudPlatform.uc]) {
    final quark = platform == CloudPlatform.quark;
    final domain = quark ? 'quark.cn' : 'uc.cn';
    final flag = quark
        ? 'quarkAuthenticatedDirectDownload'
        : 'ucAuthenticatedDirectDownload';
    final guestFlag = quark
        ? 'quarkGuestDirectDownload'
        : 'ucGuestDirectDownload';
    final file = CloudFile(
      id: 'original',
      name: 'original.bin',
      // UC guests must still be able to download above Quark's 50 MB limit.
      size: quark ? 1024 : 100 * 1024 * 1024,
      token: 'share-file-token',
    );
    final session = BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: 'share',
      rootId: '0',
      metadata: {'shareId': 'share', 'stoken': 'share-token'},
    );
    final account = Credential(platform.label, {
      'primary': '__pus=account; __puus=account',
      '${quark ? 'quark' : 'uc'}SessionRefreshedAt':
          '${DateTime.now().millisecondsSinceEpoch}',
    });

    FakeHttp transport({bool requireAccount = false}) => FakeHttp((r) {
      if (r.method == 'POST' && r.uri.path.endsWith('/file/download')) {
        if (requireAccount && (r.headers['Cookie'] ?? '').isEmpty) {
          return jsonResponse({'status': 400, 'code': 23018}, 400);
        }
        expect(r.json['fids_token'], ['share-file-token']);
        if (requireAccount) {
          expect(r.headers['Cookie'], contains('__pus=account'));
        }
        return jsonResponse({
          'status': 200,
          'code': 0,
          'data': [
            {
              'fid': file.id,
              'size': file.size,
              'download_url': 'https://dl.$domain/file',
            },
          ],
        });
      }
      expect(r.method, 'GET');
      expect(r.uri.host, 'dl.$domain');
      return HttpResult(206, 'x', {
        'content-range': ['bytes 0-0/${file.size}'],
        'content-length': ['1'],
      });
    });

    AppServices servicesFor(FakeHttp http, Map<String, Object?> settings) {
      final services = AppServices(
        store: StateStore.memory({'settings': settings}),
        dataDirectory: Directory('test-fixture'),
        cacheDirectory: Directory('test-fixture/cache'),
        files: FakeFiles(Directory('test-fixture/saved')),
        transport: FakeNative(),
        http: http,
        platformFeatures: false,
        controlEnabled: false,
      );
      addTearDown(services.close);
      return services;
    }

    test('${platform.key} guests ignore disabled and legacy flags', () async {
      for (final enabled in [false, true]) {
        final http = transport();
        final services = servicesFor(http, {flag: enabled, guestFlag: false});
        final spec = await services.cloud
            .connector(platform)
            .download(session, file, null);
        expect(spec.expectedSize, file.size);
        expect(spec.guestDownload, isTrue);
        expect(spec.cleanup, isNull);
        expect(http.calls, hasLength(2));
        expect(http.calls.first.headers['Cookie'], isEmpty);
      }
    });

    test(
      '${platform.key} signed-in direct downloads follow the current flag',
      () async {
        final http = transport(requireAccount: true);
        final services = servicesFor(http, {
          guestFlag: false,
          'ucGuestDownloadPolicy': 1,
        });
        final connector =
            services.cloud.connector(platform) as CookieCloudConnector;
        expect(
          await connector.tryShareDownload(session, file, account),
          isNull,
        );
        expect(http.calls, isEmpty);

        await services.updateSettings({guestFlag: true});
        // Guest restrictions may fall back to normal transfer, but must not
        // silently enable the separately controlled authenticated direct path.
        expect(
          await connector.tryShareDownload(session, file, account),
          isNull,
        );
        expect(http.calls, hasLength(1));
        expect(http.calls.single.headers['Cookie'], isEmpty);

        http.calls.clear();
        await services.updateSettings({guestFlag: false});
        expect(
          await connector.tryShareDownload(session, file, account),
          isNull,
        );
        expect(http.calls, isEmpty);
      },
    );

    test(
      '${platform.key} signed-in guest option isolates the saved cookie',
      () async {
        final http = transport();
        final services = servicesFor(http, {guestFlag: true});
        final connector =
            services.cloud.connector(platform) as CookieCloudConnector;
        final spec = await connector.tryShareDownload(session, file, account);
        expect(spec!.expectedSize, file.size);
        expect(spec.guestDownload, isTrue);
        expect(spec.cleanup, isNull);
        expect(http.calls, hasLength(2));
        expect(http.calls.first.headers['Cookie'], isEmpty);
      },
    );

    test(
      '${platform.key} authenticated route stays independent of guest option',
      () async {
        final http = transport(requireAccount: true);
        final services = servicesFor(http, {flag: true});
        final connector =
            services.cloud.connector(platform) as CookieCloudConnector;
        final spec = await connector.tryShareDownload(session, file, account);
        if (quark) {
          expect(spec!.expectedSize, file.size);
          expect(spec.guestDownload, isFalse);
          expect(http.calls, hasLength(2));
          expect(http.calls.first.headers['Cookie'], contains('__pus=account'));
          http.calls.clear();
          await services.updateSettings({guestFlag: true});
          final fallback = await connector.tryShareDownload(
            session,
            file,
            account,
          );
          expect(fallback, isNotNull);
          expect(fallback!.guestDownload, isFalse);
          expect(http.calls, hasLength(3));
          expect(http.calls.first.headers['Cookie'], isEmpty);
        } else {
          // Old UC settings must not re-enable the removed authenticated feature.
          expect(spec, isNull);
          expect(http.calls, hasLength(1));
          expect(http.calls.single.headers['Cookie'], isEmpty);
          expect(services.settings.toJson().containsKey(flag), isFalse);
        }
      },
    );
    test(
      '${platform.key} direct helper keeps its platform guest setting',
      () async {
        final http = transport();
        final services = servicesFor(http, {});
        final connector =
            services.cloud.connector(platform) as CookieCloudConnector;
        final spec = await connector.tryShareDownload(session, file, account);
        if (quark) {
          expect(spec, isNull);
          expect(http.calls, isEmpty);
        } else {
          expect(spec!.guestDownload, isTrue);
          expect(http.calls, hasLength(2));
          expect(http.calls.first.headers['Cookie'], isEmpty);
        }
      },
    );
  }
}
