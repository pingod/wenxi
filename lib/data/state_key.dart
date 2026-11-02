import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import '../core/crypto_box.dart';
import '../core/json.dart';
import '../diagnostics/app_log.dart';

class StateKeyRead {
  final keys = <Uint8List>[];
  bool unavailable = false, invalid = false;
  String? primary, copy;
  bool needsRepair(Uint8List key) =>
      primary != base64Encode(key) || copy != base64Encode(key);
}

class _KeyLocation {
  const _KeyLocation(this.namespace, {this.native = false});
  final String? namespace;
  final bool native;
  Json toJson() => {
    'namespace': namespace,
    if (native) 'backend': LocalStateKey.nativeBackend,
  };
}

class StateKeyFallback {
  StateKeyFallback._(this.key, this._location);
  final Uint8List key;
  final _KeyLocation _location;
}

/// Only a namespace and a password-encrypted key envelope live beside the state.
/// A second secure record repairs individual records, not a lost OS keystore.
class LocalStateKey {
  LocalStateKey(this.directory, this.storage, {bool? nativeAndroid})
    : nativeAndroid = nativeAndroid ?? Platform.isAndroid;
  final Directory directory;
  final FlutterSecureStorage storage;
  final bool nativeAndroid;
  static const nativeBackend = 'android-keystore-aes-v2';
  static const name = 'asterlink.flutter.state-key.v1';
  static const locationName = 'state-key-location.json';
  static const recoveryName = 'state-key-recovery.json';
  static const sidecars = [
    locationName,
    '$locationName.tmp',
    recoveryName,
    '$recoveryName.tmp',
  ];
  static const options = AndroidOptions(
    resetOnError: false,
    migrateWithBackup: true,
  );
  static const channel = MethodChannel('com.asterlink.app/native');
  static final _namespacePattern = RegExp(r'^state_[a-f0-9]{32}$');

  File localFile(String name) => File(p.join(directory.path, name));

  _KeyLocation _parseLocation(Json location) {
    final value = location['namespace'];
    final backend = location.str('backend');
    require(backend.isEmpty || backend == nativeBackend, '本地密钥存储格式不支持');
    require(
      location.containsKey('namespace') &&
          ((value == null && backend.isEmpty) ||
              (value is String && _namespacePattern.hasMatch(value))),
      '本地密钥位置记录损坏',
    );
    return _KeyLocation(value as String?, native: backend == nativeBackend);
  }

  Future<({_KeyLocation active, _KeyLocation? fallback})> _pointer() async {
    final file = localFile(locationName);
    if (!await file.exists()) {
      return (active: const _KeyLocation(null), fallback: null);
    }
    require(await file.length() <= 1024, '本地密钥位置记录损坏');
    final location = asJson(jsonDecode(await file.readAsString()));
    final active = _parseLocation(location);
    _KeyLocation? fallback;
    if (location['fallback'] is Map) {
      try {
        fallback = _parseLocation(asJson(location['fallback']));
      } on AppException {
        // Optional recovery metadata must not disable a working active store.
      }
    }
    return (active: active, fallback: fallback);
  }

  AndroidOptions _options(String? namespace) => namespace == null
      ? options
      : AndroidOptions(
          resetOnError: false,
          migrateWithBackup: true,
          storageNamespace: namespace,
        );
  String _name(String? namespace) =>
      namespace == null ? name : '$name.$namespace';

