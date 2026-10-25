import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/app_theme.dart';
import 'package:asterlink/ui/baidu_login_panel.dart';
import 'package:asterlink/ui/login_page.dart';
import 'native_login_support.dart';
import 'support.dart';

class _Services extends AppServices {
  _Services(Directory directory)
    : super(
        controlEnabled: false,
        store: StateStore.memory(),
        dataDirectory: directory,
        cacheDirectory: Directory('${directory.path}/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('${directory.path}/files')),
        http: LoginHttp((_) => throw StateError('Unexpected network request')),
        platformFeatures: false,
      );
  @override
  Future<WebViewEnvironment?> webEnvironment() async => null;
}

class _Cookies extends PlatformCookieManager {
  _Cookies()
    : super.implementation(const PlatformCookieManagerCreationParams());
  List<Cookie> values = [];
  final readers = <PlatformInAppWebViewController?>[];
  @override
  Future<bool> deleteAllCookies() async {
    values = [];
    return true;
  }

  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    readers.add(webViewController);
    return values;
  }
}

class _Controller extends PlatformInAppWebViewController {
  _Controller()
    : super.implementation(
        PlatformInAppWebViewControllerCreationParams(id: 901),
      );
  final state = <String, dynamic>{
    'ready': true,
    'mode': 'sms',
    'phase': '',
    'sentAt': 0,
    'qrState': 'loading',
    'qrUrl': '',
  };
  WebUri url = WebUri('https://pan.baidu.com/');
  final operations = <String>[];
  bool navigateBeforeCommand = false;
  int sends = 0, submits = 0, reloads = 0;
  @override
  Future<WebUri?> getUrl() async => url;
  @override
  Future<void> loadUrl({
    required URLRequest urlRequest,
    Uri? iosAllowingReadAccessTo,
    WebUri? allowingReadAccessTo,
  }) async {
    reloads++;
    url = urlRequest.url!;
  }

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    final match = RegExp(
      r'return bridge.command\("([^"]+)", (.+)\);',
    ).firstMatch(source);
    if (match == null) return 'ready';
    final action = match.group(1)!;
    final data = jsonDecode(match.group(2)!) as Map;
    operations.add(action);
    if (action == 'read') return jsonEncode(state);
    if (navigateBeforeCommand && (action == 'send' || action == 'submit')) {
      url = WebUri('https://untrusted.example/');
      return 'blocked';
    }
    if (action == 'send') {
      sends++;
      state['phase'] = 'sending';
      return 'started';
    }
    if (action == 'submit') {
      submits++;
      state['phase'] = 'submitting';
      return 'started';
    }
    if (action == 'mode') {
      state['mode'] = data['mode'];
      state['phase'] = '';
      state['qrState'] = 'expired';
    }
    return 'ready';
  }
}

class _View extends PlatformInAppWebViewWidget {
  _View(super.params) : super.implementation();
  bool disposed = false;
  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Colors.white,
    child: Center(child: Text('百度官方页面')),
  );
  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      params.controllerFromPlatform!(controller) as T;
  @override
  void dispose() => disposed = true;
}

