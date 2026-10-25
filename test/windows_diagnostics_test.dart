import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/diagnostics/diagnostic_bundle.dart';
import 'package:asterlink/diagnostics/diagnostic_runtime.dart';
import 'package:asterlink/diagnostics/windows_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final enabled in [false, true]) {
    test(
      'Windows startup uses native paths and the saved recording preference: $enabled',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'windows-runtime-diagnostics-',
        );
        const channel = MethodChannel('com.asterlink.app/diagnostics');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'diagnosticPaths');
          return {
            'logs': directory.path,
            'enabled': enabled,
            'session': 'fixture-native-session',
            'pid': 123,
          };
        });
        addTearDown(() async {
          DiagnosticRuntime.stop();
          DiagnosticLog.active = null;
          messenger.setMockMethodCallHandler(channel, null);
          await directory.delete(recursive: true);
        });
        final log = await DiagnosticRuntime.start();
        expect(log.directory!.path, directory.path);
        expect(log.enabled, enabled);
        if (enabled) {
          expect(
            log
                .entries()
                .firstWhere((entry) => entry.event == 'logging.native_session')
                .data['fields'],
            containsPair('nativeSession', 'fixture-native-session'),
          );
        } else {
          expect(log.entries(), isEmpty);
          expect(File('${directory.path}/disabled').existsSync(), isTrue);
        }
      },
      skip: !Platform.isWindows,
    );
  }

  test(
    'Windows exception details and complete native steps survive ZIP export',
    () async {
      final now = DateTime.utc(2026, 10, 18, 11);
      final log = DiagnosticLog.open(null, clock: () => now);
      addTearDown(log.close);
      final bundle = DiagnosticBundle(
        log,
        snapshot: () => {},
        nativeCall: (_, _) async => {
          'system': 'windows',
          'reports': [
            {
              'content': jsonEncode({
                'time': now.millisecondsSinceEpoch,
                'event': 'windows.unhandled_exception',
                'exceptionCode': '0xc0000005',
                'faultModule': 'flutter_inappwebview_windows_plugin.dll',
                'faultOffset': '0x1234',
                'frames': [
                  {'module': 'asterlink.exe', 'offset': '0x123'},
                ],
              }),
            },
          ],
          'traces': [
            {
              'content':
                  '${jsonEncode({'time': now.millisecondsSinceEpoch, 'event': 'webview.cookie_read_completed', 'value1': 4, 'value2': 0, 'value3': 1, 'cookie': 'fixture-private-cookie'})}\n{"event":"partial-private',
            },
          ],
          'exits': [
            {
              'time': now.millisecondsSinceEpoch,
              'reason': 'native_crash',
              'source': 'windows_application_error',
              'exceptionCode': 'c0000409',
              'faultModule': 'KERNELBASE.dll',
              'version': '1.9.0.190',
            },
          ],
        },
      );
      final summary = await bundle.summary();
      expect(summary, contains('0xc0000005'));
      expect(summary, contains('flutter_inappwebview_windows_plugin.dll'));
      expect(summary, contains('c0000409'));
      expect(summary, isNot(contains('Android 异常')));
      final zip = ZipDecoder().decodeBytes(await bundle.build());
      final entries = {
        for (final file in zip.files)
          file.name: utf8.decode(file.content as List<int>),
      };
      expect(
        entries['native/windows-trace-0.jsonl'],
        contains('webview.cookie_read_completed'),
      );
      expect(entries['native/system.json'], isNot(contains('"traces"')));
      expect(entries.values.join('\n'), isNot(contains('private')));
    },
  );

  test(
    'Native export is bounded and skips old records and truncated tail writes',
    () {
      final now = DateTime.now().toUtc();
      String record(int days, String event) => jsonEncode({
        'time': now.subtract(Duration(days: days)).millisecondsSinceEpoch,
        'event': event,
      });
      final files = windowsDiagnosticTraces({
        'traces': [
          for (var i = 0; i < 10; i++)
            {
              'content':
                  '${record(8, 'old')}\n${record(0, 'current')}\n${record(0, 'incomplete')}',
            },
        ],
      }, now);
      expect(files, hasLength(8));
      for (final content in files.values) {
        expect(content, contains('current'));
        expect(content, isNot(contains('old')));
        expect(content, isNot(contains('incomplete')));
      }
      expect(
        windowsDiagnosticTraces({
          'traces': [
            {'content': 'x' * (256 * 1024 + 1)},
          ],
        }, now),
        isEmpty,
      );
    },
  );

  test(
    'Windows default native channel handles export, opt-out and clear',
    () async {
      final calls = <String>[];
      const channel = MethodChannel('com.asterlink.app/diagnostics');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return call.method == 'diagnosticSnapshot'
                ? {'system': 'windows'}
                : null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final log = DiagnosticLog.open(null);
      addTearDown(log.close);
      final bundle = DiagnosticBundle(log, snapshot: () => {});
      expect((await bundle.platformSnapshot())['system'], 'windows');
      await bundle.setEnabled(false);
      expect(log.enabled, isFalse);
      await bundle.clear();
      expect(calls, [
        'diagnosticSnapshot',
        'diagnosticEnabled',
        'diagnosticClear',
      ]);
    },
    skip: !Platform.isWindows,
  );
}
