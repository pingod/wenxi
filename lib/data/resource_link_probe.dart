import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../core/json.dart';
import '../domain/aliyun_share.dart';
import '../domain/models.dart';
import '../domain/resource_search.dart';
import '../domain/tianyi_share.dart';
import 'http.dart';
import 'providers/c139.dart' show C139Protocol;
import 'providers/wopan.dart' show WopanProtocol;
import 'resource_link_checks.dart';

/// Built-in, anonymous, read-only probes. Requests go from this device directly
/// to official netdisk hosts; no search server, parser service or account store.
class LocalResourceLinkCheckApi extends ResourceLinkCheckApi {
  LocalResourceLinkCheckApi({
    JsonHttp? http,
    this.timeout = const Duration(seconds: 16),
    this.requestTimeout = const Duration(seconds: 6),
    this.clock = DateTime.now,
  }) : http = http ?? DioJsonHttp(),
       _ownsHttp = http == null;
  final JsonHttp http;
  final bool _ownsHttp;
  final Duration timeout, requestTimeout;
  final DateTime Function() clock;
  final _tokens = <CancelToken>{};
  bool _closed = false;

  @override
  Future<ResourceLinkHealth> check(
    ResourceSearchHit hit,
    CancelToken cancellation,
  ) async {
    require(!_closed && !cancellation.isCancelled, '检测已取消');
    if (!canCheckResourceLink(hit) || hit.link?.shareId?.isNotEmpty != true) {
      return ResourceLinkHealth.checked(ResourceLinkState.unsupported, clock());
    }
    final token = CancelToken();
    _tokens.add(token);
    var finished = false;
    unawaited(
      cancellation.whenCancel.then((_) {
        if (!finished) token.cancel();
      }),
    );
    final deadline = Timer(timeout, () => token.cancel('deadline'));
    final request = _ProbeHttp(http, token, requestTimeout);
    try {
      final state = await switch (hit.platform) {
        CloudPlatform.quark || CloudPlatform.uc => _quarkUc(request, hit),
        CloudPlatform.baidu => _baidu(request, hit),
        CloudPlatform.aliyun => _aliyun(request, hit),
        CloudPlatform.pan123 => _pan123(request, hit),
        CloudPlatform.tianyi => _tianyi(request, hit),
        CloudPlatform.pan115 => _pan115(request, hit),
        CloudPlatform.guangya => _guangya(request, hit),
        CloudPlatform.xunlei => _xunlei(request, hit),
        CloudPlatform.c139 => _c139(request, hit),
        CloudPlatform.wopan => _wopan(request, hit),
        _ => Future.value(ResourceLinkState.unsupported),
      };
      require(!token.isCancelled, '检测已取消或超时');
      return ResourceLinkHealth.checked(state, clock());
    } finally {
      finished = true;
      deadline.cancel();
      _tokens.remove(token);
      token.cancel('complete');
    }
  }

  @override
  void dispose() {
    _closed = true;
    for (final token in _tokens) {
      token.cancel();
    }
    _tokens.clear();
    if (_ownsHttp && http is DioJsonHttp) {
      (http as DioJsonHttp).dio.close(force: true);
    }
  }
}

const _webUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36';

/// Each request has a real cancellation token and bounded streaming response.
/// A separate client avoids sending the user's account cookies/access tokens.
class _ProbeHttp {
  _ProbeHttp(this.http, this.token, this.timeout);
  final JsonHttp http;
  final CancelToken token;
  final Duration timeout;
  static const maxBytes = 128 * 1024;

