import 'dart:async';
import 'dart:convert';
import '../../core/json.dart';
import '../../domain/baidu_share_route.dart';
import '../../domain/models.dart';
import '../../domain/public_share_route.dart';
import '../http.dart';
import '../state_store.dart';
import '../parser_rules/hub.dart';
import '../parser_rules/rule.dart';
import 'baidu_public_password.dart';

typedef _PublicPassword = ({
  ParserSharedPassword shared,
  BaiduPublicPassword? automatic,
  bool manual,
});

/// Share-only integration. Requests contain no personal account credentials.
class BaiduPublicParser {
  BaiduPublicParser(
    this.http, {
    CredentialStore? store,
    BaiduPublicPasswords? passwords,
    this.hub,
    DateTime Function()? clock,
  }) : passwords = passwords ?? BaiduPublicPasswords(http, store: store),
       clock = clock ?? DateTime.now;

  final JsonHttp http;
  final BaiduPublicPasswords passwords;
  final ParserRuleHub? hub;
  final DateTime Function() clock;
  static const site = 'https://mf.dg22.top';
  static const _requestUa = 'Dart/3.13 (dart:io)';
  static const _fallbackDownloadUa =
      'Mozilla/5.0 (Linux; Android 15) Chrome/134.0 Mobile';
  final _initialLists = <String, List<CloudFile>>{};
  final _fileDlinks =
      <(String, String), ({DateTime expiresAt, Map<String, String> links})>{};
  final _downloadGate = AsyncGate();
  final _directoryHints =
      <
        (String, String),
        ({DateTime expiresAt, Json state, Map<String, Json> files})
      >{};

  String _surl(ParsedLink link) {
    require(
      link.platform == CloudPlatform.baidu &&
          link.kind == LinkKind.cloudShare &&
          RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(link.shareId ?? ''),
      '百度分享链接不完整，请重新解析',
    );
    // LinkParser stores the short ID without the /s/1 prefix.
    return '1${link.shareId}';
  }

  Future<Json> _request(
    String operation,
    Json body, {
    String? passwordGrant,
  }) async {
    RequestScope.checkpoint();
    await hub?.ensurePublicParsing(CloudPlatform.baidu);
    var password = await _password('mf_dg22', passwordGrant);
    for (var attempt = 0; attempt < 2; attempt++) {
      final (result, response) = await _send(
        operation,
        body,
        password.shared.value,
      );
      // Live password failures use HTTP 400 + code 20016. This is distinct
      // from a Baidu share's extraction code or the personal account login.
      if (response?.integer('code') == 20016) {
        await _rejectPassword(
          'mf_dg22',
          password,
          passwordGrant,
          deferRetry: attempt > 0,
        );
        if (attempt > 0 || password.manual) {
          throw const ParserPasswordRequired('mf_dg22');
        }
        final updated = await _password('mf_dg22', null, force: true);
        if (updated.shared.value == password.shared.value) {
          throw const ParserPasswordRequired('mf_dg22');
        }
        password = updated;
        continue;
      }
      if (!result.successful) {
        throw HttpRequestFailure(
          '百度公益解析暂不可用（HTTP ${result.status}），可切换为“账号下载”',
          kind: 'baidu_public_parser',
          status: result.status,
          retryable: {408, 502, 503, 504}.contains(result.status),
        );
      }
      if (response == null) {
        throw const AppException('百度公益解析响应格式异常，可切换为“账号下载”');
      }
      if (response.integer('code') != 200) {
        var message = response.str('message').trim();
        if (message.isEmpty || message.length > 180 || message.contains('<')) {
          message = '解析站返回错误（${response.str('code').ifEmpty('未知')}）';
        }
        // Do not echo a password if an upstream error happens to contain it.
        message = message.replaceAll(password.shared.value, '[已隐藏]');
        throw AppException('百度公益解析：$message，可切换为“账号下载”');
      }
      return response;
    }
    throw const AppException('公益解析密码更新失败，可切换为“账号下载”');
  }

