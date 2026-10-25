import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import 'desktop_actions.dart';

typedef LinuxCommand =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Linux desktop integration.
///
/// Revealing a file prefers the freedesktop `FileManager1` D-Bus interface so
/// the file is *selected* like on Windows; desktops without that interface fall
/// back to opening the parent directory with `xdg-open`. Shutdown uses logind
/// through `systemctl`, so polkit decides whether the session may power off.
class LinuxActions implements DesktopActions {
  LinuxActions({required this.supported, LinuxCommand? run})
    : _run = run ?? _runProcess;

  @override
  final bool supported;
  final LinuxCommand _run;

  @override
  Future<void> revealFile(String path) async {
    require(supported, '当前平台不支持打开文件管理器');
    require(p.isAbsolute(path), '无法定位文件，请重新检查下载文件');
    final location = p.normalize(path);
    final type = await FileSystemEntity.type(location);
    require(type != FileSystemEntityType.notFound, '文件不存在或已被移动');
    if (type != FileSystemEntityType.directory &&
        await _showItems(Uri.file(location))) {
      return;
    }
    final result = await _run('xdg-open', [p.dirname(location)]);
    require(result.exitCode == 0, '未能打开文件管理器，请手动前往下载目录');
  }

  /// Selects one file through `FileManager1.ShowItems`.
  ///
  /// `dbus-send`'s `array:string:` syntax splits its argument on commas, so a
  /// file named `a,b.mp4` would be delivered as two URIs and the call still
  /// exits 0. `gdbus` takes a GVariant literal instead, which keeps the path
  /// intact; the literal is escaped below for quotes and backslashes.
  Future<bool> _showItems(Uri uri) async {
    final result = await _run('gdbus', [
      'call',
      '--session',
      '--dest',
      'org.freedesktop.FileManager1',
      '--object-path',
      '/org/freedesktop/FileManager1',
      '--method',
      'org.freedesktop.FileManager1.ShowItems',
      '[${_gvariantString(uri.toString())}]',
      "''",
    ]);
    return result.exitCode == 0;
  }

  /// Builds a single-quoted GVariant string. `gdbus` parses these literals
  /// itself, so backslashes are doubled and single quotes escaped.
  static String _gvariantString(String value) =>
      "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

  @override
  Future<void> shutdown() async {
    require(supported, '当前平台不支持下载完成后关机');
    final result = await _run('systemctl', const ['poweroff']);
    require(result.exitCode == 0, '系统未接受关机请求，请检查权限后重试');
  }

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments,
  ) => Process.run(executable, arguments);
}
