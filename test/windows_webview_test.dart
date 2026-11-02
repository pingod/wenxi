import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/platform/windows_webview.dart';

class _Environment extends Fake implements WebViewEnvironment {
  int disposals = 0;
  @override
  Future<void> dispose() async => disposals++;
}

void main() {
  late Directory root;
  setUp(
    () async =>
        root = await Directory.systemTemp.createTemp('webview-recovery-'),
  );
  tearDown(() async => root.delete(recursive: true));

  WindowsWebViewHost host(
    Future<WebViewEnvironment> Function(String) factory, {
    String? version = '130.0.0.0',
  }) => WindowsWebViewHost(
    primaryFolder: p.join(root.path, 'original'),
    recoveryFolder: p.join(root.path, 'recovery'),
    availableVersion: () async => version,
    createEnvironment: factory,
  );

  test(
    'failed profile recovers once, keeps the original data and shares startup',
    () async {
      final original = File(p.join(root.path, 'original', 'Cookies'));
      await original.parent.create();
      await original.writeAsString('existing profile');
      final calls = <String>[], pending = Completer<WebViewEnvironment>();
      final environment = _Environment();
      final service = host((folder) async {
        calls.add(p.basename(folder));
        if (calls.length == 1) {
          throw PlatformException(
            code: 'webview_environment_create',
            message: 'Catastrophic failure',
            details: {'hresult': 0x8000ffff},
          );
        }
        return pending.future;
      });
      final first = service.get(), second = service.get();
      expect(identical(first, second), isTrue);
      pending.complete(environment);
      expect(await first, same(environment));
      expect(await second, same(environment));
      expect(await service.get(), same(environment));
      expect(calls, ['original', 'recovery']);
      expect(await original.readAsString(), 'existing profile');
      await service.close();
      await service.close();
      expect(environment.disposals, 1);
    },
  );

  test(
    'directory access failure also uses the writable recovery profile',
    () async {
      var calls = 0;
      final environment = _Environment();
      final service = host((folder) async {
        if (++calls == 1) throw FileSystemException('Access denied', folder);
        return environment;
      });
      expect(await service.get(), same(environment));
      expect(calls, 2);
      await service.close();
    },
  );

  test(
    'recovery is bounded, reports HRESULT, and a manual retry can succeed',
    () async {
      var calls = 0, failing = true;
      final environment = _Environment();
      final service = host((_) async {
        calls++;
        if (failing) {
          throw PlatformException(
            code: 'webview_environment_create',
            details: {'hresult': 0x8000ffff},
          );
        }
        return environment;
      });
      await expectLater(
        service.get(),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            allOf(contains('0x8000FFFF'), contains('独立登录环境')),
          ),
        ),
      );
      expect(calls, 2);
      failing = false;
      expect(await service.get(), same(environment));
      expect(calls, 3);
      await service.close();
    },
  );

  test('missing runtime is reported before creating profiles', () async {
    final service = host((_) async => fail('No runtime'), version: null);
    await expectLater(
      service.get(),
      throwsA(
        isA<AppException>().having(
          (e) => e.message,
          'message',
          contains('未找到 Microsoft Edge WebView2 Runtime'),
        ),
      ),
    );
    await service.close();
  });

  test(
    'renderer loss creates a fresh environment and ignores late old callbacks',
    () async {
      final first = _Environment(), second = _Environment();
      var calls = 0;
      final service = host((_) async => ++calls == 1 ? first : second);
      expect(await service.get(), same(first));
      service.invalidate(first);
      expect(await service.get(), same(second));
      expect(first.disposals, 0);
      service.invalidate(first);
      expect(await service.get(), same(second));
      expect(calls, 2);
      await service.close();
      expect(first.disposals, 1);
      expect(second.disposals, 1);
    },
  );

  test('closing during startup disposes the late environment', () async {
    final entered = Completer<void>(),
        pending = Completer<WebViewEnvironment>();
    final environment = _Environment();
    final service = host((_) {
      entered.complete();
      return pending.future;
    });
    final opening = expectLater(service.get(), throwsA(isA<AppException>()));
    await entered.future;
    final closing = service.close();
    pending.complete(environment);
    await opening;
    await closing;
    expect(environment.disposals, 1);
    expect(() => service.get(), throwsA(isA<AppException>()));
  });
}