  Future<(HttpResult, Json?)> _send(
    String operation,
    Json body,
    String password,
  ) async {
    RequestScope.checkpoint();
    final result = await http.request(
      'POST',
      '$site/api/v1/user/parse/$operation',
      body: encoded({...body, 'parse_password': password}),
      headers: const {
        'User-Agent': _requestUa,
        'Accept': 'application/json',
        'Origin': site,
        'Referer': '$site/user/parse',
      },
      contentType: 'application/json;charset=utf-8',
      followRedirects: false,
    );
    RequestScope.checkpoint();
    require(result.body.length <= 8 * 1024 * 1024, '百度公益解析响应过大，请缩小目录范围');
    Json? response;
    try {
      response = result.json;
    } on AppException {
      // Preserve HTTP errors even when the body is a gateway HTML page.
    }
    return (result, response);
  }

  Future<Json> _fileList(
    ParsedLink link,
    String parent, {
    String? passwordGrant,
  }) async {
    require(parent.startsWith('/'), '百度分享文件夹路径无效，请重新解析');
    final surl = _surl(link);
    final response = await _request('get_file_list', {
      'url': 'https://pan.baidu.com/s/$surl',
      'surl': surl,
      'pwd': link.passcode ?? '',
      'dir': parent,
    }, passwordGrant: passwordGrant);
    final data = response.obj('data');
    require(data['list'] is List, '百度公益解析未返回文件列表，请稍后重试');
    return data;
  }

  List<CloudFile> _files(
    Json data,
    String parent,
    String scope, {
    CloudPlatform platform = CloudPlatform.baidu,
  }) {
    final files = <CloudFile>[];
    final dlinks = <String, String>{};
    final seen = <String>{};
    for (final entry in data.list('list')) {
      final id = entry.str('fs_id');
      final name = entry.str('server_filename').ifEmpty(entry.str('filename'));
      final directory =
          entry.integer('isdir') == 1 ||
          entry.boolean('isdir') ||
          entry.integer('is_dir') == 1 ||
          entry.boolean('is_dir');
      final path = entry.str('path');
      require(
        id.isNotEmpty &&
            name.isNotEmpty &&
            (!directory || path.startsWith('/')),
        '公益解析文件信息不完整，请重新解析',
      );
      if (!seen.add(id)) continue;
      if (!directory) {
        dlinks[id] = entry['dlink'] is String ? entry['dlink'] as String : '';
      }
      final hash = entry.str('md5');
      final hasHash = RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(hash);
      files.add(
        CloudFile(
          id: id,
          name: name,
          size: entry.integer('size'),
          isDirectory: directory,
          parentId: parent,
          token: path,
          modifiedAt: entry
              .str('server_mtime')
              .ifEmpty(entry.str('local_mtime')),
          hashType: hasHash ? 'md5' : null,
          hashValue: hasHash ? hash.toLowerCase() : null,
        ),
      );
    }
    // Signed source hints stay in a bounded memory cache. Restored tasks and
    // expired entries reload the selected directory before requesting a link.
    final key = (scope, parent);
    _fileDlinks.remove(key);
    _fileDlinks[key] = (
      expiresAt: clock().add(const Duration(minutes: 10)),
      links: dlinks,
    );
    while (_fileDlinks.length > 16) {
      _fileDlinks.remove(_fileDlinks.keys.first);
    }
    if (platform != CloudPlatform.baidu) {
      _directoryHints.remove(key);
      _directoryHints[key] = (
        expiresAt: clock().add(const Duration(minutes: 5)),
        state: data.obj('state'),
        files: {for (final f in data.list('list')) f.str('fs_id'): f},
      );
      while (_directoryHints.length > 16) {
        _directoryHints.remove(_directoryHints.keys.first);
      }
    }
    return files;
  }

  String _fileScope(BrowseSession session) => session
      .meta('parserInitialList')
      .ifEmpty('${session.meta('parserSiteId')}:${_link(session).url}');

