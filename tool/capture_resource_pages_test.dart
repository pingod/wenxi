// Render actual Flutter routes for product review. No network or account data.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/resource_search.dart';
import 'package:asterlink/data/resource_search_api.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/resource_search.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/resource_search_page.dart';

import '../test/support.dart';
import '../test/fixtures/resource_search_samples.dart';

const outputPath = String.fromEnvironment(
  'UI_RENDER_OUTPUT',
  defaultValue: 'D:/.ls/pan-relay-main/artifacts/app-ui-2026-10-22',
);

class _PreviewSearchApi implements ResourceSearchApi {
  @override
  Future<ResourceSearchOpenResult> open(
    ResourceSearchHit hit,
    CancelToken cancellation, {
    required ResourceSearchFileSelection selection,
  }) async => ResourceSearchOpenResult(
    hit: hit,
    mode: 'pool_share',
    transferScope: 'file',
    sourceFileId: selection.fileId,
  );
  @override
  Stream<ResourceSearchBatch> search(
    String keyword,
    CancelToken cancellation,
  ) => Stream.value(
    ResourceSearchBatch(resourceSearchSamples(), complete: true),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    for (final (family, path) in [
      ('PreviewAndroid', 'assets/fonts/NotoSansSC-Regular.otf'),
      ('PreviewWindows', 'C:/Windows/Fonts/msyh.ttc'),
    ]) {
      final data = await File(path).readAsBytes();
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(data)))).load();
    }
    Directory(outputPath).createSync(recursive: true);
  });

  Future<void> capture(
    WidgetTester tester,
    String filename,
    double ratio,
  ) async {
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('ui-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: ratio);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) throw StateError('PNG encoding failed');
        File('$outputPath/$filename').writeAsBytesSync(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      } finally {
        image.dispose();
      }
    });
  }

  for (final (name, platform, size, ratio, font) in [
    (
      'android',
      TargetPlatform.android,
      const Size(432, 960),
      2.5,
      'PreviewAndroid',
    ),
    (
      'windows',
      TargetPlatform.windows,
      const Size(1280, 900),
      2.0,
      'PreviewWindows',
    ),
  ]) {
    testWidgets('render $name parse and search pages', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      debugDisableShadows = false;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      try {
        final directory = Directory.systemTemp.createTempSync(
          'asterlink-render-ui-',
        );
        final store = StateStore.memory({
          'settings': {'theme': 'Light'},
          'resourceSearchHistory': ['Python 教程', '设计素材', '电子书'],
        });
        final search = ResourceSearch(store: store, api: _PreviewSearchApi());
        final services = AppServices(
          store: store,
          dataDirectory: directory,
          cacheDirectory: Directory('${directory.path}/cache'),
          transport: FakeNative(),
          files: FakeFiles(Directory('${directory.path}/files')),
          http: FakeHttp(),
          platformFeatures: false,
          controlEnabled: false,
          resourceSearch: search,
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          var closed = false;
          final closing = services.close().whenComplete(() => closed = true);
          for (var i = 0; i < 100 && !closed; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          expect(closed, isTrue, reason: 'Preview services must close');
          await closing;
          final tempRoot = Directory.systemTemp.resolveSymbolicLinksSync();
          final resolved = directory.resolveSymbolicLinksSync();
          if (!resolved.startsWith('$tempRoot${Platform.pathSeparator}') ||
              !directory.path
                  .split(Platform.pathSeparator)
                  .last
                  .startsWith('asterlink-render-ui-')) {
            throw StateError('Unexpected preview temporary directory');
          }
          directory.deleteSync(recursive: true);
        });

        await tester.runAsync(() => search.search('Python'));
        await tester.pumpWidget(
          RepaintBoundary(
            key: const Key('ui-capture'),
            child: AsterLinkApp(services, fontFamily: font),
          ),
        );
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(MainShell));
        await tester.runAsync(() async {
          for (final file in Directory(
            'assets/icons',
          ).listSync().whereType<File>()) {
            if (file.path.endsWith('.png') || file.path.endsWith('.webp')) {
              await precacheImage(
                AssetImage(file.path.replaceAll('\\', '/')),
                context,
              );
            }
          }
        });
        tester
                .widget<TextField>(find.byKey(const Key('parse-input')))
                .controller!
                .text =
            '我分享了「Python 学习资料」\n'
            '链接：https://pan.quark.cn/s/PreviewBooks\n'
            '提取码：aB12';
        await capture(tester, '$name-parse.png', ratio);

        final entry = find.byKey(const Key('parse-resource-search'));
        await tester.ensureVisible(entry);
        await tester.pumpAndSettle();
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expect(find.byType(ResourceSearchPage), findsOneWidget);
        await capture(tester, '$name-search.png', ratio);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        debugDisableShadows = true;
      }
    });
  }
}
