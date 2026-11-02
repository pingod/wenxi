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

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => records[key];

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
    final key = LocalStateKey(directory, storage);
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
}