  Future<String> _fileDlink(BrowseSession session, CloudFile file) async {
    final parent = file.parentId.ifEmpty('/');
    final key = (_fileScope(session), parent);
    final cached = _fileDlinks[key];
    if (cached == null ||
        !cached.expiresAt.isAfter(clock()) ||
        !cached.links.containsKey(file.id)) {
      _initialLists.remove(session.meta('parserInitialList'));
      await list(session, parent);
    }
    return _fileDlinks[key]?.links[file.id] ?? '';
  }

  Future<BrowseSession> openShare(
    ParsedLink link, {
    String? parserSiteId,
    String? passwordGrant,
  }) async {
    final remote = await hub?.forNewShare(
      siteId: parserSiteId,
      platform: link.platform ?? CloudPlatform.baidu,
    );
    if (remote != null) {
      return _openRemoteShare(link, remote, passwordGrant: passwordGrant);
    }
    require(link.platform == CloudPlatform.baidu, '该网盘暂无可用公益通道，请切换常规解析');
    final data = await _fileList(link, '/', passwordGrant: passwordGrant);
    require(
      data.str('uk').isNotEmpty && data.str('shareid').isNotEmpty,
      '百度公益解析缺少分享信息，请重新解析',
    );
    final initialId = newId();
    _initialLists[initialId] = _files(data, '/', initialId);
    while (_initialLists.length > 16) {
      _initialLists.remove(_initialLists.keys.first);
    }
    return BrowseSession(
      platform: CloudPlatform.baidu,
      mode: BrowseMode.share,
      title: data.str('title').ifEmpty('百度分享'),
      rootId: '/',
      metadata: {
        BaiduShareRoute.metadataKey: BaiduShareRoute.publicParser.key,
        'shortId': link.shareId!,
        'shareId': data.str('shareid'),
        'uk': data.str('uk'),
        'sekey': data.str('randsk'),
        'parserInitialList': initialId,
        'parserPasswordGrant': ?passwordGrant,
      },
      sourceLink: link,
    );
  }

  ParsedLink _link(BrowseSession session) {
    require(
      PublicShareRoute.uses(session) &&
          session.sourceLink?.platform == session.platform,
      '原分享信息缺失，请重新解析',
    );
    return session.sourceLink!;
  }

  Future<void> ensurePassword(BrowseSession session) async {
    await hub?.ensurePublicParsing(session.platform);
    final site = session.meta('parserRuleBundle').isEmpty
        ? null
        : await _snapshot(session);
    if (site != null && !site.rule.requiresPassword) return;
    await _password(
      site?.id ?? 'mf_dg22',
      session.meta('parserPasswordGrant'),
      site: site,
    );
  }

  Future<List<CloudFile>> list(BrowseSession session, String parent) async {
    await hub?.ensurePublicParsing(session.platform);
    final link = _link(session);
    if (parent == '/') {
      final cached = _initialLists.remove(session.meta('parserInitialList'));
      if (cached != null) return List.of(cached);
    }
    if (session.meta('parserRuleBundle').isNotEmpty) {
      final site = await _snapshot(session);
      final result = await _remoteRequest(site, 'list', {
        ..._remoteInput(link, parent),
        'state': _remoteState(session),
      }, passwordGrant: session.meta('parserPasswordGrant'));
      return _files(
        result,
        parent,
        _fileScope(session),
        platform: session.platform,
      );
    }
    return _files(
      await _fileList(
        link,
        parent,
        passwordGrant: session.meta('parserPasswordGrant'),
      ),
      parent,
      _fileScope(session),
    );
  }

