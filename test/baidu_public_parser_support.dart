import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/baidu_public_password.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

class BaiduPublicFixture {
  static const url = 'https://pan.baidu.com/s/1PublicFixture?pwd=a1b2';
  static const fileId = '9007199254740993';
  static const name = '下载测试 + 中文.apk';
  static const folder = '/共享文件夹 + 中文';
  static const ua = 'netdisk;P2SP;2.3.1.21;fixture;android';
  static const password = '测试密码';
  Json get passwordSecrets => {
    BaiduPublicPasswords.cacheKey: encoded({
      'schema': 2,
      'source': BaiduPublicPasswords.sourceUrl,
      'value': password,
      'fetchedAt': DateTime.now().millisecondsSinceEpoch,
      'rejected': false,
    }),
  };
  Json get authenticatedState {
    final account = Credential('UC fixture', {
      'primary': '__pus=fixture-private-uc',
    }, updatedAt: 7);
    final identity = sha256.convert(
      utf8.encode('legacy-${CloudPlatform.uc.key}|${account.updatedAt}'),
    );
    return {
      'credentials': {CloudPlatform.uc.key: account.toJson()},
      'secrets': {
        ...passwordSecrets,
        'publicParser.mfDg22.ucPassword.$identity':
            passwordSecrets[BaiduPublicPasswords.cacheKey],
      },
    };
  }

  bool publicFailure = false;
  String? returnedId;
  String? userAgent = ua;
  String uaKey = 'ua';
  List<String> urls = ['https://download.baidupcs.com/file/fixture'];
  String dlink = '', fileName = name;
  ParsedLink get link => LinkParser.parse(url).single;

  Json file([String parent = '/']) => {
    'fs_id': fileId,
    'server_filename': fileName,
    'path': parent == '/' ? '/$fileName' : '$parent/$fileName',
    if (dlink.isNotEmpty) 'dlink': dlink,
    'size': 4,
    'is_dir': 0,
    'md5': '08d6c05a21512a79a1dfeb9d2a8f262f',
    'server_mtime': 1791720000,
  };

  List<Json> files(String parent) => [
    file(parent),
    if (parent == '/')
      {
        'fs_id': '999',
        'server_filename': '共享文件夹 + 中文',
        'path': folder,
        'size': 0,
        'is_dir': 1,
      },
  ];

  HttpResult respond(RecordedRequest request) {
    if (request.uri.host == 'mf.dg22.top') {
      if (publicFailure) {
        return jsonResponse({'code': 400, 'message': '解析站暂不可用'});
      }
      if (request.uri.path.endsWith('/get_file_list')) {
        return jsonResponse({
          'code': 200,
          'data': {
            'uk': '456',
            'shareid': '123',
            'randsk': 'a%2Bb%2Fc%3D',
            'list': files(request.json.str('dir')),
          },
        });
      }
      if (request.uri.path.endsWith('/get_download_links')) {
        return jsonResponse({
          'code': 200,
          'data': [
            {
              'fs_id': returnedId ?? fileId,
              'filename': fileName,
              if (userAgent != null) uaKey: userAgent,
              'message': '请求成功',
              'urls': urls,
            },
          ],
        });
      }
    }
    if (request.uri.host == 'pan.baidu.com') {
      if (request.uri.path == '/share/verify') {
        return jsonResponse({'errno': 0, 'randsk': 'official%2Bshare%3D'});
      }
      if (request.uri.path == '/rest/2.0/xpan/share') {
        return jsonResponse({
          'errno': 0,
          'share_id': '123',
          'uk': '456',
          'list': [
            for (final item in files(request.uri.queryParameters['dir'] ?? '/'))
              {...item, 'isdir': item['is_dir']},
          ],
        });
      }
      if (request.uri.path == '/rest/2.0/xpan/nas') {
        return jsonResponse({'errno': 0, 'uk': '456'});
      }
      if (request.uri.path == '/api/filemanager') {
        return jsonResponse({'errno': 0});
      }
    }
    throw StateError(
      'Unexpected request ${request.method} ${request.uri.host}${request.uri.path}',
    );
  }
}
