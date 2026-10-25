import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/github.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/github.dart';
import 'package:asterlink/domain/github_acceleration.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'support.dart';

const _token = 'github_pat_fixture01234567890123456789';
const _root = GitHubLocation(
  kind: GitHubNodeKind.code,
  owner: 'sample',
  repo: 'files',
  ref: 'main',
  writable: true,
);
final _release = _root.copy(
  kind: GitHubNodeKind.release,
  releaseId: '12',
  ref: 'v1',
  branch: false,
);
Credential _credential() => Credential('GitHub', {
  'primary': _token,
  'username': 'sample',
  'userId': '123',
}, updatedAt: 10);
BrowseSession _session([GitHubLocation n = _root]) => BrowseSession(
  platform: CloudPlatform.github,
  mode: BrowseMode.personal,
  title: 'GitHub',
  rootId: n.id,
  metadata: const {'githubAuthenticated': 'true'},
);
Json _repo({bool push = true, bool private = false, bool archived = false}) => {
  'name': 'files',
  'full_name': 'sample/files',
  'owner': {'login': 'sample'},
  'default_branch': 'main',
  'permissions': {'push': push},
  'size': 1,
  'private': private,
  'archived': archived,
};
Json _treeRow(
  String name, {
  String sha = 'blob-old',
  String type = 'blob',
  String mode = '100644',
}) => {'path': name, 'sha': sha, 'type': type, 'mode': mode, 'size': 5};
CloudFile _file(
  String name, {
  String sha = 'blob-old',
  String mode = '100644',
  bool directory = false,
}) => CloudFile(
  id: _root
      .copy(
        kind: directory ? GitHubNodeKind.code : GitHubNodeKind.file,
        path: name,
      )
      .id,
  name: name.split('/').last,
  size: directory ? 0 : 5,
  isDirectory: directory,
  parentId: _root.id,
  token: jsonEncode({
    'sha': sha,
    'type': directory ? 'tree' : 'blob',
    'mode': mode,
  }),
);
Json _assetJson({String name = 'app.apk', int id = 45}) => {
  'id': id,
  'name': name,
  'state': 'uploaded',
  'size': 5,
  'label': 'keep this label',
  'browser_download_url':
      'https://github.com/sample/files/releases/download/v1/$name',
};
CloudFile _assetFile({String name = 'app.apk', int id = 45}) => CloudFile(
  id: _release.copy(kind: GitHubNodeKind.asset, assetId: '$id').id,
  name: name,
  size: 5,
  parentId: _release.id,
);
UploadFile _upload(String name, [List<int> bytes = const [0, 1, 2, 3, 255]]) =>
    UploadFile(
      name: name,
      size: bytes.length,
      read: (s, e) async* {
        for (var i = s; i < e; i += 2) {
          yield bytes.sublist(i, (i + 2).clamp(0, e));
        }
      },
    );
HttpResult _rows(List<Json> values) => HttpResult(200, jsonEncode(values));
Matcher _error(String text) => throwsA(
  isA<AppException>().having((e) => e.message, 'message', contains(text)),
);
List<RecordedRequest> _mutations(FakeHttp http) =>
    http.calls.where((r) => r.method != 'GET' && r.method != 'HEAD').toList();

