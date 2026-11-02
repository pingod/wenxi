import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../core/json.dart';
import '../../core/operation_progress.dart';
import '../../domain/auth.dart';
import '../../domain/links.dart';
import '../../domain/models.dart';
import '../../domain/pikpak_web_login.dart';
import '../../domain/uploads.dart';
import '../../domain/web_tokens.dart';
import '../http.dart';
import '../state_store.dart';
import '../uploads/upload_io.dart';
import 'personal_cloud.dart';
import 'token_session.dart';

// Protocol reference: NihilDigit/pikpak-kotlin (MIT), used by NihilDigit/piko.
class PikPakConnector extends PersonalCloudConnector {
  PikPakConnector(
    this.http,
    CredentialStore store, {
    this.stageCleanup,
    int Function()? now,
  }) : sessions = TokenSessions(CloudPlatform.pikpak, store, now: now);
  final JsonHttp http;
  final TokenSessions sessions;
  final Future<void> Function(DownloadCleanup)? stageCleanup;
  static const api = 'https://api-drive.mypikpak.com';
  static const userApi = 'https://user.mypikpak.com';
  static const clientId = 'YNxT9w7GMdWvEOKa';
  static const _secret = 'dbw2OtmVEeuUvIptb1Coyg';
  static const userAgent = 'ANDROID-com.pikcloud.pikpak/1.21.0';
  static const _salts = [
    '',
    'E32cSkYXC2bciKJGxRsE8ZgwmH/YwkvpD6/O9guSOa2irCwciH4xPHaH',
    'QtqgfMgHP2TFl',
    'zOKgHT56L7nIzFzDpUGhpWFrgP53m3G6ML',
    'S',
    'THxpsktzfFXizUv7DK1y/N7NZ1WhayViluBEvAJJ8bA1Wr6',
    'y9PXH3xGUhG/zQI8CaapRw2LhldCaFM9CRlKpZXJvj+pifu',
    '+RaaG7T8FRTI4cP019N5y9ofLyHE9ySFUr',
    '6Pf1l8UTeuzYldGtb/d',
  ];
  // The official web frontend's captcha profile, build d254e901. Web tokens
  // and refresh tokens belong to this client, not to the Android client.
  static const _webVersion = '2.0.0';
  static const _webTimestamp = '1792067577543';
  static const _webSalts = [
    'C9qPpZLN8ucRTaTiUMWYS9cQvWOE',
    '+r6CQVxjzJV6LCV',
    'F',
    'pFJRC',
    '9WXYIDGrwTCz2OiVlgZa90qpECPD6olt',
    '/750aCr4lm/Sly/c',
    'RB+DT/gZCrbV',
    '',
    'CyLsf7hdkIRxRm215hl',
    '7xHvLi2tOYP0Y92b',
    'ZGTXXxu8E/MIWaEDB+Sm/',
    '1UI3',
    'E7fP5Pfijd+7K+t6Tg/NhuLq0eEUVChpJSkrKxpO',
    'ihtqpG6FMt65+Xk+tWUH2',
    'NhXXU9rg4XXdzo7u5o',
  ];
  @override
  CloudPlatform get platform => CloudPlatform.pikpak;

