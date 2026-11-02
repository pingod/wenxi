import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/providers/aliyun.dart';
import 'package:asterlink/domain/aliyun_share.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';
import 'token_cloud_support.dart';

const fastId = 'QuickTransfer123';
const fastUrl = 'https://www.alipan.com/t/$fastId';

Json fastInfo() => {
  'share_id': fastId,
  'name': '课件.zip 等文件',
  'expiration': '2027-01-01T00:00:00Z',
  // A preview is intentionally not the complete set of transferable files.
  'preview_file_list': [aliFile('source-1', name: '课...件.zip')],
};

Json fastReply(String id, {String? error, bool pending = false}) => {
  'id': id,
  'status': error == null ? 201 : 400,
  'body': error == null
      ? {'file_id': id, if (pending) 'async_task_id': 'task-$id'}
      : {'code': error},
};

Json fastSaved({List<Json>? items}) => {
  'to_drive_id': 'backup',
  'to_parent_file_id': 'target:folder',
  'items': items ?? [fastReply('copy-1'), fastReply('copy-2')],
};

BrowseSession fastSession() => BrowseSession(
  platform: CloudPlatform.aliyun,
  mode: BrowseMode.share,
  rootId: 'root',
  title: '课件.zip 等文件',
  sourceLink: LinkParser.parse(fastUrl).single,
  metadata: const {'shareId': fastId, 'aliyunShareType': 'fastTransfer'},
);

CloudFile fastBundle() => CloudFile(
  id: AliyunShareLink.bundleId(fastId),
  name: '课件.zip 等文件',
  isDirectory: true,
  parentId: 'root',
);

Matcher fastFailure(String message) => throwsA(
  isA<AppException>().having((e) => e.message, 'message', contains(message)),
);

