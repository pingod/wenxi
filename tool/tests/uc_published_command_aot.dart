// Compile this check with `dart compile exe` and run the resulting executable.
// Flutter's JIT tests alone cannot detect AOT regexp interpreter stack overflow.
import 'dart:convert';
import 'dart:io';

import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/uc_published_command.dart';

void main(List<String> args) {
  const command = '執每日验证清茶生效';
  var checks = 0;
  void verify(String page, {bool invalid = false, String? expected}) {
    try {
      final result = UcPublishedCommand.extract(page);
      if (invalid) throw StateError('An invalid document was accepted');
      if (result != (expected ?? command)) {
        throw StateError('Unexpected extracted command');
      }
    } on AppException {
      if (!invalid) rethrow;
    }
    checks++;
  }

  String wrap(String literal) =>
      '<html><script>window.appData = JSON.parse(decodeURIComponent('
      '$literal));</script></html>';
  for (final length in [1, 220000, 800000]) {
    verify(
      wrap(
        jsonEncode(
          Uri.encodeComponent(
            encoded({
              'ignored': 'x' * length,
              'doc': {
                '_cachedContent': {
                  'format': 'lake',
                  'body': '<pre>$command</pre>',
                },
              },
            }),
          ),
        ),
      ),
    );
  }
  verify(
    wrap(
      jsonEncode(
        Uri.encodeComponent(
          encoded({
            'doc': {
              'body_html': '<pre>$command</pre>',
              'ignored': 'quoted "value" and \\backslash',
            },
          }),
        ).replaceAll('%22', '"').replaceAll('%5C', r'\'),
      ),
    ),
  );
  verify('<pre>$command</pre>');
  verify('<pre>輸如果你不识解開</pre>', expected: '輸如果你不识解開');
  verify('```text\n新格式_123🪁\n```', expected: '新格式_123🪁');
  verify(
    'window.appData = JSON.parse(decodeURIComponent("${'x' * 800000}',
    invalid: true,
  );
  verify(
    'window.appData = JSON.parse(decodeURIComponent(document.cookie));',
    invalid: true,
  );
  verify(wrap('"%xy"'), invalid: true);
  verify('<pre>$command</pre><pre>執另一条生效</pre>', invalid: true);

  var realPageCharacters = 0;
  if (args.isNotEmpty) {
    final page = File(args.single).readAsStringSync();
    realPageCharacters = page.length;
    require(
      UcPublishedCommand.extract(page).isNotEmpty,
      'The captured public page did not yield a command',
    );
    checks++;
  }
  stdout.writeln(
    jsonEncode({
      'passed': checks,
      'realPageCharacters': realPageCharacters,
      'productRuntime': const bool.fromEnvironment('dart.vm.product'),
    }),
  );
}
