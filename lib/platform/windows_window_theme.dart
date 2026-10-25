import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../diagnostics/app_log.dart';

/// Keeps the native window chrome in the app's effective theme.
///
/// Windows repaints its Win32 caption; on Linux the GTK runner paints the
/// header bar it creates, because GTK themes (commonly light while the app is
/// dark) would otherwise leave a bright strip above the UI.
class WindowsWindowTheme extends StatefulWidget {
  const WindowsWindowTheme({
    super.key,
    required this.child,
    this.enabled = true,
  });

  final Widget child;
  final bool enabled;

  @override
  State<WindowsWindowTheme> createState() => _WindowsWindowThemeState();
}

class _WindowsWindowThemeState extends State<WindowsWindowTheme> {
  static const _channel = MethodChannel('com.asterlink.app/window_theme');
  Brightness? _lastSent;

  bool get _supported => Platform.isWindows || Platform.isLinux;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(WindowsWindowTheme oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      _lastSent = null;
      _sync();
    }
  }

  void _sync() {
    if (!widget.enabled || !_supported) return;
    final brightness = Theme.of(context).brightness;
    if (_lastSent == brightness) return;
    _lastSent = brightness;
    unawaited(_apply(brightness));
  }

  Future<void> _apply(Brightness brightness) async {
    try {
      await _channel.invokeMethod<void>('setTheme', {
        'dark': brightness == Brightness.dark,
      });
    } catch (error, stack) {
      if (_lastSent == brightness) _lastSent = null;
      DiagnosticLog.error('window.theme_failed', error, stack);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