void main() {
  for (final url in [
    fastUrl,
    'https://www.aliyundrive.com/t/$fastId',
    'https://alipan.com/t/$fastId/?from=copy',
    'https://www.alipan.com/#/t/$fastId',
    'www.alipan.com/t/$fastId',
  ]) {
    test('recognizes fast-transfer route $url', () {
      final link = LinkParser.parse('【快传】文件：$url 点击链接保存').single;
      expect(link.platform, CloudPlatform.aliyun);
      expect(link.kind, LinkKind.cloudShare);
      expect(link.shareId, fastId);
      expect(AliyunShareLink.parse(Uri.parse(link.url))!.fastTransfer, isTrue);
      expect(ParsedLink.fromJson(link.toJson()).shareId, fastId);
    });
  }

  test('recognizes the full copied text including a Markdown URL label', () {
    final link = LinkParser.parse(
      '【快传】我给你发了 课...件.zip, 快来看看 [$fastUrl]($fastUrl)\u00a0'
      '点击链接即可保存。「阿里云盘」APP ，无需下载极速在线查看。',
    ).single;
    expect(link.url, fastUrl);
    expect(link.shareId, fastId);
    expect(link.kind, LinkKind.cloudShare);
  });

  test('normal shares and fast transfers remain distinct in mixed prose', () {
    final links = LinkParser.parse(
      '$fastUrl\nhttps://www.alipan.com/s/Share123 提取码：a123',
    );
    expect(links.map((l) => l.shareId), [fastId, 'Share123']);
    expect(links.map((l) => l.passcode), [null, 'a123']);
    expect(
      AliyunShareLink.parse(Uri.parse(links.last.url))!.fastTransfer,
      isFalse,
    );
  });

  for (final path in [
    '/t/',
    '/t/Quick-id',
    '/help/t/$fastId',
    '/login?redirect=$fastUrl',
    '/help#/t/$fastId',
  ]) {
    test('does not interpret an invalid route as a fast transfer: $path', () {
      expect(
        LinkParser.shareId(CloudPlatform.aliyun, 'https://www.alipan.com$path'),
        isNull,
      );
    });
  }

  test(
    'opening and listing are anonymous reads and expose one complete bundle',
    () async {
      final vault = await tokenVault(CloudPlatform.aliyun);
      final http = FakeHttp((r) {
        expect(r.uri.path, '/adrive/v1/share/getByAnonymous');
        expect(r.json, {'share_id': fastId});
        expect(r.headers.containsKey('Authorization'), isFalse);
        expect(r.headers.containsKey('X-Share-Token'), isFalse);
        expect(r.headers['X-Canary'], 'client=web,app=adrive,version=v0.0.1');
        expect(JsonHttp.isReadRequest(r.method, r.url), isTrue);
        return jsonResponse(fastInfo());
      });
      final connector = AliyunConnector(http, vault, now: () => tokenClock);
      final session = await connector.openShare(
        LinkParser.parse(fastUrl).single,
        null,
      );
      expect(AliyunShareLink.isFastTransfer(session), isTrue);
      final restored = BrowseSession.fromJson(session.toJson());
      final files = await connector.list(restored, 'root', null);
      expect(files.single.id, fastBundle().id);
      expect(files.single.name, '课件.zip 等文件');
      expect(files.single.isDirectory, isTrue);
      expect(connector.canDownloadFile(session, files.single), isFalse);
      await expectLater(
        connector.list(session, files.single.id, null),
        fastFailure('先转存'),
      );
      await expectLater(
        connector.download(session, files.single, null),
        fastFailure('先转存'),
      );
      await expectLater(
        connector.playback(session, tokenFile, null),
        fastFailure('先转存'),
      );
      expect(http.calls, hasLength(2));
    },
  );

  test(
    'whole transfer uses authenticated fast APIs and checks every saved item',
    () async {
      final vault = await tokenVault(CloudPlatform.aliyun);
      final http = FakeHttp((r) {
        expect(r.headers['Authorization'], 'Bearer $accessToken');
        switch (r.uri.path) {
          case '/adrive/v1/share/getShareToken':
            expect(JsonHttp.isReadRequest(r.method, r.url), isTrue);
            expect(r.json, {'share_id': fastId});
            return jsonResponse({'share_token': 'fast-token'});
          case '/adrive/v1/share/saveFile':
            expect(JsonHttp.isReadRequest(r.method, r.url), isFalse);
            expect(r.headers['X-Share-Token'], 'fast-token');
            expect(r.json, {
              'share_id': fastId,
              'to_drive_id': 'backup',
              'to_parent_file_id': 'target:folder',
            });
            return jsonResponse(
              fastSaved(
                items: [
                  fastReply('copy-1', pending: true),
                  fastReply('copy-2'),
                ],
              ),
            );
          case '/v2/async_task/get':
            expect(r.json['async_task_id'], 'task-copy-1');
            expect(JsonHttp.isReadRequest(r.method, r.url), isTrue);
            return jsonResponse({'state': 'Succeed'});
          default:
            throw StateError('Unexpected endpoint ${r.uri.path}');
        }
      });
      final connector = AliyunConnector(http, vault, now: () => tokenClock);
      await connector.saveShare(
        fastSession(),
        [fastBundle()],
        'aliyun:backup:target%3Afolder',
        vault.credential(CloudPlatform.aliyun)!,
      );
      expect(http.calls, hasLength(3));
    },
  );

  test(
    'fast transfer never silently saves a subset inferred from the preview',
    () async {
      final vault = await tokenVault(CloudPlatform.aliyun), http = FakeHttp();
      await expectLater(
        AliyunConnector(http, vault, now: () => tokenClock).saveShare(
          fastSession(),
          [tokenFile],
          'root',
          vault.credential(CloudPlatform.aliyun)!,
        ),
        fastFailure('整包转存'),
      );
      expect(http.calls, isEmpty);
    },
  );

  for (final response in [
    <String, dynamic>{},
    fastSaved(items: []),
    {...fastSaved(), 'to_parent_file_id': 'wrong-folder'},
    fastSaved(
      items: [
        {'id': '1', 'status': 201, 'body': {}},
      ],
    ),
    fastSaved(items: [fastReply('duplicate'), fastReply('duplicate')]),
    {
      ...fastSaved(),
      'items': [1],
    },
  ]) {
    test(
      'incomplete or mismatched save response cannot be reported as success: $response',
      () async {
        final vault = await tokenVault(CloudPlatform.aliyun);
        final http = FakeHttp(
          (r) => jsonResponse(
            r.uri.path.endsWith('getShareToken')
                ? {'share_token': 'fast-token'}
                : response,
          ),
        );
        await expectLater(
          AliyunConnector(http, vault, now: () => tokenClock).saveShare(
            fastSession(),
            [fastBundle()],
            'aliyun:backup:target%3Afolder',
            vault.credential(CloudPlatform.aliyun)!,
          ),
          fastFailure('目标目录'),
        );
        expect(
          http.calls.where((r) => r.uri.path.endsWith('saveFile')),
          hasLength(1),
        );
      },
    );
  }

  test('a partial quota failure reports partial completion', () async {
    final vault = await tokenVault(CloudPlatform.aliyun);
    final http = FakeHttp(
      (r) => jsonResponse(
        r.uri.path.endsWith('getShareToken')
            ? {'share_token': 'fast-token'}
            : fastSaved(
                items: [
                  fastReply('ok'),
                  fastReply('failed', error: 'QuotaExhausted.Drive'),
                ],
              ),
      ),
    );
    await expectLater(
      AliyunConnector(http, vault, now: () => tokenClock).saveShare(
        fastSession(),
        [fastBundle()],
        'aliyun:backup:target%3Afolder',
        vault.credential(CloudPlatform.aliyun)!,
      ),
      fastFailure('已转存 1 项，另有 1 项未完成：阿里云盘空间不足'),
    );
  });

  test('an ambiguous network failure does not replay saveFile', () async {
    final vault = await tokenVault(CloudPlatform.aliyun);
    final http = FakeHttp((r) {
      if (r.uri.path.endsWith('getShareToken')) {
        return jsonResponse({'share_token': 'fast-token'});
      }
      throw const HttpRequestFailure(
        'lost response',
        kind: 'connectionError',
        retryable: true,
      );
    });
    await expectLater(
      AliyunConnector(
        RetryingJsonHttp(http),
        vault,
        now: () => tokenClock,
      ).saveShare(
        fastSession(),
        [fastBundle()],
        'aliyun:backup:target%3Afolder',
        vault.credential(CloudPlatform.aliyun)!,
      ),
      throwsA(isA<HttpRequestFailure>()),
    );
    expect(
      http.calls.where((r) => r.uri.path.endsWith('saveFile')),
      hasLength(1),
    );
  });

  for (final (code, message) in [
    ('ShareExpired', '已过期'),
    ('ShareNotFound', '已取消'),
    ('SharePunished', '不可访问'),
    ('ShareMaxSaveUserCountExceed', '人数已达上限'),
    ('ShareNoValidFile', '没有可保存'),
    ('ShareTokenExpired', '凭据已失效'),
    ('ShareTokenInvalid', '凭据已失效'),
  ]) {
    test(
      'HTTP 401 $code describes the share failure without renewing the account',
      () async {
        final vault = await tokenVault(CloudPlatform.aliyun);
        final http = FakeHttp((_) => jsonResponse({'code': code}, 401));
        await expectLater(
          AliyunConnector(http, vault, now: () => tokenClock).saveShare(
            fastSession(),
            [fastBundle()],
            'aliyun:backup:target%3Afolder',
            vault.credential(CloudPlatform.aliyun)!,
          ),
          throwsA(
            isA<AliyunApiException>()
                .having((e) => e.message, 'message', contains(message))
                .having(
                  (e) => e,
                  'share error',
                  isNot(isA<AccountLoginRequired>()),
                ),
          ),
        );
        expect(http.calls, hasLength(1));
      },
    );
  }
}