class _Platform extends InAppWebViewPlatform {
  final cookies = _Cookies();
  final views = <_View>[];
  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) => cookies;
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    final view = _View(params);
    views.add(view);
    return view;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final capture = GlobalKey();
  late _Services services;
  late Directory directory;
  final platform = _Platform();
  late _Controller native;
  late _View view;
  late InAppWebViewController web;
  late WidgetTester currentTester;
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
      await (FontLoader('BaiduFixture')..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
      systemFont = true;
    }
  });
  setUp(() {
    platform.views.clear();
    platform.cookies.values = [];
    platform.cookies.readers.clear();
    InAppWebViewPlatform.instance = platform;
    directory = Directory.systemTemp.createTempSync('asterlink-baidu-widget-');
    services = _Services(directory);
    native = _Controller();
  });
  tearDown(() async {
    await currentTester.runAsync(() async {
      await services.close();
      await directory.delete(recursive: true);
    });
  });

  Future<void> tick(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> render(
    WidgetTester tester, {
    Size size = const Size(393, 852),
    double scale = 1,
  }) async {
    currentTester = tester;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          theme: appTheme(
            Brightness.light,
            fontFamily: systemFont ? 'BaiduFixture' : null,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        PasswordLoginFlow(services, CloudPlatform.baidu),
                  ),
                ),
                child: const Text('打开登录'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开登录'));
    await tester.pumpAndSettle();
    view = platform.views.single;
    view.params.onWebViewCreated!(
      view.controllerFromPlatform<InAppWebViewController>(native),
    );
    web = view.controllerFromPlatform<InAppWebViewController>(native);
    view.params.onLoadStop!(web, native.url);
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => precacheImage(
        AssetImage('assets/icons/${CloudPlatform.baidu.icon}.png'),
        tester.element(find.byType(BaiduLoginPanel)),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() => tester.pumpWidget(const SizedBox()));
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> detect(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.text('检测登录'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
  }

  Future<void> fillPhone(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const ValueKey('baidu-sms-mobile')),
      '13800138000',
    );
    await tap(tester, 'baidu-sms-agreement');
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('BAIDU_LOGIN_SCREENSHOTS')) return;
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('.local/baidu-login-20261021/$name.png');
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final (size, scale, name) in [
    (const Size(393, 852), 1.0, 'phone'),
    (const Size(1280, 800), 1.0, 'desktop'),
    (const Size(360, 800), 1.5, 'phone-large-text'),
  ]) {
    testWidgets('Baidu native phone and QR layout $name', (tester) async {
      await render(tester, size: size, scale: scale);
      expect(find.byType(BaiduLoginPanel), findsOneWidget);
      expect(find.byKey(const ValueKey('baidu-sms-mobile')), findsOneWidget);
      expect(
        view.params.initialUserScripts!.any(
          (script) => script.source == desktopLoginViewportScript,
        ),
        isFalse,
      );
      expect(native.sends, 0);
      await screenshot(tester, '$name-sms');
      final selector = find.byKey(const ValueKey('baidu-login-method'));
      await tester.ensureVisible(selector);
      await tester.tap(
        find.descendant(of: selector, matching: find.text('扫码登录')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('baidu-qr-refresh')), findsOneWidget);
      expect(find.text('二维码已失效或加载失败，请重新获取'), findsOneWidget);
      expect(view.disposed, isFalse);
      expect(platform.views, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'SMS consent, challenge visibility and success preserve the same browser',
    (tester) async {
      await render(tester);
      await tap(tester, 'baidu-sms-send');
      expect(native.sends, 0);
      await fillPhone(tester);
      await tap(tester, 'baidu-sms-send');
      expect(native.sends, 1);
      expect(find.text('百度官方页面'), findsOneWidget);
      expect(find.byKey(const ValueKey('baidu-return-native')), findsOneWidget);
      native.state['phase'] = 'verify';
      await tick(tester);
      expect(find.text('百度官方页面'), findsOneWidget);
      expect(platform.views, hasLength(1));
      await tap(tester, 'baidu-return-native');
      await tick(tester);
      expect(find.byKey(const ValueKey('baidu-sms-mobile')), findsOneWidget);
      // Merely returning or polling must not replay the send command.
      expect(native.sends, 1);
      native.state['phase'] = 'sent';
      native.state['sentAt'] = DateTime.now().millisecondsSinceEpoch;
      await tick(tester);
      expect(find.text('验证码已发送，请查看手机短信'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('baidu-sms-code')),
        '012345',
      );
      await tap(tester, 'baidu-sms-submit');
      expect(native.submits, 1);
      expect(find.text('百度官方页面'), findsOneWidget);
      expect(view.disposed, isFalse);
    },
  );

  testWidgets(
    'successful SMS delivery returns to the native six-digit code form',
    (tester) async {
      await render(tester);
      await fillPhone(tester);
      await tap(tester, 'baidu-sms-send');
      native.state['phase'] = 'sent';
      native.state['sentAt'] = DateTime.now().millisecondsSinceEpoch;
      await tick(tester);
      expect(find.byKey(const ValueKey('baidu-sms-code')), findsOneWidget);
      expect(find.byKey(const ValueKey('baidu-return-native')), findsNothing);
      await tap(tester, 'baidu-sms-send');
      expect(native.sends, 1);
      expect(platform.views, hasLength(1));
    },
  );

  testWidgets('other methods and manual entry remain available', (
    tester,
  ) async {
    await render(tester);
    await tap(tester, 'native-login-manual');
    expect(find.byType(ManualLoginPage), findsOneWidget);
    expect(native.operations, contains('pause'));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(BaiduLoginPanel), findsOneWidget);
    expect(view.disposed, isFalse);
    await tap(tester, 'native-login-web');
    expect(find.byType(BaiduLoginPanel), findsNothing);
    expect(find.byKey(const ValueKey('web-login-password')), findsOneWidget);
    expect(view.disposed, isTrue);
    expect(native.operations, contains('close'));
    await tap(tester, 'web-login-password');
    expect(find.byType(BaiduLoginPanel), findsOneWidget);
  });

  testWidgets('navigation and account changes block native sends', (
    tester,
  ) async {
    await render(tester);
    await fillPhone(tester);
    native.navigateBeforeCommand = true;
    await tap(tester, 'baidu-sms-send');
    expect(native.sends, 0);
    await tap(tester, 'baidu-return-native');
    native.navigateBeforeCommand = false;
    native.url = WebUri('https://pan.baidu.com/');
    await tester.runAsync(
      () => services.vault.putCredential(
        CloudPlatform.baidu,
        LoginCredentials.candidate(
          CloudPlatform.baidu,
          'BDUSS=other-account',
          null,
        ),
      ),
    );
    await tap(tester, 'baidu-sms-send');
    expect(native.sends, 0);
    expect(find.text('账号已发生变化，请返回后重新登录'), findsOneWidget);
  });

  testWidgets('BDUSS is saved only after real account validation succeeds', (
    tester,
  ) async {
    final validation = Completer<LoginResult>();
    var validations = 0;
    services.login.webAuthenticators[CloudPlatform.baidu] = (credential) {
      validations++;
      return validation.future;
    };
    await render(tester);
    await tap(tester, 'baidu-show-verification');
    platform.cookies.values = [
      Cookie(name: 'BDUSS', value: 'private-baidu-session'),
    ];
    await detect(tester);
    expect(validations, 1);
    expect(services.vault.credential(CloudPlatform.baidu), isNull);
    validation.complete(
      LoginResult(
        LoginCredentials.candidate(
          CloudPlatform.baidu,
          'BDUSS=private-baidu-session',
          null,
        ),
        const CloudAccount('百度测试账号'),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(services.vault.credential(CloudPlatform.baidu), isNotNull);
    expect(
      platform.cookies.readers.every((reader) => identical(reader, native)),
      isTrue,
    );
    expect(find.byType(PasswordLoginFlow), findsNothing);
  });

  testWidgets('leaving the route cancels a pending account validation', (
    tester,
  ) async {
    final validation = Completer<LoginResult>();
    var validations = 0;
    services.login.webAuthenticators[CloudPlatform.baidu] = (_) {
      validations++;
      return validation.future;
    };
    await render(tester);
    await tap(tester, 'baidu-show-verification');
    platform.cookies.values = [
      Cookie(name: 'BDUSS', value: 'private-cancelled-session'),
    ];
    await detect(tester);
    expect(validations, 1);
    await tap(tester, 'baidu-return-native');
    await tester.pageBack();
    await tester.pumpAndSettle();
    validation.complete(
      LoginResult(
        LoginCredentials.candidate(
          CloudPlatform.baidu,
          'BDUSS=private-cancelled-session',
          null,
        ),
        const CloudAccount('不应保存'),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(services.vault.credential(CloudPlatform.baidu), isNull);
    expect(native.operations, contains('close'));
  });

  testWidgets(
    'failed file-list validation leaves the account unsaved and shows the reason',
    (tester) async {
      services.login.webAuthenticators[CloudPlatform.baidu] = (_) async =>
          throw const AppException('百度文件列表校验失败');
      await render(tester);
      await tap(tester, 'baidu-show-verification');
      platform.cookies.values = [
        Cookie(name: 'BDUSS', value: 'private-invalid-session'),
      ];
      await detect(tester);
      expect(services.vault.credential(CloudPlatform.baidu), isNull);
      expect(find.text('百度文件列表校验失败'), findsOneWidget);
      expect(find.byType(PasswordLoginFlow), findsOneWidget);
    },
  );

  testWidgets('background resume and renderer retry never replay SMS', (
    tester,
  ) async {
    await render(tester);
    await fillPhone(tester);
    await tap(tester, 'baidu-sms-send');
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(native.operations, containsAll(['pause', 'resume']));
    expect(native.sends, 1);
    view.params.onRenderProcessGone!(
      web,
      RenderProcessGoneDetail(didCrash: true),
    );
    await tester.pumpAndSettle();
    expect(view.disposed, isTrue);
    expect(find.text('登录页面已停止运行，请重试或切换登录方式'), findsOneWidget);
    expect(find.text('其他登录方式（网页）'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(platform.views, hasLength(2));
    expect(native.sends, 1);
    expect(find.byType(BaiduLoginPanel), findsOneWidget);
  });

  testWidgets(
    'refresh discards an unfinished validation and starts a fresh browser',
    (tester) async {
      final validation = Completer<LoginResult>();
      var validations = 0;
      services.login.webAuthenticators[CloudPlatform.baidu] = (_) {
        validations++;
        return validation.future;
      };
      await render(tester);
      await tap(tester, 'baidu-show-verification');
      platform.cookies.values = [
        Cookie(name: 'BDUSS', value: 'private-old-browser-session'),
      ];
      await detect(tester);
      expect(validations, 1);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('刷新网页'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(view.disposed, isTrue);
      expect(platform.views, hasLength(2));
      validation.complete(
        LoginResult(
          LoginCredentials.candidate(
            CloudPlatform.baidu,
            'BDUSS=private-old-browser-session',
            null,
          ),
          const CloudAccount('旧页面账号'),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      expect(services.vault.credential(CloudPlatform.baidu), isNull);
      expect(native.sends, 0);
    },
  );
}
