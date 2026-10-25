import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/platform/external_open.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AppServices services;
  final incoming = <Map<String, Object?>>[];
  final events = <String>[];
  final externalChannel = Platform.isWindows
      ? windowsExternalOpenChannel
      : nativeChannel;

  Finder field(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label,
  );

  setUp(() {
    incoming.clear();
    events.clear();
    messenger.setMockMethodCallHandler(externalChannel, (call) async {
      if (call.method != 'takeExternalOpens') return null;
      final values = List.of(incoming);
      incoming.clear();
      return values;
    });
  });

  Future<void> deliver(Map<String, Object?> value) async {
    incoming.add(value);
    await services.externalOpens.refresh();
  }

  Future<void> render(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: MainShell(
          services,
          initialTab: 3,
          externalPlayerBuilder: (request) => _VideoStub(request, events),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void scenario(String description, Future<void> Function(WidgetTester) body) {
    testWidgets(description, (tester) async {
      services = AppServices(
        store: StateStore.memory(),
        dataDirectory: Directory('test-fixture'),
        cacheDirectory: Directory('test-fixture/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('test-fixture/saved')),
        http: FakeHttp(),
        platformFeatures: false,
        controlEnabled: false,
        clipboardReader: () async => null,
      );
      try {
        await body(tester);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        services.close().then((_) => closed = true);
        for (var i = 0; i < 50 && !closed; i++) {
          await tester.pump();
        }
        expect(closed, isTrue);
        services.store.dispose();
        messenger.setMockMethodCallHandler(externalChannel, null);
      }
    });
  }

  scenario('cold external download prefills the existing dialog exactly once', (
    tester,
  ) async {
    final value = <String, Object?>{
      'id': 'download-1',
      'kind': 'download',
      'uri': 'https://example.test/get?token=signed',
      'name': '应用.apk',
      'headers': {'Referer': 'https://example.test/', 'Cookie': 'caller'},
    };
    await deliver(value);
    await render(tester);
    expect(find.text('新建下载'), findsOneWidget);
    TextField field(String label) => tester.widget<TextField>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      ),
    );
    expect(
      field('HTTP / HTTPS 链接').controller!.text,
      'https://example.test/get?token=signed',
    );
    expect(field('保存文件名').controller!.text, '应用.apk');
    expect(field('本次下载线程数').controller!.text, '64');
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.text('新建下载'), findsOneWidget);
    await tester.ensureVisible(find.text('自定义请求头'));
    await tester.tap(find.text('自定义请求头'));
    await tester.pumpAndSettle();
    expect(field('JSON 请求头').controller!.text, contains('"Cookie":"caller"'));
    expect(services.downloads.tasks, isEmpty);
    await deliver(value);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('新建下载'), findsNothing);
    expect(services.downloads.tasks, isEmpty);
  });

  scenario(
    'each invocation confirms its own threads without changing settings',
    (tester) async {
      await render(tester);
      await deliver({
        'id': 'threads-1',
        'kind': 'download',
        'uri': 'https://download.baidupcs.com/external.apk',
      });
      await tester.pumpAndSettle();
      await tester.enterText(field('本次下载线程数'), '0');
      await tester.tap(find.text('添加下载'));
      await tester.pumpAndSettle();
      expect(find.text('线程数请输入 1–512 之间的整数'), findsOneWidget);
      expect(services.downloads.tasks, isEmpty);
      await tester.enterText(field('本次下载线程数'), '12');
      await tester.runAsync(() async {
        await tester.tap(find.text('添加下载'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('新建下载'), findsNothing);
      expect(services.downloads.tasks.single.connections, 12);
      expect(
        services.store.data.list('tasks').single.integer('connections'),
        12,
      );
      expect(services.settings.threads, 64);
      await deliver({
        'id': 'threads-2',
        'kind': 'download',
        'uri': 'https://example.test/second.apk',
      });
      await tester.pumpAndSettle();
      expect(find.text('新建下载'), findsOneWidget);
      expect(tester.widget<TextField>(field('本次下载线程数')).controller!.text, '64');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(services.downloads.tasks, hasLength(1));
    },
  );

  scenario(
    'warm download requests wait until the visible download dialog closes',
    (tester) async {
      await render(tester);
      await deliver({
        'id': 'one',
        'kind': 'download',
        'uri': 'https://example.test/one.apk',
      });
      await tester.pumpAndSettle();
      await deliver({
        'id': 'two',
        'kind': 'download',
        'uri': 'https://example.test/two.apk',
      });
      await tester.pumpAndSettle();
      expect(find.text('新建下载'), findsOneWidget);
      expect(find.text('one.apk'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('新建下载'), findsOneWidget);
      expect(find.text('two.apk'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('新建下载'), findsNothing);
    },
  );

  scenario('external cloud shares preserve extraction codes in the parser', (
    tester,
  ) async {
    await render(tester);
    const text = 'https://pan.quark.cn/s/abc123 提取码: 1234';
    await deliver({'id': 'cloud', 'kind': 'share', 'text': text});
    await tester.pumpAndSettle();
    final parse = tester.state<ParsePageState>(find.byType(ParsePage));
    expect(parse.input.text, text);
    expect(parse.current!.passcode, '1234');
    expect(find.text('新建下载'), findsNothing);
  });

  scenario(
    'a cold protocol open reaches the parser and warm opens replace it',
    (tester) async {
      await deliver({
        'id': 'cold-resolve',
        'launchUri': Uri(
          scheme: 'wenxi',
          host: 'resolve',
          queryParameters: {
            'url': 'https://pan.quark.cn/s/abc123',
            'pwd': '1234',
          },
        ).toString(),
      });
      await render(tester);
      final parse = tester.state<ParsePageState>(find.byType(ParsePage));
      expect(parse.current!.url, 'https://pan.quark.cn/s/abc123');
      expect(parse.code.text, '1234');
      expect(find.text('新建下载'), findsNothing);
      await deliver({
        'id': 'warm-resolve',
        'launchUri': Uri(
          scheme: 'wenxi',
          host: 'resolve',
          queryParameters: {
            'url': 'https://pan.baidu.com/s/1newShare',
            'pwd': 'a1B2',
          },
        ).toString(),
      });
      await tester.pumpAndSettle();
      expect(parse.current!.url, 'https://pan.baidu.com/s/1newShare');
      expect(parse.code.text, 'a1B2');
      expect(services.downloads.tasks, isEmpty);
      expect(find.text('新建下载'), findsNothing);
    },
  );

  scenario(
    'a new external video disposes the old page and back returns to the app',
    (tester) async {
      await deliver({
        'id': 'first',
        'kind': 'play',
        'uri': 'content://videos.test/1',
        'name': '第一段.mp4',
      });
      await render(tester);
      expect(find.byType(_VideoStub), findsOneWidget);
      expect(events, ['open:first']);
      await deliver({
        'id': 'second',
        'kind': 'play',
        'uri': 'https://example.test/two.mp4',
        'name': '第二段.mp4',
      });
      await tester.pumpAndSettle();
      expect(find.byType(_VideoStub), findsOneWidget);
      expect(find.text('第二段.mp4'), findsOneWidget);
      expect(events, ['open:first', 'close:first', 'open:second']);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(_VideoStub), findsNothing);
      expect(events.last, 'close:second');
    },
  );

  scenario('incoming requests wait while backgrounded and run on resume', (
    tester,
  ) async {
    await render(tester);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await deliver({
      'id': 'background',
      'kind': 'play',
      'uri': 'https://example.test/a.mp4',
    });
    await tester.pump();
    expect(events, isEmpty);
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(events, ['open:background']);
  });
}

class _VideoStub extends StatefulWidget {
  const _VideoStub(this.request, this.events);
  final ExternalOpenRequest request;
  final List<String> events;
  @override
  State<_VideoStub> createState() => _VideoStubState();
}

class _VideoStubState extends State<_VideoStub> {
  @override
  void initState() {
    super.initState();
    widget.events.add('open:${widget.request.id}');
  }

  @override
  void dispose() {
    widget.events.add('close:${widget.request.id}');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(appBar: AppBar(title: Text(widget.request.fileName)));
}
