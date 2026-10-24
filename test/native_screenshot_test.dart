import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/playback/media_backend.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = mpvTestLibrary();
  test(
    'Native screenshot and close serialize access to the mpv handle',
    () async {
      MediaKit.ensureInitialized(libmpv: library);
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null', libass: true),
      );
      final native = player.platform as NativePlayer;
      final backend = MediaKitBackend(video: false, player: player);
      addTearDown(backend.close);
      await native.setProperty('ao', 'null');
      await native.setProperty('vid', 'auto');
      await native.setProperty('hwdec', 'no');
      await backend.open(
        DownloadSpec(
          url: File('test/fixtures/player-sample.mkv').absolute.path,
          fileName: 'sample.mkv',
        ),
        Duration.zero,
      );
      await backend.play();
      await until(
        () =>
            player.state.position.inMilliseconds >= 300 &&
            backend.supportsScreenshot,
      );
      await backend.pause();
      final clean = await backend.screenshot();
      expect(clean, isNotNull);
      expect(clean!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      final pending = backend.screenshot(includeSubtitles: true);
      await Future<void>.value();
      final closing = backend.close();
      await pending;
      await closing;
      expect(await backend.screenshot(), isNull);
    },
    skip: library == null ? 'A local libmpv runtime is required.' : false,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
