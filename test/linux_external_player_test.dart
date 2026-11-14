import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/external_player_history.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/platform/linux_external_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.asterlink.app/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Linux launches the chosen binary with the media URL', () async {
    final player = LinuxExternalPlayer()
      ..executable = Platform.resolvedExecutable;
    expect(await player.open('https://example.test/movie.mkv'), isTrue);
    expect(calls.single.method, 'openExternalPlayer');
    expect(calls.single.arguments, {
      'application': Platform.resolvedExecutable,
      'url': 'https://example.test/movie.mkv',
    });
  });

  test('Linux reports a missing player instead of launching nothing', () async {
    final player = LinuxExternalPlayer()
      ..executable = '/nonexistent/mpv-player-for-test';
    await expectLater(
      player.open('https://example.test/movie.mkv'),
      throwsA(isA<AppException>()),
    );
    expect(calls, isEmpty);
  });

  test('Linux needs an absolute player path', () async {
    final player = LinuxExternalPlayer()..executable = 'mpv';
    await expectLater(
      player.open('https://example.test/movie.mkv'),
      throwsA(isA<AppException>()),
    );
    expect(calls, isEmpty);
  });

  test(
    'A runner without openExternalPlayer surfaces an actionable message',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw MissingPluginException(
          'No implementation found for method ${call.method}',
        );
      });
      final player = LinuxExternalPlayer()
        ..executable = Platform.resolvedExecutable;
      await expectLater(
        player.open('https://example.test/movie.mkv'),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('播放器启动组件不可用'),
          ),
        ),
      );
    },
  );

  test('Linux player history keeps absolute paths newest first', () async {
    final store = StateStore.memory();
    addTearDown(store.dispose);
    final history = ExternalPlayerHistory(store);
    await history.used('/usr/bin/mpv', platform: 'linux');
    await history.used('/usr/bin/vlc', platform: 'linux');
    expect(history.linux, ['/usr/bin/vlc', '/usr/bin/mpv']);
    // Repeated use moves the entry to the front instead of duplicating it.
    await history.used('/usr/bin/mpv', platform: 'linux');
    expect(history.linux, ['/usr/bin/mpv', '/usr/bin/vlc']);
    // Windows entries must never leak into the Linux list.
    await history.used(r'C:\Players\vlc.exe');
    expect(history.linux, ['/usr/bin/mpv', '/usr/bin/vlc']);
  });

  test('Linux player history rejects relative and control paths', () async {
    final store = StateStore.memory();
    addTearDown(store.dispose);
    final history = ExternalPlayerHistory(store);
    await expectLater(
      history.used('mpv', platform: 'linux'),
      throwsA(isA<AppException>()),
    );
    expect(history.linux, isEmpty);
    await store.change((draft) {
      draft['linuxExternalPlayers'] = [
        '/usr/bin/mpv',
        'relative/mpv',
        '/usr/bin/\u0000bad',
        '/usr/bin/vlc',
      ];
    });
    expect(history.linux, ['/usr/bin/mpv', '/usr/bin/vlc']);
  });
}
