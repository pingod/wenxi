import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/app_update_service.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/remote_control.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/domain/torrent.dart';
import 'package:asterlink/download/mobile_data_download_guard.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/app_update_installer.dart';
import 'package:asterlink/platform/download_network.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

class _ProbeHttp extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(RemoteIdentity(4, '"mobile-fixture"', null), false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppServices services;
  late FakeNative native;
  late DownloadNetwork network;
  var checks = 0, prompts = 0;
  const specs = [
    DownloadSpec(url: 'https://example.com/one.zip', fileName: 'one.zip'),
    DownloadSpec(url: 'https://example.com/two.zip', fileName: 'two.zip'),
  ];
  MobileDataDownloadGuard getGuard() => services.mobileDataDownloads;

  Future<MobileDataDownloadRequest> nextPrompt() async {
    final guard = getGuard(), ready = Completer<MobileDataDownloadRequest>();
    void changed() {
      final request = guard.request;
      if (request != null && !request.answered && !ready.isCompleted) {
        ready.complete(request);
      }
    }

    guard.addListener(changed);
    changed();
    try {
      return await ready.future.timeout(const Duration(seconds: 3));
    } finally {
      guard.removeListener(changed);
    }
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('aster-mobile-warning-');
    network = DownloadNetwork.mobile;
    checks = prompts = 0;
    native = FakeNative()..finish = false;
    services = AppServices(
      store: StateStore.memory(),
      dataDirectory: root,
      cacheDirectory: Directory(p.join(root.path, 'cache')),
      transport: native,
      files: FakeFiles(Directory(p.join(root.path, 'saved'))),
      http: FakeHttp(),
      transferHttp: _ProbeHttp(),
      platformFeatures: false,
      controlEnabled: false,
      downloadNetworkReader: () async {
        checks++;
        return network;
      },
    );
    getGuard().attachPresenter();
    MobileDataDownloadRequest? previous;
    getGuard().addListener(() {
      final request = getGuard().request;
      if (request != null && request != previous) {
        previous = request;
        prompts++;
      }
    });
  });

  tearDown(() async {
    await services.close();
    expect(
      p.isWithin(Directory.systemTemp.absolute.path, root.absolute.path),
      true,
    );
    await root.delete(recursive: true);
  });

  test(
    'A mobile batch creates no tasks or writers before consent; cancel aborts it',
    () async {
      await services.downloads.initialize();
      final adding = services.downloads.enqueueAll(specs);
      final rejected = expectLater(
        adding,
        throwsA(isA<DownloadConfirmationCancelled>()),
      );
      final request = await nextPrompt();
      expect(services.downloads.tasks, isEmpty);
      expect(services.store.data.list('tasks'), isEmpty);
      expect(native.begins, isEmpty);
      expect(native.openCount, 0);
      // Confirmation must never hold the scheduling/settings gate.
      await services
          .updateSettings({'threads': 16})
          .timeout(const Duration(seconds: 2));
      await services.downloads.pauseAll().timeout(const Duration(seconds: 2));
      getGuard().answer(request, MobileDataDownloadChoice.cancel);
      await rejected;
      expect(prompts, 1);
      expect(services.settings.warnOnMobileDataDownload, isTrue);
      expect(services.downloads.tasks, isEmpty);
    },
  );

  test(
    'Consent starts the entire batch once; a later mobile action asks again',
    () async {
      await services.downloads.initialize();
      final adding = services.downloads.enqueueAll(specs);
      getGuard().answer(await nextPrompt(), MobileDataDownloadChoice.download);
      expect(await adding, hasLength(2));
      expect(prompts, 1);
      final later = services.downloads.enqueue(specs.first);
      final rejected = expectLater(
        later,
        throwsA(isA<DownloadConfirmationCancelled>()),
      );
      getGuard().answer(await nextPrompt(), MobileDataDownloadChoice.cancel);
      await rejected;
      expect(prompts, 2);
      expect(services.downloads.tasks, hasLength(2));
    },
  );

  test(
    'Remembered consent skips future checks and a settings change restores reminders',
    () async {
      final adding = services.downloads.enqueue(specs.first);
      getGuard().answer(
        await nextPrompt(),
        MobileDataDownloadChoice.alwaysDownload,
      );
      await adding;
      expect(services.settings.warnOnMobileDataDownload, isFalse);
      await services.updateSettings({'threads': 24});
      await services.downloads.enqueue(specs.last);
      expect(checks, 1);
      expect(prompts, 1);
      await services.updateSettings({'warnOnMobileDataDownload': true});
      final later = services.downloads.enqueue(specs.first);
      final rejected = expectLater(
        later,
        throwsA(isA<DownloadConfirmationCancelled>()),
      );
      getGuard().answer(await nextPrompt(), MobileDataDownloadChoice.cancel);
      await rejected;
      expect(prompts, 2);
    },
  );

  test(
    'Each action reads the current network; local transfers skip mobile consent',
    () async {
      network = DownloadNetwork.other;
      await services.downloads.enqueueAll(specs);
      expect(prompts, 0);
      network = DownloadNetwork.mobile;
      await services.downloads.enqueue(
        const DownloadSpec(
          url: 'http://192.168.1.2:1234/file',
          fileName: 'local.zip',
          profile: 'lan',
        ),
      );
      expect(checks, 1);
      final later = services.downloads.enqueue(specs.first);
      final rejected = expectLater(
        later,
        throwsA(isA<DownloadConfirmationCancelled>()),
      );
      getGuard().answer(await nextPrompt(), MobileDataDownloadChoice.cancel);
      await rejected;
      expect(checks, 2);
      expect(prompts, 1);
    },
  );

  test(
    'Batch resume asks once and cancellation leaves every task paused',
    () async {
      await services.store.put('tasks', [
        for (var index = 0; index < specs.length; index++)
          DownloadTask(
            id: 'paused-$index',
            spec: specs[index],
            createdAt: index,
            status: DownloadStatus.paused,
          ).toJson(),
      ]);
      await services.downloads.initialize();
      final resuming = services.downloads.resumeAll();
      final rejected = expectLater(
        resuming,
        throwsA(isA<DownloadConfirmationCancelled>()),
      );
      getGuard().answer(await nextPrompt(), MobileDataDownloadChoice.cancel);
      await rejected;
      expect(
        services.downloads.tasks.every(
          (task) => task.status == DownloadStatus.paused,
        ),
        true,
      );
      expect(native.begins, isEmpty);
      expect(prompts, 1);
      final retry = services.downloads.batch([
        'paused-0',
        'paused-1',
      ], DownloadBatchAction.resume);
      getGuard().answer(await nextPrompt(), MobileDataDownloadChoice.download);
      expect((await retry).succeeded, hasLength(2));
      expect(prompts, 2);
    },
  );

  test(
    'Single resume and BT batch also require consent before changing the queue',
    () async {
      await services.store.put('tasks', [
        DownloadTask(
          id: 'paused',
          spec: specs.first,
          createdAt: 1,
          status: DownloadStatus.paused,
        ).toJson(),
      ]);
      await services.downloads.initialize();
      final resuming = services.downloads.resume('paused');
      final rejected = expectLater(
        resuming,
        throwsA(isA<DownloadConfirmationCancelled>()),
      );
      getGuard().answer(await nextPrompt(), MobileDataDownloadChoice.cancel);
      await rejected;
      expect(services.downloads.task('paused')!.status, DownloadStatus.paused);
      final torrent = services.downloads.enqueueTorrent(
        const TorrentInfo(
          '0123456789012345678901234567890123456789',
          'files',
          'torrent-data',
          [TorrentFile(0, 'one.zip', 4), TorrentFile(1, 'two.zip', 4)],
        ),
        [0, 1],
      );
      final torrentRejected = expectLater(
        torrent,
        throwsA(isA<DownloadConfirmationCancelled>()),
      );
      getGuard().answer(await nextPrompt(), MobileDataDownloadChoice.cancel);
      await torrentRejected;
      expect(services.downloads.tasks, hasLength(1));
      expect(native.begins, isEmpty);
      expect(prompts, 2);
    },
  );

  test(
    'Cancelling the parent operation removes its unanswered prompt',
    () async {
      final scope = RequestScope();
      final adding = scope.run(() => services.downloads.enqueue(specs.first));
      final rejected = expectLater(adding, throwsA(isA<AppException>()));
      await nextPrompt();
      scope.cancel();
      await rejected;
      expect(getGuard().request, isNull);
      expect(services.downloads.tasks, isEmpty);
    },
  );

  test(
    'An immediate pause then resume still asks before resuming mobile data',
    () async {
      network = DownloadNetwork.other;
      await services.downloads.initialize();
      final id = await services.downloads.enqueue(specs.first);
      final pausing = services.downloads.pause(id);
      network = DownloadNetwork.mobile;
      final resuming = services.downloads.resume(id);
      final rejected = expectLater(
        resuming,
        throwsA(isA<DownloadConfirmationCancelled>()),
      );
      await pausing;
      getGuard().answer(await nextPrompt(), MobileDataDownloadChoice.cancel);
      await rejected;
      expect(services.downloads.task(id)!.status, DownloadStatus.paused);
      expect(prompts, 1);
    },
  );

  test(
    'Closing with a pending prompt cancels without blocking shutdown',
    () async {
      final adding = services.downloads.enqueue(specs.first);
      final rejected = expectLater(
        adding,
        throwsA(isA<DownloadConfirmationCancelled>()),
      );
      await nextPrompt();
      await services.close().timeout(const Duration(seconds: 3));
      await rejected;
      expect(services.downloads.tasks, isEmpty);
    },
  );

  test(
    'An update cancelled at the mobile warning is neither started nor marked failed',
    () async {
      final update = RemoteUpdate(
        '2.0.0',
        200,
        Uri.parse('https://example.com/app.apk'),
        '',
      );
      final updater = AppUpdateService(
        platform: 'android',
        cloud: services.cloud,
        downloads: services.downloads,
        files: services.files,
        installer: AppUpdateInstaller(
          platform: 'android',
          desktop: services.desktop,
        ),
        currentUpdate: () => update,
        inForeground: () => true,
        openDownloads: () {},
      );
      addTearDown(updater.close);
      final updating = updater.start(update);
      getGuard().answer(await nextPrompt(), MobileDataDownloadChoice.cancel);
      expect(await updating, false);
      expect(updater.error(update), isNull);
      expect(updater.busy(update), false);
      expect(services.downloads.tasks, isEmpty);
    },
  );

  test(
    'The reminder defaults on and remembered consent survives encrypted state reopening',
    () async {
      final directory = Directory(p.join(root.path, 'persistent-state'));
      final key = Uint8List.fromList(List.generate(32, (index) => index));
      final store = await StateStore.open(directory, testKey: key);
      expect(
        AppSettings.fromJson(
          store.data.obj('settings'),
        ).warnOnMobileDataDownload,
        true,
      );
      await store.put(
        'settings',
        const AppSettings(warnOnMobileDataDownload: false).toJson(),
      );
      await store.flush();
      final reopened = await StateStore.open(directory, testKey: key);
      expect(
        AppSettings.fromJson(
          reopened.data.obj('settings'),
        ).warnOnMobileDataDownload,
        false,
      );
      reopened.dispose();
      store.dispose();
    },
  );

  test(
    'Native network status is fresh on each read and failures remain unknown',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var value = 'mobile';
      messenger.setMockMethodCallHandler(nativeChannel, (call) async {
        expect(call.method, 'downloadNetwork');
        if (value == 'error') throw PlatformException(code: 'restricted');
        return value;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(nativeChannel, null),
      );
      expect(await readDownloadNetwork(), DownloadNetwork.mobile);
      value = 'other';
      expect(await readDownloadNetwork(), DownloadNetwork.other);
      value = 'error';
      expect(await readDownloadNetwork(), DownloadNetwork.unknown);
    },
  );
}
