import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import '../diagnostics/app_log.dart';

/// A failed WebView2 profile must not prevent every provider from logging in.
/// Keep the original profile and retry with a separate writable local profile.
class WindowsWebViewHost {
  WindowsWebViewHost({
    required this.primaryFolder,
    required this.recoveryFolder,
    Future<String?> Function()? availableVersion,
    Future<WebViewEnvironment> Function(String folder)? createEnvironment,
  }) : _availableVersion =
           availableVersion ?? (() => WebViewEnvironment.getAvailableVersion()),
       _createEnvironment = createEnvironment ?? _create;

  final String primaryFolder, recoveryFolder;
  final Future<String?> Function() _availableVersion;
  final Future<WebViewEnvironment> Function(String folder) _createEnvironment;
  WebViewEnvironment? _environment;
  final _retired = <WebViewEnvironment>[];
  Future<WebViewEnvironment>? _starting;
  Future<void>? _closing;
  bool _closed = false;

  static Future<WebViewEnvironment> _create(String folder) async {
    await Directory(folder).create(recursive: true);
    return WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(userDataFolder: folder),
    );
  }

  Future<WebViewEnvironment> get() {
    require(!_closed, '网页登录组件已经关闭');
    if (_environment != null) return Future.value(_environment);
    return _starting ??= _initialize().whenComplete(() => _starting = null);
  }

  void invalidate(WebViewEnvironment? environment) {
    if (_closed ||
        environment == null ||
        !identical(environment, _environment)) {
      return;
    }
    // Existing controllers may still deliver their final callbacks. Keep their
    // environment alive until shutdown; the next explicit retry gets a new one.
    _retired.add(environment);
    _environment = null;
    DiagnosticLog.event('webview.environment.invalidated');
  }

  Future<WebViewEnvironment> _initialize() async {
    final version = await _availableVersion();
    require(
      version?.isNotEmpty == true,
      '未找到 Microsoft Edge WebView2 Runtime，请安装后重新打开应用，或使用手动登录',
    );
    DiagnosticLog.event(
      'webview.environment.initialize',
      fields: {
        'runtimeVersion': version,
        'osVersion': Platform.operatingSystemVersion,
      },
    );
    String? lastCode;
    final folders = [
      primaryFolder,
      if (!p.equals(primaryFolder, recoveryFolder)) recoveryFolder,
    ];
    for (var attempt = 0; attempt < folders.length; attempt++) {
      require(!_closed, '网页登录组件已经关闭');
      try {
        final environment = await _createEnvironment(folders[attempt]);
        if (_closed) {
          await environment.dispose();
          throw const AppException('网页登录组件已经关闭');
        }
        _environment = environment;
        if (attempt > 0) {
          DiagnosticLog.event('webview.environment.recovered');
        }
        return environment;
      } catch (error, stack) {
        if (error is! PlatformException && error is! FileSystemException) {
          rethrow;
        }
        lastCode = null;
        if (error is PlatformException) {
          final details = error.details;
          final numeric = details is Map ? details['hresult'] : null;
          lastCode = numeric is int
              ? '0x${(numeric & 0xffffffff).toRadixString(16).padLeft(8, '0').toUpperCase()}'
              : RegExp(r'^0x[0-9a-fA-F]{8}$').hasMatch(error.code)
              ? error.code
              : null;
        }
        DiagnosticLog.active?.record(
          'webview.environment.attempt_failed',
          level: 'warning',
          error: error,
          stack: stack,
          fields: {
            'profile': attempt == 0 ? 'primary' : 'recovery',
            'hresult': lastCode,
          },
        );
      }
    }
    throw AppException(
      '网页登录组件启动失败${lastCode == null ? '' : '（$lastCode）'}，'
      '已尝试独立登录环境。请修复或更新 Microsoft Edge WebView2 Runtime 后重试，也可使用手动登录',
    );
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    try {
      await _starting;
    } catch (_) {
      // A pending creation either failed or disposed its late result above.
    }
    final environment = _environment;
    _environment = null;
    await environment?.dispose();
    for (final retired in _retired) {
      await retired.dispose();
    }
    _retired.clear();
  }
}
