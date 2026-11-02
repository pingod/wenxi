import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/xunlei_kouling.dart';

void main() {
  test(
    'normalizes surrounding decorations without filtering the token content',
    () {
      expect(XunleiKouling.normalize('【张三丰资源】'), '张三丰资源');
      expect(XunleiKouling.normalize('「张三丰资源」'), '张三丰资源');
      expect(XunleiKouling.normalize('张三丰 资源'), '张三丰 资源');
      expect(XunleiKouling.normalize('@new_令牌+123'), '@new_令牌+123');
    },
  );

  test('builds the jump URL with encoded keyword and channel fields', () {
    final url = XunleiKouling.jumpUrl('张三丰资源');
    expect(url, contains('wd=%E5%BC%A0%E4%B8%89%E4%B8%B0%E8%B5%84%E6%BA%90'));
    expect(url, contains('noredirect=1'));
    expect(url, contains('lm_extend=ctype:31'));
  });

  test('converts jump locations into ordinary share links', () {
    expect(
      XunleiKouling.shareUrlFromLocation(
        'https://pan.xunlei.com/s/VOEs0DLEAfUV9o-JOAqrzgZmA1?channel=x&pwd=nw45',
      ),
      'https://pan.xunlei.com/s/VOEs0DLEAfUV9o-JOAqrzgZmA1?pwd=nw45',
    );
    expect(
      XunleiKouling.shareUrlFromLocation('https://www.example.com/search'),
      isNull,
    );
  });

  test('accepts only a share_page response', () {
    final response = HttpResult(
      200,
      '{"ext":{"kouling_type":"share_page"},"location":"https://pan.xunlei.com/s/abc?pwd=1234"}',
    );
    expect(
      XunleiKouling.shareUrlFromResponse(response.status, response.json),
      'https://pan.xunlei.com/s/abc?pwd=1234',
    );
    expect(
      () => XunleiKouling.shareUrlFromResponse(200, const {
        'ext': {'kouling_type': 'search'},
        'location': 'https://www.so.com',
      }),
      throwsA(isA<AppException>()),
    );
  });
}
