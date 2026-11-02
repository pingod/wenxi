import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/parser_rules/hub.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/ui/parser_password_web_page.dart';
import 'package:asterlink/ui/parser_site_picker.dart';
import 'parser_password_web_test.dart'
    show PasswordWebTestHub, passwordWebNow, passwordWebUcFixture;
import 'support.dart';

class _Controller extends PlatformInAppWebViewController {
  _Controller()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 17),
      );
  WebUri url = WebUri('about:blank');
  InAppWebViewSettings settings = InAppWebViewSettings(
    userAgent: 'Mozilla/5.0 Chrome/142.0.7444.7 Safari/537.36',
  );
  Object? result = {'status': 'waiting', 'message': '请完成人机验证'};
  Completer<Object?>? pending;
  Completer<InAppWebViewSettings?>? pendingSettings;
  int reads = 0, reloads = 0;
  final sources = <String>[];
  @override
  Future<InAppWebViewSettings?> getSettings() async =>
      await pendingSettings?.future ?? settings;
  @override
  Future<void> setSettings({required InAppWebViewSettings settings}) async {
    this.settings = settings;
  }

  @override
  Future<WebUri?> getUrl() async => url;
  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    reads++;
    sources.add(source);
    return await pending?.future ?? jsonEncode(result);
  }

  @override
  Future<void> stopLoading() async {}
  @override
  Future<void> loadUrl({
    required URLRequest urlRequest,
    Uri? iosAllowingReadAccessTo,
    WebUri? allowingReadAccessTo,
  }) async {
    reloads++;
    url = urlRequest.url!;
  }
}

class _View extends PlatformInAppWebViewWidget {
  _View(super.params) : super.implementation();
  bool disposed = false;
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      params.controllerFromPlatform!(controller) as T;
  @override
  void dispose() => disposed = true;
}

class _Platform extends InAppWebViewPlatform {
  final views = <_View>[];
  final controller = _Controller();
  @override
  PlatformInAppWebViewController createPlatformInAppWebViewController(
    PlatformInAppWebViewControllerCreationParams params,
  ) => controller;
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    final view = _View(params);
    views.add(view);
    return view;
  }
}

class _WidgetHub extends PasswordWebTestHub {
  _WidgetHub({
    required super.store,
    required super.http,
    super.passwordDocumentHttp,
    super.clock,
    super.fixture,
  });
  @override
  Future<ParserSharedPassword> password(
    String id, {
    bool force = false,
  }) async => throw ParserPasswordRequired(id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Platform platform;
  late PasswordWebTestHub hub;
  late FakeHttp http;
  late DiagnosticLog log;
  String? grant;
  setUp(() {
    platform = _Platform();
    InAppWebViewPlatform.instance = platform;
    http = FakeHttp(
      (_) => throw StateError('Password must stay on this device'),
    );
    log = DiagnosticLog.open(null);
    DiagnosticLog.active = log;
    grant = null;
  });
  tearDown(() {
    log.close();
    DiagnosticLog.active = null;
  });

  void prepareHub({bool uc = false, JsonHttp? documentHttp}) {
    hub = _WidgetHub(
      store: Vault(StateStore.memory()),
      http: http,
      passwordDocumentHttp: documentHttp,
      clock: () => passwordWebNow,
      fixture: uc ? passwordWebUcFixture : null,
    );
  }

  Future<void> open(
    WidgetTester tester, {
    bool uc = false,
    Future<String> Function(String)? resolve,
    JsonHttp? documentHttp,
  }) async {
    if (uc) {
      http = FakeHttp(
        (r) => jsonResponse({
          'ok': true,
          'data': r.uri.path == '/v1/sites'
              ? {
                  'sites': [
                    {'id': 'dg22_public', 'version': 2},
                  ],
                }
              : r.uri.path.endsWith('/submissions')
              ? {'status': 'pending'}
              : {'password': null},
        }),
      );
    }
    prepareHub(uc: uc, documentHttp: documentHttp);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                grant = await showParserPasswordDialog(
                  context,
                  hub,
                  'dg22_public',
                  resolveUcPassword: resolve,
                );
              },
              child: const Text('解析样本'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('解析样本'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('parser-password-web-obtain')),
    );
    await tester.tap(find.byKey(const ValueKey('parser-password-web-obtain')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ParserPasswordWebPage), findsOneWidget);
  }

