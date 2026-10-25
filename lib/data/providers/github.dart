import 'dart:async';
import 'dart:convert';
import '../../core/json.dart';
import '../../domain/auth.dart';
import '../../domain/github.dart';
import '../../domain/github_acceleration.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../http.dart';
import 'personal_cloud.dart';

part 'github_write.dart';

class GitHubConnector extends PersonalCloudConnector {
  GitHubConnector(this.http, {this.acceleration});
  final JsonHttp http;
  final GitHubAcceleration Function()? acceleration;
  static const userAgent = 'AsterLink-GitHub/1.0';
  static const apiVersion = '2022-11-28';
  static const codeUploadLimit = 100 * 1024 * 1024;
  static const assetUploadLimit = 2 * 1024 * 1024 * 1024;
  final Map<String, Future<void>> _writes = {};
  @override
  CloudPlatform get platform => CloudPlatform.github;

  static String _e(String value) => Uri.encodeComponent(value);
  static String _path(String value) => value.split('/').map(_e).join('/');
  static String _base(GitHubLocation n) =>
      '/repos/${_e(n.owner)}/${_e(n.repo)}';
  static Json _info(CloudFile file) {
    try {
      return asJson(jsonDecode(file.token));
    } catch (_) {
      return {};
    }
  }

  Map<String, String> _headers(Credential? c, {String? accept}) => {
    'User-Agent': userAgent,
    'Accept': accept ?? 'application/vnd.github+json',
    'X-GitHub-Api-Version': apiVersion,
    if (c != null)
      'Authorization':
          'Bearer ${LoginCredentials.normalize(platform, c.primary)}',
  };

  Future<HttpResult> _request(
    String method,
    String path,
    Credential? c, {
    Map<String, String> query = const {},
    Object? body,
    Set<int> acceptStatus = const {},
  }) async {
    var uri = Uri.parse(
      'https://api.github.com$path',
    ).replace(queryParameters: query.isEmpty ? null : query);
    for (var redirects = 0; ; redirects++) {
      RequestScope.checkpoint();
      final result = await http.request(
        method,
        uri.toString(),
        headers: _headers(c),
        body: body == null || body is HttpUpload ? body : jsonEncode(body),
        contentType: body == null ? null : 'application/json; charset=utf-8',
        followRedirects: false,
      );
      RequestScope.checkpoint();
      if (method == 'GET' &&
          {301, 302, 307, 308}.contains(result.status) &&
          redirects < 3) {
        final next = uri.resolve(result.header('location'));
        require(
          next.scheme == 'https' &&
              next.host == 'api.github.com' &&
              next.port == 443 &&
              next.userInfo.isEmpty,
          'GitHub 返回了无效的接口跳转',
        );
        uri = next;
        continue;
      }
      if (!acceptStatus.contains(result.status)) _check(result);
      return result;
    }
  }

  void _check(HttpResult r) {
    if (r.successful) return;
    if (r.status == 401) {
      throw const AccountLoginRequired('GitHub 访问令牌无效或已过期，请重新登录');
    }
    if (r.status == 429 ||
        r.status == 403 &&
            (r.header('x-ratelimit-remaining') == '0' ||
                r.header('retry-after').isNotEmpty)) {
      throw const AppException('GitHub 请求次数已达上限，请稍后再试；登录后可提高额度');
    }
    if (r.status == 403) {
      throw const AppException(
        'GitHub 拒绝操作，请检查令牌的仓库权限、组织授权或分支保护规则；修改工作流还需 Workflows 写入权限',
      );
    }
    if (r.status == 404) throw const AppException('GitHub 仓库或文件不存在，或当前令牌无权访问');
    if (r.status == 409 || r.status == 422) {
      throw const AppException('GitHub 未接受本次修改：可能有同名文件、分支已更新或受保护，请刷新后重试');
    }
    if (r.status == 413) {
      throw const AppException('文件超过 GitHub 上传大小限制，请使用 Releases 附件');
    }
    throw AppException('GitHub 请求失败（HTTP ${r.status}），请稍后重试');
  }

