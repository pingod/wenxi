import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/core/operation_progress.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/parser_rules/rule.dart';
import 'package:asterlink/data/parser_rules/engine.dart';
import 'package:asterlink/data/parser_rules/hub.dart';
import 'package:asterlink/data/parser_rules/server.dart';
import 'package:asterlink/data/providers/baidu_public_parser.dart';
import 'package:asterlink/data/state_store.dart';
import 'baidu_public_parser_support.dart';
import 'support.dart';

final _now = DateTime.fromMillisecondsSinceEpoch(1791936000000);
Json _fixture(String name) => asJson(
  jsonDecode(File('test/fixtures/parser_rules/$name.json').readAsStringSync()),
);
Matcher _error(String code) =>
    isA<ParserRuleError>().having((e) => e.code, 'code', code);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ParserRule rule;
  late ParserServerClient client;
  late List<(String, Json?, Map<String, String>)> calls;
  late String capability, jobId;
  late int polls;
  late String scenario;
  late Completer<void> cancelled;
  Json input() => {
    'url': BaiduPublicFixture.url,
    'pwd': 'a1b2',
    'dir': '/',
    'cookie': 'must-not-leave-app',
  };
  Json result(String state) => {
    'id': jobId,
    'siteId': rule.siteId,
    'ruleHash': ParserServerClient.hash(rule),
    'status': state,
    'stage': state == 'running' ? 'queue' : 'done',
    'progress': {'position': 3},
    'pollAfterMs': 1500,
    if (state == 'succeeded') 'list': [BaiduPublicFixture().file()],
    if (state == 'failed')
      'error': {
        'code': 'UPSTREAM_DISABLED',
        'message': 'untrusted server text',
      },
  };
  setUp(() {
    rule = ParserRule.fromJson(_fixture('server-rule'));
    calls = [];
    polls = 0;
    scenario = 'normal';
    capability = '';
    jobId = 'a' * 32;
    cancelled = Completer<void>();
    client = ParserServerClient(
      device: (_) async => 'wenxi_${'d' * 32}',
      pause: (_) => RequestScope.wait(Duration.zero),
      request: (path, {body, headers = const {}}) async {
        calls.add((path, body, headers));
        if (path == '/v1/parser/jobs') {
          capability = body!.str('capability');
          if (scenario == 'retry-create' &&
              calls.where((c) => c.$1 == path).length == 1) {
            throw const HttpRequestFailure(
              'test network loss',
              kind: 'connection',
              retryable: true,
            );
          }
          return result('queued');
        }
        expect(headers['X-Parser-Job-Key'], capability);
        if (path.endsWith('/cancel')) {
          if (!cancelled.isCompleted) cancelled.complete();
          return result('cancelled');
        }
        if (path.endsWith('/download')) {
          return {
            'fs_id': body!['fileId'],
            'name': BaiduPublicFixture.name,
            'size': 4,
            'urls': [
              scenario == 'bad-url'
                  ? 'https://evil.example/download'
                  : 'https://d.pcs.baidu.com/file/example',
            ],
            'ua': 'netdisk',
          };
        }
        polls++;
        if (scenario == 'running') return result('running');
        if (scenario == 'closed') return result('failed');
        if (scenario == 'expired') return result('expired');
        if (scenario == 'mismatch') {
          return {...result('succeeded'), 'id': 'b' * 32};
        }
        return result(polls == 1 ? 'running' : 'succeeded');
      },
    );
  });

  test(
    'Engine v2 verifies signed descriptors and cannot run a server rule locally',
    () async {
      final bundle = ParserBundle.verify(
        _fixture('bundle-server'),
        File('test/fixtures/parser_rules/public-key.txt').readAsStringSync(),
        now: _now,
      );
      expect(bundle.sites.single.rule.runsOnServer, isTrue);
      expect(bundle.sites.single.rule.requiresPassword, isFalse);
      expect(
        () => ParserRule.fromJson({...rule.json, 'operations': {}}),
        throwsA(_error('INVALID_RULE')),
      );
      await expectLater(
        ParserRuleEngine(
          FakeHttp((_) => throw StateError('unexpected HTTP')),
        ).execute(rule, 'list', input(), password: '', device: 'unused'),
        throwsA(_error('SERVER_EXECUTION_REQUIRED')),
      );
    },
  );
  test(
    'Server parsing polls progress, excludes account credentials and reuses its ticket',
    () async {
      final progress = OperationProgress();
      final positions = <int?>[];
      progress.addListener(
        () => positions.add(progress.value.lastOrNull?.queuePosition),
      );
      final listed = await progress.run(
        () => client.execute(rule, 1, 'list', input()),
      );
      expect(positions, contains(3));
      expect(
        listed.list('list').single.str('server_filename'),
        BaiduPublicFixture.name,
      );
      final create = calls.firstWhere((c) => c.$1 == '/v1/parser/jobs');
      expect(create.$2!.obj('input').keys.toSet(), {'url', 'pwd'});
      expect(jsonEncode(create.$2), isNot(contains('must-not-leave-app')));
      await client.execute(rule, 1, 'list', {
        ...input(),
        'state': listed['state'],
      });
      final download = await client.execute(rule, 1, 'download', {
        ...input(),
        'state': listed['state'],
        'file': BaiduPublicFixture().file(),
      });
      expect(download['urls'], ['https://d.pcs.baidu.com/file/example']);
      expect(calls.where((c) => c.$1 == '/v1/parser/jobs'), hasLength(1));
      expect(calls.where((c) => c.$1.contains('password')), isEmpty);
      progress.dispose();
    },
  );
  test(
    'Lost creation response retries the same idempotency key and capability',
    () async {
      scenario = 'retry-create';
      await client.execute(rule, 1, 'list', input());
      final creates = calls.where((c) => c.$1 == '/v1/parser/jobs').toList();
      expect(creates, hasLength(2));
      expect(
        creates[0].$3['Idempotency-Key'],
        creates[1].$3['Idempotency-Key'],
      );
      expect(creates[0].$2, creates[1].$2);
    },
  );
  test(
    'Closed upstream is reported without displaying arbitrary server text',
    () async {
      scenario = 'closed';
      await expectLater(
        client.execute(rule, 1, 'list', input()),
        throwsA(_error('UPSTREAM_DISABLED')),
      );
      await cancelled.future;
      expect(
        ParserServerClient.message('UPSTREAM_DISABLED'),
        contains('原站未开放此业务或当前出口无权限'),
      );
    },
  );
  test('A mismatched job cannot supply files', () async {
    scenario = 'mismatch';
    await expectLater(
      client.execute(rule, 1, 'list', input()),
      throwsA(_error('RULE_FILE_MISMATCH')),
    );
    await cancelled.future;
  });
  test(
    'Expired stored results require reparse without creating another conversion',
    () async {
      final listed = await client.execute(rule, 1, 'list', input());
      scenario = 'expired';
      await expectLater(
        client.execute(rule, 1, 'list', {...input(), 'state': listed['state']}),
        throwsA(_error('JOB_EXPIRED')),
      );
      expect(calls.where((c) => c.$1 == '/v1/parser/jobs'), hasLength(1));
    },
  );
  test('Client cancellation cancels only its own job while polling', () async {
    scenario = 'running';
    final scope = RequestScope();
    final progress = OperationProgress();
    progress.addListener(() {
      if (progress.value.any((s) => s.queuePosition == 3)) scope.cancel();
    });
    await expectLater(
      scope.run(
        () => progress.run(() => client.execute(rule, 1, 'list', input())),
      ),
      throwsA(isA<AppException>()),
    );
    await cancelled.future;
    expect(
      calls
          .where((c) => c.$1.endsWith('/cancel'))
          .single
          .$3['X-Parser-Job-Key'],
      capability,
    );
    progress.dispose();
  });
  test(
    'Cancellation while create is in flight still releases the eventual job',
    () async {
      final created = Completer<Json>(), release = Completer<void>();
      final scope = RequestScope();
      final slow = ParserServerClient(
        device: (_) async => 'wenxi_${'d' * 32}',
        request: (path, {body, headers = const {}}) async {
          if (path.endsWith('/cancel')) {
            release.complete();
            return result('cancelled');
          }
          return created.future;
        },
      );
      final task = scope.run(() => slow.execute(rule, 1, 'list', input()));
      await Future<void>.delayed(Duration.zero);
      scope.cancel();
      await expectLater(task, throwsA(isA<AppException>()));
      created.complete(result('queued'));
      await release.future;
    },
  );
  test(
    'Returned download URL must stay in the signed rule allowlist',
    () async {
      final listed = await client.execute(rule, 1, 'list', input());
      scenario = 'bad-url';
      await expectLater(
        client.execute(rule, 1, 'download', {
          ...input(),
          'state': listed['state'],
          'file': BaiduPublicFixture().file(),
        }),
        throwsA(_error('RULE_DOWNLOAD_URL')),
      );
    },
  );

  test(
    'Baidu provider reaches server channel without shared-password or upstream requests',
    () async {
      final dir = await Directory.systemTemp.createTemp('parser-server-test-');
      final store = StateStore.memory();
      final ruleHash = ParserServerClient.hash(rule);
      final transport = FakeHttp((r) {
        expect(r.uri.host, 'hub.example.com');
        expect(r.headers['X-Parser-Engine'], '${ParserRule.engine}');
        expect(r.headers['Authorization'], 'Bearer test-key');
        Json data;
        if (r.uri.path == '/v1/rules') {
          data = _fixture('bundle-server');
        } else if (r.uri.path == '/v1/parser/jobs' ||
            r.uri.path == '/v1/parser/jobs/$jobId') {
          data = {
            'id': jobId,
            'siteId': rule.siteId,
            'ruleHash': ruleHash,
            'status': 'succeeded',
            'stage': 'done',
            'list': [BaiduPublicFixture().file()],
          };
        } else if (r.uri.path.endsWith('/download')) {
          data = {
            'fs_id': BaiduPublicFixture.fileId,
            'name': BaiduPublicFixture.name,
            'ua': 'netdisk',
            'urls': ['https://d.pcs.baidu.com/file/test'],
          };
        } else {
          throw StateError('Unexpected hub request ${r.uri.path}');
        }
        return jsonResponse({'ok': true, 'data': data});
      });
      final hub = ParserRuleHub(
        store: Vault(store),
        directory: dir,
        http: transport,
        url: 'https://hub.example.com',
        apiKey: 'test-key',
        publicKey: File(
          'test/fixtures/parser_rules/public-key.txt',
        ).readAsStringSync(),
        clock: () => _now,
      );
      try {
        await hub.refresh(force: true);
        await hub.select(rule.siteId);
        final provider = BaiduPublicParser(
          transport,
          store: Vault(store),
          hub: hub,
        );
        final session = await provider.openShare(BaiduPublicFixture().link);
        final files = await provider.list(session, '/');
        await provider.list(session, '/');
        final spec = await provider.download(session, files.single);
        expect(spec.url, 'https://d.pcs.baidu.com/file/test');
        expect(
          transport.calls.where((r) => r.uri.path == '/v1/parser/jobs'),
          hasLength(1),
        );
        expect(
          transport.calls.where((r) => r.uri.path.contains('password')),
          isEmpty,
        );
      } finally {
        await hub.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
