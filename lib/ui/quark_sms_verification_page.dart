import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../data/providers/quark.dart';
import '../data/providers/quark_login.dart';
import '../domain/models.dart';
import '../domain/quark_sms_verification.dart';
import 'common.dart';
import 'login_webview.dart';

class QuarkSmsVerificationPage extends StatefulWidget {
  const QuarkSmsVerificationPage(
    this.services, {
    required this.useSlider,
    super.key,
  });
  final AppServices services;
  final bool useSlider;

  @override
  State<QuarkSmsVerificationPage> createState() =>
      _QuarkSmsVerificationPageState();
}

class _QuarkSmsVerificationPageState extends State<QuarkSmsVerificationPage> {
  WebViewEnvironment? _environment;
  InAppWebViewController? _web;
  CookieManager? _cookies;
  Timer? _timer;
  bool _ready = false, _finished = false, _checking = false;
  String _error = '';
  bool get _active => mounted && !_finished;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      widget.services.control.checkCloud(CloudPlatform.quark);
      _environment = await widget.services.webEnvironment();
      if (!_active) return;
      _cookies = CookieManager.instance(webViewEnvironment: _environment);
      await _cookies!.deleteAllCookies();
      if (_active) setState(() => _ready = true);
    } catch (_) {
      if (_active) setState(() => _error = '安全验证初始化失败，请返回重试或切换网页登录');
    }
  }

  Future<void> _capture() async {
    final web = _web;
    if (!_active || _checking || web == null) return;
    _checking = true;
    try {
      final page = (await web.getUrl())?.toString();
      if (!_active ||
          !identical(_web, web) ||
          !QuarkSmsVerification.trustedPage(page)) {
        return;
      }
      final result = await web.evaluateJavascript(
        source: QuarkSmsVerification.captureScript(useSlider: widget.useSlider),
      );
      if (!_active ||
          !identical(_web, web) ||
          result is! String ||
          result.isEmpty) {
        return;
      }
      final data = asJson(jsonDecode(result));
      if (data.values.any((value) => value is! String)) return;
      final fields = data.map((key, value) => MapEntry(key, value as String));
      if (!QuarkCaptchaProof(fields).valid) return;
      final cookies = await _cookies!.getCookies(
        url: WebUri(QuarkLoginService.mobilePage),
        webViewController: web,
      );
      if (!_active || !identical(_web, web)) return;
      // Preserve domain/path scoping when moving this private attempt's cookies
      // to its HTTP jar. Nothing is written to the account store here.
      final proof = QuarkCaptchaProof(fields, [
        for (final cookie in cookies)
          '${cookie.name}=${cookie.value}; Path=${cookie.path ?? '/'}'
              '${cookie.domain == null ? '' : '; Domain=${cookie.domain}'}'
              '${cookie.isSecure == true ? '; Secure' : ''}',
      ]);
      _timer?.cancel();
      await _cookies!.deleteAllCookies();
      if (!mounted || !_active || !identical(_web, web)) return;
      _finished = true;
      Navigator.pop(context, proof);
    } catch (_) {
      // A redirect or an SDK reload can replace the document while polling.
      // The next poll retries against the current official document.
    } finally {
      _checking = false;
    }
  }

  void _stop() {
    _finished = true;
    _timer?.cancel();
  }

  void _reload() {
    if (!_active) return;
    _timer?.cancel();
    _web = null;
    setState(() {
      _ready = false;
      _error = '';
    });
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _stop();
    },
    child: PageFrame(
      title: '夸克安全验证',
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('请完成官方安全验证，完成后将自动发送短信验证码'),
          ),
          Expanded(
            child: _error.isNotEmpty
                ? EmptyPanel(
                    '验证页面不可用',
                    _error,
                    icon: CupertinoIcons.lock_shield,
                  )
                : !_ready
                ? const Center(child: CircularProgressIndicator())
                : InAppWebView(
                    webViewEnvironment: _environment,
                    initialUrlRequest: URLRequest(
                      url: WebUri(QuarkLoginService.mobilePage),
                    ),
                    initialSettings: webSettings(
                      userAgent: QuarkConnector.webUa,
                      desktopMode: false,
                    ),
                    onWebViewCreated: (web) => _web = web,
                    onLoadStop: (web, url) {
                      if (!_active ||
                          !QuarkSmsVerification.trustedPage(url?.toString())) {
                        return;
                      }
                      _web = web;
                      _timer?.cancel();
                      _timer = Timer.periodic(
                        const Duration(milliseconds: 350),
                        (_) => unawaited(_capture()),
                      );
                      unawaited(_capture());
                    },
                    onReceivedError: (_, request, _) {
                      if (_active && request.isForMainFrame == true) {
                        setState(() => _error = '安全验证加载失败，请返回重试或切换网页登录');
                      }
                    },
                    shouldOverrideUrlLoading: (_, action) async =>
                        _active &&
                            (!action.isForMainFrame ||
                                QuarkSmsVerification.trustedPage(
                                  action.request.url?.toString(),
                                ))
                        ? NavigationActionPolicy.ALLOW
                        : NavigationActionPolicy.CANCEL,
                  ),
          ),
          TextButton.icon(
            onPressed: _ready || _error.isNotEmpty ? _reload : null,
            icon: const Icon(CupertinoIcons.arrow_clockwise, size: 18),
            label: const Text('重新加载安全验证'),
          ),
          const SizedBox(height: 16),
        ],
      ),
    ),
  );
}
