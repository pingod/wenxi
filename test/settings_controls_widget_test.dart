import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/app_text_scale.dart';
import 'package:asterlink/ui/font_size_page.dart';
import 'support.dart';

class _NonlinearTextScaler extends TextScaler {
  const _NonlinearTextScaler();

  @override
  double scale(double fontSize) => fontSize * (fontSize < 20 ? 1.8 : 1.4);

  @override
  double get textScaleFactor => 1.8;
}

class _SettingsProbe extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(RemoteIdentity(4, '"settings-fixture"', null), false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var systemFont = false;

  setUpAll(() async {
    for (final (family, asset) in [
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      (
        'packages/cupertino_icons/CupertinoIcons',
        'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      ),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (await font.exists()) {
      await (FontLoader('SettingsFixture')..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
      systemFont = true;
    }
  });

  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    final clock = Stopwatch()..start();
    bool settled() =>
        ready() && find.byType(CircularProgressIndicator).evaluate().isEmpty;
    do {
      await tester.pump(const Duration(milliseconds: 25));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    } while (!settled() && clock.elapsed < const Duration(seconds: 12));
    expect(settled(), true, reason: 'The settings action did not finish');
    await tester.pumpAndSettle();
  }

  Future<(AppServices, FakeNative)> render(
    WidgetTester tester, {
    int tab = 3,
    Size size = const Size(393, 864),
    double systemScale = 1,
    AppSettings settings = const AppSettings(theme: 'Light'),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = systemScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final native = FakeNative()..finish = false;
    late Directory root;
    late AppServices services;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('wenxi-settings-controls-');
      services = AppServices(
        store: StateStore.memory({'settings': settings.toJson()}),
        dataDirectory: root,
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        transport: native,
        files: FakeFiles(Directory(p.join(root.path, 'saved'))),
        http: FakeHttp(),
        transferHttp: _SettingsProbe(),
        platformFeatures: false,
        controlEnabled: false,
        clipboardReader: () async => null,
      );
      await services.downloads.initialize();
    });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var closed = false;
      final close = services.close().whenComplete(() => closed = true);
      await waitFor(tester, () => closed);
      await close;
      await tester.runAsync(() async {
        expect(
          p.isWithin(Directory.systemTemp.absolute.path, root.absolute.path),
          true,
        );
        await root.delete(recursive: true);
      });
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('settings-controls-capture'),
        child: AsterLinkApp(
          services,
          initialTab: tab == 0 ? 0 : tab + 1,
          fontFamily: systemFont ? 'SettingsFixture' : null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (services, native);
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> applyFont(
    WidgetTester tester,
    AppServices services,
    int percent,
  ) async {
    await tester.tap(find.byKey(const Key('font-size-apply')));
    await waitFor(tester, () => services.settings.fontScalePercent == percent);
  }

  Future<void> openMenu(WidgetTester tester, String title) async {
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  Future<void> customConcurrency(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('download-concurrency')));
    await tester.pumpAndSettle();
    await tap(tester, find.text('自定义…').last);
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    final directory = Platform.environment['APP_SETTINGS_PREVIEW_DIR'];
    if (directory == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('settings-controls-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(p.join(directory, '$name.png'));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  testWidgets(
    'Font preference preserves nonlinear scaling and follows system changes',
    (tester) async {
      TextScaler? observed;
      Future<void> build(TextScaler system, int percent) => tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(textScaler: system),
          child: AppTextScale(
            percent: percent,
            child: Builder(
              builder: (context) {
                observed = MediaQuery.textScalerOf(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      const nonlinear = _NonlinearTextScaler();
      await build(nonlinear, 100);
      expect(observed, same(nonlinear));
      await build(nonlinear, 150);
      expect(observed!.scale(12), closeTo(12 * 1.8 * 1.5, 0.0001));
      expect(observed!.scale(28), closeTo(28 * 1.4 * 1.5, 0.0001));
      await build(TextScaler.noScaling, 150);
      expect(observed!.scale(12), 18);
    },
  );

  testWidgets(
    'Font preview applies to pages and dialogs without replacing navigation state',
    (tester) async {
      final (services, _) = await render(tester, systemScale: 1.25);
      final shell = tester.state(find.byType(MainShell));
      await tap(tester, find.text('字体大小'));
      final page = tester.state(find.byType(FontSizePage));
      await tap(tester, find.byKey(const Key('font-size-140')));
      expect(services.settings.fontScalePercent, 100);
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byKey(const Key('font-size-preview'))),
        ).scale(14),
        closeTo(14 * 1.25 * 1.4, 0.0001),
      );
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byType(FontSizePage)),
        ).scale(14),
        17.5,
      );
      await applyFont(tester, services, 140);
      expect(
        services.store.data.obj('settings').integer('fontScalePercent'),
        140,
      );
      expect(tester.state(find.byType(FontSizePage)), same(page));
      expect(
        tester.state(find.byType(MainShell, skipOffstage: false)),
        same(shell),
      );
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byType(FontSizePage)),
        ).scale(14),
        closeTo(24.5, 0.0001),
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      services.requestDownloadManager();
      await tester.pumpAndSettle();
      await openMenu(tester, '新建下载');
      expect(
        MediaQuery.textScalerOf(tester.element(find.text('新建下载'))).scale(14),
        closeTo(24.5, 0.0001),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Font draft can be discarded and reset restores the current system size',
    (tester) async {
      final (services, _) = await render(
        tester,
        systemScale: 1.25,
        settings: const AppSettings(
          theme: 'Light',
          fontScalePercent: 140,
          concurrent: 7,
        ),
      );
      await tap(tester, find.text('字体大小'));
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byKey(const Key('font-size-preview'))),
        ).scale(14),
        closeTo(24.5, 0.0001),
      );
      await tap(tester, find.byKey(const Key('font-size-80')));
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(services.settings.fontScalePercent, 140);
      await tap(tester, find.text('字体大小'));
      final page = tester.state(find.byType(FontSizePage));
      await tap(tester, find.byKey(const Key('font-size-reset')));
      expect(services.settings.fontScalePercent, 140);
      await applyFont(tester, services, 100);
      expect(tester.state(find.byType(FontSizePage)), same(page));
      expect(services.settings.concurrent, 7);
      expect(
        MediaQuery.textScalerOf(tester.element(find.text('字体大小'))).scale(14),
        17.5,
      );
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      await tester.pumpAndSettle();
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byKey(const Key('font-size-preview'))),
        ).scale(14),
        21,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Maximum font size remains usable on a narrow phone', (
    tester,
  ) async {
    final (services, _) = await render(
      tester,
      size: const Size(320, 700),
      settings: const AppSettings(theme: 'Light', fontScalePercent: 180),
    );
    await tap(tester, find.text('字体大小'));
    await screenshot(tester, 'font-size-phone-180');
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.byKey(const Key('font-size-reset')),
      200,
      scrollable: find
          .descendant(
            of: find.byType(FontSizePage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tap(tester, find.byKey(const Key('font-size-reset')));
    await applyFont(tester, services, 100);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Custom concurrency validates, persists and is shared by both settings entries',
    (tester) async {
      final (services, _) = await render(tester, tab: 2);
      await customConcurrency(tester);
      final input = find.byKey(const Key('download-concurrency-input'));
      final save = find.byKey(const Key('download-concurrency-save'));
      for (final value in ['0', '33']) {
        await tester.enterText(input, value);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(find.text('请输入 1–32 之间的整数'), findsOneWidget);
        expect(services.settings.concurrent, 3);
      }
      await tester.enterText(input, '7');
      await tester.tap(save);
      await waitFor(tester, () => services.settings.concurrent == 7);
      final dropdown = tester.widget<DropdownButton<int>>(
        find.byKey(const Key('download-concurrency')),
      );
      expect(dropdown.value, 7);
      expect(dropdown.items!.where((item) => item.value == 7), hasLength(1));
      expect(services.store.data.obj('settings').integer('concurrent'), 7);
      await customConcurrency(tester);
      await tester.enterText(input, '13');
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(services.settings.concurrent, 7);
      await tap(tester, find.byKey(const ValueKey('navigation-4')));
      await tester.scrollUntilVisible(
        find.text('同时下载任务数'),
        250,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('mine')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tap(tester, find.text('同时下载任务数'));
      expect(tester.widget<TextField>(input).controller!.text, '7');
      await screenshot(tester, 'download-concurrency-phone');
      await tap(tester, find.widgetWithText(ActionChip, '32'));
      await tester.tap(save);
      await waitFor(tester, () => services.settings.concurrent == 32);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'New-download menu passes custom threads to the engine and keeps them on resume',
    (tester) async {
      final (services, native) = await render(tester, tab: 2);
      await openMenu(tester, '新建下载');
      final threads = find.byKey(const Key('direct-download-connections'));
      final submit = find.byKey(const Key('direct-download-submit'));
      expect(tester.widget<TextField>(threads).controller!.text, '64');
      await tester.enterText(
        find.byKey(const Key('direct-download-url')),
        'https://example.test/archive.zip',
      );
      await tester.enterText(
        find.byKey(const Key('direct-download-name')),
        '资料包.zip',
      );
      await tester.enterText(threads, '513');
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.text('线程数请输入 1–512 之间的整数'), findsOneWidget);
      expect(services.downloads.tasks, isEmpty);
      await tester.enterText(threads, '12');
      await screenshot(tester, 'new-download-threads-phone');
      await tester.tap(submit);
      await waitFor(tester, () => native.begins.length == 1);
      final task = services.downloads.tasks.single;
      expect(task.connections, 12);
      expect(task.spec.fileName, '资料包.zip');
      expect(native.begins.single.integer('connections'), 12);
      expect(
        services.store.data.list('tasks').single.integer('connections'),
        12,
      );
      expect(services.settings.threads, 64);
      var paused = false;
      final pause = services.downloads
          .pause(task.id)
          .whenComplete(() => paused = true);
      await waitFor(tester, () => paused);
      await pause;
      expect(services.downloads.task(task.id)!.status, DownloadStatus.paused);
      await services.updateSettings({'threads': 8});
      final resume = services.downloads.resume(task.id);
      await waitFor(tester, () => native.begins.length == 2);
      await resume;
      expect(native.begins.last.integer('connections'), 12);
      expect(
        services.store.data.list('tasks').single.integer('connections'),
        12,
      );
      await openMenu(tester, '新建下载');
      expect(tester.widget<TextField>(threads).controller!.text, '8');
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(services.downloads.tasks, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
}
