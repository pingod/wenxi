import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_command_resolver.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/baidu_public_password.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StateStore state;
  late Vault vault;
  late FakeHttp http;
  late CleanupOutbox outbox;
  late BaiduPublicPasswords passwords;
  late DateTime now;
  late int transferred, deleted, legacyFetched;
  late bool failDownload;
  late String expectedCommand;
  Future<void> Function()? beforePrefix;
  const cookie = '__pus=private-uc-account; __puus=private-uc-session';
  const value = '没有固定长度的中文密码';
  HttpResult ok(Object data) =>
      jsonResponse({'status': 200, 'code': 0, 'data': data});

  setUp(() {
    now = DateTime.now();
    transferred = deleted = legacyFetched = 0;
    failDownload = false;
    expectedCommand = '執每日更新铁观音生效';
    beforePrefix = null;
    state = StateStore.memory({
      'credentials': {
        CloudPlatform.uc.key: Credential('UC fixture', {
          'primary': cookie,
          'ucSessionRefreshedAt': '${DateTime.now().millisecondsSinceEpoch}',
        }, updatedAt: 1).toJson(),
      },
    });
    vault = Vault(state);
    http = FakeHttp((r) async {
      if (r.uri.host == 'www.yuque.com') {
        expect(r.headers.toString(), isNot(contains('private-uc')));
        return const HttpResult(
          200,
          '<article><pre><code>執每日更新铁观音生效</code></pre></article>',
        );
      }
      if (r.uri.host == 'utoken2.uc.cn') {
        expect(r.headers.toString(), isNot(contains('private-uc')));
        expect(r.json['clipboard'], expectedCommand);
        return jsonResponse({
          'success': true,
          'code': 'OK',
          'data': {'androidUrl': 'https://drive.uc.cn/s/authenticatedfixture'},
        });
      }
      expect(r.uri.host, endsWith('.uc.cn'));
      expect(r.headers['Cookie'], cookie);
      if (r.uri.path.endsWith('/share/sharepage/token')) {
        return ok({'stoken': 'share-token', 'first_fid': '0'});
      }
      if (r.uri.path.endsWith('/transfer_share/detail')) {
        return ok({
          'list': [
            {
              'fid': 'source-text',
              'file_name': '每天更新.txt.zip',
              'size': 10000,
              'share_fid_token': 'file-token',
            },
          ],
        });
      }
      if (r.uri.path.endsWith('/file/sort')) {
        return ok({
          'list': [
            {'fid': 'existing-parent', 'file_name': '文析助手临时转存', 'dir': true},
          ],
        });
      }
      if (r.uri.path.endsWith('/file') && r.method == 'POST') {
        expect(r.json['pdir_fid'], 'existing-parent');
        expect(r.json.str('file_name'), startsWith('tr_'));
        return ok({'fid': 'only-this-operation'});
      }
      if (r.uri.path.endsWith('/share/sharepage/save')) {
        expect(r.json['fid_list'], ['source-text']);
        expect(r.json['to_pdir_fid'], 'only-this-operation');
        expect(outbox.pendingCount, 1);
        await outbox.reconcile(recoverOrphans: true);
        await outbox.drain();
        expect(deleted, transferred); // The in-flight directory is protected.
        transferred++;
        return ok({'task_id': 'transfer-task'});
      }
      if (r.uri.path.endsWith('/task')) {
        return ok({
          'status': 2,
          'save_as': {
            'save_as_top_fids': ['saved-text'],
          },
        });
      }
      if (r.uri.path.endsWith('/file/download')) {
        expect(r.json['fids'], ['saved-text']);
        expect(r.json.containsKey('pwd_id'), false);
        if (failDownload) {
          return const HttpResult(503, 'temporarily unavailable');
        }
        return ok([
          {
            'fid': 'saved-text',
            'size': 10000,
            'download_url': 'https://dl.uc.cn/authenticated-prefix',
          },
        ]);
      }
      if (r.uri.path == '/authenticated-prefix') {
        expect(r.headers['Range'], 'bytes=0-4095');
        await beforePrefix?.call();
        return const HttpResult(206, '====没有固定长度的中文密码====\n第二行不会成为密码', {
          'content-type': ['text/plain'],
          'content-range': ['bytes 0-4095/10000'],
        });
      }
      if (r.uri.path.endsWith('/file/delete')) {
        expect(r.json['filelist'], ['only-this-operation']);
        deleted++;
        return ok({});
      }
      throw StateError('Unexpected route ${r.uri.path}');
    });
    outbox = CleanupOutbox(state, http);
    passwords = BaiduPublicPasswords(
      http,
      store: vault,
      cleanups: outbox,
      clock: () => now,
      commandKeys: CloudCommandKeys(uc: 'B' * 24),
      fetch: () async {
        legacyFetched++;
        return '旧游客密码';
      },
      fetchBackup: () async {
        legacyFetched++;
        return '旧备用密码';
      },
    );
  });
  tearDown(() async {
    await passwords.close();
    await outbox.drain();
  });

  test(
    'Web command uses current UC account without reading the old source or cache',
    () async {
      expectedCommand = '网页提供的新口令';
      expect(await passwords.fromUcCommand(expectedCommand), value);
      await outbox.drain();
      expect(transferred, 1);
      expect(deleted, 1);
      expect(http.calls.where((r) => r.uri.host == 'www.yuque.com'), isEmpty);
      expect(legacyFetched, 0);
      expectedCommand = '网页再次更新口令';
      expect(await passwords.fromUcCommand(expectedCommand), value);
      await outbox.drain();
      expect(transferred, 2);
      expect(deleted, 2);
    },
  );

  test(
    'Web command logout cancels the result and cleans its transfer',
    () async {
      beforePrefix = () => vault.removeCredential(CloudPlatform.uc);
      await expectLater(
        passwords.fromUcCommand(expectedCommand),
        throwsA(isA<AppException>()),
      );
      await outbox.drain();
      expect(deleted, 1);
      expect(outbox.pendingCount, 0);
    },
  );

  test(
    'Cancelling a web command releases only its own temporary transfer',
    () async {
      final scope = RequestScope(),
          started = Completer<void>(),
          never = Completer<void>();
      beforePrefix = () async {
        started.complete();
        await RequestScope.cancellable(never.future);
      };
      final work = scope.run(() => passwords.fromUcCommand(expectedCommand));
      final failure = expectLater(work, throwsA(isA<AppException>()));
      await started.future;
      scope.cancel();
      await failure;
      await Future<void>.delayed(Duration.zero);
      await outbox.drain();
      expect(deleted, 1);
      expect(outbox.pendingCount, 0);
    },
  );

  test(
    'authenticated UC transfers the selected file, reads a bounded prefix and cleans only its own folder',
    () async {
      final fetched = await passwords.authenticated().catchError((
        Object error,
      ) {
        throw StateError(
          'Failed after ${http.calls.map((r) => r.uri.host + r.uri.path).join(', ')}',
        );
      });
      expect(fetched.value, value);
      await outbox.drain();
      expect(transferred, 1);
      expect(deleted, 1);
      expect(outbox.pendingCount, 0);
      expect(legacyFetched, 0);
      expect((await passwords.authenticated()).value, value);
      expect(transferred, 1);
      now = now.add(const Duration(days: 1));
      expect((await passwords.authenticated()).value, value);
      await outbox.drain();
      expect(transferred, 2);
      expect(deleted, 2);
    },
  );

  test(
    'missing UC login never starts guest, Yuque or Gitee requests even with a legacy password cache',
    () async {
      await passwords.get();
      legacyFetched = 0;
      await vault.removeCredential(CloudPlatform.uc);
      await passwords.prefetch(authenticatedOnly: true);
      await expectLater(
        passwords.authenticated(),
        throwsA(isA<AppException>()),
      );
      expect(http.calls, isEmpty);
      expect(legacyFetched, 0);
    },
  );

  test(
    'a transfer download failure cleans its folder and cannot fall back to a guest password',
    () async {
      failDownload = true;
      await expectLater(
        passwords.authenticated(),
        throwsA(isA<AppException>()),
      );
      await outbox.drain();
      expect(transferred, 1);
      expect(deleted, greaterThanOrEqualTo(1));
      expect(outbox.pendingCount, 0);
      expect(legacyFetched, 0);
    },
  );

  test(
    'logout during reading never caches or returns the fetched password',
    () async {
      beforePrefix = () => vault.removeCredential(CloudPlatform.uc);
      await expectLater(
        passwords.authenticated(),
        throwsA(isA<AppException>()),
      );
      await outbox.drain();
      expect(deleted, 1);
      expect(
        state.data
            .obj('secrets')
            .keys
            .any((key) => key.startsWith('publicParser.mfDg22.ucPassword.')),
        false,
      );
    },
  );

  test(
    'closing while reading releases cleanup without waiting for the prefix timeout',
    () async {
      final started = Completer<void>(), never = Completer<void>();
      beforePrefix = () async {
        started.complete();
        await RequestScope.cancellable(never.future);
      };
      final work = passwords.authenticated();
      final failed = expectLater(work, throwsA(isA<AppException>()));
      await started.future;
      await passwords.close();
      await failed;
      await outbox.drain();
      expect(deleted, 1);
      expect(outbox.pendingCount, 0);
    },
  );
}
