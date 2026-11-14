import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/json.dart';
import 'windows_external_player.dart';

/// Launches a player chosen by the user on Linux.
///
/// The picker returns a plain executable path (mpv, VLC, celluloid, ...), so
/// unlike macOS there is no bundle to validate. The runner spawns it detached
/// and reports whether the process started.
class LinuxExternalPlayer extends WindowsExternalPlayer {
  static const _channel = MethodChannel('com.asterlink.app/native');

  @override
  Future<bool> open(String url) async {
    final path = executable;
    require(path != null && p.posix.isAbsolute(path), '请先选择外部播放器');
    require(await File(path!).exists(), '播放器程序不存在，请重新选择');
    require(url.isNotEmpty, '播放地址为空');
    try {
      return await _channel.invokeMethod<bool>('openExternalPlayer', {
            'application': path,
            'url': url,
          }) ??
          false;
    } on MissingPluginException {
      throw const AppException('当前系统的播放器启动组件不可用，请更新应用后重试');
    } on PlatformException catch (error) {
      throw AppException(error.message ?? '无法启动所选播放器');
    }
  }
}
