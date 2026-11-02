import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/platform/native_engine.dart';

void main() {
  for (final code in [5, 577, 1260, 4551]) {
    test(
      'Windows policy error $code identifies the blocked component',
      () async {
        final transport = DesktopGopeedTransport(
          executable: Platform.resolvedExecutable,
          launchProcess: (file) async =>
              throw ProcessException(file, [], 'blocked', code),
        );
        await expectLater(
          transport.call('open'),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              allOf(contains('Windows 安全策略'), contains('下载进度已保留')),
            ),
          ),
        );
        expect(transport.connected, isFalse);
        await transport.dispose();
      },
    );
  }

  test(
    'other launch errors do not blame the network or Windows policy',
    () async {
      final transport = DesktopGopeedTransport(
        executable: Platform.resolvedExecutable,
        launchProcess: (file) async =>
            throw ProcessException(file, [], 'bad executable', 193),
      );
      await expectLater(
        transport.call('open'),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            allOf(contains('错误 193'), contains('完整版本'), isNot(contains('网络'))),
          ),
        ),
      );
      await transport.dispose();
    },
  );
}
