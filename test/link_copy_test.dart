import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ParsedLink link(
    String url, {
    CloudPlatform platform = CloudPlatform.quark,
    String? code = 'new1',
    LinkKind kind = LinkKind.cloudShare,
  }) => ParsedLink(
    source: url,
    url: url,
    platform: platform,
    kind: kind,
    passcode: code,
  );

  test(
    'Copied shares keep literal extraction codes and unchanged encoded query values',
    () {
      expect(
        link('https://pan.quark.cn/s/test', code: 'A%2B+B').textForCopy,
        'https://pan.quark.cn/s/test 提取码：A%2B+B',
      );
      expect(
        link(
          'https://pan.quark.cn/s/test?pwd=%41%252B%2BB',
          code: 'A%2B+B',
        ).textForCopy,
        'https://pan.quark.cn/s/test?pwd=%41%252B%2BB 提取码：A%2B+B',
      );
    },
  );

  test(
    'Manually corrected codes replace stale URL passwords without changing share identity or other fields',
    () {
      final share = link(
        'https://pan.baidu.com/s/1example?token=A%2B+B&pwd=old1&password=old1',
        platform: CloudPlatform.baidu,
      );
      expect(
        share.textForCopy,
        'https://pan.baidu.com/s/1example?token=A%2B+B&pwd=new1&password=new1 提取码：new1',
      );
      expect(LinkParser.parse(share.textForCopy).single.passcode, 'new1');
      expect(share.url, contains('pwd=old1'));
    },
  );

  test('Tianyi code and Wopan shareCode parameters remain share identifiers', () {
    expect(
      link(
        'https://cloud.189.cn/web/share?code=shareID12345&accessCode=old1',
        platform: CloudPlatform.tianyi,
      ).textForCopy,
      'https://cloud.189.cn/web/share?code=shareID12345&accessCode=new1 提取码：new1',
    );
    expect(
      link(
        'https://pan.wo.cn/s?shareCode=shareID&pwd=old1',
        platform: CloudPlatform.wopan,
      ).textForCopy,
      'https://pan.wo.cn/s?shareCode=shareID&pwd=new1 提取码：new1',
    );
  });

  test('Fragment query and bare password fragments use the current code', () {
    expect(
      link('https://pan.quark.cn/#/s/test?pwd=old1&x=A%2b+B').textForCopy,
      'https://pan.quark.cn/#/s/test?pwd=new1&x=A%2b+B 提取码：new1',
    );
    expect(
      link('https://pan.quark.cn/s/test#old1').textForCopy,
      'https://pan.quark.cn/s/test#new1 提取码：new1',
    );
    expect(
      link('https://pan.quark.cn/s/test#pwd=old1').textForCopy,
      'https://pan.quark.cn/s/test#pwd=new1 提取码：new1',
    );
  });

  test(
    'Nested redirect URLs are preserved and provider-specific password fields update',
    () {
      expect(
        link(
          'https://pan.quark.cn/s/test?redirect=https://example.test/?pwd=keep&pwd=old1',
        ).textForCopy,
        'https://pan.quark.cn/s/test?redirect=https://example.test/?pwd=keep&pwd=new1 提取码：new1',
      );
      expect(
        link(
          'https://ctfile.com/f/123-456?p=old1',
          platform: CloudPlatform.ctfile,
        ).textForCopy,
        'https://ctfile.com/f/123-456?p=new1 提取码：new1',
      );
      expect(
        link(
          'https://feijipan.com/s/abc123?code=old1',
          platform: CloudPlatform.feijipan,
        ).textForCopy,
        'https://feijipan.com/s/abc123?code=new1 提取码：new1',
      );
      expect(
        link(
          'https://mypikpak.com/s/abc?pass_code=old1',
          platform: CloudPlatform.pikpak,
        ).textForCopy,
        'https://mypikpak.com/s/abc?pass_code=new1 提取码：new1',
      );
    },
  );

  test(
    'Direct and magnet URLs and shares without separate codes copy verbatim',
    () {
      for (final (url, kind) in [
        (
          'https://example.test/a.zip?password=signed&token=A%2b+B',
          LinkKind.direct,
        ),
        ('magnet:?xt=urn:btih:0123456789abcdef&dn=a%2bb', LinkKind.magnet),
      ]) {
        expect(link(url, kind: kind).textForCopy, url);
      }
      expect(
        link('https://pan.quark.cn/s/test?pwd=old1', code: null).textForCopy,
        'https://pan.quark.cn/s/test?pwd=old1',
      );
    },
  );
}
