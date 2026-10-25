import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/parser_rules/engine.dart';
import 'package:asterlink/data/parser_rules/rule.dart';
import 'package:asterlink/data/parser_rules/site_protection.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'support.dart';

const _blocked = HttpResult(
  403,
  '''<!DOCTYPE html><html><body>
<h1>Sorry, <span>you have been blocked</span></h1>
<div id="cf-error-details">Cloudflare Ray ID: 0123456789abcdef</div>
This body has private-cookie and private-password and must not be logged.
</body></html>''',
  {
    'Server': ['cloudflare'],
    'Content-Type': ['text/html; charset=UTF-8'],
    'CF-Ray': ['0123456789abcdef-SJC'],
    'Set-Cookie': ['private-cookie'],
  },
);
const _challenge = HttpResult(
  403,
  '''<!DOCTYPE html><html><body>
<script src="/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1"></script>
</body></html>''',
  {
    'server': ['cloudflare'],
    'cf-mitigated': ['challenge'],
    'content-type': ['text/html'],
    'cf-ray': ['abcdef0123456789-HKG'],
  },
);

ParserRule _rule(int engine) => ParserRule.fromJson({
  'schema': 1,
  'engine': engine,
  'siteId': 'protection_test',
  'name': '测试',
  'authMode': 'password',
  'allowedHosts': ['api.example.com'],
  'downloadHosts': ['files.example.com'],
  'operations': {
    'list': {
      'steps': [
        {
          'id': 'list',
          'method': 'GET',
          'url': 'https://api.example.com/list?token=private-query',
        },
      ],
      'result': {
        'list': {r'$ref': 'last.files'},
      },
    },
    'download': {
      'steps': [
        {'id': 'link', 'method': 'GET', 'url': 'https://api.example.com/link'},
      ],
      'result': {
        'fs_id': {r'$ref': 'input.file.fs_id'},
        'urls': [
          {r'$ref': 'last.url'},
        ],
      },
    },
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Cloudflare block and challenge are distinct from an ordinary API rejection',
    () {
      expect(ParserSiteProtection.detect(_blocked)?.code, 'CF_BLOCKED');
      expect(ParserSiteProtection.detect(_challenge)?.code, 'CF_CHALLENGE');
      expect(
        ParserSiteProtection.detect(_blocked)?.cfRay,
        '0123456789abcdef-SJC',
      );
      for (final response in [
        const HttpResult(400, '{"code":20016,"message":"password rejected"}', {
          'server': ['cloudflare'],
          'content-type': ['application/json'],
        }),
        const HttpResult(
          403,
          '{"error":"Sorry, you have been blocked by Cloudflare"}',
          {
            'server': ['cloudflare'],
            'content-type': ['application/json'],
          },
        ),
        const HttpResult(403, '<html>Permission denied</html>', {
          'server': ['cloudflare'],
          'content-type': ['text/html'],
        }),
        const HttpResult(
          200,
          '<html><script src="/cdn-cgi/challenge-platform/script.js"></script></html>',
          {
            'server': ['cloudflare'],
            'content-type': ['text/html'],
          },
        ),
      ]) {
        expect(ParserSiteProtection.detect(response), isNull);
      }
      expect(ParserSiteProtection.rayId('private-data'), isEmpty);
      expect(ParserSiteProtection.rayId('0123456789abcdef\nsecret'), isEmpty);
    },
  );

  for (final engine in [1, 3, 4]) {
    for (final response in [_blocked, _challenge]) {
      final code = identical(response, _blocked)
          ? 'CF_BLOCKED'
          : 'CF_CHALLENGE';
      test(
        'Engine $engine reports $code without suggesting rule or password refresh',
        () async {
          final log = DiagnosticLog.open(null);
          DiagnosticLog.active = log;
          addTearDown(() {
            DiagnosticLog.active = null;
            log.close();
          });
          final http = FakeHttp((_) => response);
          await expectLater(
            ParserRuleEngine(http).execute(
              _rule(engine),
              'list',
              {},
              password: 'private-password',
              device: 'device',
            ),
            throwsA(
              isA<ParserRuleError>()
                  .having((e) => e.code, 'code', code)
                  .having((e) => e.suggestsRuleUpdate, 'refresh', false)
                  .having((e) => e.message, 'message', contains('Cloudflare')),
            ),
          );
          expect(http.calls, hasLength(1));
          final entries = log.entries().where(
            (e) => e.event == 'parser.upstream.protection',
          );
          expect(entries, hasLength(1));
          expect(
            entries.single.data['fields'],
            containsPair('httpStatus', 403),
          );
          expect(
            entries.single.data['fields'],
            containsPair('host', 'api.example.com'),
          );
          final logs = log.exportFiles().values.join('\n');
          expect(logs, contains('cfRay'));
          for (final secret in [
            'private-cookie',
            'private-query',
            'private-password',
          ]) {
            expect(logs, isNot(contains(secret)));
          }
        },
      );
    }
  }
}