  Future<HttpResult> request(
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    String? contentType,
  }) async {
    require(!token.isCancelled, '检测已取消');
    final cancel = CancelToken();
    var finished = false;
    unawaited(
      token.whenCancel.then((_) {
        if (!finished) cancel.cancel();
      }),
    );
    final deadline = Timer(timeout, () => cancel.cancel('deadline'));
    final requestHeaders = {
      'User-Agent': _webUa,
      'Accept': 'application/json',
      ...headers,
    };
    final method = body == null ? 'GET' : 'POST';
    try {
      final client = http;
      final HttpResult result;
      if (client is DioJsonHttp) {
        final response = await client.dio.request<ResponseBody>(
          url,
          data: body,
          cancelToken: cancel,
          options: Options(
            method: method,
            headers: requestHeaders,
            contentType: contentType,
            responseType: ResponseType.stream,
            followRedirects: false,
            receiveTimeout: timeout,
            validateStatus: (_) => true,
          ),
        );
        if (response.statusCode == 429) throw ResourceLinkCheckLimited();
        require(response.data != null, '网盘未返回内容');
        final bytes = <int>[];
        await for (final chunk in response.data!.stream) {
          require(!cancel.isCancelled, '检测已取消或超时');
          require(bytes.length + chunk.length <= maxBytes, '网盘检测响应过大');
          bytes.addAll(chunk);
        }
        result = HttpResult(
          response.statusCode ?? 0,
          utf8.decode(bytes),
          response.headers.map,
        );
      } else {
        final scope = RequestScope();
        unawaited(cancel.whenCancel.then((_) => scope.cancel()));
        if (cancel.isCancelled) scope.cancel();
        result = await scope.run(
          () => RequestScope.cancellable(
            client.request(
              method,
              url,
              body: body,
              headers: requestHeaders,
              contentType: contentType,
              followRedirects: false,
            ),
          ),
          inheritGuard: false,
        );
      }
      require(!cancel.isCancelled && !token.isCancelled, '检测已取消或超时');
      if (result.status == 429) throw ResourceLinkCheckLimited();
      // A login page, removed API route or WAF response is not a dead share.
      require(
        !{401, 403}.contains(result.status) && result.status < 500,
        '网盘暂时限制访问',
      );
      require(utf8.encode(result.body).length <= maxBytes, '网盘检测响应过大');
      return result;
    } finally {
      finished = true;
      deadline.cancel();
      cancel.cancel('complete');
    }
  }

  Future<Json> json(
    String url, {
    Json? body,
    Map<String, String> headers = const {},
  }) async {
    final response = await request(
      url,
      body: body == null ? null : jsonEncode(body),
      headers: headers,
      contentType: body == null ? null : 'application/json; charset=utf-8',
    );
    require(
      response.successful || {400, 404}.contains(response.status),
      '网盘检测暂不可用',
    );
    final value = jsonDecode(response.body);
    require(value is Map, '网盘检测响应格式无效');
    return {...asJson(value), '_probe_http_status': response.status};
  }
}

String _message(Json value) => [
  'message',
  'msg',
  'errmsg',
  'error_description',
  'error',
  'desc',
].map(value.str).where((s) => s.isNotEmpty).join(' ');

bool _flag(Object? value) => {true, 1, '1', 'true'}.contains(value);

ResourceLinkState _failure(
  String code,
  String message, {
  Set<String> locked = const {},
  Set<String> invalid = const {},
}) {
  final text = '$code $message'.toLowerCase();
  if (code == '429' ||
      code == '100011' ||
      RegExp(r'频繁|too many requests|rate.?limit|frequency').hasMatch(text)) {
    throw ResourceLinkCheckLimited();
  }
  // Check access restrictions before error words such as "password" or "expired".
  if (RegExp(
    r'captcha|验证码|人机|风控|安全验证|登录|令牌|凭据|login|unauth|access.?token|invalid.?token|token.*expired',
  ).hasMatch(text)) {
    return ResourceLinkState.unknown;
  }
  if (locked.contains(code) ||
      RegExp(
        r'提取码|访问码|访问密码|密码错误|password|pass.?code|accesscode|pwdnotmatch',
      ).hasMatch(text)) {
    return ResourceLinkState.locked;
  }
  if (invalid.contains(code) ||
      RegExp(
        r'(?:分享(?:链接|文件|内容)?|链接|文件|资源)(?:已(?:经)?(?:被)?|被)?(?:不存在|取消|删除|失效|过期)|'
        r'分享已关闭|文件没有被分享|share[._ ]?(?:link[._ ]?)?(?:not[._ ]?found|expired|cancelled|canceled|deleted)|'
        r'file[._ ]?not[._ ]?found|share_id invalid',
      ).hasMatch(text)) {
    return ResourceLinkState.invalid;
  }
  return ResourceLinkState.unknown;
}

ResourceLinkState? _error(
  Json value, {
  String field = 'code',
  Set<String> success = const {'', '0'},
  Set<String> locked = const {},
  Set<String> invalid = const {},
}) {
  final code = value.str(field);
  if (success.contains(code) &&
      value['success'] != false &&
      value.str('error').isEmpty) {
    return value.integer('_probe_http_status') >= 400
        ? ResourceLinkState.unknown
        : null;
  }
  return _failure(code, _message(value), locked: locked, invalid: invalid);
}

