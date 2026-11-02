import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/remote_control.dart';
import 'package:asterlink/platform/app_update_installer.dart';
import 'package:asterlink/platform/windows_actions.dart';

void main() {
  late Directory directory;
  late AppUpdateInstaller installer;
  final update = RemoteUpdate(
    '1.2.0',
    120,
    Uri.parse('https://example.test/setup.exe'),
    '',
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('aster-update-package-');
    installer = AppUpdateInstaller(
      platform: 'windows',
      desktop: WindowsActions(supported: false),
    );
  });
  tearDown(() => directory.delete(recursive: true));
  Future<DownloadTask> file(String name, List<int> bytes) async {
    final file = File('${directory.path}/$name');
    await file.writeAsBytes(bytes);
    return DownloadTask(
      id: 'update',
      createdAt: 1,
      status: DownloadStatus.completed,
      spec: DownloadSpec(url: 'https://example.test/$name', fileName: name),
      savedPath: file.path,
    );
  }

  test(
    'Windows EXE requires MZ and PE headers before opening an installer',
    () async {
      final bytes = Uint8List(132)
        ..[0] = 0x4d
        ..[1] = 0x5a;
      ByteData.sublistView(bytes).setUint32(0x3c, 128, Endian.little);
      bytes[128] = 0x50;
      bytes[129] = 0x45;
      final valid = await file('setup.exe', bytes);
      expect(await installer.prepare(valid, update), valid.savedPath);
      bytes[128] = 0;
      expect(
        () async => installer.prepare(await file('invalid.exe', bytes), update),
        throwsA(isA<AppException>()),
      );
      expect(
        () async => installer.prepare(
          await file('webpage.exe', '<html>not an installer</html>'.codeUnits),
          update,
        ),
        throwsA(isA<AppException>()),
      );
    },
  );
  test('ZIP update remains an archive and rejects a renamed webpage', () async {
    final zip = await file('app.zip', [0x50, 0x4b, 3, 4]);
    expect(await installer.prepare(zip, update), zip.savedPath);
    expect(
      () async =>
          installer.prepare(await file('page.zip', 'HTML'.codeUnits), update),
      throwsA(isA<AppException>()),
    );
    expect(AppUpdateInstaller.supportsName('app.zip', 'android'), isFalse);
    expect(AppUpdateInstaller.supportsName('app.APK', 'android'), isTrue);
  });
}
