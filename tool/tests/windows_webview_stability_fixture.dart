// Local-only WebView2 fixture. No real account, cookies, or external site is used.
import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Cookie;
import 'dart:ui' as ui;

import 'package:asterlink/ui/login_webview.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:window_manager/window_manager.dart';

Future<bool> serveStabilityFixture(HttpRequest request) async {
  if (!request.uri.path.startsWith('/stability/')) return false;
  final response = request.response;
  response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
  if (request.uri.path == '/stability/redirect') {
    response.statusCode = HttpStatus.found;
    response.headers.set(
      HttpHeaders.locationHeader,
      '/stability/page?step=${request.uri.queryParameters['step']}#after-login',
    );
  } else {
    response.headers.contentType = ContentType.html;
    response.write(
      '''<!doctype html><html><head><title>Local login stability</title>
<style>body{margin:0;background:rgb(24,40,70);color:white;font:18px sans-serif}
canvas{display:block}iframe{width:100px;height:30px;border:0}</style></head>
<body><canvas width="420" height="150"></canvas><div>Local WebView2 fixture</div>
<script>
window.renderTicks = 0;
const canvas = document.querySelector('canvas');
const context = canvas.getContext('2d');
setInterval(() => {
  ++window.renderTicks;
  context.fillStyle = '#e43187'; context.fillRect(0, 0, 210, 150);
  context.fillStyle = '#24bda6'; context.fillRect(210, 0, 210, 150);
  context.fillStyle = '#fff'; context.fillRect(window.renderTicks % 390, 20, 30, 30);
}, 30);
</script></body></html>''',
    );
  }
  await response.close();
  return true;
}

Future<void> verifyPermissionReplies({
  required String origin,
  required Directory output,
  required void Function(String, bool) check,
}) async {
  for (final scenario in [
    'missing-handler',
    'null-reply',
    'delayed-null-reply',
    'grant',
    'disposed-null-reply',
  ]) {
    // Permission decisions can persist for an origin. Each case gets its own
    // profile so a previously denied request cannot skip the native callback.
    final environment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: '${output.path}/permission-profile-$scenario',
      ),
    );
    final started = Completer<void>();
    final releaseReply = Completer<void>();
    final returned = Completer<void>();
    var calls = 0;
    HeadlessInAppWebView? view;
    try {
      final loaded = Completer<void>();
      final page = '$origin/stability/permission?case=$scenario';
      view = HeadlessInAppWebView(
        webViewEnvironment: environment,
        initialSettings: webSettings(),
        initialUrlRequest: URLRequest(url: WebUri(page)),
        shouldOverrideUrlLoading: (_, _) async => NavigationActionPolicy.ALLOW,
        onLoadStop: (_, url) {
          if (url?.toString() == page && !loaded.isCompleted) loaded.complete();
        },
        // The production Baidu login view has no onPermissionRequest handler.
        onPermissionRequest: scenario == 'missing-handler'
            ? null
            : (_, request) async {
                ++calls;
                if (!started.isCompleted) started.complete();
                if (scenario == 'disposed-null-reply') {
                  await releaseReply.future;
                } else if (scenario == 'delayed-null-reply') {
                  await Future<void>.delayed(const Duration(milliseconds: 350));
                }
                if (!returned.isCompleted) returned.complete();
                if (scenario == 'grant') {
                  return PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                }
                return null;
              },
      );
      await view.run().timeout(const Duration(seconds: 10));
      await loaded.future.timeout(const Duration(seconds: 10));
      final web = view.webViewController!;
      await web.callDevToolsProtocolMethod(
        methodName: 'Runtime.evaluate',
        parameters: {
          'expression': '''
window.permissionResult = 'waiting';
Notification.requestPermission().then(value => window.permissionResult = value);
true;''',
          'userGesture': true,
          'returnByValue': true,
        },
      );
      if (scenario == 'disposed-null-reply') {
        await started.future.timeout(const Duration(seconds: 10));
        await view.dispose();
        view = null;
        releaseReply.complete();
        await returned.future.timeout(const Duration(seconds: 10));
        final reopened = Completer<void>();
        view = HeadlessInAppWebView(
          webViewEnvironment: environment,
          initialSettings: webSettings(),
          initialUrlRequest: URLRequest(url: WebUri(page)),
          shouldOverrideUrlLoading: (_, _) async =>
              NavigationActionPolicy.ALLOW,
          onLoadStop: (_, url) {
            if (url?.toString() == page && !reopened.isCompleted) {
              reopened.complete();
            }
          },
        );
        await view.run().timeout(const Duration(seconds: 10));
        await reopened.future.timeout(const Duration(seconds: 10));
        check(
          'A null permission reply after disposal leaves the next page usable',
          calls == 1 &&
              await view.webViewController!.evaluateJavascript(
                    source: '1 + 1',
                  ) ==
                  2,
        );
        continue;
      }
      final expected = scenario == 'grant' ? 'granted' : 'denied';
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (await web.evaluateJavascript(source: 'window.permissionResult') !=
          expected) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Permission request did not complete: $scenario');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      check(
        'Permission $scenario completes and the live page keeps working',
        calls == (scenario == 'missing-handler' ? 0 : 1) &&
            await web.evaluateJavascript(source: '1 + 1') == 2,
      );
    } finally {
      if (!releaseReply.isCompleted) releaseReply.complete();
      await view?.dispose().timeout(const Duration(seconds: 3));
      await environment.dispose().timeout(const Duration(seconds: 3));
    }
  }
}

