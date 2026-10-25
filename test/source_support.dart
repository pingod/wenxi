import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/sources/package.dart';

final sourcePublicKey = File(
  'test/fixtures/sources/public-key.txt',
).readAsStringSync();
final sourceTestNow = DateTime.fromMillisecondsSinceEpoch(1792195300000);
Json sourceEnvelope([String name = 'catalog-1']) => asJson(
  jsonDecode(File('test/fixtures/sources/$name.json').readAsStringSync()),
);
const jsonSourceUrl = 'https://json.example.com/share/sample';
final hasSourceNative = Platform.environment['ASTERLINK_JS_LIBRARY'] != null;
Future<Json> sourceOrigin(SourcePackage source, Json options) async {
  final uri = Uri.parse(options.str('url'));
  Json file(String id, String name) => {
    'id': id,
    'name': name,
    'kind': 'file',
    'size': 4,
  };
  Json response(Object data) => {'status': 200, 'text': jsonEncode(data)};
  if (uri.host == 'json.example.com') {
    if (uri.path == '/api/download') {
      final body = options.obj('body');
      if (body.str('token') != 'fixture-token') {
        throw StateError('Missing restore state');
      }
      return response({
        'urls': [
          'https://files.example.com/${body.str('version')}-${body.str('id')}.bin',
        ],
      });
    }
    final body = options.obj('body');
    if (body.str('directory').isNotEmpty) {
      return response({
        'items': [file('inside', '目录文件.bin')],
        'state': {'token': 'fixture-token'},
      });
    }
    if (body.str('cursor') == 'page2') {
      return response({
        'items': [file('two', '第二页.bin')],
        'state': {'token': 'fixture-token'},
      });
    }
    if (body.str('query').isNotEmpty) {
      return response({
        'items': [file('found', '搜索结果.bin')],
        'state': {'token': 'fixture-token'},
      });
    }
    return response({
      'title': 'JSON 文件库',
      'items': [
        file('one', '样本.bin'),
        {'id': 'folder', 'name': '目录', 'kind': 'directory'},
      ],
      'state': {'token': 'fixture-token'},
      'hasMore': true,
      'cursor': 'page2',
    });
  }
  if (uri.host == 'html.example.org') {
    return {
      'status': 200,
      'text':
          '<html><a class="download" href="https://files.example.com/html.bin">网页文件.bin</a></html>',
    };
  }
  if (uri.host == 'api.example.net') {
    if (uri.path == '/list') {
      final sign = sha256
          .convert(utf8.encode('https://api.example.net/share/sample'))
          .toString();
      if (options.obj('headers').str('X-Sign') != sign) {
        throw StateError('Incorrect request signature');
      }
      return response({
        'files': [file('signed', '签名文件.bin')],
      });
    }
    final expected = Hmac(
      sha256,
      utf8.encode('18446744073709551615'),
    ).convert(utf8.encode('signed')).toString();
    if (options.obj('headers').str('X-Sign') != expected) {
      throw StateError('Incorrect download signature');
    }
    return response({
      'urls': ['https://files.example.com/signed.bin'],
    });
  }
  throw StateError('Unexpected fixture request');
}
