import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/baidu_web_login.dart';

void main() {
  test('Baidu form adapter only trusts the official main document', () {
    expect(BaiduWebLogin.trusted('https://pan.baidu.com/'), isTrue);
    expect(BaiduWebLogin.trusted('https://pan.baidu.com:443/'), isTrue);
    for (final value in [
      null,
      'http://pan.baidu.com/',
      'https://pan.baidu.com.evil.example/',
      'https://passport.baidu.com/',
      'https://pan.baidu.com:444/',
      'https://user@pan.baidu.com/',
      'https://pan.baidu.com/disk/main',
    ]) {
      expect(BaiduWebLogin.trusted(value), isFalse, reason: value);
    }
  });

  test('Baidu input and QR images are constrained to the official formats', () {
    expect(BaiduWebLogin.validMobile('13800138000'), isTrue);
    expect(BaiduWebLogin.validMobile('23800138000'), isFalse);
    expect(BaiduWebLogin.validCode('012345'), isTrue);
    expect(BaiduWebLogin.validCode('1234'), isFalse);
    expect(BaiduWebLogin.validCode('1234567'), isFalse);
    const qr = 'https://passport.baidu.com/v2/api/qrcode?sign=fixture';
    expect(BaiduWebLogin.qrImage(qr), qr);
    for (final value in [
      'https://passport.baidu.com.evil.example/v2/api/qrcode',
      'https://passport.baidu.com:444/v2/api/qrcode',
      'https://user@passport.baidu.com/v2/api/qrcode',
      'http://passport.baidu.com/v2/api/qrcode',
      'https://passport.baidu.com/other',
      'data:image/png;base64,fixture',
    ]) {
      expect(BaiduWebLogin.qrImage(value), isEmpty);
    }
    expect(BaiduWebLogin.decode('not json'), isEmpty);
    expect(BaiduWebLogin.decode('null'), isEmpty);
  });

  test(
    'official SDK adapter dispatches once and preserves user verification',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-baidu-adapter-',
      );
      try {
        final fixture = File('${directory.path}/scripts.json');
        await fixture.writeAsString(
          jsonEncode({
            'bootstrap': BaiduWebLogin.bootstrap('fixture-session'),
            'read': BaiduWebLogin.read('fixture-session'),
            'send': BaiduWebLogin.command('fixture-session', 'send', {
              'id': 'native-send',
              'mobile': '13800138000',
              'agreed': true,
            }),
            'wrongSession': BaiduWebLogin.command('other-session', 'send', {
              'id': 'wrong-session',
              'mobile': '13800138000',
              'agreed': true,
            }),
          }),
        );
        final result = await Process.run('node', [
          File('tool/baidu-login-scripts.test.cjs').absolute.path,
          fixture.path,
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        stdout.write(result.stdout);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
