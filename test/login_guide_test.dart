import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/login_guide.dart';
import 'package:asterlink/domain/models.dart';

void main() {
  test('every platform reachable from a browser has a guide', () {
    for (final platform in CloudPlatform.values) {
      final guide = LoginGuide.forPlatform(platform);
      if (platform == CloudPlatform.ctfile ||
          platform == CloudPlatform.github) {
        expect(guide, isNotNull, reason: '${platform.name} needs a guide');
        continue;
      }
      // Every platform except GitHub is logged in through its website.
      expect(guide, isNotNull, reason: '${platform.name} needs a guide');
      expect(guide!.url, startsWith('https://'));
      expect(guide.steps, isNotEmpty);
    }
    expect(
      LoginGuide.forPlatform(CloudPlatform.pan115)!.source,
      LoginCredentialSource.cookie,
    );
    expect(
      LoginGuide.forPlatform(CloudPlatform.aliyun)!.source,
      LoginCredentialSource.storage,
    );
    expect(LoginGuide.forPlatform(CloudPlatform.aliyun)!.storageKey, 'token');
    expect(
      LoginGuide.forPlatform(CloudPlatform.pan123)!.source,
      LoginCredentialSource.token,
    );
  });

  test('steps name the Local Storage key the site actually uses', () {
    final aliyun = LoginGuide.forPlatform(CloudPlatform.aliyun)!;
    expect(aliyun.steps.join('\n'), contains('token'));
    // Cookies have no key to name; the steps must point at DevTools instead.
    final baidu = LoginGuide.forPlatform(CloudPlatform.baidu)!;
    expect(baidu.steps.join('\n'), contains('Cookie'));
    expect(baidu.steps.join('\n'), isNot(contains('Local Storage')));
  });

  test('a Cookie header from the clipboard becomes the stored cookie', () {
    final value = LoginGuide.extract(
      CloudPlatform.baidu,
      'BDUSS=clipboard-cookie; STOKEN=token-value',
    );
    expect(value, 'BDUSS=clipboard-cookie; STOKEN=token-value');
  });

  test('a "Cookie:" line copied out of DevTools is unwrapped', () {
    expect(
      LoginGuide.extract(CloudPlatform.quark, 'Cookie: __pus=abc; __puus=def'),
      '__pus=abc; __puus=def',
    );
    expect(
      LoginGuide.extract(
        CloudPlatform.baidu,
        'request header\ncookie: BDUSS=multi-line; STOKEN=s',
      ),
      'BDUSS=multi-line; STOKEN=s',
    );
  });

  test('DevTools cookie table rows are rebuilt into one header', () {
    const table =
        'Name\tValue\tDomain\tPath\n'
        'BDUSS\tfrom-table\t.baidu.com\t/\n'
        'STOKEN\tsecond\t.baidu.com\t/\n';
    expect(
      LoginGuide.extract(CloudPlatform.baidu, table),
      'BDUSS=from-table; STOKEN=second',
    );
    // One row is not enough evidence, and a banner row must not leak in.
    expect(LoginGuide.extract(CloudPlatform.baidu, 'Name\tValue'), isNull);
  });

  test('a JSON Local Storage value survives surrounding quotes', () {
    const token =
        '{"access_token":"access-from-storage","refresh_token":"refresh-from-storage"}';
    expect(
      LoginGuide.extract(CloudPlatform.aliyun, token),
      contains('access-from-storage'),
    );
    expect(
      LoginGuide.extract(
        CloudPlatform.aliyun,
        '"${token.replaceAll('"', r'\"')}"',
      ),
      contains('access-from-storage'),
    );
  });

  test('a JSON value copied with its table row still yields the token', () {
    final value = LoginGuide.extract(
      CloudPlatform.wopan,
      'refresh_token\t{"refresh_token":"r-token-value-long"}\tlocalStorage',
    );
    expect(value, contains('r-token-value-long'));
  });

  test('prose without a credential is rejected', () {
    for (final platform in [
      CloudPlatform.baidu,
      CloudPlatform.pan115,
      CloudPlatform.aliyun,
      CloudPlatform.pan123,
    ]) {
      expect(LoginGuide.extract(platform, '登录成功，欢迎回来'), isNull);
      expect(LoginGuide.extract(platform, ''), isNull);
      expect(LoginGuide.extract(platform, null), isNull);
    }
  });

  test('oversized clipboard text is ignored', () {
    final huge = 'BDUSS=${'x' * (64 * 1024)}';
    expect(LoginGuide.extract(CloudPlatform.baidu, huge), isNull);
  });

  test('the GitHub token guide accepts a personal access token', () {
    final guide = LoginGuide.forPlatform(CloudPlatform.github)!;
    expect(guide.url, 'https://github.com/settings/tokens');
    expect(
      LoginGuide.extract(CloudPlatform.github, 'ghp_${'a' * 30}'),
      'ghp_${'a' * 30}',
    );
  });
}
