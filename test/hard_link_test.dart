import 'dart:io';

import 'package:asterlink/platform/hard_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('aster-link-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('publishing a payload adds a second name for the same bytes', () async {
    final source = File(p.join(root.path, 'payload.gopeed'));
    await source.writeAsString('payload bytes');
    final target = p.join(root.path, 'video.mp4');

    linkPublishedFile(source.path, target);

    expect(await File(target).readAsString(), 'payload bytes');
    // A hard link survives deleting the cache name, which is what publishing
    // relies on: the export is complete before the payload is removed.
    await source.delete();
    expect(await File(target).readAsString(), 'payload bytes');
  });

  test('an existing export name is reported instead of overwritten', () async {
    final source = File(p.join(root.path, 'payload.gopeed'));
    await source.writeAsString('payload bytes');
    final target = File(p.join(root.path, 'video.mp4'))
      ..writeAsStringSync('older export');

    expect(
      () => linkPublishedFile(source.path, target.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(await target.readAsString(), 'older export');
  });

  test('one directory can hold both the cache and the destination', () async {
    final source = File(p.join(root.path, 'payload.gopeed'));
    await source.writeAsString('payload bytes');

    expect(
      hardLinkableAcross(root.path, root.path),
      isTrue,
      reason: 'A single directory is one filesystem that links.',
    );
    expect(
      await File(p.join(root.path, 'payload.gopeed')).readAsString(),
      'payload bytes',
      reason: 'Probing must not consume or rename the payload.',
    );
    expect(
      (await root.list().toList())
          .map((entity) => p.basename(entity.path))
          .where((name) => name.startsWith('.asterlink-link-probe-')),
      isEmpty,
      reason: 'Probe files are cleaned up.',
    );
  });
}
