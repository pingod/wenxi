import 'dart:convert';
import 'package:crypto/crypto.dart' as hashes;
import 'package:pointycastle/export.dart';
import '../../core/json.dart';
import '../../core/login_crypto.dart';
import 'package.dart';

class SourceRelease {
  const SourceRelease._(
    this.package,
    this.version,
    this.hash,
    this.proof,
    this.catalogId,
  );
  final SourcePackage package;
  final int version;
  final String hash;
  final Json proof;
  final String catalogId;
}

class SourceCatalog {
  SourceCatalog._(this.revision, this.releases, this.envelope, this.expiresAt);
  final int revision;
  final List<SourceRelease> releases;
  final Json envelope;
  final DateTime expiresAt;
  static SourceCatalog verify(
    Json envelope,
    String publicKey,
    DateTime now, {
    bool archived = false,
  }) {
    try {
      if (envelope.str('algorithm') != 'RSA-SHA256' ||
          envelope.str('payload').length > 6000000 ||
          envelope.str('signature').length > 1024) {
        throw const FormatException();
      }
      final bytes = base64Decode(envelope.str('payload'));
      final pem = utf8.decode(base64Decode(publicKey));
      final signer = Signer('SHA-256/RSA')
        ..init(false, PublicKeyParameter<RSAPublicKey>(LoginRsa(pem).key));
      if (!signer.verifySignature(
        bytes,
        RSASignature(base64Decode(envelope.str('signature'))),
      )) {
        throw const FormatException();
      }
      final doc = asJson(jsonDecode(utf8.decode(bytes)));
      final issued = doc.integer('issuedAt'),
          expires = doc.integer('expiresAt'),
          seconds = now.millisecondsSinceEpoch ~/ 1000;
      if (doc['schema'] != 1 ||
          doc['purpose'] != 'asterlink-sources' ||
          doc['revision'] is! int ||
          doc.integer('revision') < 1 ||
          doc['issuedAt'] is! int ||
          doc['expiresAt'] is! int ||
          expires <= issued ||
          expires - issued > 7 * 86400 ||
          (!archived && (issued > seconds + 300 || expires < seconds)) ||
          doc['packages'] is! List ||
          (doc['packages'] as List).length > 64) {
        throw const FormatException();
      }
      final records = <SourceRelease>[], seen = <String>{};
      final catalogId = hashes.sha256.convert(bytes).toString();
      for (final raw in doc['packages'] as List) {
        if (raw is! Map) throw const FormatException();
        final item = asJson(raw);
        final payload = base64Decode(item.str('payload'));
        if (payload.length > SourcePackage.maxBytes) {
          throw const FormatException();
        }
        final hash = hashes.sha256.convert(payload).toString();
        final source = SourcePackage.fromJson(
          asJson(jsonDecode(utf8.decode(payload))),
        );
        if (item.str('id') != source.id ||
            item.str('hash') != hash ||
            item['version'] is! int ||
            item.integer('version') < 1 ||
            !seen.add(source.id)) {
          throw const FormatException();
        }
        records.add(
          SourceRelease._(
            source,
            item.integer('version'),
            hash,
            envelope,
            catalogId,
          ),
        );
      }
      return SourceCatalog._(
        doc.integer('revision'),
        List.unmodifiable(records),
        envelope,
        DateTime.fromMillisecondsSinceEpoch(expires * 1000),
      );
    } catch (_) {
      throw const SourceError('SOURCE_SIGNATURE', '来源接入包签名校验失败，保留上次可用配置');
    }
  }
}
