import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/download_request.dart';
import 'support.dart';
import 'uc_tv_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final guest in [null, false, true]) {
    test(
      'UC uses the signed-in account first with guest setting $guest',
      () async {
        final f = UcTvFixture(
          credential: ucTvCredential(authorized: false).withFields({
            'ucSessionRefreshedAt': '${DateTime.now().millisecondsSinceEpoch}',
          }, preserveRevision: true),
        );
        final services = AppServices(
          store: f.store,
          dataDirectory: Directory('test-fixture'),
          cacheDirectory: Directory('test-fixture/cache'),
          files: FakeFiles(Directory('test-fixture/saved')),
          transport: FakeNative(),
          http: f.http,
          platformFeatures: false,
          controlEnabled: false,
        );
        addTearDown(services.close);
        if (guest != null) {
          await services.updateSettings({'ucGuestDirectDownload': guest});
        }
        var notices = 0;
        final spec = await DownloadRequestContext(
          id: 'uc-account-priority',
          retries: 0,
          onGuestDownload: () => notices++,
        ).run(() => services.cloud.prepare(ucTvShare, ucTvVideo));

        expect(spec.url, 'https://media.example/original.mp4');
        expect(spec.guestDownload, isFalse);
        expect(spec.cleanup, isNotNull);
        expect(spec.source!['accountRevision'], 7);
        expect(notices, 0);
        final request = f.calls('/1/clouddrive/file/download').single;
        expect(request.json.containsKey('pwd_id'), isFalse);
        expect(request.json['fids'], ['saved-video']);
        expect(request.headers['Cookie'], f.credential.primary);
        expect(f.calls('/1/clouddrive/share/sharepage/save'), hasLength(1));
        expect(
          services.vault.credential(CloudPlatform.uc)!.primary,
          f.credential.primary,
        );
      },
    );
  }
}
