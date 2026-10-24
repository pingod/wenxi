import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import '../core/json.dart';
import '../domain/downloads.dart';
import '../domain/remote_control.dart';
import 'desktop_actions.dart';

class AppUpdateInstaller {
  AppUpdateInstaller({required this.platform, required this.desktop});
  final String platform;
  final DesktopActions desktop;
  static const _channel = MethodChannel('com.asterlink.app/native');

  static bool supportsName(String name, String platform) {
    final lower = name.toLowerCase();
    return platform == 'android'
        ? lower.endsWith('.apk')
        : platform == 'windows' &&
              (lower.endsWith('.exe') || lower.endsWith('.zip'));
  }

  static void requirePackageName(String name, String platform) => require(
    supportsName(name, platform),
    platform == 'android'
        ? '安卓更新链接必须是单个 APK 安装包'
        : 'Windows 更新链接必须是单个 EXE 安装包或 ZIP 压缩包',
  );

  Future<String> prepare(DownloadTask task, RemoteUpdate update) async {
    requirePackageName(task.spec.fileName, platform);
    final path = task.savedPath!;
    if (platform == 'android') {
      try {
        final prepared = await _channel.invokeMethod<String>(
          'prepareAppUpdate',
          {'path': path, 'version': update.version, 'build': update.build},
        );
        require(prepared != null && prepared.isNotEmpty, '无法校验更新安装包');
        return prepared!;
      } on PlatformException catch (error) {
        throw AppException(error.message ?? '安装包校验失败，请使用浏览器更新');
      }
    }
    require(platform == 'windows', '当前平台请使用浏览器更新');
    final input = await File(path).open();
    try {
      final bytes = await input.read(4);
      final zip = task.spec.fileName.toLowerCase().endsWith('.zip');
      require(
        bytes.length == 4 &&
            (zip
                ? bytes[0] == 0x50 &&
                      bytes[1] == 0x4b &&
                      bytes[2] == 3 &&
                      bytes[3] == 4
                : bytes[0] == 0x4d && bytes[1] == 0x5a),
        '下载内容不是有效的安装包，请重试或使用浏览器更新',
      );
      if (!zip) {
        // Reject HTML or other data renamed to .exe, including an MZ prefix
        // without a valid portable-executable header.
        await input.setPosition(0x3c);
        final offsetBytes = await input.read(4);
        require(offsetBytes.length == 4, '安装包不完整，请重新下载');
        final offset = ByteData.sublistView(
          offsetBytes,
        ).getUint32(0, Endian.little);
        require(offset >= 64 && offset + 4 <= await input.length(), '安装包格式有误');
        await input.setPosition(offset);
        final signature = await input.read(4);
        require(
          signature.length == 4 &&
              signature[0] == 0x50 &&
              signature[1] == 0x45 &&
              signature[2] == 0 &&
              signature[3] == 0,
          '安装包格式有误',
        );
      }
    } finally {
      await input.close();
    }
    return path;
  }

  Future<void> open(String path, String name) async {
    if (platform == 'android') {
      try {
        await _channel.invokeMethod<void>('openFile', {
          'path': path,
          'name': name,
        });
      } on PlatformException catch (error) {
        throw AppException(error.message ?? '无法打开系统安装器');
      }
    } else if (name.toLowerCase().endsWith('.zip')) {
      await desktop.revealFile(path);
    } else {
      final result = await OpenFilex.open(path);
      require(result.type == ResultType.done, '无法打开安装器，请到下载管理中打开文件');
    }
  }
}