ResourceLinkState _files(
  Object? value, {
  Set<String> ids = const {'fid', 'file_id', 'fileId', 'FileId', 'id'},
}) {
  if (value is! List || value.any((item) => item is! Map)) {
    return ResourceLinkState.unknown;
  }
  if (value.isEmpty) return ResourceLinkState.invalid;
  return value.any((item) => ids.any((key) => asJson(item).str(key).isNotEmpty))
      ? ResourceLinkState.valid
      : ResourceLinkState.unknown;
}

Future<ResourceLinkState> _quarkUc(
  _ProbeHttp http,
  ResourceSearchHit hit,
) async {
  final quark = hit.platform == CloudPlatform.quark;
  final base = quark ? 'https://drive-pc.quark.cn' : 'https://pc-api.uc.cn';
  final origin = quark ? 'https://pan.quark.cn' : 'https://drive.uc.cn';
  final headers = {'Origin': origin, 'Referer': '$origin/'};
  ResourceLinkState? shareError(Json value) {
    if (value.containsKey('status') && value.integer('status') != 200) {
      return _failure(value.str('code'), _message(value), locked: {'41008'});
    }
    return _error(value, locked: {'41008'});
  }

  String url(String path, [Json values = const {}]) => query(
    '$base/1/clouddrive/$path',
    {'pr': quark ? 'ucpro' : 'UCBrowser', 'fr': 'pc', ...values},
  );
  final token = await http.json(
    url('share/sharepage/token'),
    body: {
      'pwd_id': hit.link!.shareId,
      'passcode': hit.password,
      if (quark)
        'support_visit_limit_private_share': true
      else
        'share_for_transfer': true,
    },
    headers: headers,
  );
  var error = shareError(token);
  if (error != null) return error;
  final stoken = token.obj('data').str('stoken');
  if (stoken.isEmpty) return ResourceLinkState.unknown;
  final detail = await http.json(
    url(quark ? 'share/sharepage/detail' : 'transfer_share/detail', {
      'pwd_id': hit.link!.shareId,
      'stoken': stoken,
      'pdir_fid': quark ? '' : '0',
      '_page': 1,
      '_size': 1,
      if (quark)
        'ver': 2
      else ...{
        'entry': 'ft',
        'fetch_file_list': 1,
        '_fetch_share': 1,
      },
    }),
    headers: headers,
  );
  error = shareError(detail);
  if (error != null) return error;
  final data = detail.obj('data');
  if (_flag(data['is_expire']) || data.obj('share').integer('status') > 1) {
    return ResourceLinkState.invalid;
  }
  return _files(data['list']);
}

Future<ResourceLinkState> _baidu(_ProbeHttp http, ResourceSearchHit hit) async {
  final id = hit.link!.shareId!;
  final headers = {'Referer': 'https://pan.baidu.com/s/1$id'};
  if (hit.password.isNotEmpty) {
    final response = await http.request(
      query('https://pan.baidu.com/share/verify', {'surl': id}),
      body: form({'pwd': hit.password, 'vcode': '', 'vcode_str': ''}),
      headers: headers,
      contentType: 'application/x-www-form-urlencoded; charset=utf-8',
    );
    final value = response.json;
    final error = _error(
      value,
      field: 'errno',
      success: {'0'},
      locked: {'-9', '-12'},
    );
    if (error != null) return error;
    if (!response.successful) return ResourceLinkState.unknown;
    final key = value.str('randsk');
    if (key.isEmpty || RegExp(r'[\x00-\x20\x7f;]').hasMatch(key)) {
      return ResourceLinkState.unknown;
    }
    headers['Cookie'] = 'BDCLND=$key';
  }
  final value = await http.json(
    query('https://pan.baidu.com/share/list', {
      'web': 1,
      'page': 1,
      'num': 1,
      'order': 'time',
      'desc': 1,
      'showempty': 0,
      'shorturl': id,
      'root': 1,
      'clienttype': 0,
    }),
    headers: headers,
  );
  final error = _error(
    value,
    field: 'errno',
    success: {'0'},
    locked: {'-9', '-12'},
  );
  return error ?? _files(value['list'], ids: {'fs_id'});
}