FakeHttp _api({
  List<Json>? tree,
  List<Json>? assets,
  Json? repository,
  FutureOr<HttpResult?> Function(RecordedRequest)? intercept,
}) => FakeHttp((r) async {
  final custom = await intercept?.call(r);
  if (custom != null) return custom;
  if (r.uri.host == 'raw.githubusercontent.com') {
    expect(r.headers.containsKey('Authorization'), isFalse);
    return const HttpResult(206, 'x', {
      'content-range': ['bytes 0-0/5'],
    });
  }
  final path = Uri.decodeComponent(r.uri.path);
  if (path == '/user') {
    return jsonResponse({'id': 123, 'login': 'sample', 'name': '测试用户'});
  }
  if (path == '/repos/sample/files') return jsonResponse(repository ?? _repo());
  if (path == '/user/repos' || path == '/users/sample/repos') {
    return _rows([repository ?? _repo()]);
  }
  if (path == '/users/sample') {
    return jsonResponse({'login': 'sample', 'type': 'User'});
  }
  if (path == '/repos/sample/files/branches') {
    return _rows([
      {'name': 'main'},
    ]);
  }
  if (path == '/repos/sample/files/tags') return _rows([]);
  if (path.startsWith('/repos/sample/files/commits/')) {
    return jsonResponse({
      'sha': 'commit-old',
      'commit': {
        'tree': {'sha': 'tree-old'},
      },
    });
  }
  if (path == '/repos/sample/files/git/trees/tree-old') {
    return jsonResponse({
      'tree': tree ?? [_treeRow('old.txt')],
      'truncated': false,
    });
  }
  if (path == '/repos/sample/files/git/trees' && r.method == 'POST') {
    return jsonResponse({'sha': 'tree-new'}, 201);
  }
  if (path == '/repos/sample/files/git/commits' && r.method == 'POST') {
    return jsonResponse({'sha': 'commit-new'}, 201);
  }
  if (path.startsWith('/repos/sample/files/git/refs/heads/') &&
      r.method == 'PATCH') {
    return jsonResponse({
      'object': {'sha': 'commit-new'},
    });
  }
  if (path == '/repos/sample/files/releases/12') {
    return jsonResponse({
      'id': 12,
      'tag_name': 'v1',
      'upload_url':
          'https://uploads.github.com/repos/sample/files/releases/12/assets{?name,label}',
    });
  }
  if (path == '/repos/sample/files/releases/12/assets') {
    if (r.method == 'POST') return jsonResponse(_assetJson(), 201);
    return _rows(assets ?? [_assetJson()]);
  }
  if (path == '/repos/sample/files/releases/assets/45') {
    return r.method == 'DELETE'
        ? const HttpResult(204, '')
        : jsonResponse(_assetJson());
  }
  throw StateError('Unexpected fixture request: ${r.method} $path');
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('GitHub link recognition', () {
    for (final url in [
      'https://github.com/sample',
      'https://github.com/sample/files',
      'https://github.com/sample/files/tree/feature/android/目录',
      'https://github.com/sample/files/blob/main/说明%20文档.md',
      'https://github.com/sample/files/releases',
      'https://github.com/sample/files/releases/latest/download/app.apk',
      'https://github.com/sample/files/releases/download/release/v1/app.apk',
      'https://raw.githubusercontent.com/sample/files/refs/heads/main/README.md',
      'https://codeload.github.com/sample/files/zip/refs/heads/main',
      'https://github.com/sample/files/archive/refs/heads/main.zip',
      'https://github.com/orgs/sample/repositories',
    ]) {
      test('recognizes $url without treating names as passcodes', () {
        final parsed = LinkParser.parse('$url 密码：1234').single;
        expect(parsed.platform, CloudPlatform.github);
        expect(parsed.kind, LinkKind.cloudShare);
        expect(Uri.parse(parsed.url).pathSegments, Uri.parse(url).pathSegments);
        expect(parsed.passcode, isNull);
      });
    }
    for (final url in [
      'https://github.com/login',
      'https://github.com/settings/tokens',
      'https://github.com/sample/files/issues/12',
      'https://github.com/sample/files/actions',
      'https://github.com.evil.test/sample/files',
      'https://api.github.com/sample/files',
    ]) {
      test('does not treat unrelated URL as a repository: $url', () {
        expect(LinkParser.shareId(CloudPlatform.github, url), isNull);
      });
    }
    test('coordinates reject traversal and preserve Unicode', () {
      final n = _root.copy(ref: 'feature/android', path: '文档/空 格.txt');
      expect(GitHubLocation.parse(n.id).path, n.path);
      expect(GitHubLocation.parse(n.id).ref, n.ref);
      expect(GitHubLocation.tryParse(_root.copy(path: '../secret').id), isNull);
      expect(GitHubLocation.tryParse(_root.copy(ref: 'main..x').id), isNull);
      expect(n.id, isNot(contains(_token)));
    });
  });

  test(
    'token login verifies identity; invalid credentials do not replace saved account',
    () async {
      final store = Vault(StateStore.memory());
      await store.putCredential(CloudPlatform.github, _credential());
      var expired = false;
      final provider = GitHubConnector(
        _api(
          intercept: (_) =>
              expired ? const HttpResult(401, '<html>no</html>') : null,
        ),
      );
      final login = AccountLoginService(
        store,
        (_, c) => provider.account(c),
        webAuthenticators: {CloudPlatform.github: provider.authenticate},
      );
      final result = await login.submitWeb(
        CloudPlatform.github,
        'Bearer $_token',
      );
      expect(result.credential.field('userId'), '123');
      expect(result.credential.field('username'), 'sample');
      expect(result.account.nickname, '测试用户');
      expect(
        LoginCredentials.savedCookie(CloudPlatform.github, result.credential),
        isNull,
      );
      final before = store.credential(CloudPlatform.github)!;
      expired = true;
      await expectLater(
        login.submitWeb(
          CloudPlatform.github,
          'github_pat_invalid01234567890123',
        ),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(store.credential(CloudPlatform.github)!.sameAs(before), isTrue);
    },
  );

  test(
    'own account lists accessible private and collaborator repositories, with pagination',
    () async {
      final http = _api(
        intercept: (r) {
          if (r.uri.path == '/user/repos') {
            expect(
              r.uri.queryParameters['affiliation'],
              'owner,collaborator,organization_member',
            );
            expect(r.headers['Authorization'], 'Bearer $_token');
            return _rows(
              r.uri.queryParameters['page'] == '1'
                  ? List.generate(100, (_) => _repo(private: true))
                  : [_repo()],
            );
          }
          return null;
        },
      );
      final provider = GitHubConnector(http);
      final session = await provider.openPersonal(_credential());
      final files = await provider.list(session, session.rootId, _credential());
      expect(files, hasLength(101));
      expect(
        http.calls.where((r) => r.uri.path == '/users/sample/repos'),
        isEmpty,
      );
    },
  );

  test(
    'public repository browsing needs no login and only code/asset rows are manageable',
    () async {
      final http = _api();
      final provider = GitHubConnector(http);
      final share = await provider.openShare(
        LinkParser.parse('https://github.com/sample/files').single,
        null,
      );
      final files = await provider.list(share, share.rootId, null);
      expect(files.map((f) => f.name), contains('代码 · main'));
      expect(
        http.calls.every((r) => !r.headers.containsKey('Authorization')),
        isTrue,
      );
      expect(provider.canRenameFile(share, _file('old.txt')), isFalse);
      expect(
        provider.canUploadTo(
          _session(),
          _root.copy(kind: GitHubNodeKind.repository).id,
        ),
        isFalse,
      );
      expect(provider.canUploadTo(_session(), _root.id), isTrue);
      expect(provider.canCreateFolderIn(_session(), _release.id), isFalse);
      expect(provider.canUploadTo(_session(), _release.id), isTrue);
      expect(provider.canMoveFile(_session(), _assetFile()), isFalse);
      expect(provider.canRenameFile(_session(), _file('old.txt')), isTrue);
      expect(
        provider.canUploadTo(_session(), _root.copy(branch: false).id),
        isFalse,
      );
    },
  );

  test(
    'branch names with slashes use the longest actual branch prefix',
    () async {
      final http = _api(
        intercept: (r) => r.uri.path.endsWith('/branches')
            ? _rows([
                {'name': 'feature'},
                {'name': 'feature/android'},
              ])
            : null,
      );
      final session = await GitHubConnector(http).openShare(
        LinkParser.parse(
          'https://github.com/sample/files/tree/feature/android/目录',
        ).single,
        null,
      );
      final root = GitHubLocation.parse(session.rootId);
      expect(root.ref, 'feature/android');
      expect(root.path, '目录');
    },
  );

  test(
    'tree listing retains blob SHA and executable mode and refuses truncated lists',
    () async {
      final provider = GitHubConnector(
        _api(tree: [_treeRow('run.sh', mode: '100755')]),
      );
      final files = await provider.list(_session(), _root.id, _credential());
      expect(jsonDecode(files.single.token)['mode'], '100755');
      final truncated = GitHubConnector(
        _api(
          intercept: (r) => r.uri.path.contains('/git/trees/')
              ? jsonResponse({'tree': [], 'truncated': true})
              : null,
        ),
      );
      await expectLater(
        truncated.list(_session(), _root.id, _credential()),
        _error('截断'),
      );
    },
  );

  test(
    'Chinese file paths are encoded once and PAT is absent from the raw download',
    () async {
      final http = _api(
        intercept: (r) {
          if (r.uri.path.contains('/contents/')) {
            expect(r.url, isNot(contains('%25E')));
            expect(Uri.decodeComponent(r.uri.path), endsWith('/文档/空 格.txt'));
            expect(r.uri.queryParameters['ref'], 'refs/heads/main');
            return jsonResponse({
              'type': 'file',
              'sha': 'blob-old',
              'size': 5,
              'download_url':
                  'https://raw.githubusercontent.com/sample/files/main/file.txt?token=temporary',
            });
          }
          return null;
        },
      );
      final spec = await GitHubConnector(
        http,
        acceleration: () => const GitHubAcceleration(mode: 'gh-proxy.com'),
      ).download(_session(), _file('文档/空 格.txt'), _credential());
      expect(
        spec.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(jsonEncode(spec.toJson()), isNot(contains(_token)));
      expect(
        http.calls
            .where((r) => r.headers.containsKey('Authorization'))
            .every((r) => r.uri.host == 'api.github.com'),
        isTrue,
      );
    },
  );

  test('changed source and non-GitHub download hosts are rejected', () async {
    for (final changed in [false, true]) {
      final provider = GitHubConnector(
        _api(
          intercept: (r) => r.uri.path.contains('/contents/')
              ? jsonResponse({
                  'type': 'file',
                  'sha': changed ? 'blob-new' : 'blob-old',
                  'download_url': 'https://evil.test/download',
                })
              : null,
        ),
      );
      await expectLater(
        provider.download(_session(), _file('old.txt'), _credential()),
        _error(changed ? '内容已变化' : '有效的文件直链'),
      );
    }
  });

  test(
    'creating a folder initializes an empty repository with an empty .gitkeep',
    () async {
      var initialized = false;
      final http = _api(
        intercept: (r) async {
          if (r.uri.path.contains('/commits/') && !initialized) {
            return jsonResponse({'message': 'Git Repository is empty.'}, 409);
          }
          if (r.method == 'PUT') {
            final body = r.body! as HttpUpload;
            final bytes = await body.open().expand((b) => b).toList();
            expect(bytes.length, body.length);
            expect(jsonDecode(utf8.decode(bytes))['content'], '');
            expect(r.uri.path, endsWith('/contents/new-folder/.gitkeep'));
            initialized = true;
            return jsonResponse({
              'content': {'sha': 'empty-blob', 'path': 'new-folder/.gitkeep'},
            }, 201);
          }
          if (r.uri.path.endsWith('/git/trees/tree-old') && initialized) {
            return jsonResponse({
              'tree': [
                _treeRow(
                  'new-folder',
                  sha: 'folder-tree',
                  type: 'tree',
                  mode: '040000',
                ),
              ],
            });
          }
          return null;
        },
      );
      final result = await GitHubConnector(
        http,
      ).createFolder(_session(), _root.id, 'new-folder', _credential());
      expect(result.isDirectory, isTrue);
      expect(result.name, 'new-folder');
      expect(jsonDecode(result.token)['sha'], 'folder-tree');
      expect(_mutations(http), hasLength(1));
    },
  );

  test(
    'Public raw preflight uses configured acceleration but preserves the original file URL',
    () async {
      const raw = 'https://raw.githubusercontent.com/sample/files/main/old.txt';
      final http = _api(
        intercept: (r) {
          if (r.uri.path.contains('/contents/')) {
            return jsonResponse({
              'type': 'file',
              'sha': 'blob-old',
              'size': 5,
              'download_url': raw,
            });
          }
          if (r.uri.host == 'gh-proxy.com') {
            expect(r.url, 'https://gh-proxy.com/$raw');
            expect(r.headers.containsKey('Authorization'), isFalse);
            return const HttpResult(206, 'x', {
              'content-range': ['bytes 0-0/5'],
            });
          }
          return null;
        },
      );
      final spec = await GitHubConnector(
        http,
        acceleration: () => const GitHubAcceleration(mode: 'gh-proxy.com'),
      ).download(_session(), _file('old.txt'), _credential());
      expect(spec.url, raw);
      expect(
        http.calls.where((r) => r.uri.host == 'gh-proxy.com'),
        hasLength(1),
      );
      expect(
        http.calls.where((r) => r.uri.host == 'raw.githubusercontent.com'),
        isEmpty,
      );
      expect(jsonEncode(spec.toJson()), isNot(contains(_token)));
    },
  );

  test(
    'unreachable public raw host falls back to the official raw-blob API without PAT',
    () async {
      final http = _api(
        intercept: (r) {
          if (r.uri.host == 'raw.githubusercontent.com') {
            throw const HttpRequestFailure(
              'connection reset',
              kind: 'connectionError',
            );
          }
          if (r.uri.path.contains('/contents/')) {
            return jsonResponse({
              'type': 'file',
              'sha': 'blob-old',
              'download_url':
                  'https://raw.githubusercontent.com/sample/files/main/old.txt',
            });
          }
          if (r.uri.path.contains('/git/blobs/')) {
            expect(r.headers['Accept'], 'application/vnd.github.raw+json');
            expect(r.headers.containsKey('Authorization'), isFalse);
            return const HttpResult(206, 'x');
          }
          return null;
        },
      );
      final spec = await GitHubConnector(
        http,
      ).download(_session(), _file('old.txt'), _credential());
      expect(Uri.parse(spec.url).host, 'api.github.com');
      expect(spec.headers.containsKey('Authorization'), isFalse);
      expect(spec.headers['Accept'], 'application/vnd.github.raw+json');
    },
  );

  test(
    'private asset redirects are resolved with auth, but CDN gets no PAT',
    () async {
      final http = _api(
        repository: _repo(private: true),
        intercept: (r) {
          if (r.headers['Accept'] == 'application/octet-stream') {
            expect(r.uri.host, 'api.github.com');
            expect(r.headers['Authorization'], 'Bearer $_token');
            return const HttpResult(302, '', {
              'location': [
                'https://release-assets.githubusercontent.com/github/asset?sig=temporary',
              ],
            });
          }
          return null;
        },
      );
      final spec = await GitHubConnector(
        http,
      ).download(_session(), _assetFile(), _credential());
      expect(spec.url, contains('release-assets.githubusercontent.com'));
      expect(spec.headers, {'User-Agent': GitHubConnector.userAgent});
      expect(http.calls.where((r) => r.uri.host != 'api.github.com'), isEmpty);
    },
  );

  test(
    'source ZIP uses GitHub JSON negotiation and clears auth after the redirect',
    () async {
      final http = _api(
        intercept: (r) {
          if (r.uri.path.contains('/zipball/')) {
            expect(r.headers['Accept'], 'application/vnd.github+json');
            expect(r.uri.path, endsWith('/zipball/refs/heads/main'));
            return const HttpResult(302, '', {
              'location': [
                'https://codeload.github.com/sample/files/legacy.zip/main',
              ],
            });
          }
          return null;
        },
      );
      final node = _root.copy(kind: GitHubNodeKind.archive);
      final spec = await GitHubConnector(http).download(
        _session(),
        CloudFile(id: node.id, name: 'files-main.zip'),
        _credential(),
      );
      expect(spec.headers, {'User-Agent': GitHubConnector.userAgent});
      expect(spec.expectedSize, 0);
    },
  );

  test(
    'code upload streams valid base64 JSON and never supplies an overwrite SHA',
    () async {
      var read = false;
      final progress = <UploadProgress>[];
      final http = _api(
        tree: [],
        intercept: (r) async {
          if (r.method != 'PUT') return null;
          expect(r.body, isA<HttpUpload>());
          expect(read, isFalse);
          final stream = r.body! as HttpUpload;
          final bytes = await stream.open().expand((part) => part).toList();
          expect(bytes.length, stream.length);
          final data = asJson(jsonDecode(utf8.decode(bytes)));
          expect(data['branch'], 'main');
          expect(data.containsKey('sha'), isFalse);
          expect(base64Decode(data.str('content')), [0, 1, 2, 3, 255]);
          stream.onProgress?.call(stream.length, stream.length);
          return jsonResponse({
            'content': {'path': '测试.txt', 'sha': 'uploaded'},
          }, 201);
        },
      );
      final file = UploadFile(
        name: '测试.txt',
        size: 5,
        read: (s, e) async* {
          read = true;
          yield [0];
          yield [1, 2];
          yield [3, 255];
        },
      );
      final result = await GitHubConnector(http).upload(
        _session(),
        _root.id,
        file,
        _credential(),
        onProgress: progress.add,
      );
      expect(result.name, '测试.txt');
      expect(result.size, 5);
      expect(progress.last.phase, UploadPhase.finishing);
      expect(progress.last.sent, 5);
    },
  );

  test(
    'upload refuses existing names and over-limit files without reading their bytes',
    () async {
      final http = _api();
      final provider = GitHubConnector(http);
      await expectLater(
        provider.upload(
          _session(),
          _root.id,
          _upload('old.txt'),
          _credential(),
        ),
        _error('同名'),
      );
      expect(_mutations(http), isEmpty);
      final huge = UploadFile(
        name: 'huge.zip',
        size: GitHubConnector.codeUploadLimit + 1,
        read: (_, _) => throw StateError('Must not read'),
      );
      final before = http.calls.length;
      await expectLater(
        provider.upload(_session(), _root.id, huge, _credential()),
        _error('100 MiB'),
      );
      expect(http.calls.length, before);
    },
  );

  test(
    'new files can initialize an empty repository on the selected branch',
    () async {
      final http = _api(
        intercept: (r) {
          if (r.uri.path.contains('/commits/')) {
            return jsonResponse({'message': 'Git Repository is empty.'}, 409);
          }
          if (r.method == 'PUT') {
            return jsonResponse({
              'content': {'path': 'first.txt', 'sha': 'uploaded'},
            }, 201);
          }
          return null;
        },
      );
      final result = await GitHubConnector(
        http,
      ).upload(_session(), _root.id, _upload('first.txt'), _credential());
      expect(result.name, 'first.txt');
      expect(_mutations(http).single.method, 'PUT');
    },
  );

  test(
    'rename creates one atomic commit and preserves executable mode',
    () async {
      final http = _api(tree: [_treeRow('old.txt', mode: '100755')]);
      await GitHubConnector(http).rename(
        _session(),
        _file('old.txt', mode: '100755'),
        'new.txt',
        _credential(),
      );
      final calls = _mutations(http);
      expect(calls.map((r) => r.method), ['POST', 'POST', 'PATCH']);
      expect(calls[0].json['base_tree'], 'tree-old');
      expect(calls[0].json['tree'], [
        {'path': 'old.txt', 'mode': '100755', 'type': 'blob', 'sha': null},
        {
          'path': 'new.txt',
          'mode': '100755',
          'type': 'blob',
          'sha': 'blob-old',
        },
      ]);
      expect(calls[1].json['parents'], ['commit-old']);
      expect(calls[2].json, {'sha': 'commit-new', 'force': false});
      expect(http.calls.where((r) => r.method == 'DELETE'), isEmpty);
    },
  );

  test(
    'directory rename reuses the whole tree without downloading its contents',
    () async {
      final http = _api(
        tree: [
          _treeRow('folder', sha: 'folder-tree', type: 'tree', mode: '040000'),
        ],
      );
      await GitHubConnector(http).rename(
        _session(),
        _file('folder', sha: 'folder-tree', directory: true, mode: '040000'),
        'renamed',
        _credential(),
      );
      final changes = _mutations(http).first.json.list('tree');
      expect(changes.last, {
        'path': 'renamed',
        'mode': '040000',
        'type': 'tree',
        'sha': 'folder-tree',
      });
    },
  );

  test('stale SHA and destination collisions fail before any write', () async {
    for (final stale in [false, true]) {
      final http = _api(
        tree: [
          _treeRow('old.txt', sha: stale ? 'new-content' : 'blob-old'),
          _treeRow('new.txt'),
        ],
      );
      await expectLater(
        GitHubConnector(
          http,
        ).rename(_session(), _file('old.txt'), 'new.txt', _credential()),
        _error(stale ? '内容已变化' : '同名'),
      );
      expect(_mutations(http), isEmpty);
    }
  });

  test(
    'branch conflict never retries with force and never removes old content separately',
    () async {
      final http = _api(
        intercept: (r) => r.method == 'PATCH'
            ? jsonResponse({'message': 'Update is not a fast forward'}, 422)
            : null,
      );
      await expectLater(
        GitHubConnector(
          http,
        ).rename(_session(), _file('old.txt'), 'new.txt', _credential()),
        _error('分支已更新'),
      );
      expect(http.calls.where((r) => r.method == 'PATCH'), hasLength(1));
      expect(_mutations(http).last.json['force'], isFalse);
      expect(http.calls.where((r) => r.method == 'DELETE'), isEmpty);
    },
  );

  test(
    'batch deletion is a single commit, and permission is rechecked',
    () async {
      final http = _api(tree: [_treeRow('old.txt'), _treeRow('another.txt')]);
      await GitHubConnector(http).delete(_session(), [
        _file('old.txt'),
        _file('another.txt'),
      ], _credential());
      expect(_mutations(http).first.json.list('tree'), hasLength(2));
      expect(
        _mutations(http).where((r) => r.uri.path.endsWith('/git/commits')),
        hasLength(1),
      );
      final denied = _api(repository: _repo(push: false));
      await expectLater(
        GitHubConnector(
          denied,
        ).delete(_session(), [_file('old.txt')], _credential()),
        _error('写入权限'),
      );
      expect(_mutations(denied), isEmpty);
    },
  );

  test('move refuses another branch and a folder moving into itself', () async {
    final http = _api(
      tree: [_treeRow('folder', type: 'tree', mode: '040000')],
    );
    final provider = GitHubConnector(http);
    await expectLater(
      provider.move(
        _session(),
        [_file('old.txt')],
        _root.copy(ref: 'other').id,
        _credential(),
      ),
      _error('同一分支'),
    );
    expect(_mutations(http), isEmpty);
  });

  test(
    'release uploads stream binary and only send credentials to official upload host',
    () async {
      final http = _api(
        assets: [],
        intercept: (r) async {
          if (r.method != 'POST') return null;
          expect(r.uri.host, 'uploads.github.com');
          expect(r.uri.queryParameters['name'], 'app.apk');
          final body = r.body! as HttpUpload;
          expect(await body.open().expand((part) => part).toList(), [
            0,
            1,
            2,
            3,
            255,
          ]);
          return jsonResponse(_assetJson(), 201);
        },
      );
      final result = await GitHubConnector(
        http,
      ).upload(_session(), _release.id, _upload('app.apk'), _credential());
      expect(result.id, _assetFile().id);
    },
  );

  test(
    'foreign upload endpoints and immutable releases cannot be written',
    () async {
      for (final immutable in [false, true]) {
        final http = _api(
          assets: [],
          intercept: (r) => r.uri.path == '/repos/sample/files/releases/12'
              ? jsonResponse({
                  'immutable': immutable,
                  'upload_url': 'https://evil.test/upload',
                })
              : null,
        );
        await expectLater(
          GitHubConnector(
            http,
          ).upload(_session(), _release.id, _upload('new.apk'), _credential()),
          _error(immutable ? '锁定' : '上传地址无效'),
        );
        expect(_mutations(http), isEmpty);
      }
    },
  );

  test(
    'release asset rename preserves its label; deletion targets the selected asset ID',
    () async {
      final http = _api();
      final provider = GitHubConnector(http);
      await provider.rename(
        _session(),
        _assetFile(),
        'renamed.apk',
        _credential(),
      );
      expect(_mutations(http).single.json, {'name': 'renamed.apk'});
      await provider.delete(_session(), [_assetFile()], _credential());
      expect(_mutations(http).last.method, 'DELETE');
      expect(
        _mutations(http).last.uri.path,
        '/repos/sample/files/releases/assets/45',
      );
    },
  );

  test(
    'cancelled queued mutation does not let later writes overtake the current one',
    () async {
      final blocked = Completer<HttpResult>();
      var first = true, active = 0, maximum = 0;
      final http = _api(
        tree: [],
        intercept: (r) async {
          if (r.method != 'PUT') return null;
          active++;
          if (active > maximum) maximum = active;
          if (first) {
            first = false;
            await blocked.future;
          }
          active--;
          final path = Uri.decodeComponent(r.uri.path).split('/contents/').last;
          return jsonResponse({
            'content': {'path': path, 'sha': 'uploaded'},
          }, 201);
        },
      );
      final provider = GitHubConnector(http);
      final firstWrite = provider.upload(
        _session(),
        _root.id,
        _upload('first.txt'),
        _credential(),
      );
      await until(() => active == 1);
      final scope = RequestScope();
      final cancelled = scope.run(
        () => provider.upload(
          _session(),
          _root.id,
          _upload('cancelled.txt'),
          _credential(),
        ),
      );
      final expectation = expectLater(cancelled, throwsA(isA<AppException>()));
      scope.cancel();
      await expectation;
      final third = provider.upload(
        _session(),
        _root.id,
        _upload('third.txt'),
        _credential(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(_mutations(http), hasLength(1));
      blocked.complete(jsonResponse({}));
      await firstWrite;
      await third;
      expect(maximum, 1);
      expect(
        _mutations(http).map((r) => r.uri.path),
        isNot(contains(endsWith('cancelled.txt'))),
      );
    },
  );

  test(
    'repository integration preserves download origin and rejects virtual-root upload',
    () async {
      final store = StateStore.memory(), vault = Vault(StateStore.memory());
      await vault.putCredential(CloudPlatform.github, _credential());
      final http = _api();
      final repository = CloudRepository(
        http,
        vault,
        CleanupOutbox(store, http),
      );
      final session = await repository.personal(CloudPlatform.github);
      expect(session.canManageFiles, isTrue);
      final spec = repository.planDownload(session, _file('old.txt'));
      expect(spec.platform, CloudPlatform.github);
      expect(spec.source, isNotNull);
      await expectLater(
        repository.upload(session, session.rootId, _upload('new.txt')),
        _error('不支持上传'),
      );
      expect(_mutations(http), isEmpty);
    },
  );
}
