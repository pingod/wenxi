import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/providers/guangya.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';
import 'token_cloud_support.dart';

const _platform = CloudPlatform.guangya;
const _ownerParent = 'owner-private-folder';
const _sharedParent = 'shared-folder';
const _hash = '0123456789abcdef0123456789abcdef';
const _source = CloudFile(
  id: 'shared-file',
  name: 'archive.zip',
  size: 37472036,
  parentId: _ownerParent,
  hashType: 'md5',
  hashValue: _hash,
);
const _item = <String, dynamic>{
  'fileId': 'shared-file',
  'fileName': 'archive.zip',
  'fileSize': 37472036,
  'parentId': _ownerParent,
  'resType': 1,
  'md5': _hash,
};

class _Fixture {
  _Fixture(this.vault, this.http)
    : repository = CloudRepository(
        http,
        vault,
        CleanupOutbox(vault.store, http),
      );

  final Vault vault;
  final FakeHttp http;
  final CloudRepository repository;

  static Future<_Fixture> create({
    List<Json> rootFiles = const [_item],
    int unavailableCode = 143,
  }) async {
    final vault = await tokenVault(
      _platform,
      tokenCredential(_platform, fields: {'expiresAt': '4102444800000'}),
    );
    final http = FakeHttp((request) {
      switch (request.uri.path) {
        case '/userres/v1/get_share_summary':
          return guangyaResponse({'title': '共享文件'});
        case '/userres/v1/get_share_access_token':
          return guangyaResponse({'accessToken': 'share-access'});
        case '/userres/v1/get_share_page_files_list':
          final parent = request.json.str('parentId');
          if (parent == _ownerParent) {
            return guangyaResponse({}, code: unavailableCode, message: '文件不存在');
          }
          expect(parent, anyOf('', _sharedParent));
          return guangyaResponse({
            'list': parent.isEmpty ? rootFiles : [_item],
            'total': parent.isEmpty ? rootFiles.length : 1,
            'cursor': 100,
          });
        case '/userres/v1/get_share_download_url':
          expect(request.json['fileId'], _source.id);
          expect(request.headers['Authorization'], 'Bearer $accessToken');
          return guangyaResponse({
            'signedURL': 'https://download.example/archive.zip?sign=fixture',
          });
        case '/userres/v1/file/get_file_list':
          return guangyaResponse({}, code: 143, message: '文件不存在');
        default:
          throw StateError('Unexpected endpoint ${request.uri.path}');
      }
    });
    return _Fixture(vault, http);
  }

  List<String> get shareParents => http.calls
      .where(
        (request) => request.uri.path.endsWith('get_share_page_files_list'),
      )
      .map((request) => request.json.str('parentId'))
      .toList();

  bool get requestedDownload => http.calls.any(
    (request) => request.uri.path.endsWith('get_share_download_url'),
  );

  DownloadSpec legacyPlan({bool personal = false}) => DownloadSpec(
    url: '',
    fileName: _source.name,
    expectedSize: _source.size,
    source: DownloadOrigin(
      personal ? tokenPersonal(_platform) : tokenShare(_platform),
      _source,
      vault.credential(_platform)!.updatedAt,
    ).toJson(),
  );
}

void main() {
  for (final parent in ['root', _sharedParent]) {
    test(
      'Guangya queued share download retains its visible parent: $parent',
      () async {
        final fixture = await _Fixture.create();
        final repository = fixture.repository;
        final share = await repository.share(tokenShare(_platform).sourceLink!);
        final files = await repository.list(share, parent);
        expect(files.single.parentId, parent);

        final planned = repository.planDownload(share, files.single);
        final prepared = await repository.refresh(planned);
        final origin = DownloadOrigin.fromJson(prepared.source!);
        expect(
          prepared.url,
          'https://download.example/archive.zip?sign=fixture',
        );
        expect(origin.file.parentId, parent);
        expect(origin.file.hashValue, _hash);
        expect(fixture.shareParents, [
          parent == 'root' ? '' : parent,
          parent == 'root' ? '' : parent,
        ]);
        expect(fixture.requestedDownload, isTrue);
      },
    );
  }

  test('Guangya retries an old root task with its exact shared file', () async {
    final fixture = await _Fixture.create();
    final result = await fixture.repository.refresh(fixture.legacyPlan());
    final origin = DownloadOrigin.fromJson(result.source!);
    expect(fixture.shareParents, [_ownerParent, '']);
    expect(origin.file.id, _source.id);
    expect(origin.file.parentId, 'root');
    expect(origin.file.hashValue, _hash);
    expect(result.cleanup, isNull);
    expect(fixture.requestedDownload, isTrue);
  });

  for (final scenario in [
    'missing',
    'same-name',
    'size-changed',
    'hash-changed',
  ]) {
    test(
      'Guangya old-task recovery rejects a different source: $scenario',
      () async {
        final fixture = await _Fixture.create(
          rootFiles: [
            if (scenario != 'missing')
              {
                ..._item,
                if (scenario == 'same-name') 'fileId': 'different-file',
                if (scenario == 'size-changed') 'fileSize': _source.size + 1,
                if (scenario == 'hash-changed')
                  'md5': 'abcdef0123456789abcdef0123456789',
              },
          ],
        );
        await expectLater(
          fixture.repository.refresh(fixture.legacyPlan()),
          throwsA(isA<AppException>()),
        );
        expect(fixture.shareParents, [_ownerParent, '']);
        expect(fixture.requestedDownload, isFalse);
      },
    );
  }

  test('Guangya does not retry other share errors through the root', () async {
    final fixture = await _Fixture.create(unavailableCode: 209);
    await expectLater(
      fixture.repository.refresh(fixture.legacyPlan()),
      throwsA(
        isA<GuangyaApiException>().having((error) => error.code, 'code', '209'),
      ),
    );
    expect(fixture.shareParents, [_ownerParent]);
    expect(fixture.requestedDownload, isFalse);
  });

  test('Guangya personal file errors never recover through a share', () async {
    final fixture = await _Fixture.create();
    await expectLater(
      fixture.repository.refresh(fixture.legacyPlan(personal: true)),
      throwsA(
        isA<GuangyaApiException>().having((error) => error.code, 'code', '143'),
      ),
    );
    expect(fixture.shareParents, isEmpty);
    expect(fixture.requestedDownload, isFalse);
  });
}
