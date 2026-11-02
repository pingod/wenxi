import 'dart:io';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/data/sources/catalog.dart';
import 'package:asterlink/data/sources/results.dart';
import 'package:asterlink/data/sources/service.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/domain/playback_source.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:asterlink/ui/app_theme.dart';
import 'package:asterlink/ui/cloud_accounts_page.dart';
import 'package:asterlink/ui/cloud_favorites_page.dart';
import 'package:asterlink/ui/cloud_page.dart';
import 'package:asterlink/ui/downloads_page.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'package:asterlink/ui/recent_playback_page.dart';
import 'package:asterlink/ui/uploads_page.dart';
import 'package:asterlink/ui/source_browser_page.dart';
import 'package:asterlink/upload/upload_task.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'app_context_menu_test.dart' show rightClick;
import 'browser_test_support.dart';
import 'support.dart';
import 'source_support.dart';

class _ReadOnlyConnector extends BrowserTestConnector {
  _ReadOnlyConnector() : super(CloudPlatform.tianyi);
  @override
  bool canRenameFile(BrowseSession session, CloudFile file) => false;
  @override
  bool canMoveFile(BrowseSession session, CloudFile file) => false;
  @override
  bool canDeleteFile(BrowseSession session, CloudFile file) => false;
}

void main() {
  String? copiedText;
  Future<void> closeServices(
    WidgetTester tester,
    Future<void> Function() close,
  ) async {
    var closed = false;
    final closing = close().then((_) => closed = true);
    for (var i = 0; i < 200 && !closed; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(closed, isTrue, reason: 'Context menu fixture did not close');
    await closing;
  }

  void scenario(
    String name,
    Future<void> Function(WidgetTester, BrowserUiFixture) body,
  ) {
    testWidgets(name, (tester) async {
      copiedText = null;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final fixture = await BrowserUiFixture.create();
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      try {
        await body(tester, fixture);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await closeServices(tester, fixture.close);
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  Future<void> render(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(body: page),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String label) async {
    final item = find.descendant(
      of: find.byType(PopupMenuItem<String>),
      matching: find.text(label),
    );
    await tester.ensureVisible(item);
    await tester.tap(item);
    await tester.pumpAndSettle();
  }

  Future<void> dismiss(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  }

  scenario(
    'file right click opens folders, selection acts on the correct files and deletion confirms',
    (tester, fixture) async {
      await fixture.render(tester, size: const Size(1100, 900));
      final photos = find.byKey(const Key('browser-file-photos'));
      final work = find.byKey(const Key('browser-file-work'));
      await rightClick(tester, tester.getCenter(photos));
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('刷新'), findsNothing);
      await choose(tester, '选择此项');
      await rightClick(tester, tester.getCenter(work));
      await choose(tester, '选择此项');
      await rightClick(tester, tester.getCenter(photos));
      expect(find.text('下载（2 项）'), findsOneWidget);
      expect(find.text('重命名'), findsNothing);
      await choose(tester, '删除（2 项）');
      expect(find.textContaining('确认删除选中的 2 项'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      // An unselected row must never inherit the previous batch target.
      await rightClick(
        tester,
        tester.getCenter(find.byKey(const Key('browser-file-notes'))),
      );
      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('删除（2 项）'), findsNothing);
      await choose(tester, '复制文件名');
      expect(copiedText, '使用说明.txt');
      await rightClick(tester, tester.getCenter(photos));
      await choose(tester, '退出多选');
      await rightClick(tester, tester.getCenter(photos));
      await choose(tester, '打开文件夹');
      expect(fixture.connector.reads.last.$2, 'photos');
      expect(find.text('旧目录视频.mp4'), findsOneWidget);
    },
  );

  scenario(
    'folder background offers upload/create and read-only files hide mutations',
    (tester, fixture) async {
      await fixture.render(tester, size: const Size(1100, 900));
      await rightClick(tester, const Offset(1010, 740));
      expect(find.text('刷新'), findsOneWidget);
      expect(find.text('上传文件'), findsOneWidget);
      await choose(tester, '新建文件夹');
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      fixture.services.cloud.connectors[CloudPlatform.tianyi] =
          _ReadOnlyConnector();
      await rightClick(
        tester,
        tester.getCenter(find.byKey(const Key('browser-file-notes'))),
      );
      expect(find.text('重命名'), findsNothing);
      expect(find.text('移动'), findsNothing);
      expect(find.text('删除'), findsNothing);
      await dismiss(tester);
    },
  );

  scenario('file grid keeps right-click actions', (tester, fixture) async {
    await fixture.services.store.change(
      (draft) => draft.obj('settings')['browserView'] = 'grid',
    );
    await fixture.render(tester, size: const Size(1100, 900));
    await rightClick(
      tester,
      tester.getCenter(find.byKey(const Key('browser-file-notes'))),
    );
    await choose(tester, '复制文件名');
    expect(copiedText, '使用说明.txt');
  });

  scenario('download menus respect task state and reuse deletion confirmation', (
    tester,
    fixture,
  ) async {
    final services = fixture.services;
    await tester.runAsync(
      () => services.downloads.importPausedQueue(
        () => services.store.put('tasks', [
          for (final id in ['one', 'two'])
            DownloadTask(
              id: id,
              spec: DownloadSpec(
                url: 'https://example.invalid/$id',
                fileName: '$id.zip',
              ),
              createdAt: 1,
              status: DownloadStatus.paused,
            ).toJson(),
        ]),
      ),
    );
    await render(tester, DownloadsPage(services));
    final one = find.byKey(const Key('download-row-one'));
    final two = find.byKey(const Key('download-row-two'));
    await rightClick(tester, tester.getCenter(one));
    expect(find.text('继续下载'), findsOneWidget);
    expect(find.text('暂停下载'), findsNothing);
    await choose(tester, '复制下载链接');
    expect(copiedText, 'https://example.invalid/one');
    await rightClick(tester, tester.getCenter(one));
    await choose(tester, '删除任务');
    expect(
      find.byKey(const Key('downloads-confirm-single-delete')),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(services.downloads.task('one'), isNotNull);
    await rightClick(tester, tester.getCenter(one));
    await choose(tester, '选择此项');
    await rightClick(tester, tester.getCenter(two));
    await choose(tester, '选择此项');
    await rightClick(tester, tester.getCenter(one));
    expect(
      find.text('${DownloadBatchAction.resume.label}（2 项）'),
      findsOneWidget,
    );
    await choose(tester, '退出多选');
    // A completion after opening the menu must not execute the old resume command.
    await rightClick(tester, tester.getCenter(one));
    await tester.runAsync(
      () => services.downloads.importPausedQueue(
        () => services.store.put('tasks', [
          for (final task in services.downloads.tasks)
            (task.id == 'one' ? task.update({'status': 'completed'}) : task)
                .toJson(),
        ]),
      ),
    );
    await choose(tester, '继续下载');
    expect(services.downloads.task('one')!.status, DownloadStatus.completed);
    await rightClick(tester, tester.getCenter(one));
    expect(find.text('移除下载记录'), findsOneWidget);
    expect(find.text('继续下载'), findsNothing);
    await dismiss(tester);
  });

  scenario('upload right click offers retry and removes only the record', (
    tester,
    fixture,
  ) async {
    final task = UploadTask(
      id: 'upload',
      name: '上传文件.zip',
      session: fixture.services.cloud.bindSession(
        fixture.connector.personalSession(),
      ),
      parent: 'personal-root',
      folderName: '全部文件',
      accountName: '测试账号',
      path: 'fixture.zip',
      size: 10,
      status: UploadStatus.failed,
      phase: UploadPhase.uploading,
      createdAt: 1,
      modifiedAt: 1,
    );
    final services = AppServices(
      controlEnabled: false,
      store: StateStore.memory({
        'uploadTasks': [task.toJson()],
      }),
      dataDirectory: fixture.directory,
      cacheDirectory: Directory('${fixture.directory.path}/upload-cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('${fixture.directory.path}/upload-files')),
      http: FakeHttp(),
      platformFeatures: false,
    );
    await services.uploads.initialize();
    await render(tester, UploadsPage(services));
    await rightClick(
      tester,
      tester.getCenter(find.byKey(const Key('upload-row-upload'))),
    );
    expect(find.text('重新上传'), findsOneWidget);
    expect(find.text('取消上传'), findsNothing);
    await choose(tester, '删除记录');
    expect(services.uploads.task('upload'), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await closeServices(tester, services.close);
  });

  scenario(
    'platform and account menus open management and preserve account targets',
    (tester, fixture) async {
      final services = fixture.services;
      await render(tester, CloudPage(services));
      final card = find.byKey(Key('cloud-context-${CloudPlatform.tianyi.key}'));
      await tester.ensureVisible(card);
      await rightClick(tester, tester.getCenter(card));
      await choose(tester, '多账号管理');
      expect(find.byType(CloudAccountsPage), findsOneWidget);
      final id = services.vault.activeAccountId(CloudPlatform.tianyi)!;
      await rightClick(
        tester,
        tester.getCenter(find.byKey(Key('account-$id'))),
      );
      await choose(tester, '自定义账号名称');
      await tester.enterText(find.byType(TextField), '右键修改名称');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(
        services.vault.profiles(CloudPlatform.tianyi).single.name,
        '右键修改名称',
      );
    },
  );

  scenario('favorites and recent playback use real context commands', (
    tester,
    fixture,
  ) async {
    final services = fixture.services;
    await services.favorites.toggle(
      services.cloud.bindSession(fixture.connector.personalSession()),
      const CloudFile(id: 'photos', name: '假期相册', isDirectory: true),
      [('personal-root', '全部文件')],
    );
    final id = services.favorites.all.single.id;
    await render(tester, CloudFavoritesPage(services));
    await rightClick(tester, tester.getCenter(find.byKey(Key('favorite-$id'))));
    await choose(tester, '取消收藏');
    expect(services.favorites.all, isEmpty);
    await PlaybackStore(services.store).save(
      'record',
      const PlaybackBookmark(
        position: Duration.zero,
        duration: Duration(minutes: 1),
        name: '媒体.mp4',
        source: PlaybackSource.local(path: 'fixture.mp4'),
        updatedAt: 1,
      ),
    );
    await render(tester, RecentPlaybackPage(services));
    await rightClick(
      tester,
      tester.getCenter(find.byKey(const Key('recent-play-record'))),
    );
    await choose(tester, '移除记录');
    expect(recentPlayback(services), isEmpty);
  });

  scenario(
    'parse history right click copies the extraction code and deletes the record',
    (tester, fixture) async {
      final services = fixture.services;
      final link = ParsedLink(
        source: 'https://cloud.189.cn/t/test',
        kind: LinkKind.cloudShare,
        platform: CloudPlatform.tianyi,
        url: 'https://cloud.189.cn/t/test',
        passcode: '1234',
      );
      await services.store.put('history', [
        {
          'fileName': '历史分享',
          'platform': 'tianyi',
          'normalizedUrl': link.url,
          'createdAt': 1,
          'link': link.toJson(),
        },
      ]);
      await render(tester, ParsePage(services));
      await tester.tap(find.byKey(const Key('parse-history')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('复制分享链接'));
      await tester.pumpAndSettle();
      expect(copiedText, '${link.url} 提取码：1234');
      expect(find.text('历史分享'), findsOneWidget);
      expect(services.store.data.list('history'), hasLength(1));
      copiedText = null;
      await rightClick(tester, tester.getCenter(find.text('历史分享')));
      await choose(tester, '复制分享链接');
      expect(copiedText, '${link.url} 提取码：1234');
      await rightClick(tester, tester.getCenter(find.text('历史分享')));
      await choose(tester, '删除这条历史');
      expect(services.store.data.list('history'), isEmpty);
      expect(find.text('暂无历史解析'), findsOneWidget);
    },
  );

  scenario(
    'remote source file right click copies names and offers batch download',
    (tester, fixture) async {
      final release = SourceCatalog.verify(
        sourceEnvelope(),
        sourcePublicKey,
        sourceTestNow,
      ).releases.first;
      final session = SourceSession(
        release,
        const {},
        SourcePage.fromJson(release.package, {
          'title': '规则来源文件',
          'items': [
            {'id': 'a', 'name': '来源文件 A.zip', 'kind': 'file', 'size': 4},
            {'id': 'b', 'name': '来源文件 B.zip', 'kind': 'file', 'size': 4},
          ],
        }),
      );
      await render(tester, SourceBrowserPage(fixture.services, session));
      await rightClick(
        tester,
        tester.getCenter(find.byKey(const Key('source-item-a'))),
      );
      await choose(tester, '复制文件名');
      expect(copiedText, '来源文件 A.zip');
      for (final id in ['a', 'b']) {
        await rightClick(
          tester,
          tester.getCenter(find.byKey(Key('source-item-$id'))),
        );
        await choose(tester, '选择此项');
      }
      await rightClick(
        tester,
        tester.getCenter(find.byKey(const Key('source-item-a'))),
      );
      expect(find.text('下载（2 项）'), findsOneWidget);
      await dismiss(tester);
    },
  );
}