  Future<String?> _read(
    String key,
    String? namespace, {
    bool native = false,
    bool copy = false,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        if (native) {
          final bytes = await channel.invokeMethod<Uint8List>('readStateKey', {
            'namespace': namespace,
            'copy': copy,
          });
          return bytes == null ? null : base64Encode(bytes);
        }
        return await storage.read(key: key, aOptions: _options(namespace));
      } on PlatformException catch (error) {
        if (attempt >= 2) {
          _recordFailure(native ? 'native_read' : 'legacy_read', error);
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 100 * (attempt + 1)));
      }
    }
  }

  Future<StateKeyRead> read() async {
    final result = StateKeyRead();
    _KeyLocation location;
    try {
      location = (await _pointer()).active;
    } on FormatException {
      result.invalid = true;
      return result;
    } on AppException {
      result.invalid = true;
      return result;
    }
    return _readLocation(location);
  }

  Future<StateKeyRead> _readLocation(_KeyLocation location) async {
    final result = StateKeyRead();
    final namespace = location.namespace;
    // A pointer to an existing namespace is not a fresh installation, even if
    // every record disappears. Never replace its key with a random one.
    if (location.native && !nativeAndroid) {
      result.unavailable = true;
      return result;
    }
    for (final copy in [false, true]) {
      try {
        final value = await _read(
          '${_name(namespace)}${copy ? '.copy' : ''}',
          namespace,
          native: location.native,
          copy: copy,
        );
        if (copy) {
          result.copy = value;
        } else {
          result.primary = value;
        }
        if (value == null) continue;
        final key = base64Decode(value);
        if (key.length != 32) {
          result.invalid = true;
        } else if (!result.keys.any((k) => listEquals(k, key))) {
          result.keys.add(key);
        }
      } on PlatformException {
        result.unavailable = true;
      } on FormatException {
        result.invalid = true;
      }
    }
    if (namespace != null && result.keys.isEmpty) result.invalid = true;
    return result;
  }

  Future<List<StateKeyFallback>> readFallbacks() async {
    try {
      final location = (await _pointer()).fallback;
      if (location == null) return [];
      final saved = await _readLocation(location);
      return [for (final key in saved.keys) StateKeyFallback._(key, location)];
    } on AppException {
      return [];
    } on FormatException {
      return [];
    }
  }

  /// Only call after this exact key decrypts the newest local snapshot.
  Future<void> useFallback(StateKeyFallback fallback) async {
    final previous = (await _pointer()).active;
    await _writePointer(fallback._location, previous);
    DiagnosticLog.active?.record('state_key.fallback_restored');
  }

  Future<void> _writePointer(_KeyLocation active, _KeyLocation? fallback) =>
      writeAtomic(
        localFile(locationName),
        utf8.encode(
          jsonEncode({
            ...active.toJson(),
            if (fallback != null) 'fallback': fallback.toJson(),
          }),
        ),
      );

  Future<_KeyLocation?> _verifiedPrevious(Uint8List key) async {
    try {
      final pointer = await _pointer();
      // Preserve an independent legacy fallback across subsequent native repairs.
      for (final location in [pointer.fallback, pointer.active]) {
        if (location == null) continue;
        final saved = await _readLocation(location);
        if (saved.keys.any((candidate) => listEquals(candidate, key))) {
          return location;
        }
      }
    } on AppException {
      // A verified password recovery may replace damaged pointer metadata.
    } on FormatException {
      // Leave damaged metadata to the existing archive/rollback mechanism.
    }
    return null;
  }

  static void _recordFailure(String operation, PlatformException error) {
    // Plugin messages may contain values. Keep only known error categories;
    // native details consist solely of exception class names.
    final description = '${error.code} ${error.message} ${error.details}';
    const categories = [
      'KeyPermanentlyInvalidatedException',
      'UserNotAuthenticatedException',
      'UnrecoverableKeyException',
      'KeyStoreException',
      'InvalidKeyException',
      'InvalidAlgorithmParameterException',
      'BadPaddingException',
      'AEADBadTagException',
      'IllegalBlockSizeException',
      'IOException',
      'FileNotFoundException',
      'IllegalStateException',
      'IllegalArgumentException',
    ];
    DiagnosticLog.active?.record(
      'state_key.storage_failed',
      level: 'warning',
      fields: {
        'operation': operation,
        'categories': categories.where(description.contains).toList(),
      },
    );
  }

  Future<void> _write(Uint8List key, String? namespace) async {
    require(key.length == 32, '本地密钥格式错误');
    final value = base64Encode(key);
    for (final suffix in ['', '.copy']) {
      await storage.write(
        key: '${_name(namespace)}$suffix',
        value: value,
        aOptions: _options(namespace),
      );
    }
    if (Platform.isAndroid) {
      require(
        await channel.invokeMethod<bool>('flushStateKeyStorage', {
              'namespace': namespace,
            }) ==
            true,
        '本地密钥未能保存到设备，请检查可用存储空间后重试',
      );
    }
    for (final suffix in ['', '.copy']) {
      require(
        await _read('${_name(namespace)}$suffix', namespace) == value,
        '本地加密密钥保存失败，请检查系统安全存储后重试',
      );
    }
  }

  Future<void> save(Uint8List key) async {
    final location = (await _pointer()).active;
    if (nativeAndroid && location.native) {
      // Repair an existing native store without overwriting its usable record.
      await saveFresh(key);
    } else {
      require(!location.native, '此设备不支持原本的密钥存储');
      await _write(key, location.namespace);
    }
  }

  Future<void> saveForImport(Uint8List key) async {
    if (nativeAndroid) {
      // Import changes account data, not the device key. Do not migrate a
      // healthy existing user's storage merely because they import a backup.
      final saved = await read();
      if (saved.keys.any((candidate) => listEquals(candidate, key))) return;
    }
    await saveFresh(key);
  }

  /// Call only with a key authenticated against local data or a verified backup.
  /// Old storage is left intact; the pointer switches only after durable writes.
  Future<void> saveFresh(Uint8List key) async {
    final namespace =
        'state_${CryptoBox.random(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    require(key.length == 32, '本地密钥格式错误');
    final previous = nativeAndroid ? await _verifiedPrevious(key) : null;
    if (nativeAndroid) {
      try {
        require(
          await channel.invokeMethod<bool>('writeStateKey', {
                'namespace': namespace,
                'value': key,
              }) ==
              true,
          '本地加密密钥保存失败',
        );
        for (final copy in [false, true]) {
          require(
            await _read('', namespace, native: true, copy: copy) ==
                base64Encode(key),
            '本地加密密钥保存校验失败',
          );
        }
      } on PlatformException catch (error) {
        _recordFailure('native_write', error);
        rethrow;
      }
    } else {
      await _write(key, namespace);
    }
    await _writePointer(
      _KeyLocation(namespace, native: nativeAndroid),
      previous,
    );
  }

  Future<bool> canUnlock() => localFile(recoveryName).exists();

  Future<Uint8List> prepareRecovery(Uint8List key, String password) =>
      compute(_wrapKey, (key, password));

  Future<Uint8List> unlock(String password) async {
    final file = localFile(recoveryName);
    require(await file.exists(), '此设备尚未建立密码恢复保护，请选择备份文件恢复');
    require(await file.length() <= 8192, '本地密码恢复文件损坏');
    return compute(_unwrapKey, (await file.readAsBytes(), password));
  }

  Future<void> installRecovery(List<int> bytes) =>
      writeAtomic(localFile(recoveryName), bytes);

  static Future<void> writeAtomic(File file, List<int> bytes) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    require(listEquals(bytes, await temporary.readAsBytes()), '本地文件保存校验失败');
    await temporary.rename(file.path);
  }
}

