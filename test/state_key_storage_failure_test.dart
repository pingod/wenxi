import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_key.dart';
import 'package:asterlink/data/state_store.dart';

// Reproduces the macOS startup failure where the plugin's data-protection
// keychain rejects writes with OSStatus -34018 because the app lacks the
// keychain-access-groups entitlement. The plugin reports it as
// `Unexpected security result code` with the status in `details`.
class _DenyingStorage extends FlutterSecureStorage {
  _DenyingStorage(this.failure);
  final PlatformException failure;
  final records = <String, String>{};
  int writes = 0;
  int reads = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads++;
    return records[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes++;
    throw failure;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('state-key-failure-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<String> saveFailure(PlatformException failure) async {
    final storage = _DenyingStorage(failure);
    // These cases exercise the OS-storage backend on every host, including
    // Windows where the file backend is the default.
    final key = LocalStateKey(
      directory,
      storage,
      windowsFiles: false,
      privateBackend: false,
    );
    try {
      await key.save(Uint8List.fromList(CryptoBox.random(32)));
      fail('keychain writes should not silently succeed');
    } on AppException catch (error) {
      expect(storage.writes, greaterThan(0));
      return error.message;
    }
  }

  test('macOS missing entitlement becomes an actionable message', () async {
    final message = await saveFailure(
      PlatformException(
        code: 'Unexpected security result code',
        message: 'A required entitlement is not present.',
        details: -34018,
      ),
    );
    // A bare PlatformException would only render the generic fallback text.
    expect(message, contains('macOS'));
    expect(message, contains('钥匙串'));
    expect(message, contains('原始数据未被修改'));
  });

  test('locked keychain is reported as a lock, not as a missing key', () async {
    final message = await saveFailure(
      PlatformException(code: 'Unexpected security result code', details: -25308),
    );
    expect(message, contains('锁定'));
  });

  test('other storage failures keep the platform code in the message', () async {
    final message = await saveFailure(
      PlatformException(code: 'secure-write-unavailable'),
    );
    expect(message, contains('secure-write-unavailable'));
    expect(message, contains('原始数据未被修改'));
  });

  test('a failed write never touches the persisted state file', () async {
    final storage = _DenyingStorage(
      PlatformException(
        code: 'Unexpected security result code',
        details: -34018,
      ),
    );
    final state = File('${directory.path}/state-v1.enc')
      ..writeAsBytesSync([7, 8, 9]);
    final before = state.readAsBytesSync();
    await expectLater(
      LocalStateKey(
        directory,
        storage,
        windowsFiles: false,
        privateBackend: false,
      ).save(Uint8List.fromList(CryptoBox.random(32))),
      throwsA(isA<AppException>()),
    );
    expect(state.readAsBytesSync(), before);
    expect(
      File('${directory.path}/${LocalStateKey.locationName}').existsSync(),
      isFalse,
      reason: 'the storage pointer must stay untouched after a failed write',
    );
    expect(storage.records, isEmpty);
  });

  test('the shared secure storage uses the login keychain on macOS', () {
    // The data-protection keychain needs an entitlement that ad-hoc and
    // Developer ID builds do not have, so macOS must opt out of it.
    final options = StateStore.secureStorage.mOptions;
    expect(options, isA<MacOsOptions>());
    expect((options as MacOsOptions).usesDataProtectionKeychain, isFalse);
  });

  group('private file backend (Android and macOS default)', () {
    // The login keychain binds an item to the creating code signature, so a
    // rebuilt ad-hoc app cannot read what the previous build wrote and stalls
    // on an unanswerable prompt. Both platforms therefore keep the key in the
    // app's private directory instead.
    test('a fresh key is stored in the private directory, never in OS storage',
        () async {
      final storage = _DenyingStorage(
        PlatformException(
          code: 'Unexpected security result code',
          details: -34018,
        ),
      );
      final localKey = LocalStateKey(
        directory,
        storage,
        windowsFiles: false,
        privateBackend: true,
      );
      final key = Uint8List.fromList(CryptoBox.random(32));
      await localKey.saveFresh(key);

      expect(storage.writes, 0, reason: 'no keychain write may be attempted');

      final location = asJson(
        jsonDecode(
          await File(
            '${directory.path}/${LocalStateKey.locationName}',
          ).readAsString(),
        ),
      );
      expect(location['backend'], LocalStateKey.privateBackend);
      final namespace = location['namespace'] as String;
      for (final copy in ['primary.bin', 'copy.bin']) {
        final file = File(
          '${directory.path}/${LocalStateKey.privateDirectoryName}/'
          '$namespace/$copy',
        );
        expect(file.existsSync(), isTrue);
        expect(file.readAsBytesSync(), key);
      }

      final read = await localKey.read();
      expect(read.keys.single, key);
      expect(read.needsMigration, isFalse);
    });

    test('a keychain-only record is never read on macOS', () async {
      // Reading it would raise the system access prompt, which blocks startup
      // until somebody clicks it, and an ad-hoc rebuild cannot be authorised
      // anyway. The record is reported as unavailable so the startup page can
      // offer the backup and password recovery paths instead.
      final storage = _DenyingStorage(
        PlatformException(code: 'unused', details: 0),
      );
      final key = Uint8List.fromList(CryptoBox.random(32));
      final namespace = 'state_${'0' * 32}';
      storage.records['${LocalStateKey.name}.$namespace'] = base64Encode(key);
      storage.records['${LocalStateKey.name}.$namespace.copy'] =
          base64Encode(key);
      await File('${directory.path}/${LocalStateKey.locationName}')
          .writeAsString(jsonEncode({'namespace': namespace}));

      final localKey = LocalStateKey(
        directory,
        storage,
        windowsFiles: false,
        privateBackend: true,
      );
      final read = await localKey.read();
      expect(read.keys, isEmpty);
      expect(read.unavailable, isTrue);
      expect(
        storage.reads,
        0,
        reason: 'no keychain access prompt may be triggered',
      );

      await localKey.save(key);
      final migrated = await localKey.read();
      expect(migrated.needsMigration, isFalse);
      expect(migrated.keys.single, key);
      expect(storage.writes, 0);
    });
  });
}
