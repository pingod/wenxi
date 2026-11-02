import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/platform/linux_actions.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('asterlink-linux-actions-');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'FileManager1 selects a file, otherwise xdg-open shows its folder',
    () async {
      final file = await File(
        p.join(root.path, '中文 video & (1).mp4'),
      ).writeAsString('x');
      final calls = <(String, List<String>)>[];
      ProcessResult reply(int code) =>
          ProcessResult(0, code, const <String>[], const <String>[]);

      final actions = LinuxActions(
        supported: true,
        run: (command, arguments) async {
          calls.add((command, arguments));
          // Simulate a desktop without the optional FileManager1 backend.
          return reply(calls.length == 1 ? 1 : 0);
        },
      );
      await actions.revealFile(file.path);
      expect(calls.length, 2);
      expect(calls.first.$1, 'gdbus');
      expect(
        calls.first.$2,
        contains("[${_literal(Uri.file(p.normalize(file.path)).toString())}]"),
      );
      expect(calls.last.$1, 'xdg-open');
      expect(calls.last.$2, [p.normalize(root.path)]);
    },
  );

  test(
    'File names containing commas quote or backslashes reach D-Bus intact',
    () async {
      // dbus-send's `array:string:` splits on commas, which silently turned
      // `a,b.mp4` into two URIs while still exiting 0.
      for (final name in [
        'a,b.mp4',
        "it's a video.mp4",
        r'back\slash.mp4',
        'quote".mp4',
      ]) {
        final file = await File(p.join(root.path, name)).writeAsString('x');
        late List<String> arguments;
        final actions = LinuxActions(
          supported: true,
          run: (command, args) async {
            expect(command, 'gdbus');
            arguments = args;
            return ProcessResult(0, 0, const <String>[], const <String>[]);
          },
        );
        await actions.revealFile(file.path);
        final uri = Uri.file(p.normalize(file.path)).toString();
        // gdbus puts the GVariant array right after --method <name>.
        final literal = arguments[arguments.length - 2];
        expect(literal, '[${_literal(uri)}]');
        // Exactly one array element: no unescaped separator survives.
        expect(literal, isNot(contains("', '")));
      }
    },
  );

  test(
    'revealFile rejects missing and relative paths without running commands',
    () async {
      var ran = 0;
      final actions = LinuxActions(
        supported: true,
        run: (_, _) async {
          ran++;
          return ProcessResult(0, 0, const <String>[], const <String>[]);
        },
      );
      await expectLater(
        actions.revealFile(p.join(root.path, 'missing.mp4')),
        throwsA(isA<AppException>()),
      );
      await expectLater(
        actions.revealFile('relative.mp4'),
        throwsA(isA<AppException>()),
      );
      expect(ran, 0);
    },
  );

  test('Shutdown is refused when the platform is unsupported', () async {
    final unavailable = LinuxActions(
      supported: false,
      run: (_, _) async => fail('Unsupported platform must not run commands'),
    );
    await expectLater(unavailable.shutdown(), throwsA(isA<AppException>()));
  });

  test('Shutdown reports a rejected poweroff request', () async {
    final actions = LinuxActions(
      supported: true,
      run: (command, arguments) async {
        expect(command, 'systemctl');
        expect(arguments, ['poweroff']);
        return ProcessResult(0, 1, const <String>[], const <String>['denied']);
      },
    );
    await expectLater(actions.shutdown(), throwsA(isA<AppException>()));
  });
}

/// Mirrors the GVariant single-quoted literal built by LinuxActions.
String _literal(String value) =>
    "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