Future<void> verifyWebViewStability({
  required String origin,
  required WebViewEnvironment environment,
  required Directory output,
  required void Function(String, bool) check,
}) async {
  await windowManager.ensureInitialized();
  // The runner shows its window after the first frame; keep this test invisible.
  await windowManager.setOpacity(0);
  final generation = ValueNotifier<int>(0);
  final size = ValueNotifier<Size>(const Size(560, 360));
  final rendered = GlobalKey();
  final ready = <int, Completer<InAppWebViewController>>{};
  final loaded = <String, Completer<void>>{};
  final delayedResource = Completer<void>();
  var resourceCalls = 0;
  var permissionCalls = 0;
  var navigationCalls = 0;
  var pendingResourceStarted = false;
  var pendingResourceReturned = false;
  final rendererFailure = Completer<RenderProcessGoneDetail>();

  Future<void> waitFor(FutureOr<bool> Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!await condition()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('WebView2 fixture condition timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  String initialUrl(int value) => '$origin/stability/page?view=$value';
  void prepare(int value) {
    ready[value] = Completer<InAppWebViewController>();
    loaded[initialUrl(value)] = Completer<void>();
  }

  prepare(0);
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder<int>(
            valueListenable: generation,
            builder: (context, value, _) {
              if (value < 0) return const SizedBox.shrink();
              return ValueListenableBuilder<Size>(
                valueListenable: size,
                builder: (context, dimensions, _) => SizedBox(
                  width: dimensions.width,
                  height: dimensions.height,
                  child: RepaintBoundary(
                    key: rendered,
                    child: InAppWebView(
                      key: ValueKey(value),
                      webViewEnvironment: environment,
                      initialSettings: webSettings()
                        ..useShouldInterceptRequest = true
                        ..useOnRenderProcessGone = true,
                      onRenderProcessGone: (_, detail) {
                        if (!rendererFailure.isCompleted) {
                          rendererFailure.complete(detail);
                        }
                      },
                      initialUrlRequest: URLRequest(
                        url: WebUri(initialUrl(value)),
                      ),
                      onWebViewCreated: (web) => ready[value]!.complete(web),
                      onLoadStop: (_, url) {
                        final completion = loaded[url?.toString()];
                        if (completion != null && !completion.isCompleted) {
                          completion.complete();
                        }
                      },
                      shouldOverrideUrlLoading: (_, _) async {
                        ++navigationCalls;
                        await Future<void>.delayed(
                          const Duration(milliseconds: 50),
                        );
                        return NavigationActionPolicy.ALLOW;
                      },
                      onPermissionRequest: (_, request) async {
                        ++permissionCalls;
                        await Future<void>.delayed(
                          const Duration(milliseconds: 500),
                        );
                        return PermissionResponse(
                          resources: request.resources,
                          action: PermissionResponseAction.DENY,
                        );
                      },
                      shouldInterceptRequest: (_, request) async {
                        final path = request.url.path;
                        if (path != '/stability/data' &&
                            path != '/stability/pending') {
                          return null;
                        }
                        ++resourceCalls;
                        if (path == '/stability/pending') {
                          pendingResourceStarted = true;
                          await delayedResource.future;
                          pendingResourceReturned = true;
                        } else {
                          await Future<void>.delayed(
                            const Duration(milliseconds: 350),
                          );
                        }
                        return WebResourceResponse(
                          contentType: 'text/plain',
                          statusCode: 200,
                          reasonPhrase: 'OK',
                          data: Uint8List.fromList(utf8.encode('fixture-data')),
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );

  try {
    final web = await ready[0]!.future.timeout(const Duration(seconds: 10));
    await loaded[initialUrl(0)]!.future.timeout(const Duration(seconds: 10));
    var protocolErrorReturned = false;
    try {
      await web.callDevToolsProtocolMethod(
        methodName: 'AsterLink.fixtureUnsupportedMethod',
      );
    } on PlatformException {
      protocolErrorReturned = true;
    }
    check(
      'Failed browser protocol call returns an error without terminating the host',
      protocolErrorReturned &&
          await web.evaluateJavascript(source: '1 + 1') == 2,
    );
    await web.callDevToolsProtocolMethod(
      methodName: 'Runtime.evaluate',
      parameters: {
        'expression': '''
window.permissionResult = 'waiting';
Notification.requestPermission().then(value => window.permissionResult = value);
window.resourceResult = 'waiting';
fetch('/stability/data').then(r => r.text()).then(value => window.resourceResult = value);
true;''',
        'userGesture': true,
        'returnByValue': true,
      },
    );
    await waitFor(() async {
      return await web.evaluateJavascript(
            source:
                "window.permissionResult === 'denied' && window.resourceResult === 'fixture-data'",
          ) ==
          true;
    });
    check(
      'Live page survives delayed permission and resource replies',
      permissionCalls > 0 && resourceCalls > 0,
    );

    for (var step = 0; step < 12; ++step) {
      final target = '$origin/stability/page?step=$step#after-login';
      loaded[target] = Completer<void>();
      await web.loadUrl(
        urlRequest: URLRequest(
          url: WebUri('$origin/stability/redirect?step=$step'),
        ),
      );
      await loaded[target]!.future.timeout(const Duration(seconds: 10));
      size.value = step.isEven ? const Size(560, 360) : const Size(420, 280);
      await web.evaluateJavascript(
        source:
            '''
for (const message of [null, 7, 'invalid', {name:'callHandler'},
  {name:'callHandler', body:{handlerName:'fixture', _callHandlerID:1, args:'invalid'}}]) {
  window.chrome.webview.postMessage(message);
}
const frame = document.createElement('iframe');
frame.src = '/stability/frame?step=$step'; document.body.appendChild(frame);
true;''',
      );
      final reply = await web.callAsyncJavaScript(
        functionBody:
            'await new Promise(r => setTimeout(r, 50)); return {ok:true};',
      );
      if (reply?.value is! Map || reply!.value['ok'] != true) {
        throw StateError('Asynchronous page reply failed after redirect $step');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    check(
      'Rendered login page survives 12 redirects, frame changes, and resizes',
      navigationCalls >= 24,
    );

    final firstTick = await web.evaluateJavascript(
      source: 'window.renderTicks',
    );
    final cookies = CookieManager.instance(webViewEnvironment: environment);
    for (var poll = 0; poll < 40; ++poll) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await cookies.getCookies(url: WebUri(origin), webViewController: web);
    }
    final lastTick = await web.evaluateJavascript(source: 'window.renderTicks');
    check(
      'Page keeps running during 40 native cookie polls over 10 seconds',
      // An invisible Windows test window may throttle page timers.
      firstTick is num && lastTick is num && lastTick > firstTick + 2,
    );
    await WidgetsBinding.instance.endOfFrame;
    final boundary =
        rendered.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final picture = await boundary.toImage(pixelRatio: 1);
    try {
      final pixels = (await picture.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final colors = <int>{};
      for (var offset = 0; offset + 4 <= pixels.lengthInBytes; offset += 128) {
        colors.add(pixels.getUint32(offset));
      }
      check(
        'WebView GPU texture produces a nonblank Flutter frame',
        colors.length > 3,
      );
      final png = (await picture.toByteData(format: ui.ImageByteFormat.png))!;
      await File('${output.path}/webview-render.png').writeAsBytes(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
    } finally {
      picture.dispose();
    }

    await web.evaluateJavascript(
      source: "fetch('/stability/pending').catch(() => {}); true;",
    );
    await waitFor(() => pendingResourceStarted);
    generation.value = -1;
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    delayedResource.complete();
    await waitFor(() => pendingResourceReturned);
    prepare(1);
    generation.value = 1;
    final reopened = await ready[1]!.future.timeout(
      const Duration(seconds: 10),
    );
    await loaded[initialUrl(1)]!.future.timeout(const Duration(seconds: 10));
    check(
      'Late resource reply after disposal does not affect a new login window',
      await reopened.evaluateJavascript(source: '1 + 1') == 2,
    );
    // This URL deliberately crashes only the isolated test renderer. Verify
    // native ProcessFailed reaches Dart and the host can create another view.
    await reopened.loadUrl(
      urlRequest: URLRequest(url: WebUri('chrome://crash')),
    );
    final failure = await rendererFailure.future.timeout(
      const Duration(seconds: 10),
    );
    check(
      'A real WebView2 renderer crash reaches onRenderProcessGone',
      failure.didCrash,
    );
    generation.value = -1;
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    prepare(2);
    generation.value = 2;
    final recovered = await ready[2]!.future.timeout(
      const Duration(seconds: 10),
    );
    await loaded[initialUrl(2)]!.future.timeout(const Duration(seconds: 10));
    check(
      'The host survives a renderer crash and can reopen a login page',
      await recovered.evaluateJavascript(source: '2 + 2') == 4,
    );
  } finally {
    if (!delayedResource.isCompleted) delayedResource.complete();
    generation.value = -1;
    await WidgetsBinding.instance.endOfFrame;
    runApp(const SizedBox.shrink());
    await WidgetsBinding.instance.endOfFrame;
    generation.dispose();
    size.dispose();
    await windowManager.hide();
  }
}