  Future<Json> _get(
    String path,
    Credential? c, {
    Map<String, String> query = const {},
  }) async => (await _request('GET', path, c, query: query)).json;

  Future<List<Json>> _pages(
    String path,
    Credential? c, {
    Map<String, String> query = const {},
  }) async {
    final result = <Json>[];
    for (var page = 1; page <= 100; page++) {
      final response = await _request(
        'GET',
        path,
        c,
        query: {...query, 'per_page': '100', 'page': '$page'},
      );
      final Object? raw;
      try {
        raw = jsonDecode(response.body);
      } catch (_) {
        throw const AppException('GitHub 文件列表格式异常');
      }
      require(raw is List, 'GitHub 文件列表格式异常');
      final rows = (raw as List).map(asJson).toList();
      result.addAll(rows);
      if (rows.length < 100 &&
          !response.header('link').contains('rel="next"')) {
        return result;
      }
    }
    throw const AppException('GitHub 列表超过一万项，请通过具体仓库链接打开');
  }

  Future<Json> _repository(GitHubLocation n, Credential? c) async {
    require(n.repo.isNotEmpty, '请先打开 GitHub 仓库');
    return _get(_base(n), c);
  }

  GitHubLocation _repoNode(Json repo, {required bool authenticated}) =>
      GitHubLocation(
        kind: GitHubNodeKind.repository,
        owner: repo.obj('owner').str('login'),
        repo: repo.str('name'),
        ref: repo.str('default_branch').ifEmpty('main'),
        writable:
            authenticated &&
            repo.obj('permissions').boolean('push') &&
            !repo.boolean('archived') &&
            !repo.boolean('disabled'),
      );

  Future<LoginResult> authenticate(Credential c) async {
    final user = await _get('/user', c);
    require(
      user.str('id').isNotEmpty && GitHubLocation.validOwner(user.str('login')),
      'GitHub 未返回有效的账号信息',
    );
    return LoginResult(
      c.withFields({
        'userId': user.str('id'),
        'username': user.str('login'),
        'authType': 'githubToken',
      }),
      CloudAccount(user.str('name').trim().ifEmpty(user.str('login'))),
    );
  }

  @override
  Future<CloudAccount> account(Credential credential) async =>
      (await authenticate(credential)).account;

  BrowseSession _session(GitHubLocation root, Credential? c, {String? title}) =>
      BrowseSession(
        platform: platform,
        mode: BrowseMode.share,
        title: title ?? root.repository,
        rootId: root.id,
        metadata: {'githubAuthenticated': '${c != null}'},
      );