Future<ResourceLinkState> _aliyun(
  _ProbeHttp http,
  ResourceSearchHit hit,
) async {
  final route = AliyunShareLink.parse(Uri.parse(hit.url));
  if (route == null) return ResourceLinkState.unknown;
  final headers = {
    'Origin': 'https://www.alipan.com',
    'Referer': 'https://www.alipan.com/',
    'x-canary': route.fastTransfer
        ? 'client=web,app=adrive,version=v0.0.1'
        : 'client=web,app=share,version=v2.3.1',
  };
  if (route.fastTransfer) {
    final info = await http.json(
      'https://api.aliyundrive.com/adrive/v1/share/getByAnonymous',
      body: {'share_id': route.id},
      headers: headers,
    );
    final error = _error(info);
    if (error != null) return error;
    if (info.str('share_id') != route.id) return ResourceLinkState.unknown;
    return _files(info['preview_file_list']);
  }
  final token = await http.json(
    'https://api.aliyundrive.com/v2/share_link/get_share_token',
    body: {'share_id': route.id, 'share_pwd': hit.password},
    headers: headers,
  );
  var error = _error(token);
  if (error != null) return error;
  if (token.str('share_token').isEmpty) return ResourceLinkState.unknown;
  final files = await http.json(
    'https://api.aliyundrive.com/adrive/v2/file/list_by_share',
    body: {
      'share_id': route.id,
      'parent_file_id': 'root',
      'limit': 1,
      'order_by': 'name',
      'order_direction': 'ASC',
    },
    headers: {...headers, 'X-Share-Token': token.str('share_token')},
  );
  error = _error(files);
  return error ?? _files(files['items']);
}

Future<ResourceLinkState> _pan123(
  _ProbeHttp http,
  ResourceSearchHit hit,
) async {
  final value = await http.json(
    query('https://yun.123pan.cn/b/api/share/get', {
      'limit': 1,
      'next': 0,
      'orderBy': 'file_name',
      'orderDirection': 'asc',
      'shareKey': hit.link!.shareId,
      'ParentFileId': '0',
      'Page': 1,
      if (hit.password.isNotEmpty) 'SharePwd': hit.password,
    }),
    headers: {'User-Agent': 'Dart/3.12 (dart:io)'},
  );
  final error = _error(value, success: {'0'});
  if (error != null) return error;
  final data = value.obj('data');
  if (_flag(data['Expired'])) return ResourceLinkState.invalid;
  if (_flag(data['HasPwd']) && hit.password.isEmpty) {
    return ResourceLinkState.locked;
  }
  return _files(data['InfoList']);
}

Future<ResourceLinkState> _tianyi(
  _ProbeHttp http,
  ResourceSearchHit hit,
) async {
  const base = 'https://cloud.189.cn/api/open/share';
  final headers = {'Sign-Type': '1', 'Referer': 'https://cloud.189.cn/web/'};
  final info = await http.json(
    query('$base/getShareInfoByCodeV2.action', {
      'shareCode': hit.link!.shareId,
    }),
    headers: headers,
  );
  ResourceLinkState? error(Json data) {
    for (final field in ['res_code', 'errorCode', 'code']) {
      if (!data.containsKey(field)) continue;
      final state = _error(
        data,
        field: field,
        success: {'', '0', 'Success', 'success'},
        locked: {
          'AccessCodeError',
          'ShareAccessCodeError',
          'ShareAccessCodeNotMatch',
          'NeedAccessCode',
        },
        invalid: {
          'ShareNotFound',
          'ShareInfoNotFound',
          'ShareExpired',
          'ShareExpiredError',
          'ShareCanceled',
          'ShareAuditNotPass',
          'FileNotFound',
        },
      );
      if (state != null) return state;
    }
    return data.integer('_probe_http_status') >= 400
        ? ResourceLinkState.unknown
        : null;
  }

  final failed = error(info);
  if (failed != null) return failed;
  final locked = tianyiNeedsAccessCode(info);
  if (locked && hit.password.isEmpty) return ResourceLinkState.locked;
  if (hit.password.isNotEmpty) {
    final verified = await http.json(
      query('$base/checkAccessCode.action', {
        'shareCode': hit.link!.shareId,
        'accessCode': hit.password,
      }),
      headers: headers,
    );
    final failed = error(verified);
    if (failed != null) return failed;
    if (verified.str('shareId').isEmpty) return ResourceLinkState.unknown;
  }
  return info.str('fileId').isNotEmpty && info.str('fileName').isNotEmpty
      ? ResourceLinkState.valid
      : ResourceLinkState.unknown;
}

