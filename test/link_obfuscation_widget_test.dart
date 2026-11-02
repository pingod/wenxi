import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/clipboard_link_banner.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'support.dart';

void main() {
  const input = 'https://删github.com/删diabl0w/删DFRoot/releases';
  const expected = 'https://github.com/diabl0w/DFRoot/releases';
  late AppServices services;
  late FakeHttp http;

  Future<void> render(WidgetTester tester, {bool clipboard = false}) async {
    http = FakeHttp((request) {
      expect(request.uri.host, 'api.github.com');
      if (request.uri.path == '/repos/diabl0w/DFRoot') {
        return jsonResponse({
          'name': 'DFRoot',
          'owner': {'login': 'diabl0w'},
          'default_branch': 'main',
        });
      }
      if (request.uri.path == '/repos/diabl0w/DFRoot/releases') {
        return HttpResult(
          200,
          jsonEncode([
            {'id': 1, 'name': 'DFRoot v1', 'tag_name': 'v1'},
          ]),
        );
      }
      throw StateError('Unexpected request: ${request.uri}');
    });
    services = AppServices(
      store: StateStore.memory(),
      dataDirectory: Directory('test-fixture/link-obfuscation'),
      cacheDirectory: Directory('test-fixture/link-obfuscation/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('test-fixture/link-obfuscation/saved')),
      http: http,
      platformFeatures: false,
      controlEnabled: false,
      clipboardReader: () async => clipboard ? input : null,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var closed = false;
      final closing = services.close().whenComplete(() => closed = true);
      for (var index = 0; index < 100 && !closed; index++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(closed, true);
      await closing;
      services.store.dispose();
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(AsterLinkApp(services));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Pasting an obfuscated GitHub link selects the clean release URL',
    (tester) async {
      await render(tester);
      final page = tester.state<ParsePageState>(find.byType(ParsePage));
      page.input.text = '“[$input]($input)”';
      await tester.pumpAndSettle();
      expect(page.current!.url, expected);
      expect(page.current!.kind, LinkKind.cloudShare);
      expect(page.current!.platform, CloudPlatform.github);
      expect(page.links, hasLength(1));
      expect(page.error, isEmpty);
      expect(http.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Clicking an obfuscated clipboard link parses its clean URL and opens releases',
    (tester) async {
      await render(tester, clipboard: true);
      expect(find.byType(ClipboardLinkBanner), findsOneWidget);
      expect(http.calls, isEmpty);
      await tester.tap(find.text('立即解析'));
      await tester.pumpAndSettle();
      final page = tester.state<ParsePageState>(
        find.byType(ParsePage, skipOffstage: false),
      );
      expect(page.input.text, expected);
      expect(page.current!.url, expected);
      expect(page.current!.platform, CloudPlatform.github);
      expect(find.byType(ClipboardLinkBanner), findsNothing);
      expect(http.calls.map((request) => request.uri.path), [
        '/repos/diabl0w/DFRoot',
        '/repos/diabl0w/DFRoot/releases',
      ]);
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(find.text('DFRoot v1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
