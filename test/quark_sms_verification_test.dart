import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/quark_sms_verification.dart';

void main() {
  test(
    'official captcha adapter captures proof without sending SMS or submitting a code',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-quark-captcha-',
      );
      try {
        final fixture = File('${directory.path}/scripts.json');
        await fixture.writeAsString(
          jsonEncode({
            'capture': QuarkSmsVerification.captureScript(useSlider: false),
            'slider': QuarkSmsVerification.captureScript(useSlider: true),
          }),
        );
        final result = await Process.run('node', [
          File('tool/quark-login-scripts.test.cjs').absolute.path,
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
