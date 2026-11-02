import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'windows_storage.dart';

/// `linkat(2)`: Dart exposes symlinks but no hard links, so the POSIX publish
/// path calls libc directly while Windows keeps `CreateHardLinkW`.
///
/// `link(2)` is not usable through FFI here: on macOS the symbol resolves to a
/// compatibility stub that fails with ENOENT, while `linkat` with AT_FDCWD links
/// the very same paths. AT_FDCWD itself differs per platform, so it is passed in
/// instead of being read from a header.
typedef _LinkNative =
    Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>, Int32);
typedef _LinkDart =
    int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int);

final _LinkDart _linkAt =
    (Platform.isMacOS
            ? DynamicLibrary.open('/usr/lib/libSystem.B.dylib')
            : DynamicLibrary.process())
        .lookupFunction<_LinkNative, _LinkDart>('linkat');

/// `AT_FDCWD` is -2 on Apple platforms and -100 in the Linux kernel ABI.
final _atFdcwd = Platform.isMacOS || Platform.isIOS ? -2 : -100;

const _publishFailure = '无法发布下载文件，缓存已保留，请检查目录权限后重试';

/// Publishes [source] as [target] on one filesystem without allocating a second
/// copy of the bytes.
///
/// Both platforms throw a [FileSystemException] when [target] already exists or
/// the two paths are on different filesystems, which is what the publish loop
/// retries on.
void linkPublishedFile(String source, String target) {
  if (Platform.isWindows) {
    WindowsStorage.createHardLink(source, target);
    return;
  }
  final existing = source.toNativeUtf8();
  final output = target.toNativeUtf8();
  try {
    if (_linkAt(_atFdcwd, existing, _atFdcwd, output, 0) != 0) {
      throw FileSystemException(_publishFailure, target);
    }
  } finally {
    calloc.free(existing);
    calloc.free(output);
  }
}

/// Whether a finished payload in [from] can be published into [to] with a hard
/// link instead of a full copy.
///
/// Both directories must share one filesystem that links. Windows answers with
/// its kernel volume query, which needs no writes; elsewhere the only portable
/// answer is a probe, because Dart exposes no device id and a destination can be
/// a network share or an exFAT volume that reports the same root as the cache.
bool hardLinkableAcross(String from, String to) {
  if (Platform.isWindows) {
    final source = WindowsStorage.volume(from);
    final target = WindowsStorage.volume(to);
    return source != null &&
        target != null &&
        source.id == target.id &&
        source.supportsHardLinks &&
        target.supportsHardLinks;
  }
  final name = '.asterlink-link-probe-$pid';
  final source = File(p.join(from, name));
  // The link needs its own name: cache and destination are often one directory,
  // where linking to the source name would only report EEXIST.
  final linked = File(p.join(to, '$name-link'));
  try {
    source.createSync();
    linkPublishedFile(source.path, linked.path);
    return true;
  } on FileSystemException {
    return false;
  } finally {
    for (final file in [linked, source]) {
      try {
        if (file.existsSync()) file.deleteSync();
      } on FileSystemException {
        // A leftover probe file must never fail a download.
      }
    }
  }
}