const _purpose = 'wenxi-local-state-key-v1';

Uint8List _wrapKey((Uint8List, String) input) {
  require(input.$2.length >= 6, '备份密码至少需要 6 位');
  final salt = CryptoBox.random(16);
  final wrappingKey = CryptoBox.derive(input.$2, salt, 210000);
  final plain = Uint8List.fromList(
    utf8.encode(
      jsonEncode({'purpose': _purpose, 'key': base64Encode(input.$1)}),
    ),
  );
  try {
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': _purpose,
          'kdf': 'PBKDF2WithHmacSHA256',
          'salt': base64Encode(salt),
          'iterations': 210000,
          'data': base64Encode(CryptoBox.seal(wrappingKey, plain)),
        }),
      ),
    );
  } finally {
    wrappingKey.fillRange(0, wrappingKey.length, 0);
    plain.fillRange(0, plain.length, 0);
  }
}

Uint8List _unwrapKey((Uint8List, String) input) {
  Uint8List? wrappingKey, plain;
  try {
    final envelope = asJson(jsonDecode(utf8.decode(input.$1)));
    require(envelope.str('format') == _purpose, '恢复文件格式错误');
    wrappingKey = CryptoBox.derive(
      input.$2,
      base64Decode(envelope.str('salt')),
      envelope.integer('iterations'),
      // Legacy local recovery files predate the kdf field and used SHA-1.
      sha1: envelope.str('kdf', 'PBKDF2WithHmacSHA1') == 'PBKDF2WithHmacSHA1',
    );
    plain = CryptoBox.open(wrappingKey, base64Decode(envelope.str('data')));
    final payload = asJson(jsonDecode(utf8.decode(plain)));
    require(payload.str('purpose') == _purpose, '恢复文件格式错误');
    final key = base64Decode(payload.str('key'));
    require(key.length == 32, '恢复密钥格式错误');
    return key;
  } on FormatException {
    throw const AppException('备份密码错误或本地恢复文件已损坏');
  } on AppException {
    throw const AppException('备份密码错误或本地恢复文件已损坏');
  } finally {
    wrappingKey?.fillRange(0, wrappingKey.length, 0);
    plain?.fillRange(0, plain.length, 0);
  }
}