  Future<DownloadSpec> download(BrowseSession session, CloudFile file) =>
      _downloadGate.run(() async {
        await hub?.ensurePublicParsing(session.platform);
        final link = _link(session);
        require(!file.isDirectory, '文件夹不能直接下载');
        if (session.meta('parserRuleBundle').isNotEmpty) {
          return _remoteDownload(session, file, link);
        }
        final fileId = int.tryParse(file.id);
        require(fileId != null && fileId > 0, '百度文件标识无效，请重新解析');
        final parent = file.parentId.ifEmpty('/');
        require(parent.startsWith('/'), '百度分享文件夹路径无效，请重新解析');
        final dlink = await _fileDlink(session, file);
        final response = await _request('get_download_links', {
          'randsk': session.meta('sekey'),
          'uk': session.meta('uk'),
          'shareid': session.meta('shareId'),
          'fs_id': [fileId],
          'dlink': dlink.isEmpty ? <String>[] : [dlink],
          'surl': _surl(link),
          'dir': parent,
          'pwd': link.passcode ?? '',
          'token': 'guest',
          'download_folder': 0,
        }, passwordGrant: session.meta('parserPasswordGrant'));
        final entries = response.list('data');
        final item = entries
            .where((entry) => entry.str('fs_id') == file.id)
            .firstOrNull;
        require(item != null, '百度公益解析返回的文件不一致，请重新解析');
        final candidates = item!['urls'];
        final urls = candidates is List
            ? candidates.whereType<String>()
            : const <String>[];
        final uri = urls
            .map(Uri.tryParse)
            .whereType<Uri>()
            .where(
              (uri) =>
                  {'http', 'https'}.contains(uri.scheme) &&
                  uri.userInfo.isEmpty &&
                  !uri.hasFragment &&
                  ['baidu.com', 'baidupcs.com', 'baidubce.com'].any(
                    (domain) =>
                        uri.host == domain || uri.host.endsWith('.$domain'),
                  ),
            )
            .firstOrNull;
        require(uri != null, '百度公益解析没有返回有效下载地址，可切换为“账号下载”');
        // Live responses use "ua"; older site versions used "user_agent".
        final ua = item
            .str('ua')
            .ifEmpty(item.str('user_agent'))
            .ifEmpty(_fallbackDownloadUa);
        require(
          ua.length <= 1024 && !RegExp(r'[\x00-\x1f\x7f]').hasMatch(ua),
          '百度公益解析返回的下载参数无效',
        );
        return DownloadSpec(
          url: uri.toString(),
          fileName: file.name,
          expectedSize: file.size,
          checksumType: file.hashType,
          checksumValue: file.hashValue,
          headers: {'User-Agent': ua, 'Accept-Encoding': 'identity'},
          profile: BaiduShareRoute.publicDownloadProfile,
        );
      });

  Json _remoteInput(ParsedLink link, String parent) {
    require(
      link.kind == LinkKind.cloudShare &&
          PublicShareRoute.platforms.contains(link.platform),
      '分享链接类型不受当前解析通道支持',
    );
    final baidu = link.platform == CloudPlatform.baidu;
    require(
      parent.isNotEmpty &&
          parent.length <= 4096 &&
          !RegExp(r'[\x00-\x1f\x7f]').hasMatch(parent) &&
          (!baidu || parent.startsWith('/')),
      '分享文件夹标识无效，请重新解析',
    );
    final surl = baidu ? _surl(link) : link.shareId ?? '';
    require(surl.isNotEmpty, '分享编号缺失，请重新解析');
    return {
      'url': baidu ? 'https://pan.baidu.com/s/$surl' : link.url,
      'surl': surl,
      'platform': link.platform!.name,
      'pwd': link.passcode ?? '',
      'dir': parent,
    };
  }

  Future<_PublicPassword> _password(
    String id,
    String? grant, {
    ParserSite? site,
    bool force = false,
  }) async {
    RequestScope.checkpoint();
    final approved = hub?.grantedPassword(id, grant);
    if (approved != null) {
      return (shared: approved, automatic: null, manual: true);
    }
    // Rules for an existing task stay pinned; password policy follows the
    // newest signed site settings, including when a cached password exists.
    final current = hub?.currentSite(id) ?? site;
    if (current?.passwordPrompt.autoFill == false ||
        (current?.passwordPrompt.webFlow != null &&
            current?.passwordPrompt.webFlow?.sharePassword != true)) {
      throw ParserPasswordRequired(id);
    }
    if (id == 'mf_dg22') throw ParserPasswordRequired(id);
    late ParserSharedPassword value;
    try {
      value = await hub!.password(id, force: force);
    } catch (_) {
      RequestScope.checkpoint();
      if (current?.passwordPrompt.webFlow != null) {
        throw ParserPasswordRequired(id);
      }
      rethrow;
    }
    final latest = hub!.currentSite(id)?.passwordPrompt;
    if (latest?.autoFill == false ||
        (latest?.webFlow != null && latest?.webFlow?.sharePassword != true)) {
      throw ParserPasswordRequired(id);
    }
    return (shared: value, automatic: null, manual: false);
  }

