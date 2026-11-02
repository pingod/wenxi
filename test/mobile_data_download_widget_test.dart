import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/platform/download_network.dart';
import 'package:asterlink/ui/common.dart';
import 'package:asterlink/ui/mobile_data_download_prompt.dart';
import 'package:asterlink/ui/mine_page.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final active = <AppServices>[];
  var completedBatches = 0;
  const promptKey = ValueKey('mobile-data-download-prompt');
  const rememberKey = ValueKey('mobile-data-download-remember');
  const settingKey = ValueKey('mobile-data-download-warning-setting');
  const specs = [
    DownloadSpec(url: 'https://example.com/one.zip', fileName: 'one.zip'),
    DownloadSpec(url: 'https://example.com/two.zip', fileName: 'two.zip'),
  ];

  void warningTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      completedBatches = 0;
      try {
        await body(tester);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        for (final services in active) {
          await services.close();
        }
        active.clear();
        await tester.pumpAndSettle();
      }
    });
  }

  Future<AppServices> render(
    WidgetTester tester, {
    DownloadNetwork network = DownloadNetwork.mobile,
    StateStore? store,
    bool shell = false,
  }) async {
    final services = AppServices(
      store: store ?? StateStore.memory(),
      dataDirectory: Directory('test-fixture/mobile-warning'),
      cacheDirectory: Directory('test-fixture/mobile-warning/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('test-fixture/mobile-warning/saved')),
      http: FakeHttp(),
      platformFeatures: false,
      controlEnabled: false,
      downloadNetworkReader: () async => network,
    );
    active.add(services);
    await tester.pumpWidget(
      shell
          ? AsterLinkApp(services, initialTab: 4)
          : MaterialApp(
              theme: appTheme(Brightness.light),
              home: Scaffold(
                body: Column(
                  children: [
                    MobileDataDownloadPrompt(services.mobileDataDownloads),
                    Builder(
                      builder: (context) => TextButton(
                        onPressed: () async {
                          final result = await busy(
                            context,
                            () => services.downloads.enqueueAll(specs),
                          );
                          if (result != null) completedBatches++;
                        },
                        child: const Text('测试下载'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
    await tester.pumpAndSettle();
    return services;
  }

  Future<void> start(WidgetTester tester) async {
    await tester.tap(find.text('测试下载'));
    // The progress route behind the confirmation animates until the user
    // answers, so pump bounded frames instead of waiting for it to settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  warningTest(
    'Cancelling a checked warning creates no tasks and is not shown as an error',
    (tester) async {
      final services = await render(tester);
      await start(tester);
      expect(find.byKey(promptKey), findsOneWidget);
      expect(services.downloads.tasks, isEmpty);
      await tester.tap(find.byKey(rememberKey));
      await tester.pump();
      await tester.tap(
        find.descendant(of: find.byKey(promptKey), matching: find.text('取消')),
      );
      await tester.pumpAndSettle();
      expect(services.downloads.tasks, isEmpty);
      expect(services.settings.warnOnMobileDataDownload, true);
      expect(completedBatches, 0);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  warningTest(
    'A batch has one confirmation and ordinary consent is only for this action',
    (tester) async {
      final services = await render(tester);
      await start(tester);
      expect(find.byKey(promptKey), findsOneWidget);
      await tester.tap(find.text('继续下载'));
      await tester.pumpAndSettle();
      expect(completedBatches, 1);
      expect(services.downloads.tasks, hasLength(2));
      expect(services.settings.warnOnMobileDataDownload, true);
      await start(tester);
      expect(find.byKey(promptKey), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(completedBatches, 1);
      expect(services.downloads.tasks, hasLength(2));
    },
  );

  warningTest(
    'Remembered consent survives reconstruction and the real settings switch restores it',
    (tester) async {
      final services = await render(tester);
      await start(tester);
      await tester.tap(find.byKey(rememberKey));
      await tester.pump();
      await tester.tap(find.text('继续下载'));
      await tester.pumpAndSettle();
      expect(services.settings.warnOnMobileDataDownload, false);
      expect(completedBatches, 1);
      await start(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(promptKey), findsNothing);
      expect(completedBatches, 2);

      final reopened = await render(
        tester,
        store: StateStore.memory({'settings': services.settings.toJson()}),
        shell: true,
      );
      expect(reopened.settings.warnOnMobileDataDownload, false);
      await tester.scrollUntilVisible(
        find.byKey(settingKey),
        300,
        scrollable: find
            .descendant(
              of: find.byType(MinePage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(settingKey));
      await tester.pumpAndSettle();
      expect(reopened.settings.warnOnMobileDataDownload, true);
      final adding = reopened.downloads.enqueue(specs.first);
      final cancelled = expectLater(
        adding,
        throwsA(isA<DownloadConfirmationCancelled>()),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(promptKey), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await cancelled;
      expect(reopened.downloads.tasks, isEmpty);
    },
  );

  warningTest(
    'Wi-Fi skips the dialog and an unidentified VPN warns without claiming it is mobile',
    (tester) async {
      final wifi = await render(tester, network: DownloadNetwork.other);
      await start(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(promptKey), findsNothing);
      expect(wifi.downloads.tasks, hasLength(2));
      final unknown = await render(tester, network: DownloadNetwork.unknown);
      await start(tester);
      expect(find.textContaining('暂时无法确认当前网络类型'), findsOneWidget);
      expect(unknown.downloads.tasks, isEmpty);
      await tester.tap(
        find.descendant(of: find.byKey(promptKey), matching: find.text('取消')),
      );
      await tester.pumpAndSettle();
    },
  );

  warningTest(
    'Background requests wait for the foreground and removing the UI cancels the request',
    (tester) async {
      final services = await render(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final adding = services.downloads.enqueue(specs.first);
      final cancelled = expectLater(
        adding,
        throwsA(isA<DownloadConfirmationCancelled>()),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(promptKey), findsNothing);
      expect(services.downloads.tasks, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(promptKey), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await cancelled;
      expect(services.downloads.tasks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  warningTest('Parent operation cancellation removes the displayed warning', (
    tester,
  ) async {
    final services = await render(tester), scope = RequestScope();
    final adding = scope.run(() => services.downloads.enqueue(specs.first));
    final cancelled = expectLater(adding, throwsA(isA<Exception>()));
    await tester.pumpAndSettle();
    expect(find.byKey(promptKey), findsOneWidget);
    scope.cancel();
    await tester.pumpAndSettle();
    await cancelled;
    expect(find.byKey(promptKey), findsNothing);
    expect(services.downloads.tasks, isEmpty);
  });

  warningTest(
    'The checkbox and actions fit a small phone at large text scale',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final services = await render(tester);
      await start(tester);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(rememberKey));
      await tester.pump();
      await tester.tap(find.byKey(rememberKey));
      await tester.pump();
      await tester.tap(find.text('继续下载'));
      await tester.pumpAndSettle();
      expect(services.settings.warnOnMobileDataDownload, false);
      expect(completedBatches, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