Future<ResourceLinkState> _pan115(
  _ProbeHttp http,
  ResourceSearchHit hit,
) async {
  if (hit.password.isEmpty) return ResourceLinkState.locked;
  final value = await http.json(
    query('https://115cdn.com/webapi/share/snap', {
      'share_code': hit.link!.shareId,
      'receive_code': hit.password,
      'offset': 0,
      'limit': 1,
    }),
    headers: {
      'Referer': 'https://115cdn.com/',
      'X-Requested-With': 'XMLHttpRequest',
    },
  );
  if (!_flag(value['state'])) {
    return _failure(value.str('errno', value.str('code')), _message(value));
  }
  if (value.integer('_probe_http_status') >= 400) {
    return ResourceLinkState.unknown;
  }
  final data = value.obj('data');
  return _files(data['list'], ids: {'fid', 'cid', 'file_id', 'category_id'});
}

Future<ResourceLinkState> _guangya(
  _ProbeHttp http,
  ResourceSearchHit hit,
) async {
  final headers = {
    'Origin': 'https://www.guangyapan.com',
    'Referer': 'https://www.guangyapan.com/',
    'did': newId().replaceAll('-', ''),
    'dt': '4',
  };
  final token = await http.json(
    'https://api.guangyapan.com/userres/v1/get_share_access_token',
    body: {'shareId': hit.link!.shareId, 'code': hit.password},
    headers: headers,
  );
  var error = _error(token, locked: {'209'}, invalid: {'200', '201', '202'});
  if (error != null) return error;
  final access = token
      .obj('data')
      .str('accessToken', token.obj('data').str('access_token'));
  if (access.isEmpty) return ResourceLinkState.unknown;
  final files = await http.json(
    'https://api.guangyapan.com/userres/v1/get_share_page_files_list',
    body: {
      'parentId': '',
      'pageSize': 1,
      'orderBy': 0,
      'sortType': 0,
      'accessToken': access,
    },
    headers: headers,
  );
  error = _error(files, locked: {'209'}, invalid: {'200', '201', '202'});
  if (error != null) return error;
  final data = files.obj('data');
  return _files(
    data['list'] ??
        data['items'] ??
        data['files'] ??
        data['records'] ??
        data['content'],
    ids: {'fileId', 'file_id', 'id', 'resId', 'resourceId'},
  );
}

Future<ResourceLinkState> _xunlei(
  _ProbeHttp http,
  ResourceSearchHit hit,
) async {
  final value = await http.json(
    query('https://api-pan.xunlei.com/drive/v1/share', {
      'share_id': hit.link!.shareId,
      'pass_code': hit.password,
      'limit': 1,
    }),
    headers: {
      'Origin': 'https://pan.xunlei.com',
      'Referer': 'https://pan.xunlei.com/',
    },
  );
  final status = value.str('share_status');
  if ({
    'PASS_CODE_EMPTY',
    'PASS_CODE_ERROR',
    'PASS_CODE_NEED',
  }.contains(status)) {
    return ResourceLinkState.locked;
  }
  if ({
    'SENSITIVE_RESOURCE',
    'DELETED',
    'EXPIRED',
    'CANCELLED',
    'NOT_FOUND',
  }.contains(status)) {
    return ResourceLinkState.invalid;
  }
  final error = _error(value, field: 'error_code', locked: {'1004'});
  if (error != null) return error;
  if (status != 'OK') return ResourceLinkState.unknown;
  return _files(value['files']);
}