  static String _id(String id) {
    require(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id), 'PikPak 文件标识无效，请刷新列表');
    return id;
  }

  static String _client(TokenSession session) =>
      session.field('clientId') == PikPakWebLogin.clientId
      ? PikPakWebLogin.clientId
      : clientId;

  Future<HttpResult> _raw(
    String method,
    String url,
    String device, {
    Json? body,
    String access = '',
    String captcha = '',
    String client = clientId,
  }) => http.request(
    method,
    url,
    headers: {
      'User-Agent': client == PikPakWebLogin.clientId
          ? WebLoginTarget.desktopUserAgent
          : userAgent,
      'X-Device-Id': device,
      'X-Client-Id': client,
      if (client == PikPakWebLogin.clientId) ...{
        'Origin': 'https://mypikpak.com',
        'Referer': 'https://mypikpak.com/',
        'X-Sdk-Version': '8.1.4',
        'X-Protocol-Version': '301',
      },
      if (access.isNotEmpty) 'Authorization': 'Bearer $access',
      if (captcha.isNotEmpty) 'X-Captcha-Token': captcha,
    },
    body: body == null ? null : jsonEncode(body),
    contentType: body == null ? null : 'application/json',
    followRedirects: false,
  );

  Json _checked(HttpResult response) {
    if (response.status == 401) {
      throw const AccountLoginRequired('PikPak 登录已过期，请重新登录');
    }
    final data = response.body.trim().isEmpty && response.successful
        ? <String, dynamic>{}
        : response.json;
    final error = data.str('error');
    if (data.integer('error_code') == 4126 ||
        {
          'unauthenticated',
          'invalid_grant',
          'invalid_refresh_token',
        }.contains(error)) {
      throw const AccountLoginRequired('PikPak 登录已过期，请重新登录');
    }
    if (!response.successful ||
        data.integer('error_code') != 0 ||
        error.isNotEmpty) {
      final message = switch (error) {
        'file_restore_own' => '这是当前账号自己的分享，请在个人网盘中下载',
        'captcha_required' ||
        'captcha_invalid' ||
        'captcha_token_invalid' => 'PikPak 需要安全验证，请切换网页登录后重试',
        'invalid_account_or_password' ||
        'invalid_password' => 'PikPak 账号或密码不正确',
        'space_not_enough' ||
        'storage_space_not_enough' => 'PikPak 空间不足，请清理空间后重试',
        _ =>
          'PikPak 请求失败（${RegExp(r'^[a-zA-Z0-9_]{1,80}$').hasMatch(error) ? error : response.status}），请稍后重试',
      };
      throw AppException(message);
    }
    return data;
  }

  Future<String> _captcha(
    String device,
    String action, {
    String username = '',
    String user = '',
    String previous = '',
    String client = clientId,
  }) async {
    final web = client == PikPakWebLogin.clientId;
    final timestamp = web ? _webTimestamp : '${sessions.now()}';
    final version = web ? _webVersion : '1.21.0';
    final package = web ? 'mypikpak.com' : 'com.pikcloud.pikpak';
    var sign = '$client$version$package$device$timestamp';
    for (final salt in web ? _webSalts : _salts) {
      sign = md5.convert(utf8.encode('$sign$salt')).toString();
    }
    final result = _checked(
      await _raw(
        'POST',
        '$userApi/v1/shield/captcha/init',
        device,
        client: client,
        body: {
          'client_id': client,
          'device_id': device,
          'action': action,
          if (username.isEmpty) 'captcha_token': previous,
          'meta': username.isNotEmpty
              ? {'username': username}
              : {
                  'captcha_sign': '1.$sign',
                  'user_id': user,
                  'package_name': package,
                  'client_version': version,
                  'timestamp': timestamp,
                },
          if (username.isEmpty)
            'redirect_uri': web
                ? 'https://mypikpak.com/loading'
                : 'https://api.mypikpak.com/v1/auth/callback',
        },
      ),
    );
    require(result.str('url').isEmpty, 'PikPak 需要安全验证，请切换网页登录完成验证');
    final token = result.str('captcha_token');
    require(WebTokens.validToken(token), 'PikPak 未返回验证凭据，请使用网页登录');
    return token;
  }

  Future<LoginResult> password(String username, String password) async {
    username = username.trim();
    require(username.isNotEmpty && password.isNotEmpty, '请输入 PikPak 账号和密码');
    final device = newId().replaceAll('-', '');
    final captcha = await _captcha(
      device,
      'POST:$userApi/v1/auth/signin',
      username: username,
    );
    final data = _checked(
      await _raw(
        'POST',
        '$userApi/v1/auth/signin',
        device,
        body: {
          'client_id': clientId,
          'client_secret': _secret,
          'grant_type': 'password',
          'username': username,
          'password': password,
          'captcha_token': captcha,
        },
      ),
    );
    final session = sessions.open(
      Credential(platform.label, {'deviceId': device, 'username': username}),
      candidate: true,
    );
    await sessions.update(session, {
      ...sessions.refreshedFields(session, data),
      'captchaToken': captcha,
      'authType': 'webToken',
    });
    final account = await _account(session);
    return LoginResult(session.credential, account);
  }

  Future<TokenSession> _session(Credential c, {bool candidate = false}) async {
    final session = sessions.open(c, candidate: candidate);
    if (session.field('deviceId').isEmpty) {
      await sessions.gate.run(() async {
        sessions.checkpoint(session);
        if (session.field('deviceId').isEmpty) {
          await sessions.update(session, {
            'deviceId': newId().replaceAll('-', ''),
          });
        }
      });
    }
    await sessions.fresh(session, _renew);
    return session;
  }

  Future<void> _renew(TokenSession session) async {
    final data = _checked(
      await _raw(
        'POST',
        '$userApi/v1/auth/token',
        session.field('deviceId'),
        client: _client(session),
        body: {
          'client_id': _client(session),
          if (_client(session) == clientId) 'client_secret': _secret,
          'grant_type': 'refresh_token',
          'refresh_token': session.refresh,
        },
      ),
    );
    await sessions.update(session, sessions.refreshedFields(session, data));
  }

  Future<Json> _call(
    TokenSession session,
    String method,
    String path, {
    Json? body,
    Json params = const {},
    bool user = false,
  }) async {
    await sessions.fresh(session, _renew);
    final url = query('${user ? userApi : api}$path', params);
    var refreshed = false, recaptcha = false;
    while (true) {
      sessions.checkpoint(session);
      final access = session.access, captcha = session.field('captchaToken');
      final response = await _raw(
        method,
        url,
        session.field('deviceId'),
        client: _client(session),
        access: access,
        captcha: captcha,
        body: body,
      );
      sessions.checkpoint(session);
      if (response.status == 401 && !refreshed) {
        refreshed = true;
        await sessions.fresh(
          session,
          _renew,
          force: true,
          rejectedAccess: access,
        );
        continue;
      }
      final data = response.body.trim().isEmpty && response.successful
          ? <String, dynamic>{}
          : response.json;
      if (!recaptcha &&
          {
            'captcha_required',
            'captcha_invalid',
            'captcha_token_invalid',
          }.contains(data.str('error'))) {
        recaptcha = true;
        await sessions.gate.run(() async {
          sessions.checkpoint(session);
          if (session.field('captchaToken') != captcha) return;
          final actionPath = path.startsWith('/drive/v1/files/')
              ? '/drive/v1/files'
              : path;
          final token = await _captcha(
            session.field('deviceId'),
            '$method:${user ? userApi + path : actionPath}',
            user: session.field('userId'),
            previous: captcha,
            client: _client(session),
          );
          await sessions.update(session, {'captchaToken': token});
        });
        continue;
      }
      return _checked(response);
    }
  }

  Future<CloudAccount> _account(TokenSession session) async {
    final user = await _call(session, 'GET', '/v1/user/me', user: true);
    require(user.str('sub').isNotEmpty, 'PikPak 未返回账号标识');
    await sessions.update(session, {
      'userId': user.str('sub'),
      'nickname': user.str('name').ifEmpty('PikPak 用户'),
    });
    final quota = (await _call(session, 'GET', '/drive/v1/about')).obj('quota');
    return CloudAccount(
      session.field('nickname'),
      used: quota.integer('usage'),
      total: quota.integer('limit'),
    );
  }

  Future<LoginResult> authenticate(Credential c) async {
    final session = await _session(c, candidate: true);
    final account = await _account(session);
    return LoginResult(session.credential, account);
  }

  @override
  Future<CloudAccount> account(Credential c) async =>
      _account(await _session(c));
  @override
  Future<BrowseSession> openPersonal(Credential c) async {
    await _session(c);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: '我的 PikPak',
      rootId: '',
    );
  }

  CloudFile _file(Json data, {String? parent, String token = ''}) {
    final name = data.str('name');
    require(name.isNotEmpty, 'PikPak 文件名称缺失，请刷新列表');
    return CloudFile(
      id: _id(data.str('id')),
      name: name,
      size: data.integer('size'),
      isDirectory: data.str('kind') == 'drive#folder',
      parentId: parent ?? data.str('parent_id'),
      modifiedAt: data.str('modified_time').ifEmpty(data.str('created_time')),
      token: token,
      thumbnailUrl: data.str('thumbnail_link'),
    );
    // PikPak's hash is GCID, not a whole-file SHA1 checksum.
  }

  void _shareStatus(Json data) {
    final status = data.str('share_status');
    if (status.isEmpty || status == 'OK') return;
    throw AppException(switch (status) {
      'PASS_CODE_EMPTY' => 'PikPak 分享需要提取码，请填写后重试',
      'PASS_CODE_ERROR' => 'PikPak 分享提取码错误，请重新填写',
      'DELETED' || 'EXPIRED' || 'NOT_FOUND' => 'PikPak 分享已失效或被取消',
      _ => 'PikPak 分享暂不可访问（$status）',
    });
  }

  Future<Json> _shareRead(
    BrowseSession s, {
    String parent = '',
    String page = '',
    bool opening = false,
  }) async {
    final data = _checked(
      await _raw(
        'GET',
        query('$api/drive/v1/share${opening ? '' : '/detail'}', {
          'share_id': s.meta('shareId'),
          'limit': 100,
          'thumbnail_size': 'SIZE_SMALL',
          if (opening && s.meta('code').isNotEmpty) 'pass_code': s.meta('code'),
          if (!opening) 'pass_code_token': s.meta('passCodeToken'),
          if (parent.isNotEmpty) 'parent_id': parent,
          if (page.isNotEmpty) 'page_token': page,
        }),
        s.meta('deviceId'),
      ),
    );
    _shareStatus(data);
    require(data['files'] is List, 'PikPak 分享列表格式异常');
    return data;
  }

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    final id = LinkParser.shareId(platform, link.url);
    require(id != null, '无法识别 PikPak 分享链接');
    final metadata = {
      'shareId': id!,
      'code': link.passcode ?? '',
      'deviceId': newId().replaceAll('-', ''),
    };
    final draft = BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: 'PikPak 分享',
      rootId: '',
      metadata: metadata,
    );
    final data = await _shareRead(draft, opening: true);
    require(data.str('pass_code_token').isNotEmpty, 'PikPak 未返回分享访问凭据');
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: data.str('title').ifEmpty('PikPak 分享'),
      rootId: '',
      metadata: {...metadata, 'passCodeToken': data.str('pass_code_token')},
      sourceLink: link,
    );
  }

  Future<List<CloudFile>> _personalList(
    TokenSession session,
    String parent,
  ) async {
    final result = <CloudFile>[];
    final pages = <String>{};
    var page = '';
    do {
      require(pages.add(page), 'PikPak 分页重复，请稍后刷新');
      final data = await _call(
        session,
        'GET',
        '/drive/v1/files',
        params: {
          'parent_id': parent,
          'limit': 500,
          'page_token': page,
          'thumbnail_size': 'SIZE_SMALL',
          'with_audit': false,
          'filters': jsonEncode({
            'trashed': {'eq': false},
          }),
        },
      );
      require(data['files'] is List, 'PikPak 文件列表格式异常');
      result.addAll(data.list('files').map((v) => _file(asJson(v))));
      page = data.str('next_page_token');
    } while (page.isNotEmpty);
    return result;
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parentId,
    Credential? c,
  ) async {
    require(s.platform == platform, '网盘来源不一致');
    if (s.mode == BrowseMode.personal) {
      if (c == null) throw const AccountLoginRequired('请先登录 PikPak');
      return _personalList(await _session(c), parentId);
    }
    // A folder carries its ancestry, allowing queued nested share restores after restart.
    final ancestors = parentId.isEmpty
        ? <String>[]
        : parentId.split('/').map(_id).toList();
    final result = <CloudFile>[];
    final pages = <String>{};
    var page = '';
    do {
      require(pages.add(page), 'PikPak 分享分页重复，请重新解析');
      final data = await _shareRead(
        s,
        parent: ancestors.lastOrNull ?? '',
        page: page,
      );
      for (final row in data.list('files')) {
        final f = _file(
          asJson(row),
          parent: parentId,
          token: jsonEncode(ancestors),
        );
        result.add(
          f.isDirectory
              ? CloudFile(
                  id: [...ancestors, f.id].join('/'),
                  name: f.name,
                  isDirectory: true,
                  parentId: parentId,
                  modifiedAt: f.modifiedAt,
                  token: f.token,
                )
              : f,
        );
      }
      page = data.str('next_page_token');
    } while (page.isNotEmpty);
    return result;
  }

  Future<CloudFile> _folder(
    TokenSession session,
    String parent,
    String name,
  ) async {
    cloudFileName(name);
    return _file(
      (await _call(
        session,
        'POST',
        '/drive/v1/files',
        body: {'kind': 'drive#folder', 'name': name, 'parent_id': parent},
      )).obj('file'),
    );
  }

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async {
    personal(s);
    return _folder(await _session(c), parent, name);
  }

  @override
  Future<void> rename(
    BrowseSession s,
    CloudFile f,
    String name,
    Credential c,
  ) async {
    personal(s);
    cloudFileName(name);
    await _call(
      await _session(c),
      'PATCH',
      '/drive/v1/files/${_id(f.id)}',
      body: {'name': name},
    );
  }

  Future<void> _batch(
    TokenSession session,
    List<CloudFile> files,
    String op, {
    String? target,
  }) async {
    for (var offset = 0; offset < files.length; offset += 100) {
      await _call(
        session,
        'POST',
        '/drive/v1/files:$op',
        body: {
          'ids': files.skip(offset).take(100).map((f) => _id(f.id)).toList(),
          if (target != null) 'to': {'parent_id': target},
        },
      );
    }
  }

  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    personal(s);
    await _batch(await _session(c), files, 'batchMove', target: target);
  }

  @override
  Future<void> delete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    personal(s);
    await _batch(await _session(c), files, 'batchTrash');
  }

  Future<void> deleteTemporaryFolder(
    String id,
    String name,
    Credential c,
  ) async {
    final session = await _session(c);
    final folder = (await _personalList(
      session,
      '',
    )).where((f) => f.id == id).firstOrNull;
    if (folder == null) return;
    require(folder.isDirectory && folder.name == name, 'PikPak 临时目录已变化，停止清理');
    await _call(session, 'DELETE', '/drive/v1/files/${_id(id)}');
  }

  Future<void> _restore(
    TokenSession session,
    BrowseSession s,
    List<CloudFile> files,
    String target,
  ) async {
    require(
      s.mode == BrowseMode.share && s.platform == platform,
      '请先打开 PikPak 分享',
    );
    final groups = <String, List<CloudFile>>{};
    for (final f in files) {
      groups.putIfAbsent(f.token.ifEmpty('[]'), () => []).add(f);
    }
    for (final group in groups.entries) {
      final ancestors = (jsonDecode(group.key) as List)
          .map((v) => _id('$v'))
          .toList();
      for (var offset = 0; offset < group.value.length; offset += 100) {
        final data = await _call(
          session,
          'POST',
          '/drive/v1/share/restore',
          body: {
            'share_id': s.meta('shareId'),
            'pass_code_token': s.meta('passCodeToken'),
            'file_ids': group.value
                .skip(offset)
                .take(100)
                .map((f) => _id(f.id.split('/').last))
                .toList(),
            'ancestor_ids': ancestors,
            'parent_id': target,
            'specify_parent_id': true,
          },
        );
        _shareStatus(data);
        final task = data.str('restore_task_id');
        require(task.isNotEmpty, 'PikPak 未返回转存任务，请刷新目标目录确认');
        var complete = false;
        for (var attempt = 0; attempt < 60; attempt++) {
          final status = await _call(
            session,
            'GET',
            '/drive/v1/tasks/${_id(task)}',
          );
          final phase = status.str('phase');
          if (phase == 'PHASE_TYPE_COMPLETE') {
            complete = true;
            break;
          }
          require(
            !{'PHASE_TYPE_ERROR', 'PHASE_TYPE_CANCELED'}.contains(phase),
            'PikPak 转存失败，请检查容量或分享状态',
          );
          await RequestScope.wait(const Duration(seconds: 1));
        }
        require(complete, 'PikPak 转存仍在处理中，请稍后查看网盘');
      }
    }
  }

  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async => _restore(await _session(c), s, files, target);

  @override
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  ) async {
    personal(s);
    require(files.isNotEmpty, '请选择要分享的文件');
    final code = options.passcode ?? '';
    require(
      code.isEmpty || RegExp(r'^[A-Za-z0-9]{4,10}$').hasMatch(code),
      'PikPak 提取码需要 4–10 位字母或数字',
    );
    final data = await _call(
      await _session(c),
      'POST',
      '/drive/v1/share',
      body: {
        'file_ids': files.map((f) => _id(f.id)).toList(),
        'expiration_days': options.expiryDays ?? -1,
        'share_to': code.isEmpty ? 'publiclink' : 'encryptedlink',
        'pass_code_option': code.isEmpty ? 'NOT_REQUIRED' : 'REQUIRED',
        if (code.isNotEmpty) 'custom_pass_code': code,
      },
    );
    final url = data.str('share_url');
    require(LinkParser.shareId(platform, url) != null, 'PikPak 未返回有效分享链接');
    return ShareCreation(url, data.str('pass_code'), options.title);
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile file,
    Credential? c,
  ) async {
    require(s.platform == platform && !file.isDirectory, '请选择 PikPak 文件');
    if (c == null) throw const AccountLoginRequired('请先登录 PikPak，分享文件需转存后下载');
    final session = await _session(c);
    var id = file.id;
    DownloadCleanup? cleanup;
    if (s.mode == BrowseMode.share) {
      final folder = await OperationProgress.step(
        OperationStage.createTemporary,
        () => _folder(session, '', 'AsterLink临时转存_${newId()}'),
      );
      cleanup = DownloadCleanup(
        url: '',
        action: {
          'kind': 'temporary-folder',
          'platform': platform.key,
          'folderId': folder.id,
          'name': folder.name,
          'accountRevision': session.credential.updatedAt,
        },
      );
      await stageCleanup?.call(cleanup);
      await OperationProgress.step(
        OperationStage.transfer,
        () => _restore(session, s, [file], folder.id),
      );
      var copied = <CloudFile>[];
      for (var attempt = 0; attempt < 8; attempt++) {
        copied = (await _personalList(session, folder.id))
            .where(
              (f) =>
                  !f.isDirectory && f.name == file.name && f.size == file.size,
            )
            .toList();
        if (copied.isNotEmpty) break;
        await RequestScope.wait(const Duration(milliseconds: 750));
      }
      require(copied.length == 1, 'PikPak 转存后的文件尚未就绪，请稍后重试');
      id = copied.single.id;
    }
    final data = await OperationProgress.step(
      OperationStage.downloadLink,
      () => _call(
        session,
        'GET',
        '/drive/v1/files/${_id(id)}',
        params: {'thumbnail_size': 'SIZE_SMALL'},
      ),
    );
    final url = data
        .obj('links')
        .obj('application/octet-stream')
        .str('url')
        .ifEmpty(data.str('web_content_link'));
    require(
      file.size <= 0 || data.integer('size', file.size) == file.size,
      'PikPak 返回的文件大小与所选文件不一致',
    );
    return DownloadSpec(
      url: checkedCloudUrl(url, 'PikPak 尚未生成下载地址，请稍后重试或检查账号权益'),
      fileName: file.name,
      expectedSize: data.integer('size', file.size),
      headers: {'User-Agent': userAgent},
      profile: 'pikpak',
      cleanup: cleanup,
    );
  }

  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) async {
    personal(s);
    cloudFileName(source.name);
    final session = await _session(c);
    final io = UploadIO(http, source, onProgress);
    final size = source.size;
    final block = size > 0 && size < 0x8000000
        ? 0x40000
        : size >= 0x8000000 && size < 0x10000000
        ? 0x80000
        : size <= 0x10000000 || size > 0x20000000
        ? 0x200000
        : 0x100000;
    final hashes = <int>[];
    for (var offset = 0; offset < size; offset += block) {
      sessions.checkpoint(session);
      final end = (offset + block).clamp(0, size);
      final bytes = await io.bytes(offset, end);
      require(bytes.length == end - offset, '本地文件已变化，请重新选择');
      hashes.addAll(sha1.convert(bytes).bytes);
      io.progress(UploadPhase.preparing, end);
    }
    final data = await _call(
      session,
      'POST',
      '/drive/v1/files',
      body: {
        'kind': 'drive#file',
        'name': source.name,
        'size': '$size',
        'hash': sha1.convert(hashes).toString().toUpperCase(),
        'upload_type': 'UPLOAD_TYPE_RESUMABLE',
        'parent_id': parent,
        'body': {'duration': '', 'width': '', 'height': ''},
        'objProvider': {'provider': 'UPLOAD_TYPE_UNKNOWN'},
      },
    );
    final file = _file(data.obj('file'));
    var completed = data.obj('file').str('phase') == 'PHASE_TYPE_COMPLETE';
    try {
      if (!completed) {
        final params = data.obj('resumable').obj('params');
        await io.oss(
          endpoint: params.str('endpoint'),
          bucket: params.str('bucket'),
          object: params.str('key'),
          access: params.str('access_key_id'),
          secret: params.str('access_key_secret'),
          token: params.str('security_token'),
          exactEndpoint: true,
          contentType: 'application/octet-stream',
          abortOnCancel: true,
        );
      }
      io.progress(UploadPhase.finishing, size);
      for (var attempt = 0; attempt < 15; attempt++) {
        final detail = await _call(
          session,
          'GET',
          '/drive/v1/files/${_id(file.id)}',
        );
        if (detail.str('phase') == 'PHASE_TYPE_COMPLETE') {
          require(detail.integer('size') == size, 'PikPak 上传后的文件大小不一致');
          completed = true;
          return _file(detail);
        }
        require(detail.str('phase') != 'PHASE_TYPE_ERROR', 'PikPak 上传处理失败');
        await RequestScope.wait(const Duration(seconds: 1));
      }
      throw const AppException('PikPak 仍在处理上传文件，请稍后刷新');
    } finally {
      if (!completed) {
        try {
          await RequestScope().run(() async {
            // Only remove this upload's unfinished node; a completed file may
            // have reached the server just before cancellation or a timeout.
            final detail = await _call(
              session,
              'GET',
              '/drive/v1/files/${_id(file.id)}',
            );
            if (detail.str('phase') == 'PHASE_TYPE_COMPLETE') return;
            require(
              detail.str('id') == file.id &&
                  detail.str('name') == source.name &&
                  detail.str('parent_id') == parent,
              'PikPak 上传文件已变化，停止清理',
            );
            await _call(session, 'DELETE', '/drive/v1/files/${_id(file.id)}');
          });
        } catch (_) {}
      }
    }
  }
}