  Future<void> _rejectPassword(
    String id,
    _PublicPassword value,
    String? grant, {
    bool deferRetry = false,
  }) async {
    if (value.shared.version >= 0) await hub?.reportRejected(id, value.shared);
    if (value.manual) await hub?.revokePasswordGrant(grant);
  }

  Future<Json> _remoteRequest(
    ParserSite site,
    String operation,
    Json input, {
    String? passwordGrant,
  }) async {
    final service = hub!;
    await service.ensurePublicParsing(site.rule.platform);
    if (site.rule.runsOnServer) {
      return service.server.execute(site.rule, site.version, operation, input);
    }
    final currentSite = service.currentSite(site.id) ?? site;
    if (!site.rule.requiresPasswordFor(operation) &&
        (!site.rule.requiresPassword || currentSite.passwordPrompt.autoFill)) {
      try {
        return await service.engine.execute(
          site.rule,
          operation,
          input,
          password: '',
          device: await service.device(site.rule.deviceGroup),
        );
      } on ParserRuleError catch (error) {
        // A site can move its password gate from download to list at any time.
        if (!site.rule.requiresPassword || error.code != 'password_rejected') {
          rethrow;
        }
      }
    }
    var password = await _password(site.id, passwordGrant, site: site);
    final device = await service.device(site.rule.deviceGroup);
    for (var attempt = 0; attempt < 2; attempt++) {
      RequestScope.checkpoint();
      try {
        final result = await service.engine.execute(
          site.rule,
          operation,
          input,
          password: password.shared.value,
          device: device,
        );
        RequestScope.checkpoint();
        unawaited(service.shareGrantedPassword(site.id, passwordGrant));
        return result;
      } on ParserRuleError catch (error) {
        if (error.code != 'password_rejected') rethrow;
        await _rejectPassword(
          site.id,
          password,
          passwordGrant,
          deferRetry: attempt > 0,
        );
        if (attempt > 0 || password.manual) {
          throw ParserPasswordRequired(site.id, '当前解析密码已失效，请在“解析密码”中补充后重试');
        }
        final updated = await _password(site.id, null, site: site, force: true);
        if (updated.shared.value == password.shared.value) {
          throw ParserPasswordRequired(site.id, '解析密码尚未更新，请补充当前密码后重试');
        }
        password = updated;
      }
    }
    throw ParserPasswordRequired(site.id);
  }

  Future<BrowseSession> _openRemoteShare(
    ParsedLink link,
    ParserSite site, {
    String? passwordGrant,
  }) async {
    require(site.rule.platform == link.platform, '解析通道与网盘不匹配，请重新选择');
    Json data;
    try {
      data = await _remoteRequest(
        site,
        'list',
        _remoteInput(link, '/'),
        passwordGrant: passwordGrant,
      );
    } on ParserRuleError catch (error) {
      if (!error.suggestsRuleUpdate || !await hub!.refreshAfterFailure()) {
        rethrow;
      }
      final updated = await hub!.forNewShare(
        siteId: site.id,
        platform: site.rule.platform,
      );
      if (updated == null || updated.bundleId == site.bundleId) rethrow;
      site = updated;
      data = await _remoteRequest(
        site,
        'list',
        _remoteInput(link, '/'),
        passwordGrant: passwordGrant,
      );
    }
    final initialId = newId();
    _initialLists[initialId] = _files(
      data,
      '/',
      initialId,
      platform: site.rule.platform,
    );
    while (_initialLists.length > 16) {
      _initialLists.remove(_initialLists.keys.first);
    }
    final state = data.obj('state');
    return BrowseSession(
      platform: site.rule.platform,
      mode: BrowseMode.share,
      title: data.str('title').ifEmpty('${site.rule.platform.shortName}分享'),
      rootId: '/',
      sourceLink: link,
      metadata: {
        if (site.rule.platform == CloudPlatform.baidu)
          BaiduShareRoute.metadataKey: BaiduShareRoute.publicParser.key,
        PublicShareRoute.metadataKey: 'remote',
        'shortId': link.shareId!,
        'shareId': state.str('shareid'),
        'uk': state.str('uk'),
        'sekey': state.str('randsk'),
        'parserInitialList': initialId,
        'parserRuleBundle': site.bundleId,
        'parserSiteId': site.id,
        'parserPasswordGrant': ?passwordGrant,
        'parserRuleVersion': '${site.version}',
        'parserState': encoded(state),
      },
    );
  }