Future<ResourceLinkState> _c139(_ProbeHttp http, ResourceSearchHit hit) async {
  final response = await http.request(
    'https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink/getOutLinkInfoV6',
    body: C139Protocol.encrypt(
      jsonEncode({
        'getOutLinkInfoReq': {
          'account': '',
          'linkID': hit.link!.shareId,
          'passwd': hit.password,
          'caSrt': 1,
          'coSrt': 1,
          'srtDr': 0,
          'bNum': 1,
          'pCaID': 'root',
          'eNum': 1,
        },
      }),
    ),
    contentType: 'application/json; charset=utf-8',
    headers: {
      'hcy-cool-flag': '1',
      'x-deviceinfo': '||3|12.27.0|||||chrome 150.0.0.0|360X444|zh-cn|||',
      'x-huawei-channelsrc': '10245500',
      'x-mm-source': '0002',
      'Origin': 'https://yun.139.com',
      'Referer': 'https://yun.139.com/',
    },
  );
  Json value;
  try {
    value = response.json;
  } on AppException {
    value = asJson(jsonDecode(C139Protocol.decrypt(response.body)));
  }
  final error = _error(
    value,
    field: value.containsKey('resultCode') ? 'resultCode' : 'code',
    success: {'', '0', '0000', '200'},
  );
  if (error != null) return error;
  if (!response.successful) return ResourceLinkState.unknown;
  var data = value.obj('data');
  for (final key in ['getOutLinkInfoResp', 'getOutLinkRes']) {
    if (data[key] is Map) {
      data = data.obj(key);
      break;
    }
  }
  if (data['caLst'] is! List && data['coLst'] is! List) {
    return ResourceLinkState.unknown;
  }
  return _files(
    [
      if (data['caLst'] is List) ...data['caLst'],
      if (data['coLst'] is List) ...data['coLst'],
    ],
    ids: {'caID', 'coID'},
  );
}

Future<ResourceLinkState> _wopan(_ProbeHttp http, ResourceSearchHit hit) async {
  var uri = Uri.parse(hit.url);
  for (var hop = 0; hop < 5; hop++) {
    if (!{'pan.wo.cn', 'panservice.mail.wo.cn'}.contains(uri.host) ||
        uri.userInfo.isNotEmpty ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.port != (uri.scheme == 'https' ? 443 : 80)) {
      return ResourceLinkState.unknown;
    }
    uri = uri.replace(scheme: 'https', port: 443);
    final fragment = Uri.tryParse(
      uri.fragment.startsWith('/') || uri.fragment.startsWith('?')
          ? uri.fragment
          : '?${uri.fragment}',
    );
    final params = {
      for (final part in [
        uri,
        if (fragment != null && !fragment.hasAuthority) fragment,
      ])
        for (final entry in part.queryParameters.entries)
          entry.key.toLowerCase(): entry.value,
    };
    final id = params['shareid'] ?? params['surl'] ?? '';
    if (id.isNotEmpty) {
      final client =
          {
            WopanProtocol.clientId,
            WopanProtocol.webClientId,
          }.contains(params['clientid'])
          ? params['clientid']!
          : WopanProtocol.clientId;
      final now = DateTime.now().millisecondsSinceEpoch;
      final value = await http.json(
        '${WopanProtocol.origin}/wohome/dispatcher',
        body: {
          'header': WopanProtocol.header(
            '100002',
            'ShareFileDetail',
            now,
            now % 90000 + 100000,
          ),
          'body': {
            'clientId': client,
            'secret': true,
            'secretType': 'ClientSecret',
            'param': WopanProtocol.encrypt(
              {
                'shareId': id,
                'shareCode': hit.password.ifEmpty(params['sharecode'] ?? ''),
              },
              'api-user',
              '',
              client: client,
            ),
          },
        },
        headers: {
          'Origin': WopanProtocol.origin,
          'Referer': '${WopanProtocol.origin}/h5/wocloudshare/',
        },
      );
      final rsp = value.obj('RSP');
      if (rsp.str('RSP_CODE') != '0000' || value.str('STATUS') != '200') {
        return _failure(
          rsp.str('RSP_CODE'),
          rsp.str('RSP_DESC'),
          invalid: {'130013'},
        );
      }
      if (value.integer('_probe_http_status') >= 400) {
        return ResourceLinkState.unknown;
      }
      return _files(
        WopanProtocol.decodeValue(rsp['DATA'], 'api-user', '', client: client),
        ids: {'id', 'fileId'},
      );
    }
    if (uri.host == 'pan.wo.cn' &&
        RegExp(r'^/s/[A-Za-z0-9_-]+/?$').hasMatch(uri.path)) {
      uri = uri.replace(host: 'panservice.mail.wo.cn');
    }
    final response = await http.request(uri.toString());
    final location = response.header('location');
    if (!{301, 302, 303, 307, 308}.contains(response.status) ||
        location.isEmpty) {
      return ResourceLinkState.unknown;
    }
    uri = uri.resolve(location);
  }
  return ResourceLinkState.unknown;
}
