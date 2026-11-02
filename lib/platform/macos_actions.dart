import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import 'desktop_actions.dart';

typedef MacosCommand =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// macOS desktop integration.
///
/// Revealing a file uses `open -R`, which selects the file in Finder just like
/// the Windows/Space-explorer behaviour. Shutdown and sleep go through
/// AppleScript (`osascript`), so the system shows its own confirmation prompt and
/// the request fails cleanly when the user declines instead of silently doing
/// nothing. No privileged helper is required.
class MacosActions implements DesktopActions {
  MacosActions({required this.supported, MacosCommand? run})
    : _run = run ?? _runProcess;

  @override
  final bool supported;
  final MacosCommand _run;

  @override
  Future<void> revealFile(String path) async {
    require(supported, '当前平台不支持打开访达');
    require(p.isAbsolute(path), '无法定位文件，请重新检查下载文件');
    final location = p.normalize(path);
    final type = await FileSystemEntity.type(location);
    require(type != FileSystemEntityType.notFound, '文件不存在或已被移动');
    final result = await _run('open', ['-R', location]);
    require(result.exitCode == 0, '未能打开访达，请手动前往下载目录');
  }

  @override
  Future<void> shutdown() async {
    require(supported, '当前平台不支持下载完成后关机');
    final result = await _run('osascript', const [
      '-e',
      'tell application "System Events" to shut down',
    ]);
    require(result.exitCode == 0, '系统未接受关机请求，请检查权限后重试');
  }

  @override
  Future<void> hibernate() async {
    require(supported, '当前平台不支持下载完成后休眠');
    // `pmset sleepnow` puts the machine to sleep; macOS has no user-facing
    // hibernate that differs from sleep, so sleep is the closest equivalent.
    final result = await _run('pmset', const ['sleepnow']);
    require(result.exitCode == 0, '系统未接受休眠请求，请检查权限后重试');
  }

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments,
  ) => Process.run(executable, arguments);
}