  Future<ParserSite> _snapshot(BrowseSession session) async {
    require(hub != null && hub!.configured, '当前安装包未配置规则服务，请重新解析分享');
    final site = await hub!.snapshot(
      session.meta('parserRuleBundle'),
      session.meta('parserSiteId'),
    );
    require(site.rule.platform == session.platform, '分享与解析规则的网盘不一致，请重新解析');
    return site;
  }

  Future<DownloadSpec> _remoteDownload(
    BrowseSession session,
    CloudFile file,
    ParsedLink link,
  ) async {
    final site = await _snapshot(session);
    var state = _remoteState(session);
    Json extra = {};
    if (session.platform != CloudPlatform.baidu && !site.rule.runsOnServer) {
      final parent = file.parentId.ifEmpty('/');
      final key = (_fileScope(session), parent);
      var hints = _directoryHints[key];
      if (hints == null ||
          !hints.expiresAt.isAfter(clock()) ||
          !hints.files.containsKey(file.id)) {
        _initialLists.remove(session.meta('parserInitialList'));
        await list(session, parent);
        hints = _directoryHints[key];
      }
      final fresh = hints?.files[file.id];
      require(
        fresh != null &&
            fresh.integer('isdir') == 0 &&
            fresh.str('server_filename') == file.name &&
            !(file.size > 0 &&
                fresh.integer('size') > 0 &&
                file.size != fresh.integer('size')),
        '分享文件内容已变化，请重新解析',
      );
      state = {...state, ...hints!.state};
      extra = fresh!.obj('extra');
    }
    final dlink = site.id == 'mf_dg22' ? await _fileDlink(session, file) : '';
    Json result;
    try {
      result = await _remoteRequest(site, 'download', {
        ..._remoteInput(link, file.parentId.ifEmpty('/')),
        'state': state,
        'file': {
          'fs_id': file.id,
          'server_filename': file.name,
          'size': file.size,
          'path': file.token,
          'extra': extra,
          if (site.id == 'mf_dg22') 'dlink': dlink,
        },
      }, passwordGrant: session.meta('parserPasswordGrant'));
    } on ParserRuleError catch (error) {
      if (error.suggestsRuleUpdate && await hub!.refreshAfterFailure()) {
        throw const AppException('解析规则已有更新，请重新解析分享后下载；正在下载的其他文件不受影响');
      }
      rethrow;
    }
    final urls = (result['urls'] as List).whereType<String>();
    final url = urls.firstWhere(site.rule.permitsDownload);
    final ua = result
        .str('ua')
        .ifEmpty(site.rule.json.str('downloadUserAgent'))
        .ifEmpty(_fallbackDownloadUa);
    return DownloadSpec(
      url: url,
      fileName: file.name,
      expectedSize: file.size,
      checksumType: file.hashType,
      checksumValue: file.hashValue,
      headers: {
        'User-Agent': ua,
        'Accept-Encoding': 'identity',
        ...site.rule.downloadHeaders(result),
      },
      profile: PublicShareRoute.profile(session.platform),
    );
  }

  Json _remoteState(BrowseSession session) {
    try {
      return asJson(jsonDecode(session.meta('parserState')));
    } catch (_) {
      throw const AppException('分享状态信息缺失，请重新解析');
    }
  }
}
