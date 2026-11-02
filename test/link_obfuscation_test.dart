import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/github.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/platform/clipboard_links.dart';
import 'package:asterlink/platform/external_open.dart';

void main() {
  const clean = 'https://github.com/diabl0w/DFRoot/releases';
  const shared = 'https://删github.com/删diabl0w/删DFRoot/releases';

  test('A scheme-less direct URL retains its original paste for history', () {
    const source = 'exam删ple.com/fil删e.zip';
    final link = LinkParser.parse(source).single;
    expect(link.url, 'https://example.com/file.zip');
    expect(link.source, source);
    expect(link.kind, LinkKind.direct);
  });

  test('The provided link opens the original GitHub release coordinates', () {
    final link = LinkParser.parse(shared).single;
    expect(link.url, clean);
    expect(link.source, shared);
    expect(link.kind, LinkKind.cloudShare);
    expect(link.platform, CloudPlatform.github);
    final github = GitHubLink.parse(Uri.parse(link.url))!;
    expect(github.owner, 'diabl0w');
    expect(github.repo, 'DFRoot');
    expect(github.route, 'releases');
  });

  for (final marker in ['删', '删删', '%E5%88%A0', '%e5%88%a0', '删%E5%88%A0删']) {
    test('Restores a $marker marker at every character boundary', () {
      for (var index = 0; index <= clean.length; index++) {
        final input =
            '${clean.substring(0, index)}$marker${clean.substring(index)}';
        final links = LinkParser.parse(input);
        expect(links, hasLength(1), reason: 'position $index: $input');
        expect(links.single.url, clean, reason: 'position $index: $input');
        expect(links.single.platform, CloudPlatform.github);
        expect(links.single.kind, LinkKind.cloudShare);
        expect(LinkParser.normalize(input), clean);
      }
    });
  }

  test(
    'Scattered markers can separate every protocol, host and path character',
    () {
      final input = '删${clean.split('').join('删删')}删';
      final link = LinkParser.parse(input).single;
      expect(link.url, clean);
      expect(link.kind, LinkKind.cloudShare);
    },
  );

  test(
    'Bare hosts, Markdown, surrounding quotes and URL duplicates are accepted',
    () {
      for (final input in [
        '删git删hub.co删m/di删abl0w/DFR删oot/releas删es',
        '下载：删git删hub.com/删diabl0w/删DFRoot/releases。',
        '[发布页面]($shared)',
        '“[$shared]($shared)”',
        '“$shared”',
        '‘$shared’',
        '$shared\n$clean',
      ]) {
        final links = LinkParser.parse(input);
        expect(links, hasLength(1), reason: input);
        expect(links.single.url, clean, reason: input);
        expect(links.single.source, input);
        expect(links.single.platform, CloudPlatform.github);
      }
    },
  );

  test(
    'URL code markers are removed and adjacent labels keep their own share',
    () {
      final links = LinkParser.parse(
        '请删除说明文字，只取链接：\n'
        'https://删pan.quark.cn/s/删First提取码：q123\n\n'
        '提取码：u123\nhttps://drive.u删c.cn/s/Se删cond\n\n'
        'https://pan.baidu.com/s/1Thi删rd?pw删d=b删123 密码：old1',
      );
      expect(links.map((link) => link.shareId), ['First', 'Second', 'Third']);
      expect(links.map((link) => link.passcode), ['q123', 'u123', 'b123']);
      expect(links.every((link) => !link.url.contains('删')), true);
      final duplicate = LinkParser.parse(
        'https://删pan.quark.cn/s/Fi删rst\nhttps://pan.quark.cn/s/First 提取码：q123',
      );
      expect(duplicate, hasLength(1));
      expect(duplicate.single.passcode, 'q123');
    },
  );

  test(
    'Signed URL bytes, path case and query order survive marker removal',
    () {
      const input =
          'HT删TPS://Exam删ple.COM/X%2删fY%2Fz?b=2&a=%2b+%20&a=删3#frag删ment';
      const expected =
          'https://example.com/X%2fY%2Fz?b=2&a=%2b+%20&a=3#fragment';
      expect(LinkParser.normalize(input), expected);
      expect(LinkParser.parse(input).single.url, expected);
    },
  );

  test(
    'Literal and encoded Chinese names and surrounding prose remain unchanged',
    () {
      for (final name in [
        '删除说明.md',
        '请勿删.txt',
        '误删恢复.zip',
        '%E5%88%A0%E9%99%A4%E8%AF%B4%E6%98%8E.md',
        '%e5%88%a0除说明.md',
        '删%E9%99%A4说明.md',
      ]) {
        final url = 'https://github.com/sample/files/blob/main/$name';
        expect(LinkParser.parse(url).single.url, url);
        expect(LinkParser.normalize(url), url);
        final obscured = url.replaceFirst('github', '删github');
        expect(LinkParser.parse(obscured).single.url, url);
      }
      const prose = '删掉干扰文字后打开 $shared，删除说明不要改。';
      final link = LinkParser.parse(prose).single;
      expect(link.url, clean);
      expect(link.source, prose);
      const query =
          'https://example.com/file?name=%E5%88%A0%E9%99%A4&note=勿删&sig=Ab%2b+%20';
      expect(LinkParser.parse(query).single.url, query);
    },
  );

  test(
    'Cleaning does not grant a lookalike, login or nested URL GitHub status',
    () {
      for (final input in [
        'https://删github.com.evil.test/diabl0w/DFRoot/releases',
        'https://example.com/?next=https://删github.com/diabl0w/DFRoot/releases',
        'https://github.com/删login',
        'https://github.com/sample/files/删issues/1',
      ]) {
        final links = LinkParser.parse(input);
        expect(
          links.where((link) => link.kind == LinkKind.cloudShare),
          isEmpty,
          reason: input,
        );
        expect(ClipboardLinkSuggestion.fromText(input), isNull, reason: input);
      }
      for (final input in [
        'https://删user:pass@github.com/diabl0w/DFRoot/releases',
        'https://删github.com/diabl0w/DFRoot/%oops',
        'ftp://删github.com/diabl0w/DFRoot/releases',
      ]) {
        expect(() => LinkParser.normalize(input), throwsA(isA<AppException>()));
        expect(ClipboardLinkSuggestion.fromText(input), isNull, reason: input);
      }
    },
  );

  test(
    'Clipboard deduplication and system sharing use the same restored URL',
    () {
      final suggestion = ClipboardLinkSuggestion.fromText(shared)!;
      expect(suggestion.text, clean);
      expect(
        suggestion.fingerprint,
        ClipboardLinkSuggestion.fromText(clean)!.fingerprint,
      );
      final request = ExternalOpenRequest.fromPlatform({
        'id': 'delete-marker-share',
        'kind': 'share',
        'text': shared,
      });
      expect(request.kind, ExternalOpenKind.share);
      expect(LinkParser.parse(request.sharedText).single.url, clean);
      expect(request.downloadUrl, isNull);
    },
  );

  test('Long non-URL marker runs and prose do not produce a link', () {
    expect(LinkParser.parse('${'删' * 16384}说明文字'), isEmpty);
    expect(LinkParser.parse('请删除原链接，然后重新发送。'), isEmpty);
  });
}
