import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/providers/aliyun.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'aliyun_fast_transfer_test.dart' show fastInfo, fastSession, fastReply;
import 'browser_test_support.dart';
import 'support.dart';
import 'token_cloud_support.dart';

void main() {
  final fixtures = <BrowserUiFixture>[];
  void browserTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        for (final fixture in fixtures) {
          await fixture.close();
        }
        fixtures.clear();
      }
    });
  }

  for (final fail in [false, true]) {
    browserTest(
      fail
          ? 'failed fast transfer keeps the share open with a useful error'
          : 'fast transfer saves everything then opens the chosen personal directory',
      (tester) async {
        final fixture = await BrowserUiFixture.create(
          platform: CloudPlatform.aliyun,
        );
        fixtures.add(fixture);
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final vault = fixture.services.vault;
        await vault.putCredential(
          CloudPlatform.aliyun,
          tokenCredential(CloudPlatform.aliyun),
        );
        var saves = 0;
        final http = FakeHttp((r) {
          switch (r.uri.path) {
            case '/adrive/v1/share/getByAnonymous':
              return jsonResponse(fastInfo());
            case '/adrive/v1/share/getShareToken':
              return jsonResponse({'share_token': 'fast-token'});
            case '/adrive/v1/share/saveFile':
              saves++;
              expect(r.json['to_drive_id'], 'resource');
              expect(r.json['to_parent_file_id'], 'target-folder');
              return jsonResponse({
                'to_drive_id': 'resource',
                'to_parent_file_id': 'target-folder',
                'items': [
                  fastReply(
                    'copied-file',
                    error: fail ? 'QuotaExhausted.Drive' : null,
                  ),
                ],
              });
            case '/adrive/v3/file/list':
              return jsonResponse({
                'items': r.json['parent_file_id'] == 'root'
                    ? [aliFile('target-folder', folder: true, name: '快传目标目录')]
                    : [
                        if (saves > 0 && !fail)
                          aliFile(
                            'copied-file',
                            name: '完整课件.zip',
                            parent: 'target-folder',
                          ),
                      ],
              });
            default:
              return aliDefaultResponse(r);
          }
        });
        fixture.services.cloud.connectors[CloudPlatform.aliyun] =
            AliyunConnector(
              http,
              vault,
              now: () => tokenClock,
              listRequestInterval: Duration.zero,
            );
        await fixture.render(tester, session: fastSession());
        expect(
          find.byKey(const Key('aliyun-fast-transfer-save')),
          findsOneWidget,
        );
        expect(find.text('下载'), findsNothing);
        expect(saves, 0);
        await tester.tap(find.byKey(const Key('aliyun-fast-transfer-save')));
        await tester.pumpAndSettle();
        expect(find.text('选择目标文件夹'), findsOneWidget);
        expect(saves, 0);
        await tester.tap(find.text('快传目标目录'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('选择“快传目标目录”'));
        await tester.pumpAndSettle();
        expect(saves, 1);
        if (fail) {
          expect(
            find.byKey(const Key('aliyun-fast-transfer-save')),
            findsOneWidget,
          );
          expect(find.textContaining('阿里云盘空间不足'), findsOneWidget);
          expect(find.text('完整课件.zip'), findsNothing);
        } else {
          expect(
            find.byKey(const Key('aliyun-fast-transfer-save')),
            findsNothing,
          );
          expect(find.text('完整课件.zip'), findsOneWidget);
          final page = tester.widget<BrowserPage>(
            find.byType(BrowserPage).last,
          );
          expect(page.session.mode, BrowseMode.personal);
          expect(page.initialTrail!.last.$1, 'target-folder');
          expect(page.popAtInitialDirectory, isTrue);
          await tester.longPress(find.text('完整课件.zip'));
          await tester.pumpAndSettle();
          expect(find.text('下载'), findsWidgets);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  browserTest(
    'cancelling the destination picker leaves the fast transfer unsaved',
    (tester) async {
      final fixture = await BrowserUiFixture.create(
        platform: CloudPlatform.aliyun,
      );
      fixtures.add(fixture);
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final vault = fixture.services.vault;
      await vault.putCredential(
        CloudPlatform.aliyun,
        tokenCredential(CloudPlatform.aliyun),
      );
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('getByAnonymous')) {
          return jsonResponse(fastInfo());
        }
        if (r.uri.path.endsWith('/file/list')) {
          return jsonResponse({'items': []});
        }
        return aliDefaultResponse(r);
      });
      fixture.services.cloud.connectors[CloudPlatform.aliyun] = AliyunConnector(
        http,
        vault,
        now: () => tokenClock,
        listRequestInterval: Duration.zero,
      );
      await fixture.render(tester, session: fastSession());
      await tester.tap(find.byKey(const Key('aliyun-fast-transfer-save')));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('aliyun-fast-transfer-save')),
        findsOneWidget,
      );
      expect(http.calls.any((r) => r.uri.path.endsWith('saveFile')), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