  Future<(_View, InAppWebViewController)> attach(WidgetTester tester) async {
    final view = platform.views.last;
    final controller = view.controllerFromPlatform<InAppWebViewController>(
      platform.controller,
    );
    view.params.onWebViewCreated!(controller);
    await tester.pump();
    return (view, controller);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    final closing = hub.close();
    await tester.pump();
    await closing;
  }

  testWidgets(
    'UC command resolves once, fills only its matching page and returns the final password',
    (tester) async {
      final pending = Completer<String>();
      var calls = 0;
      String? receivedCommand;
      await open(
        tester,
        uc: true,
        resolve: (command) {
          receivedCommand = command;
          calls++;
          return pending.future;
        },
      );
      final (view, controller) = await attach(tester);
      platform.controller.result = {
        'status': 'ucPassword',
        'command': '网页UC口令样本',
      };
      view.params.onLoadStop!(controller, platform.controller.url);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(calls, 1);
      expect(receivedCommand, '网页UC口令样本');
      expect(grant, null);
      pending.complete('首行访问密码');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 850));
      expect(
        platform.controller.sources.last,
        contains('"firstPassword":"首行访问密码"'),
      );
      expect(
        platform.controller.sources.last,
        contains('"ucCommand":"网页UC口令样本"'),
      );
      expect(calls, 1);
      platform.controller.result = {
        'status': 'success',
        'password': '最终解析密码-A7!',
      };
      await tester.pump(const Duration(milliseconds: 850));
      await tester.pump(const Duration(milliseconds: 400));
      expect(hub.grantedPassword('dg22_public', grant)!.value, '最终解析密码-A7!');
      final submissions = http.calls
          .where((r) => r.uri.path.endsWith('/submissions'))
          .toList();
      expect(submissions.length, 1);
      expect(submissions.single.json['password'], '最终解析密码-A7!');
      expect(submissions.single.body.toString(), isNot(contains('首行访问密码')));
      expect(submissions.single.body.toString(), isNot(contains('网页UC口令样本')));
      final logs = log.exportFiles().values.join('\n');
      expect(logs, contains('parser.password_web.uc_captured'));
      for (final secret in ['首行访问密码', '最终解析密码', '网页UC口令样本']) {
        expect(logs, isNot(contains(secret)));
      }
      await close(tester);
    },
  );

  for (final action in ['back', 'reload', 'navigate', 'timeout']) {
    testWidgets('UC read cancellation on $action ignores late file contents', (
      tester,
    ) async {
      final pending = Completer<String>();
      bool cancelled = false;
      await open(
        tester,
        uc: true,
        resolve: (_) {
          RequestScope.current!.whenCancel.then((_) => cancelled = true);
          return pending.future;
        },
      );
      final (view, controller) = await attach(tester);
      platform.controller.result = {'status': 'ucPassword', 'command': '待取消口令'};
      view.params.onLoadStop!(controller, platform.controller.url);
      await tester.pump();
      switch (action) {
        case 'back':
          await tester.tap(find.text('返回填写'));
        case 'reload':
          await tester.tap(find.byKey(const ValueKey('password-web-reload')));
        case 'navigate':
          platform.controller.url = WebUri('https://other.example/');
          view.params.onLoadStart!(controller, platform.controller.url);
        case 'timeout':
          await tester.pump(const Duration(seconds: 46));
      }
      await tester.pump();
      expect(cancelled, true);
      pending.complete('迟到的访问密码');
      await tester.pump(const Duration(milliseconds: 850));
      expect(grant, null);
      expect(platform.controller.sources.join(), isNot(contains('迟到的访问密码')));
      await close(tester);
    });
  }

  testWidgets(
    'A failed UC lookup shows its error and waits for reload before retrying',
    (tester) async {
      var calls = 0;
      await open(
        tester,
        uc: true,
        resolve: (_) async {
          calls++;
          throw const AppException('请先登录 UC 网盘再获取密码');
        },
      );
      final (view, controller) = await attach(tester);
      platform.controller.result = {'status': 'ucPassword', 'command': '失败口令'};
      view.params.onLoadStop!(controller, platform.controller.url);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('请先登录 UC 网盘再获取密码'), findsOneWidget);
      expect(calls, 1);
      await tester.tap(find.byKey(const ValueKey('password-web-reload')));
      await tester.pump();
      view.params.onLoadStop!(controller, platform.controller.url);
      await tester.pump();
      expect(calls, 2);
      await close(tester);
    },
  );

  testWidgets('A fixed-password recipe cannot invoke the UC account reader', (
    tester,
  ) async {
    var calls = 0;
    await open(
      tester,
      resolve: (_) async {
        calls++;
        return '不应读取';
      },
    );
    final (view, controller) = await attach(tester);
    platform.controller.result = {'status': 'ucPassword', 'command': '未授权口令'};
    view.params.onLoadStop!(controller, platform.controller.url);
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 0);
    expect(grant, null);
    await close(tester);
  });

  testWidgets(
    'Browser result returns a local receipt and logs only lifecycle metadata',
    (tester) async {
      await open(tester);
      final (view, controller) = await attach(tester);
      expect(view.params.initialSettings!.incognito, false);
      expect(view.params.initialSettings!.cacheEnabled, true);
      expect(view.params.initialSettings!.cacheMode, CacheMode.LOAD_DEFAULT);
      expect(view.params.initialSettings!.allowFileAccess, false);
      expect(view.params.initialSettings!.thirdPartyCookiesEnabled, true);
      expect(
        view.params.initialSettings!.requestedWithHeaderOriginAllowList,
        isEmpty,
      );
      expect(view.params.initialUrlRequest!.url.toString(), 'about:blank');
      expect(view.params.initialSettings!.userAgent, isNull);
      expect(platform.controller.url.toString(), 'https://mmhq.dg22.top/');
      expect(
        platform.controller.settings.userAgent,
        contains('Chrome/142.0.7444.7 UCBrowser/'),
      );
      view.params.onLoadStop!(controller, platform.controller.url);
      await tester.pump();
      expect(find.text('请完成人机验证'), findsOneWidget);
      platform.controller.result = {
        'status': 'success',
        'password': 'device-only-secret',
      };
      await tester.pump(const Duration(milliseconds: 850));
      for (var i = 0; i < 8 && grant == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(
        grant,
        isNotNull,
        reason:
            'reads=${platform.controller.reads}; '
            'text=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join(" | ")}; '
            'events=${log.entries().map((e) => e.event).join(",")}',
      );
      expect(
        hub.grantedPassword('dg22_public', grant)!.value,
        'device-only-secret',
      );
      expect(http.calls, isEmpty);
      final logs = log.exportFiles().values.join('\n');
      expect(logs, contains('parser.password_web.captured'));
      expect(logs, isNot(contains('device-only-secret')));
      expect(logs, isNot(contains('测试访问密码')));
      await close(tester);
    },
  );

  testWidgets('Cancelling ignores a late browser result and stops polling', (
    tester,
  ) async {
    await open(tester);
    final (view, controller) = await attach(tester);
    platform.controller.pending = Completer<Object?>();
    view.params.onLoadStop!(controller, platform.controller.url);
    await tester.pump();
    await tester.tap(find.text('返回填写'));
    await tester.pump(const Duration(milliseconds: 400));
    platform.controller.pending!.complete({
      'status': 'success',
      'password': 'late-secret',
    });
    await tester.pumpAndSettle();
    expect(grant, null);
    expect(view.disposed, true);
    final reads = platform.controller.reads;
    await tester.pump(const Duration(seconds: 3));
    expect(platform.controller.reads, reads);
    expect(find.byKey(const ValueKey('parser-password-input')), findsOneWidget);
    await close(tester);
  });

  testWidgets(
    'A Cloudflare block stops polling and UC reads without granting a password',
    (tester) async {
      var ucReads = 0;
      await open(
        tester,
        uc: true,
        resolve: (_) async {
          ucReads++;
          return 'unused';
        },
      );
      final (view, controller) = await attach(tester);
      final callsBefore = http.calls.length;
      platform.controller.result = {
        'status': 'error',
        'code': 'CF_BLOCKED',
        'message': '原站 Cloudflare 拦截了当前网页，请用 UC 浏览器打开',
        'cfRay': '0123456789abcdef',
        'password': 'must-not-be-used',
        'command': 'must-not-be-resolved',
      };
      view.params.onReceivedHttpError!(
        controller,
        WebResourceRequest(url: platform.controller.url, isForMainFrame: true),
        WebResourceResponse(
          statusCode: 403,
          reasonPhrase: 'Forbidden',
          headers: {
            'Server': 'cloudflare',
            'CF-Ray': '0123456789abcdef-HKG',
            'Set-Cookie': 'private-cookie',
          },
        ),
      );
      view.params.onLoadStop!(controller, platform.controller.url);
      await tester.pump();
      expect(find.textContaining('原站 Cloudflare 拦截'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('password-web-external')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('password-web-copy-url')),
        findsOneWidget,
      );
      final reads = platform.controller.reads;
      view.params.onLoadStop!(controller, platform.controller.url);
      await tester.pump(const Duration(seconds: 3));
      expect(platform.controller.reads, reads);
      expect(ucReads, 0);
      expect(grant, null);
      expect(http.calls.length, callsBefore);
      final records = log.entries();
      expect(
        records.where((e) => e.event == 'parser.password_web.blocked'),
        hasLength(1),
      );
      final logs = log.exportFiles().values.join('\n');
      expect(logs, contains('0123456789abcdef'));
      expect(logs, isNot(contains('must-not-be-used')));
      expect(logs, isNot(contains('must-not-be-resolved')));
      expect(logs, isNot(contains('private-cookie')));

      // Explicit reload starts a fresh attempt; the old block cannot capture a result.
      platform.controller.result = {'status': 'waiting', 'message': '请完成人机验证'};
      await tester.tap(find.byKey(const ValueKey('password-web-reload')));
      await tester.pump();
      view.params.onLoadStop!(controller, platform.controller.url);
      await tester.pump();
      expect(platform.controller.reads, greaterThan(reads));
      expect(find.text('请完成人机验证'), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets(
    'An HTTP challenge can still load and the browser URL is copied without session data',
    (tester) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await open(tester);
      final (view, controller) = await attach(tester);
      platform.controller.url = WebUri(
        'https://mmhq.dg22.top/?session=private',
      );
      view.params.onReceivedHttpError!(
        controller,
        WebResourceRequest(url: platform.controller.url, isForMainFrame: true),
        WebResourceResponse(
          statusCode: 403,
          reasonPhrase: 'Forbidden',
          headers: {'server': 'cloudflare', 'cf-ray': 'invalid-secret-ray'},
        ),
      );
      view.params.onLoadStop!(controller, platform.controller.url);
      await tester.pump();
      expect(find.text('请完成人机验证'), findsOneWidget);
      final reads = platform.controller.reads;
      await tester.pump(const Duration(milliseconds: 850));
      expect(platform.controller.reads, greaterThan(reads));
      await tester.tap(find.byKey(const ValueKey('password-web-copy-url')));
      await tester.pump();
      expect(copied, 'https://mmhq.dg22.top/');
      final logs = log.exportFiles().values.join('\n');
      expect(logs, isNot(contains('invalid-secret-ray')));
      expect(logs, isNot(contains('session=private')));
      await close(tester);
    },
  );

  testWidgets(
    'Blocked Android document gets one native GET without intercepting verification requests',
    (tester) async {
      final documents = FakeHttp(
        (_) => const HttpResult(200, '<html>public-page</html>', {
          'content-type': ['text/html; charset=utf-8'],
        }),
      );
      await open(tester, documentHttp: documents);
      final (view, controller) = await attach(tester);
      expect(view.params.initialSettings!.useShouldInterceptRequest, true);
      platform.controller.result = {'status': 'waiting', 'message': '请完成人机验证'};
      view.params.onLoadStop!(controller, platform.controller.url);
      await tester.pump();
      expect(documents.calls, isEmpty);
      platform.controller.result = {
        'status': 'error',
        'code': 'CF_BLOCKED',
        'message': '已拦截',
      };
      await tester.pump(const Duration(milliseconds: 850));
      expect(documents.calls, hasLength(1));
      expect(documents.calls.single.method, 'GET');
      expect(
        documents.calls.single.headers['User-Agent'],
        platform.controller.settings.userAgent,
      );
      expect(platform.controller.reloads, 2);
      view.params.onLoadStart!(controller, platform.controller.url);
      final intercept = view.params.shouldInterceptRequest!;
      for (final request in [
        WebResourceRequest(
          url: platform.controller.url,
          isForMainFrame: false,
          method: 'GET',
        ),
        WebResourceRequest(
          url: platform.controller.url,
          isForMainFrame: true,
          method: 'POST',
        ),
        WebResourceRequest(url: platform.controller.url, isForMainFrame: true),
        WebResourceRequest(
          url: WebUri('https://challenges.cloudflare.com/'),
          isForMainFrame: true,
          method: 'GET',
        ),
        WebResourceRequest(
          url: WebUri('https://mmhq.dg22.top/next'),
          isForMainFrame: true,
          method: 'GET',
        ),
      ]) {
        expect(await intercept(controller, request), null);
      }
      final main = WebResourceRequest(
        url: platform.controller.url,
        isForMainFrame: true,
        method: 'GET',
      );
      final response = await intercept(controller, main);
      expect(response!.statusCode, 200);
      expect(utf8.decode(response.data!), contains('public-page'));
      expect(await intercept(controller, main), null);
      view.params.onLoadStop!(controller, platform.controller.url);
      await tester.pump(const Duration(seconds: 3));
      expect(documents.calls, hasLength(1));
      expect(platform.controller.reloads, 2);
      expect(grant, null);
      expect(
        log.entries().where(
          (e) => e.event == 'parser.password_web.compatibility_loaded',
        ),
        hasLength(1),
      );
      await close(tester);
    },
  );

  for (final action in ['back', 'reload', 'navigate', 'timeout']) {
    testWidgets(
      'Compatibility GET cancellation on $action discards a late document',
      (tester) async {
        final pending = Completer<HttpResult>();
        var cancelled = false;
        final documents = FakeHttp((_) {
          RequestScope.current!.whenCancel.then((_) => cancelled = true);
          return pending.future;
        });
        await open(tester, documentHttp: documents);
        final (view, controller) = await attach(tester);
        platform.controller.result = {
          'status': 'error',
          'code': 'CF_BLOCKED',
          'message': '已拦截',
        };
        view.params.onLoadStop!(controller, platform.controller.url);
        await tester.pump();
        expect(documents.calls, hasLength(1));
        switch (action) {
          case 'back':
            await tester.tap(find.text('返回填写'));
            await tester.pump(const Duration(milliseconds: 400));
          case 'reload':
            await tester.tap(find.byKey(const ValueKey('password-web-reload')));
            await tester.pump();
          case 'navigate':
            view.params.onLoadStart!(
              controller,
              WebUri('https://mmhq.dg22.top/next'),
            );
            await tester.pump();
          case 'timeout':
            await tester.pump(const Duration(seconds: 26));
            expect(find.textContaining('兼容加载未能打开页面'), findsOneWidget);
        }
        expect(cancelled, true);
        final loads = platform.controller.reloads;
        pending.complete(
          const HttpResult(200, 'late-document', {
            'content-type': ['text/html'],
          }),
        );
        await tester.pump();
        expect(platform.controller.reloads, loads);
        expect(
          await view.params.shouldInterceptRequest!(
            controller,
            WebResourceRequest(
              url: WebUri('https://mmhq.dg22.top/'),
              isForMainFrame: true,
              method: 'GET',
            ),
          ),
          null,
        );
        expect(grant, null);
        await close(tester);
      },
    );
  }

  testWidgets(
    'Turnstile errors keep only the code and a successful result can still complete',
    (tester) async {
      await open(tester);
      final (view, controller) = await attach(tester);
      final error = ConsoleMessage(
        message:
            '[Cloudflare Turnstile] Error: 600010. token=console-private-secret',
        messageLevel: ConsoleMessageLevel.ERROR,
      );
      view.params.onConsoleMessage!(controller, error);
      view.params.onConsoleMessage!(controller, error);
      view.params.onLoadStop!(controller, platform.controller.url);
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('600010'), findsOneWidget);
      expect(find.text('请完成人机验证'), findsNothing);
      final logs = log.exportFiles().values.join('\n');
      expect(
        log.entries().where(
          (e) => e.event == 'parser.password_web.verification_failed',
        ),
        hasLength(1),
      );
      expect(logs, contains('600010'));
      expect(logs, isNot(contains('console-private-secret')));
      platform.controller.result = {
        'status': 'success',
        'password': 'final-after-error',
      };
      await tester.pump(const Duration(milliseconds: 850));
      for (var i = 0; i < 8 && grant == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(
        hub.grantedPassword('dg22_public', grant)!.value,
        'final-after-error',
      );
      await close(tester);
    },
  );

  testWidgets(
    'Foreign navigation and native permission requests are rejected',
    (tester) async {
      await open(tester);
      final (view, controller) = await attach(tester);
      view.params.onLoadStart!(controller, platform.controller.url);
      final blankNavigation = await view.params.shouldOverrideUrlLoading!(
        controller,
        NavigationAction(
          request: URLRequest(url: WebUri('about:blank')),
          isForMainFrame: true,
        ),
      );
      expect(blankNavigation, NavigationActionPolicy.CANCEL);
      final navigation = await view.params.shouldOverrideUrlLoading!(
        controller,
        NavigationAction(
          request: URLRequest(url: WebUri('https://other.example/')),
          isForMainFrame: true,
        ),
      );
      expect(navigation, NavigationActionPolicy.CANCEL);
      final permission = await view.params.onPermissionRequest!(
        controller,
        PermissionRequest(
          origin: WebUri('https://mmhq.dg22.top'),
          resources: [PermissionResourceType.CAMERA],
        ),
      );
      expect(permission!.action, PermissionResponseAction.DENY);
      platform.controller.pending = Completer<Object?>();
      view.params.onLoadStop!(controller, platform.controller.url);
      await tester.pump();
      view.params.onLoadStart!(controller, WebUri('https://other.example/'));
      platform.controller.pending!.complete({
        'status': 'success',
        'password': 'stale-navigation-secret',
      });
      await tester.pump();
      expect(grant, null);
      expect(find.byType(ParserPasswordWebPage), findsOneWidget);
      await close(tester);
    },
  );

  testWidgets(
    'A stalled script offers retry and late timeout results cannot continue',
    (tester) async {
      await open(tester);
      final (view, controller) = await attach(tester);
      platform.controller.pending = Completer<Object?>();
      view.params.onLoadStop!(controller, platform.controller.url);
      await tester.pump();
      await tester.pump(const Duration(seconds: 9));
      expect(find.text('读取网页失败，请重新加载后再试'), findsOneWidget);
      platform.controller.pending!.complete({
        'status': 'success',
        'password': 'timed-out-secret',
      });
      platform.controller.pending = null;
      await tester.pump();
      expect(grant, null);
      final loads = platform.controller.reloads;
      await tester.tap(find.byKey(const ValueKey('password-web-reload')));
      await tester.pump();
      expect(platform.controller.reloads, loads + 1);
      await close(tester);
    },
  );

  testWidgets('Initial blank navigation waits for the real browser settings', (
    tester,
  ) async {
    await open(tester);
    platform.controller.pendingSettings = Completer<InAppWebViewSettings?>();
    final (view, controller) = await attach(tester);
    view.params.onLoadStart!(controller, WebUri('about:blank'));
    view.params.onLoadStop!(controller, WebUri('about:blank'));
    await tester.pump(const Duration(seconds: 2));
    expect(platform.controller.reads, 0);
    expect(platform.controller.reloads, 0);
    platform.controller.pendingSettings!.complete(platform.controller.settings);
    await tester.pump();
    expect(platform.controller.reloads, 1);
    expect(platform.controller.url.toString(), 'https://mmhq.dg22.top/');
    await close(tester);
  });

  testWidgets('A timed out browser initialization can retry safely', (
    tester,
  ) async {
    await open(tester);
    platform.controller.pendingSettings = Completer<InAppWebViewSettings?>();
    await attach(tester);
    await tester.pump(const Duration(seconds: 11));
    expect(find.text('网页加载失败，请重新加载后再试，或返回手动填写密码'), findsOneWidget);
    platform.controller.pendingSettings!.complete(platform.controller.settings);
    platform.controller.pendingSettings = null;
    await tester.pump();
    expect(platform.controller.reloads, 0);
    await tester.tap(find.byKey(const ValueKey('password-web-reload')));
    await tester.pump();
    expect(platform.controller.reloads, 1);
    await close(tester);
  });

  testWidgets('Closing during browser initialization ignores its late result', (
    tester,
  ) async {
    await open(tester);
    platform.controller.pendingSettings = Completer<InAppWebViewSettings?>();
    final (view, _) = await attach(tester);
    await tester.tap(find.text('返回填写'));
    await tester.pump(const Duration(milliseconds: 400));
    platform.controller.pendingSettings!.complete(platform.controller.settings);
    await tester.pumpAndSettle();
    expect(view.disposed, true);
    expect(platform.controller.reloads, 0);
    expect(grant, null);
    await close(tester);
  });

  testWidgets('Manual fallback for a web recipe also stays local', (
    tester,
  ) async {
    prepareHub();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                grant = await showParserPasswordDialog(
                  context,
                  hub,
                  'dg22_public',
                );
              },
              child: const Text('解析样本'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('解析样本'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('parser-password-input')),
      '手动本机密码',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '继续解析'));
    await tester.pumpAndSettle();
    expect(hub.grantedPassword('dg22_public', grant)!.value, '手动本机密码');
    expect(http.calls, isEmpty);
    await close(tester);
  });
}