  @override
  Future<BrowseSession> openPersonal(Credential c) async {
    final saved = c.field('username');
    final login = GitHubLocation.validOwner(saved)
        ? saved
        : (await _get('/user', c)).str('login');
    require(GitHubLocation.validOwner(login), 'GitHub 账号信息无效');
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: 'GitHub · $login',
      rootId: GitHubLocation(kind: GitHubNodeKind.account, owner: login).id,
      metadata: {'githubAuthenticated': 'true'},
    );
  }

  Future<({String ref, String path, bool branch})> _resolveRef(
    GitHubLocation n,
    List<String> raw,
    Credential? c,
  ) async {
    final parts = List<String>.of(raw);
    bool? explicitBranch;
    if (parts.length >= 2 &&
        parts.first == 'refs' &&
        {'heads', 'tags'}.contains(parts[1])) {
      explicitBranch = parts[1] == 'heads';
      parts.removeRange(0, 2);
    }
    require(parts.isNotEmpty, 'GitHub 链接缺少分支或文件路径');
    final joined = parts.join('/');
    require(GitHubLocation.validPath(joined), 'GitHub 文件路径无效');
    // Longest match matters for branches such as feature/android and tags with '/'.
    final matches = <({String ref, bool branch})>[];
    if (explicitBranch != false) {
      for (final row in await _pages('${_base(n)}/branches', c)) {
        final name = row.str('name');
        if (joined == name || joined.startsWith('$name/')) {
          matches.add((ref: name, branch: true));
        }
      }
    }
    if (explicitBranch != true) {
      for (final row in await _pages('${_base(n)}/tags', c)) {
        final name = row.str('name');
        if (joined == name || joined.startsWith('$name/')) {
          matches.add((ref: name, branch: false));
        }
      }
    }
    matches.sort((a, b) => b.ref.length.compareTo(a.ref.length));
    if (matches.isNotEmpty) {
      final match = matches.first;
      return (
        ref: match.ref,
        path: joined == match.ref ? '' : joined.substring(match.ref.length + 1),
        branch: match.branch,
      );
    }
    require(
      explicitBranch == null &&
          RegExp(r'^[0-9a-fA-F]{40,64}$').hasMatch(parts.first),
      'GitHub 分支或标签不存在，请检查链接',
    );
    return (ref: parts.first, path: parts.skip(1).join('/'), branch: false);
  }

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    final c = credential;
    final parsed = GitHubLink.parse(Uri.parse(link.url));
    require(parsed != null, '不支持此 GitHub 链接，请使用账号、仓库、代码或 Releases 链接');
    final p = parsed!;
    if (p.route == 'owner') {
      final user = await _get('/users/${_e(p.owner)}', c);
      return _session(
        GitHubLocation(kind: GitHubNodeKind.owner, owner: user.str('login')),
        c,
        title: 'GitHub · ${user.str('login')}',
      );
    }
    final repo = await _repository(
      GitHubLocation(
        kind: GitHubNodeKind.repository,
        owner: p.owner,
        repo: p.repo,
      ),
      c,
    );
    final root = _repoNode(repo, authenticated: c != null);
    if (p.route == 'repository') return _session(root, c);
    if (p.route == 'tree' || p.route == 'blob') {
      final resolved = await _resolveRef(root, p.tail, c);
      require(p.route != 'blob' || resolved.path.isNotEmpty, 'GitHub 链接缺少文件名');
      return _session(
        root.copy(
          kind: p.route == 'tree' ? GitHubNodeKind.code : GitHubNodeKind.file,
          ref: resolved.ref,
          path: resolved.path,
          branch: resolved.branch,
        ),
        c,
      );
    }
    if (p.route == 'archive') {
      final tail = List<String>.of(p.tail);
      tail[tail.length - 1] = tail.last.replaceFirst(RegExp(r'\.zip$'), '');
      final resolved = await _resolveRef(root, tail, c);
      require(resolved.path.isEmpty, 'GitHub 源码压缩包链接无效');
      return _session(
        root.copy(
          kind: GitHubNodeKind.archive,
          ref: resolved.ref,
          branch: resolved.branch,
        ),
        c,
      );
    }
    if (p.tail.isEmpty) {
      return _session(root.copy(kind: GitHubNodeKind.releases), c);
    }
    final latest = p.tail.first == 'latest';
    final download =
        p.tail.first == 'download' ||
        latest && p.tail.length > 1 && p.tail[1] == 'download';
    require(!download || p.tail.length >= 3, 'GitHub 附件链接缺少文件名');
    final tag = p.tail
        .skip(1)
        .take(p.tail.length - (download ? 2 : 1))
        .join('/');
    final release = await _get(
      '${_base(root)}/releases/${latest ? 'latest' : 'tags/${_e(tag)}'}',
      c,
    );
    final node = root.copy(
      kind: GitHubNodeKind.release,
      releaseId: release.str('id'),
      ref: release.str('tag_name'),
      branch: false,
    );
    if (!download) return _session(node, c);
    final assets = await _pages(
      '${_base(root)}/releases/${node.releaseId}/assets',
      c,
    );
    final asset = assets.where((a) => a.str('name') == p.tail.last).firstOrNull;
    require(asset != null, 'GitHub 发布中没有此附件');
    return _session(
      node.copy(kind: GitHubNodeKind.asset, assetId: asset!.str('id')),
      c,
    );
  }

  CloudFile _folder(
    GitHubLocation n,
    String name,
    String parent, {
    String modified = '',
    Json info = const {},
  }) => CloudFile(
    id: n.id,
    name: name,
    parentId: parent,
    isDirectory: true,
    token: jsonEncode(info),
    modifiedAt: modified,
  );

  CloudFile _asset(GitHubLocation parent, Json a, {String? parentId}) {
    final digest = a.str('digest').split(':');
    return CloudFile(
      id: parent.copy(kind: GitHubNodeKind.asset, assetId: a.str('id')).id,
      name: a.str('name'),
      size: a.integer('size'),
      parentId: parentId ?? parent.id,
      modifiedAt: a.str('updated_at'),
      token: jsonEncode({'name': a.str('name'), 'state': a.str('state')}),
      hashType: digest.length == 2 && digest.first == 'sha256'
          ? 'sha256'
          : null,
      hashValue: digest.length == 2 && digest.first == 'sha256'
          ? digest.last
          : null,
    );
  }

  CloudFile _archive(GitHubLocation n, String parent) => CloudFile(
    id: n.copy(kind: GitHubNodeKind.archive, path: '', assetId: '').id,
    name: '${n.repo}-${n.ref.replaceAll(RegExp(r'[^\w.-]'), '_')}.zip',
    parentId: parent,
  );

  Future<_GitHubSnapshot?> _snapshot(GitHubLocation n, Credential? c) async {
    require(n.ref.isNotEmpty, 'GitHub 分支信息缺失');
    final response = await _request(
      'GET',
      '${_base(n)}/commits/${_path(n.branch ? 'heads/${n.ref}' : n.ref)}',
      c,
      acceptStatus: {409},
    );
    if (response.status == 409 &&
        response.json.str('message').toLowerCase().contains('empty')) {
      return null;
    }
    _check(response);
    final data = response.json;
    final commit = data.str('sha'),
        tree = data.obj('commit').obj('tree').str('sha');
    require(commit.isNotEmpty && tree.isNotEmpty, 'GitHub 未返回完整的提交信息');
    return _GitHubSnapshot(commit, tree);
  }

  Future<List<Json>> _tree(GitHubLocation n, String sha, Credential? c) async {
    final data = await _get('${_base(n)}/git/trees/${_e(sha)}', c);
    require(!data.boolean('truncated'), 'GitHub 目录过大，列表被截断，请在网页查看后分目录管理');
    return data.list('tree').map(asJson).toList();
  }

  Future<Json?> _entryAt(
    GitHubLocation n,
    _GitHubSnapshot snapshot,
    String path,
    Credential? c,
  ) async {
    var sha = snapshot.tree;
    if (path.isEmpty) return {'sha': sha, 'type': 'tree', 'mode': '040000'};
    final parts = path.split('/');
    for (var i = 0; i < parts.length; i++) {
      final found = (await _tree(
        n,
        sha,
        c,
      )).where((e) => e.str('path') == parts[i]).firstOrNull;
      if (found == null) return null;
      if (i == parts.length - 1) return found;
      require(found.str('type') == 'tree', 'GitHub 父目录已变化，请刷新文件列表');
      sha = found.str('sha');
    }
    return null;
  }

  Future<List<CloudFile>> _codeFiles(GitHubLocation n, Credential? c) async {
    final snapshot = await _snapshot(n, c);
    if (snapshot == null) {
      require(n.path.isEmpty, 'GitHub 仓库为空，此目录尚不存在');
      return [];
    }
    final entry = await _entryAt(n, snapshot, n.path, c);
    require(
      entry != null && entry.str('type') == 'tree',
      'GitHub 目录不存在或已被移动，请刷新',
    );
    return [
      for (final e in await _tree(n, entry!.str('sha'), c))
        CloudFile(
          id: n
              .copy(
                kind: e.str('type') == 'tree'
                    ? GitHubNodeKind.code
                    : GitHubNodeKind.file,
                path: [if (n.path.isNotEmpty) n.path, e.str('path')].join('/'),
              )
              .id,
          name: e.str('path'),
          size: e.integer('size'),
          isDirectory: e.str('type') == 'tree',
          parentId: n.id,
          token: jsonEncode({
            'sha': e.str('sha'),
            'type': e.str('type'),
            'mode': e.str('mode'),
          }),
        ),
    ];
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parentId,
    Credential? c,
  ) async {
    require(s.platform == platform, 'GitHub 来源不一致');
    final n = GitHubLocation.parse(parentId);
    switch (n.kind) {
      case GitHubNodeKind.account:
      case GitHubNodeKind.owner:
        final mine =
            n.kind == GitHubNodeKind.account ||
            c != null &&
                c.field('username').toLowerCase() == n.owner.toLowerCase();
        require(!mine || c != null, '请先登录 GitHub');
        final String endpoint;
        if (mine) {
          endpoint = '/user/repos';
        } else {
          final owner = await _get('/users/${_e(n.owner)}', c);
          endpoint =
              '/${owner.str('type') == 'Organization' ? 'orgs' : 'users'}/${_e(n.owner)}/repos';
        }
        final repos = await _pages(
          endpoint,
          c,
          query: {
            'sort': 'updated',
            if (mine) 'affiliation': 'owner,collaborator,organization_member',
          },
        );
        return [
          for (final repo in repos)
            _folder(
              _repoNode(repo, authenticated: c != null),
              repo.str('full_name'),
              parentId,
              modified: repo.str('updated_at'),
              info: {
                'description': repo.str('description'),
                'private': repo.boolean('private'),
              },
            ),
        ];
      case GitHubNodeKind.repository:
        final repo = await _repository(n, c);
        final root = _repoNode(repo, authenticated: c != null);
        return [
          _folder(
            root.copy(kind: GitHubNodeKind.code),
            '代码 · ${root.ref}',
            parentId,
          ),
          _folder(root.copy(kind: GitHubNodeKind.branches), '分支', parentId),
          _folder(
            root.copy(kind: GitHubNodeKind.releases),
            'Releases · 发布附件',
            parentId,
          ),
          if (repo.integer('size') > 0) _archive(root, parentId),
        ];
      case GitHubNodeKind.branches:
        return [
          for (final b in await _pages('${_base(n)}/branches', c))
            _folder(
              n.copy(
                kind: GitHubNodeKind.code,
                ref: b.str('name'),
                path: '',
                branch: true,
              ),
              b.str('name'),
              parentId,
            ),
        ];
      case GitHubNodeKind.code:
        return _codeFiles(n, c);
      case GitHubNodeKind.releases:
        return [
          for (final r in await _pages('${_base(n)}/releases', c))
            _folder(
              n.copy(
                kind: GitHubNodeKind.release,
                releaseId: r.str('id'),
                ref: r.str('tag_name'),
                branch: false,
                writable: n.writable && !r.boolean('immutable'),
              ),
              '${r.str('name').ifEmpty(r.str('tag_name'))}${r.boolean('draft') ? ' · 草稿' : ''}',
              parentId,
              modified: r.str('published_at').ifEmpty(r.str('created_at')),
            ),
        ];
      case GitHubNodeKind.release:
        return [
          for (final a in await _pages(
            '${_base(n)}/releases/${n.releaseId}/assets',
            c,
          ))
            if (a.str('state') == 'uploaded') _asset(n, a),
          _archive(n, parentId),
        ];
      case GitHubNodeKind.asset:
        final a = await _get('${_base(n)}/releases/assets/${n.assetId}', c);
        return [_asset(n, a, parentId: parentId)];
      case GitHubNodeKind.archive:
        return [_archive(n, parentId)];
      case GitHubNodeKind.file:
        final info = await _get(
          '${_base(n)}/contents/${_path(n.path)}',
          c,
          query: {'ref': n.branch ? 'refs/heads/${n.ref}' : n.ref},
        );
        require(
          info.str('type') == 'file' || info.str('type') == 'symlink',
          'GitHub 链接指向的不是文件',
        );
        return [
          CloudFile(
            id: n.id,
            name: info.str('name'),
            size: info.integer('size'),
            parentId: parentId,
            token: jsonEncode({
              'sha': info.str('sha'),
              'type': info.str('type') == 'symlink' ? 'symlink' : 'blob',
              'mode': info.str('type') == 'symlink' ? '120000' : '100644',
            }),
          ),
        ];
    }
  }

  bool _manageable(BrowseSession s, GitHubLocation? n) =>
      s.platform == platform && s.canManageFiles && n != null && n.writable;
  @override
  bool canUploadTo(BrowseSession session, String parent) {
    final n = GitHubLocation.tryParse(parent);
    return _manageable(session, n) &&
        (n!.kind == GitHubNodeKind.code && n.branch ||
            n.kind == GitHubNodeKind.release);
  }

  @override
  bool canCreateFolderIn(BrowseSession session, String parent) {
    final n = GitHubLocation.tryParse(parent);
    return _manageable(session, n) &&
        n!.kind == GitHubNodeKind.code &&
        n.branch;
  }

  @override
  bool canRenameFile(BrowseSession session, CloudFile file) {
    final n = GitHubLocation.tryParse(file.id);
    return _manageable(session, n) &&
        (n!.isCodeItem || n.kind == GitHubNodeKind.asset);
  }

  @override
  bool canDeleteFile(BrowseSession session, CloudFile file) =>
      canRenameFile(session, file);
  @override
  bool canMoveFile(BrowseSession session, CloudFile file) =>
      _manageable(session, GitHubLocation.tryParse(file.id)) &&
      GitHubLocation.parse(file.id).isCodeItem;
  @override
  bool canDownloadFile(BrowseSession session, CloudFile file) {
    final n = GitHubLocation.tryParse(file.id);
    return n != null &&
        {
          GitHubNodeKind.code,
          GitHubNodeKind.release,
          GitHubNodeKind.file,
          GitHubNodeKind.asset,
          GitHubNodeKind.archive,
        }.contains(n.kind);
  }

  static bool _downloadUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.port == 443 &&
        uri.userInfo.isEmpty &&
        {
          'github.com',
          'raw.githubusercontent.com',
          'codeload.github.com',
          'release-assets.githubusercontent.com',
          'objects.githubusercontent.com',
          'github-releases.githubusercontent.com',
        }.contains(uri.host.toLowerCase());
  }

  Future<String> _redirectDownload(
    String path,
    Credential? c, {
    String accept = 'application/octet-stream',
  }) async {
    final url = Uri.parse('https://api.github.com$path')
        .replace(
          queryParameters: {
            'download': '1',
            '_': '${DateTime.now().millisecondsSinceEpoch}',
          },
        )
        .toString();
    final response = await http.peek(
      url,
      _headers(c, accept: accept),
      maxBytes: 1024,
      followRedirects: false,
    );
    if ({301, 302, 303, 307, 308}.contains(response.status)) {
      final result = response.header('location');
      require(_downloadUrl(result), 'GitHub 未返回有效的下载地址');
      return result;
    }
    _check(response);
    throw const AppException('GitHub 尚未返回附件直链，请稍后重试');
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile file,
    Credential? c,
  ) async {
    require(!file.isDirectory && canDownloadFile(s, file), '请选择代码文件或发布附件下载');
    final n = GitHubLocation.parse(file.id);
    String url;
    Map<String, String> downloadHeaders = const {'User-Agent': userAgent};
    switch (n.kind) {
      case GitHubNodeKind.file:
        require(
          _info(file).str('type') != 'commit' &&
              _info(file).str('mode') != '120000',
          '此项为子模块或符号链接，请下载仓库源码 ZIP',
        );
        final info = await _get(
          '${_base(n)}/contents/${_path(n.path)}',
          c,
          query: {'ref': n.branch ? 'refs/heads/${n.ref}' : n.ref},
        );
        require(info.str('type') == 'file', 'GitHub 源文件已变化，请刷新后重试');
        final expected = _info(file).str('sha');
        require(
          expected.isEmpty || info.str('sha') == expected,
          'GitHub 文件内容已变化，请刷新文件列表后下载',
        );
        if (info.str('encoding') == 'base64' && info.integer('size') < 1024) {
          final content = utf8.decode(
            base64.decode(info.str('content').replaceAll(RegExp(r'\s'), '')),
            allowMalformed: true,
          );
          require(
            !content.startsWith('version https://git-lfs.github.com/spec/v1'),
            '此文件由 Git LFS 管理，请从 GitHub 网页下载，或选择 Releases 附件',
          );
        }
        url = info.str('download_url');
        require(_downloadUrl(url), 'GitHub 未返回有效的文件直链，请稍后重试');
        var rawReady = false;
        try {
          final probeUrl =
              acceleration?.call().urlFor(url, downloadHeaders) ?? url;
          final probe = await http.peek(
            probeUrl,
            downloadHeaders,
            maxBytes: 1,
            followRedirects: false,
          );
          final location = probe.header('location');
          final redirect = location.isEmpty
              ? null
              : Uri.tryParse(probeUrl)?.resolve(location);
          rawReady =
              probe.successful ||
              {301, 302, 303, 307, 308}.contains(probe.status) &&
                  (_downloadUrl(location) ||
                      probeUrl != url &&
                          redirect != null &&
                          {'http', 'https'}.contains(redirect.scheme) &&
                          redirect.host.isNotEmpty &&
                          redirect.userInfo.isEmpty);
        } on HttpRequestFailure {
          RequestScope.checkpoint();
        }
        if (!rawReady) {
          // Public code remains downloadable when raw.githubusercontent.com
          // is unreachable. The fallback intentionally has no PAT, so native
          // redirect caching can never forward it to a download/CDN host.
          final fallback =
              'https://api.github.com${_base(n)}/git/blobs/${_e(info.str('sha'))}';
          final headers = _headers(
            null,
            accept: 'application/vnd.github.raw+json',
          );
          final probe = await http.peek(
            fallback,
            headers,
            maxBytes: 1,
            followRedirects: false,
          );
          if (probe.status == 404) {
            throw const AppException('GitHub 原始文件服务器暂时无法连接，请检查网络后重试');
          }
          _check(probe);
          url = fallback;
          downloadHeaders = headers;
        }
      case GitHubNodeKind.asset:
        final a = await _get('${_base(n)}/releases/assets/${n.assetId}', c);
        require(
          a.str('state') == 'uploaded' && a.integer('size') == file.size,
          'GitHub 发布附件仍在上传或内容已变化',
        );
        final repo = await _repository(n, c);
        url = repo.boolean('private')
            ? await _redirectDownload(
                '${_base(n)}/releases/assets/${n.assetId}',
                c,
              )
            : a.str('browser_download_url');
      case GitHubNodeKind.archive:
        url = await _redirectDownload(
          '${_base(n)}/zipball/${_path(n.branch ? 'refs/heads/${n.ref}' : n.ref)}',
          c,
          accept: 'application/vnd.github+json',
        );
      default:
        throw const AppException('请选择代码文件或发布附件下载');
    }
    require(
      _downloadUrl(url) || Uri.parse(url).host == 'api.github.com',
      'GitHub 未返回有效的文件直链，请稍后重试',
    );
    // PATs are only used with GitHub's API. Raw/CDN downloads get no credentials.
    return DownloadSpec(
      url: url,
      fileName: file.name,
      expectedSize: file.size,
      headers: downloadHeaders,
      profile: 'github',
      checksumType: file.hashType,
      checksumValue: file.hashValue,
    );
  }

  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) => _uploadFile(s, parent, source, c, onProgress: onProgress);
  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) => _createFolder(s, parent, name, c);
  @override
  Future<void> rename(
    BrowseSession s,
    CloudFile file,
    String name,
    Credential c,
  ) => _rename(s, file, name, c);
  @override
  Future<void> delete(BrowseSession s, List<CloudFile> files, Credential c) =>
      _delete(s, files, c);
  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) => _move(s, files, target, c);
}

class _GitHubSnapshot {
  const _GitHubSnapshot(this.commit, this.tree);
  final String commit, tree;
}
