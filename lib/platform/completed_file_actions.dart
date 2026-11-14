import 'dart:io';

import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../core/json.dart';

/// Opens the saved file itself, independently of the app's media preview.
class CompletedFileActions {
  CompletedFileActions({
    String? platform,
    MethodChannel channel = const MethodChannel('com.asterlink.app/native'),
    MethodChannel windowsChannel = const MethodChannel(
      'com.asterlink.app/file_actions',
    ),
    SharePlus? sharing,
    Future<void> Function(String path)? reveal,
  }) : _platform = platform ?? Platform.operatingSystem,
       _channel = channel,
       _windowsChannel = windowsChannel,
       _sharing = sharing ?? SharePlus.instance,
       _reveal = reveal;

  final String _platform;
  final MethodChannel _channel, _windowsChannel;
  final SharePlus _sharing;

  /// Linux has neither a system "open with" chooser nor a file share sheet, so
  /// both entries locate the download in the file manager instead and the user
  /// picks an application from there.
  final Future<void> Function(String path)? _reveal;

  Future<void> _locate(String path) async {
    final reveal = _reveal;
    if (reveal == null) throw const AppException('当前系统不支持选择其他应用');
    await reveal(path);
  }

  Future<void> openWith(String path, String name, {Rect? origin}) async {
    try {
      switch (_platform) {
        case 'android':
          await _channel.invokeMethod<void>('openFile', {
            'path': path,
            'name': name,
            'chooseApp': true,
          });
        case 'windows':
          await _windowsChannel.invokeMethod<void>('openWith', {'path': path});
        case 'macos':
          await _channel.invokeMethod<void>('openWith', {'path': path});
        case 'ios':
          // The iOS share sheet offers compatible apps and "Copy to" actions
          // without first opening Quick Look or the built-in video player.
          await share(path, name, origin: origin);
        case 'linux':
          await _locate(path);
        default:
          throw const AppException('当前系统不支持选择其他应用');
      }
    } on PlatformException catch (error) {
      throw AppException(error.message ?? '无法选择应用，请检查文件访问权限');
    }
  }

  Future<void> share(String path, String name, {Rect? origin}) async {
    try {
      if (_platform == 'android') {
        // SAF documents are content URIs: pass them directly to Android rather
        // than treating them as a local filesystem path or copying large files.
        await _channel.invokeMethod<void>('shareFile', {
          'path': path,
          'name': name,
        });
      } else if (_platform == 'linux') {
        await _locate(path);
      } else {
        await _sharing.share(
          ShareParams(files: [XFile(path)], sharePositionOrigin: origin),
        );
      }
    } on PlatformException catch (error) {
      throw AppException(error.message ?? '无法分享文件，请检查文件访问权限');
    }
  }
}
