import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/login_guide.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/login_guide_panel.dart';

void main() {
  Future<void> render(
    WidgetTester tester,
    LoginGuide guide, {
    required ValueChanged<String> onFill,
    String? clipboard,
    bool enabled = true,
    bool opened = true,
    Duration pollInterval = const Duration(milliseconds: 10),
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: LoginGuidePanel(
            guide: guide,
            onFill: onFill,
            enabled: enabled,
            pollInterval: pollInterval,
            openBrowser: (_) async => opened,
            readClipboard: () async => clipboard,
          ),
        ),
      ),
    ),
  );

  testWidgets('the panel states the browser steps before opening anything', (
    tester,
  ) async {
    await render(
      tester,
      LoginGuide.forPlatform(CloudPlatform.baidu)!,
      onFill: (_) {},
    );
    expect(find.text('在浏览器里登录百度'), findsOneWidget);
    expect(find.textContaining('F12'), findsOneWidget);
    // Nothing is read until the browser is open.
    expect(find.byKey(const ValueKey('login-guide-fill')), findsNothing);
    expect(find.text('停止读取剪贴板'), findsNothing);
  });

  testWidgets('opening the browser starts watching the clipboard', (
    tester,
  ) async {
    Uri? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoginGuidePanel(
            guide: LoginGuide.forPlatform(CloudPlatform.baidu)!,
            onFill: (_) {},
            pollInterval: const Duration(milliseconds: 10),
            openBrowser: (url) async {
              opened = url;
              return true;
            },
            readClipboard: () async => 'nothing useful yet',
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('login-guide-open')));
    // The watching spinner keeps animating, so settle frames instead of
    // waiting for an idle tree the poll never reaches.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(opened.toString(), 'https://pan.baidu.com/');
    expect(find.text('停止读取剪贴板'), findsOneWidget);
    await tester.tap(find.text('停止读取剪贴板'));
    await tester.pumpAndSettle();
    expect(find.text('停止读取剪贴板'), findsNothing);
  });

  testWidgets('a slow clipboard read that matches is offered for filling', (
    tester,
  ) async {
    var reads = 0;
    String? filled;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoginGuidePanel(
            guide: LoginGuide.forPlatform(CloudPlatform.quark)!,
            onFill: (value) => filled = value,
            pollInterval: const Duration(milliseconds: 10),
            openBrowser: (_) async => true,
            readClipboard: () async {
              reads++;
              return reads < 3 ? '登录成功，欢迎回来' : '__pus=1; __puus=2';
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('login-guide-open')));
    await tester.pumpAndSettle();
    expect(reads, greaterThanOrEqualTo(3));
    expect(find.text('已从剪贴板读取到夸克凭据'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('login-guide-fill')));
    await tester.pumpAndSettle();
    expect(filled, '__pus=1; __puus=2');
    // The offer is consumed so the same value is not filled twice.
    expect(find.byKey(const ValueKey('login-guide-fill')), findsNothing);
  });

  testWidgets('a browser that will not open says so and stops watching', (
    tester,
  ) async {
    await render(
      tester,
      LoginGuide.forPlatform(CloudPlatform.baidu)!,
      onFill: (_) {},
      opened: false,
      clipboard: 'BDUSS=not-used',
    );
    await tester.tap(find.byKey(const ValueKey('login-guide-open')));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂时无法打开浏览器'), findsOneWidget);
    expect(find.byKey(const ValueKey('login-guide-fill')), findsNothing);
  });

  testWidgets('filling is disabled while the page is submitting', (
    tester,
  ) async {
    await render(
      tester,
      LoginGuide.forPlatform(CloudPlatform.baidu)!,
      onFill: (_) {},
      enabled: false,
      clipboard: 'BDUSS=held-back',
    );
    await tester.tap(find.byKey(const ValueKey('login-guide-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('login-guide-fill')), findsOneWidget);
    final button = tester.widget<TextButton>(
      find.byKey(const ValueKey('login-guide-fill')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('the panel collapses without losing the open browser state', (
    tester,
  ) async {
    await render(
      tester,
      LoginGuide.forPlatform(CloudPlatform.baidu)!,
      onFill: (_) {},
      clipboard: 'BDUSS=collapsed; STOKEN=s',
    );
    await tester.tap(find.byKey(const ValueKey('login-guide-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('在浏览器里登录百度'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('login-guide-fill')), findsNothing);
    await tester.tap(find.text('在浏览器里登录百度'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('login-guide-fill')), findsOneWidget);
  });

  testWidgets('an unreadable clipboard stops polling instead of throwing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoginGuidePanel(
            guide: LoginGuide.forPlatform(CloudPlatform.baidu)!,
            onFill: (_) {},
            pollInterval: const Duration(milliseconds: 10),
            openBrowser: (_) async => true,
            readClipboard: () async => throw StateError('no clipboard'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('login-guide-open')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('停止读取剪贴板'), findsNothing);
  });
}
