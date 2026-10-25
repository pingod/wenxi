import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/appearance.dart';
import 'package:asterlink/domain/background.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/app_background.dart';
import 'package:asterlink/ui/appearance_preview.dart';
import 'package:asterlink/ui/background_crop_page.dart';
import 'package:asterlink/ui/background_page.dart';
import 'background_support.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var systemFont = false;
  setUpAll(() async {
    for (final pair in [
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      (
        'packages/cupertino_icons/CupertinoIcons',
        'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      ),
    ]) {
      await (FontLoader(pair.$1)..addFont(rootBundle.load(pair.$2))).load();
    }
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (await font.exists()) {
      await (FontLoader('BackgroundFixture')..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
      systemFont = true;
    }
  });

  Future<void> settle(WidgetTester tester, {int cycles = 6}) async {
    for (var i = 0; i < cycles; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  Future<AppServices> render(
    WidgetTester tester, {
    Size size = const Size(393, 864),
    double scale = 1,
    String mode = 'Light',
    bool withImage = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('wenxi-background-ui-'),
    ))!;
    final services = (await tester.runAsync(() async {
      final services = AppServices(
        store: StateStore.memory(),
        dataDirectory: directory,
        cacheDirectory: Directory('${directory.path}/cache'),
        transport: FakeNative(),
        files: FakeFiles(directory),
        http: FakeHttp(),
        controlEnabled: false,
        platformFeatures: false,
      );
      var background = const BackgroundSettings();
      if (withImage) {
        final lease = services.backgrounds.beginDraft();
        final day = await services.backgrounds.importFile(
          XFile.fromData(await backgroundFixture()),
          lease,
        );
        final night = await services.backgrounds.importFile(
          XFile.fromData(await backgroundFixture(night: true)),
          lease,
        );
        background = BackgroundSettings(day: day, night: night);
        await services.store.put(
          'settings',
          AppSettings(
            theme: mode,
            themePalette: AppPalette.mint,
            background: background,
          ).toJson(),
        );
        await services.backgrounds.endDraft(lease);
      } else {
        await services.store.put('settings', AppSettings(theme: mode).toJson());
      }
      return services;
    }))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var closed = false;
      services.close().then((_) => closed = true);
      for (var i = 0; i < 40 && !closed; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(closed, isTrue);
      var cleaned = false;
      services.backgrounds.collectUnused().then((_) => cleaned = true);
      for (var i = 0; i < 40 && !cleaned; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(cleaned, isTrue);
      await tester.runAsync(() => directory.delete(recursive: true));
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.platformDispatcher.clearPlatformBrightnessTestValue();
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('background-capture'),
        child: AsterLinkApp(
          services,
          initialTab: 4,
          fontFamily: systemFont ? 'BackgroundFixture' : null,
        ),
      ),
    );
    await settle(tester);
    return services;
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await settle(tester);
  }

  Future<void> editor(WidgetTester tester) async {
    await tester.tap(find.text('主题与外观'));
    await settle(tester);
    await tap(tester, 'appearance-background');
  }

  Future<void> slider(WidgetTester tester, String key, double fraction) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    final rect = tester.getRect(finder);
    await tester.tapAt(
      Offset(rect.left + 24 + (rect.width - 48) * fraction, rect.center.dy),
    );
    await settle(tester);
  }

  AppearancePreview preview(WidgetTester tester) =>
      tester.widget<AppearancePreview>(find.byType(AppearancePreview));

  Future<void> screenshot(WidgetTester tester, String name) async {
    final output = Platform.environment['APP_BACKGROUND_PREVIEW_DIR'];
    if (output == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('background-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        final file = File('$output/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      } finally {
        image.dispose();
      }
    });
  }

  testWidgets(
    'controls and both device crops preview locally, then apply without replacing the shell',
    (tester) async {
      final services = await render(tester);
      final before = services.settings.background;
      final downloads = services.downloads;
      final shell = tester.state(find.byType(MainShell));
      await editor(tester);
      await slider(tester, 'background-brightness', .4);
      await slider(tester, 'background-blur', .7);
      await slider(tester, 'background-transparency', .5);
      expect(
        preview(tester).settings.background.brightness,
        isNot(before.brightness),
      );
      expect(preview(tester).settings.background.blur, isNot(before.blur));
      expect(
        preview(tester).settings.background.cardOpacity,
        isNot(before.cardOpacity),
      );
      expect(services.settings.background, before);
      await tap(tester, 'background-day-crop');
      await slider(tester, 'background-crop-zoom', .5);
      await tester.drag(
        find.byKey(const Key('background-crop-gesture')),
        const Offset(40, 28),
      );
      await settle(tester);
      await screenshot(tester, 'phone-crop');
      await tester.tap(find.text('电脑'));
      await settle(tester);
      await slider(tester, 'background-crop-zoom', .7);
      await tester.drag(
        find.byKey(const Key('background-crop-gesture')),
        const Offset(-40, -12),
      );
      await tap(tester, 'background-crop-done');
      final draft = preview(tester).settings.background;
      expect(draft.day!.phone, isNot(before.day!.phone));
      expect(draft.day!.desktop, isNot(before.day!.desktop));
      expect(draft.day!.phone, isNot(draft.day!.desktop));
      expect(services.settings.background, before);
      await tap(tester, 'background-apply');
      expect(find.byType(BackgroundPage), findsNothing);
      expect(services.settings.background, draft);
      expect(services.downloads, same(downloads));
      expect(
        tester.state(find.byType(MainShell, skipOffstage: false)),
        same(shell),
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'returning discards background removal; applying removal preserves theme',
    (tester) async {
      final services = await render(tester);
      final before = services.settings.background;
      await editor(tester);
      await tap(tester, 'background-remove-all');
      expect(preview(tester).settings.background.hasImage, isFalse);
      await tester.tap(find.byType(BackButton));
      await settle(tester);
      expect(services.settings.background, before);
      expect(
        await tester.runAsync(
          () => services.backgrounds.file(before.day!.id).exists(),
        ),
        isTrue,
      );
      await tap(tester, 'appearance-background');
      await tap(tester, 'background-remove-all');
      await tap(tester, 'background-apply');
      expect(services.settings.background.hasImage, isFalse);
      expect(services.settings.themePalette, AppPalette.mint);
      // Route disposal starts asynchronous cleanup after the exit animation.
      await settle(tester);
      expect(
        await tester.runAsync(
          () => services.backgrounds.file(before.day!.id).exists(),
        ),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('choosing an actual local image prepares it before applying', (
    tester,
  ) async {
    final services = await render(tester, withImage: false);
    final source = (await tester.runAsync(
      () async => File(
        '${services.dataDirectory.path}/gallery.png',
      ).writeAsBytes(await backgroundFixture(width: 2400, height: 1800)),
    ))!;
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    // Exercise selection and bounded file I/O while substituting only the OS dialog.
    navigator.push<AppSettings>(
      MaterialPageRoute(
        builder: (_) => BackgroundPage(
          services,
          initial: services.settings,
          pickImage: () async => XFile(source.path),
        ),
      ),
    );
    await settle(tester);
    await tap(tester, 'background-day-select');
    for (
      var i = 0;
      i < 30 && !preview(tester).settings.background.hasImage;
      i++
    ) {
      await settle(tester, cycles: 2);
    }
    final picture = preview(tester).settings.background.day!;
    expect(picture.width, lessThanOrEqualTo(backgroundMaxSide));
    expect(services.settings.background.hasImage, isFalse);
    await tester.runAsync(() => source.delete());
    await tap(tester, 'background-apply');
    expect(services.settings.background.day, picture);
    expect(
      await tester.runAsync(
        () => services.backgrounds.file(picture.id).exists(),
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    ('phone', const Size(393, 864), 1.0, 'Light'),
    ('phone-dark', const Size(393, 864), 1.0, 'Dark'),
    ('phone-large-text', const Size(320, 700), 1.8, 'Dark'),
    ('desktop', const Size(1100, 820), 1.0, 'Light'),
  ]) {
    testWidgets(
      '${scenario.$1} shares a static background on all main pages and has usable controls',
      (tester) async {
        final services = await render(
          tester,
          size: scenario.$2,
          scale: scenario.$3,
          mode: scenario.$4,
        );
        final layer = tester.renderObject(
          find.byKey(const Key('app-background-layer')),
        );
        for (var i = 0; i < 5; i++) {
          await tap(tester, 'navigation-$i');
          expect(
            tester.renderObject(find.byKey(const Key('app-background-layer'))),
            same(layer),
          );
          for (final scaffold in tester.widgetList<Scaffold>(
            find.byType(Scaffold),
          )) {
            expect(scaffold.backgroundColor, Colors.transparent);
          }
          expect(
            tester.widget<BackgroundScope>(find.byType(BackgroundScope)).active,
            isTrue,
          );
          final backgroundView = tester.widget<BackgroundImageView>(
            find.byType(BackgroundImageView),
          );
          expect(
            backgroundView.picture,
            services.settings.background.pictureFor(scenario.$4 == 'Dark'),
          );
          await screenshot(
            tester,
            '${scenario.$1}-${['parse', 'resources', 'cloud', 'transfers', 'mine'][i]}',
          );
          expect(tester.takeException(), isNull);
        }
        await editor(tester);
        await screenshot(tester, '${scenario.$1}-editor');
        expect(
          find.byKey(const Key('background-apply')).hitTestable(),
          findsOneWidget,
        );
        for (final key in [
          'background-brightness',
          'background-blur',
          'background-transparency',
        ]) {
          await slider(tester, key, .5);
          expect(tester.takeException(), isNull);
        }
        await screenshot(tester, '${scenario.$1}-adjustments');
        await tap(tester, 'background-day-crop');
        expect(find.byType(BackgroundCropPage), findsOneWidget);
        expect(
          find.byKey(const Key('background-crop-done')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(
        scenario.$1 == 'desktop'
            ? TargetPlatform.windows
            : TargetPlatform.android,
      ),
    );
  }

  testWidgets(
    'missing wallpaper falls back safely and high contrast uses opaque surfaces',
    (tester) async {
      final services = await render(tester);
      final picture = services.settings.background.day!;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => services.backgrounds.file(picture.id).delete(),
      );
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await tester.pumpWidget(AsterLinkApp(services));
      await settle(tester);
      expect(find.byType(MainShell), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(393, 864),
              highContrast: true,
            ),
            child: AppBackground(
              repository: services.backgrounds,
              settings: services.settings.background,
              child: Builder(
                builder: (context) => Scaffold(
                  body: ColoredBox(
                    key: const Key('accessible-surface'),
                    color: backgroundSurface(context),
                    child: const Text('可读内容'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(
        tester.widget<BackgroundScope>(find.byType(BackgroundScope)).active,
        isFalse,
      );
      expect(find.byType(BackgroundImageView), findsNothing);
      expect(
        tester
            .widget<ColoredBox>(find.byKey(const Key('accessible-surface')))
            .color
            .a,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
