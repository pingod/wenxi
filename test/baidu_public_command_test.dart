import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/baidu_public_command.dart';
import 'support.dart';

const _command = '執一如既往铁观音生效';
const _previous = '執心急如焚核桃仁生效';

String _page(Json doc) =>
    '<html><head><meta name="description" content="$_previous"></head>'
    '<body><script>window.appData = JSON.parse(decodeURIComponent('
    '${jsonEncode(Uri.encodeComponent(encoded({'doc': doc})))}));</script></body></html>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'public markdown HTML exposes the current command in cached lake content',
    () {
      final page = _page({
        'body': '',
        'body_html': '',
        'description': _previous,
        '_cachedContent': {
          'format': 'lake',
          'body':
              '<p>每天复制下方口令</p><pre class="ne-codeblock"><code>$_command</code></pre>'
              '<p>下载后的第一行是密码</p><img alt="$_previous" src="old.png">',
        },
      });
      expect(BaiduPublicCommandSource.extract(page), _command);
    },
  );

  test('rendered HTML and plain markdown remain compatible', () {
    for (final body in [
      '<article><pre><code>$_command</code></pre></article>',
      '<p>复制下方口令</p><p>「$_command」</p>',
      '# 每日更新\n\n```text\n$_command\n```\n',
      _page({'body_html': '<pre><code>$_command</code></pre>'}),
      _page({'body': '每日口令：$_command'}),
      '<pre><code>執一如既往&#x94c1;观音生效</code></pre>',
      '<code>執一如既往\u200b铁观音生效</code>',
    ]) {
      expect(BaiduPublicCommandSource.extract(body), _command);
    }
  });

  test(
    'only the current copyable block is used, duplicate nodes are deduplicated',
    () {
      expect(
        BaiduPublicCommandSource.extract(
          '<script>"$_previous"</script><style>/* $_previous */</style>'
          '<p>旧版截图中的文字：$_previous</p>'
          '<pre><code>$_command</code></pre><code>$_command</code>'
          '<pre hidden>$_previous</pre><img alt="$_previous">',
        ),
        _command,
      );
    },
  );

  test('command length is not tied to one published phrase', () {
    for (final text in ['執短生效', '執不一样的超长每日分享口令生效', '执测试生效']) {
      expect(BaiduPublicCommandSource.extract('<pre>$text</pre>'), text);
    }
  });

  test(
    'copyable blocks accept changing formats without fixed token markers',
    () {
      for (final command in [
        '輸如果你不识解開',
        '~U_Cfc773YARWW~',
        '新样式+_/#123🪁',
        '不限前后缀的口令 ${'a' * 160}',
      ]) {
        for (final body in [
          '<pre><code>$command</code></pre>',
          _page({
            '_cachedContent': {'body': '<pre>$command</pre>'},
          }),
          '# 每日口令\n\n```text\n$command\n```\n',
          '~~~~text\n$command\n~~~~\n',
          '<p>口令：$command</p><p>复制后打开 UC 浏览器</p>',
          '<p>复制下面的口令</p><p>「$command」</p>',
          command,
        ]) {
          expect(BaiduPublicCommandSource.extract(body), command);
        }
      }
    },
  );

  test('automated source still requires one bounded copyable value', () {
    for (final body in [
      '<pre>新口令_one</pre><pre>新口令_two</pre>',
      '<pre>${'x' * 2001}</pre><p>口令：不可退回这个旧口令</p>',
      '```text\n新口令_one\n```\n```text\n新口令_two\n```',
    ]) {
      expect(
        () => BaiduPublicCommandSource.extract(body),
        throwsA(isA<AppException>()),
      );
    }
  });

  test('large bootstrap strings are scanned without a recursive regex', () {
    for (final length in [220000, 800000]) {
      final page = _page({
        'unused': 'x' * length,
        '_cachedContent': {'body': '<pre>$_command</pre>'},
      });
      expect(BaiduPublicCommandSource.extract(page), _command);
    }
  });

  test(
    'embedded strings preserve escaped quotes and skip unrelated appData text',
    () {
      final literal = jsonEncode(
        Uri.encodeComponent(
          encoded({
            'doc': {
              'body_html': '<pre>$_command</pre>',
              'ignored': 'quoted "value" and \\backslash',
            },
          }),
        ).replaceAll('%22', '"').replaceAll('%5C', r'\'),
      );
      final page =
          '<!-- window.appData is initialized below -->'
          '<script>window.appData = JSON.parse(decodeURIComponent($literal));</script>';
      expect(BaiduPublicCommandSource.extract(page), _command);
    },
  );

  test(
    'unterminated and nonliteral bootstrap values fail without executing scripts',
    () {
      for (final value in [
        '"${'x' * 800000}',
        '"${'x' * 220000}" + readFromWindow()))',
        'document.cookie));',
      ]) {
        expect(
          () => BaiduPublicCommandSource.extract(
            'window.appData = JSON.parse(decodeURIComponent($value',
          ),
          throwsA(isA<AppException>()),
        );
      }
    },
  );

  for (final (name, body) in [
    ('missing', '<html><body>暂未公开</body></html>'),
    ('ambiguous', '<pre>$_command</pre><pre>$_previous</pre>'),
    ('private document', _page({'body': '', 'description': _previous})),
    ('script only', '<script>"$_command"</script>'),
    ('image only', '<img alt="$_command" title="$_command">'),
    (
      'invalid percent encoding',
      '<script>window.appData=JSON.parse(decodeURIComponent("%xy"));</script>',
    ),
  ]) {
    test('invalid document fails without guessing: $name', () {
      expect(
        () => BaiduPublicCommandSource.extract(body),
        throwsA(isA<AppException>()),
      );
    });
  }

  test(
    'public document read is bounded, fresh, and sends no login credentials',
    () async {
      final now = DateTime.utc(2026, 10, 12);
      final http = FakeHttp((r) {
        expect(r.method, 'GET');
        expect(
          r.uri.toString(),
          startsWith('${BaiduPublicCommandSource.pageUrl}/markdown?'),
        );
        expect(r.uri.queryParameters['_t'], '${now.millisecondsSinceEpoch}');
        expect(
          r.headers['Range'],
          'bytes=0-${BaiduPublicCommandSource.maximumBytes - 1}',
        );
        expect(r.headers['Cache-Control'], 'no-cache');
        expect(r.headers['User-Agent'], contains('Windows'));
        expect(
          r.headers.keys.map((key) => key.toLowerCase()),
          isNot(anyElement(isIn(['cookie', 'authorization']))),
        );
        return HttpResult(
          200,
          _page({
            '_cachedContent': {'body': '<pre>$_command</pre>'},
          }),
        );
      });
      expect(
        await BaiduPublicCommandSource(http, clock: () => now).read(),
        _command,
      );
      expect(http.calls, hasLength(1));
    },
  );

  test(
    'redirects are restricted to Yuque and remain credential-free',
    () async {
      final http = FakeHttp(
        (r) => r.uri.host == 'www.yuque.com'
            ? const HttpResult(302, '', {
                'location': ['https://yuque.com/public/markdown'],
              })
            : HttpResult(200, '<pre>$_command</pre>'),
      );
      expect(await BaiduPublicCommandSource(http).read(), _command);
      expect(http.calls, hasLength(2));
      final other = FakeHttp(
        (_) => const HttpResult(302, '', {
          'location': ['https://unrelated.example/markdown'],
        }),
      );
      await expectLater(
        BaiduPublicCommandSource(other).read(),
        throwsA(isA<AppException>()),
      );
      expect(other.calls, hasLength(1));
    },
  );

  test(
    'an incomplete range or an HTTP error cannot supply the daily command',
    () async {
      for (final response in [
        HttpResult(206, '<pre>$_command</pre>', {
          'content-range': ['bytes 0-99/200'],
        }),
        HttpResult(503, '<pre>$_command</pre>'),
        HttpResult(200, ' ' * BaiduPublicCommandSource.maximumBytes),
      ]) {
        await expectLater(
          BaiduPublicCommandSource(FakeHttp((_) => response)).read(),
          throwsA(isA<AppException>()),
        );
      }
    },
  );

  testWidgets('a stalled document read is cancelled at its own timeout', (
    tester,
  ) async {
    final response = Completer<HttpResult>();
    final result = BaiduPublicCommandSource(
      FakeHttp((_) => response.future),
    ).read();
    final checked = expectLater(result, throwsA(isA<AppException>()));
    await tester.pump();
    await tester.pump(const Duration(seconds: 13));
    await checked;
    response.complete(HttpResult(200, '<pre>$_command</pre>'));
    await tester.pump();
  });
}
