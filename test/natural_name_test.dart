import 'package:asterlink/core/natural_name.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<String> sorted(List<String> names, {bool ascending = true}) {
    final keys = {for (final name in names) name: NaturalName(name)};
    return [...names]..sort((a, b) {
      final order = keys[a]!.compareTo(keys[b]!);
      return ascending ? order : -order;
    });
  }

  test('episode names compare the complete number in either direction', () {
    final names = [
      for (final episode in [19, 1, 10, 11, 2, 9, 20, 100]) '第$episode集.mp4',
    ];
    final expected = [
      for (final episode in [1, 2, 9, 10, 11, 19, 20, 100]) '第$episode集.mp4',
    ];
    expect(sorted(names), expected);
    expect(sorted(names, ascending: false), expected.reversed);
  });

  test('season and episode segments compare independently', () {
    expect(sorted(['S02E01.mkv', 'S01E10.mkv', 's01e02.mkv', 'S01E1.mkv']), [
      'S01E1.mkv',
      's01e02.mkv',
      'S01E10.mkv',
      'S02E01.mkv',
    ]);
    expect(NaturalName('S01E1.MKV').compareTo(NaturalName('s1e001.mkv')), 0);
    expect(NaturalName('第1集.mp4').compareTo(NaturalName('第01集.mp4')), 0);
  });

  test('Chinese episode and season numbers follow numeric order', () {
    expect(sorted(['第一百零二集', '第十二集', '第一集', '第十集', '第二集']), [
      '第一集',
      '第二集',
      '第十集',
      '第十二集',
      '第一百零二集',
    ]);
    expect(sorted(['第十季', '第两季', '第一季']), ['第一季', '第两季', '第十季']);
  });

  test('very long numbers do not overflow and plain names still sort', () {
    final smaller = '9' * 40, larger = '1${'0' * 40}';
    expect(sorted(['part$larger.zip', 'part$smaller.zip']), [
      'part$smaller.zip',
      'part$larger.zip',
    ]);
    expect(sorted(['Bravo.txt', 'alpha.txt', '', 'Charlie.txt']), [
      '',
      'alpha.txt',
      'Bravo.txt',
      'Charlie.txt',
    ]);
  });
}
