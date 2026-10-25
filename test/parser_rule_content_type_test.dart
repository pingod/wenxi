import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/parser_rules/engine.dart';
import 'package:asterlink/data/parser_rules/rule.dart';

class _Http extends JsonHttp {
  final calls =
      <({String? contentType, Map<String, String> headers, Object? body})>[];

  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) async {
    calls.add((contentType: contentType, headers: headers, body: body));
    // The upstream accepts the exact declared media type, like MF's native API.
    if (headers.entries.any(
      (entry) =>
          entry.key.toLowerCase() == 'content-type' &&
          entry.value != contentType,
    )) {
      return const HttpResult(403, '<html>Unsupported request profile</html>');
    }
    return HttpResult(200, jsonEncode({'files': <Json>[]}));
  }
}

ParserRule _rule(int engine, String codec, Map<String, String> headers) =>
    ParserRule.fromJson({
      'schema': 1,
      'engine': engine,
      'siteId': 'content_type_test',
      'name': 'Content type test',
      'allowedHosts': ['parser.example.com'],
      'downloadHosts': ['files.example.com'],
      'operations': {
        'list': {
          'steps': [
            {
              'id': 'request',
              'method': 'POST',
              'url': 'https://parser.example.com/list',
              'codec': codec,
              'headers': headers,
              'body': {
                'path': '/中文目录',
                'parse_password': {r'$ref': 'secret.password'},
              },
            },
          ],
          'result': {
            'list': {r'$ref': 'last.files'},
          },
        },
        'download': {
          'steps': [
            {
              'id': 'request',
              'method': 'GET',
              'url': 'https://parser.example.com/link',
            },
          ],
          'result': {
            'fs_id': {r'$ref': 'input.file.fs_id'},
            'urls': ['https://files.example.com/file'],
          },
        },
      },
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final engine in [1, 4]) {
    test(
      'Engine $engine honors the exact rule media type and keeps CheckRand valid',
      () async {
        for (final header in ['Content-Type', 'content-type', 'cOnTeNt-TyPe']) {
          final http = _Http();
          final result = await ParserRuleEngine(http).execute(
            _rule(engine, 'checkrand', {header: 'application/json'}),
            'list',
            {},
            password: '精确密码-A7',
            device: 'fixture',
          );
          expect(result['list'], isEmpty);
          final sent = http.calls.single;
          expect(sent.contentType, 'application/json');
          final body = asJson(jsonDecode(sent.body as String));
          final signature = body.remove('rand1');
          final nonce = body.remove('rand2');
          expect(
            body.remove('rand3'),
            sha1.convert(utf8.encode(nonce as String)).toString(),
          );
          expect(
            signature,
            sha1.convert(utf8.encode(jsonEncode(body))).toString(),
          );
          expect(body['path'], '/中文目录');
          expect(body['parse_password'], '精确密码-A7');
        }
      },
    );

    test(
      'Engine $engine preserves defaults and supports custom JSON and form media types',
      () async {
        for (final (codec, declared, expected) in <(String, String?, String)>[
          ('json', null, 'application/json;charset=utf-8'),
          ('form', null, 'application/x-www-form-urlencoded'),
          (
            'json',
            'application/vnd.example+json',
            'application/vnd.example+json',
          ),
          (
            'form',
            'application/x-www-form-urlencoded;charset=UTF-8',
            'application/x-www-form-urlencoded;charset=UTF-8',
          ),
        ]) {
          final http = _Http();
          await ParserRuleEngine(http).execute(
            _rule(engine, codec, {'Content-Type': ?declared}),
            'list',
            {},
            password: 'fixture',
            device: 'fixture',
          );
          expect(http.calls.single.contentType, expected);
          final body = http.calls.single.body as String;
          if (codec == 'form') {
            expect(Uri.splitQueryString(body)['path'], '/中文目录');
          } else {
            expect(asJson(jsonDecode(body))['path'], '/中文目录');
          }
        }
      },
    );
  }
}
