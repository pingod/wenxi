import 'dart:io';
import 'package:flutter/foundation.dart';

/// Desktops run the bundled Gopeed helper as a child process and share the wide
/// window layout. Android uses the service/JNI path instead, and the web build
/// has no native engine at all.
///
/// IO-level decisions (paths, helper name, tray) use this getter. Widget code
/// uses [isDesktopTarget] with `Theme.of(context).platform` so tests keep the
/// ability to override the platform with `debugDefaultTargetPlatformOverride`.
bool get isDesktopPlatform => Platform.isWindows || Platform.isLinux;

/// Framework platform check for layout decisions. Mirrors the previous
/// `TargetPlatform.windows` tests while also covering Linux desktops.
bool isDesktopTarget(TargetPlatform platform) =>
    platform == TargetPlatform.windows ||
    platform == TargetPlatform.linux ||
    platform == TargetPlatform.macOS;

/// Windows ships the helper as `asterlink_gopeed.exe`; Linux keeps the plain
/// executable name next to the app binary.
String desktopHelperName() =>
    Platform.isWindows ? 'asterlink_gopeed.exe' : 'asterlink_gopeed';

/// Web login relies on the WebView2 bridge on Windows and the platform WebView
/// on Android. Linux has no browser component in this app yet, so the UI leads
/// those entries to manual credential entry instead.
bool get supportsWebLoginUi =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.android;
