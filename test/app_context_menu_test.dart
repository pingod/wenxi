import 'package:asterlink/ui/app_context_menu.dart';
import 'package:asterlink/ui/app_popup_menu.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const action = AppMenuAction(value: 'open', label: '打开文件', icon: Icons.folder);

Future<void> rightClick(WidgetTester tester, Offset position) async {
  await tester.tapAt(
    position,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await tester.pumpAndSettle();
}

void main() {
  void scenario(String name, WidgetTesterCallback callback) => testWidgets(
    name,
    callback,
    variant: TargetPlatformVariant.only(
      name.startsWith('Android')
          ? TargetPlatform.android
          : TargetPlatform.windows,
    ),
  );

  scenario(
    'secondary click anchors a popup without triggering the primary action',
    (tester) async {
      final selected = <String>[];
      var primary = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppContextMenu<String>(
              actions: () => [action],
              onSelected: selected.add,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => primary++,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      await rightClick(tester, const Offset(220, 180));
      expect(primary, 0);
      expect(find.byType(BottomSheet), findsNothing);
      final rect = tester.getRect(find.byType(PopupMenuItem<String>));
      expect(rect.left, closeTo(220, 1));
      expect(rect.top, closeTo(186, 1));
      await tester.tap(find.text('打开文件'));
      await tester.pumpAndSettle();
      expect(selected, ['open']);
      await tester.tapAt(const Offset(220, 180));
      expect(primary, 1);
    },
  );

  scenario('Escape and outside click dismiss; keyboard can choose a command', (
    tester,
  ) async {
    final selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppContextMenu<String>(
            actions: () => [action],
            onSelected: selected.add,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await rightClick(tester, const Offset(80, 80));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('打开文件'), findsNothing);
    await rightClick(tester, const Offset(80, 80));
    await tester.tapAt(const Offset(700, 500));
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    await rightClick(tester, const Offset(80, 80));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, ['open']);
  });

  scenario('a nested row consumes right clicks before the folder background', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppContextMenu<String>(
            actions: () => [
              const AppMenuAction(
                value: 'refresh',
                label: '刷新目录',
                icon: Icons.refresh,
              ),
            ],
            onSelected: (_) {},
            child: Align(
              alignment: Alignment.topLeft,
              child: AppContextMenu<String>(
                actions: () => [action],
                onSelected: (_) {},
                child: const SizedBox(width: 300, height: 100),
              ),
            ),
          ),
        ),
      ),
    );
    await rightClick(tester, const Offset(50, 50));
    expect(find.text('打开文件'), findsOneWidget);
    expect(find.text('刷新目录'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await rightClick(tester, const Offset(500, 400));
    expect(find.text('刷新目录'), findsOneWidget);
    expect(find.text('打开文件'), findsNothing);
  });

  scenario('disabled and newly unavailable actions are never dispatched', (
    tester,
  ) async {
    final selected = <String>[];
    var available = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppContextMenu<String>(
            actions: () => [
              if (available) action,
              const AppMenuAction(
                value: 'disabled',
                label: '不可用',
                icon: Icons.lock,
                enabled: false,
              ),
            ],
            onSelected: selected.add,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await rightClick(tester, const Offset(80, 80));
    await tester.tap(find.text('不可用'));
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(find.text('打开文件'), findsOneWidget);
    available = false;
    await tester.tap(find.text('打开文件'));
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
  });

  for (final dispose in [false, true]) {
    scenario(
      'a ${dispose ? 'removed' : 'changed'} target cannot run a stale menu command',
      (tester) async {
        final selected = <String>[];
        final target = ValueNotifier(1);
        addTearDown(target.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<int>(
                valueListenable: target,
                builder: (_, id, _) => dispose && id == 2
                    ? const SizedBox.expand()
                    : AppContextMenu<String>(
                        identity: id,
                        actions: () => [action],
                        onSelected: selected.add,
                        child: const SizedBox.expand(),
                      ),
              ),
            ),
          ),
        );
        await rightClick(tester, const Offset(80, 80));
        target.value = 2;
        await tester.pump();
        await tester.tap(find.text('打开文件'));
        await tester.pumpAndSettle();
        expect(selected, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  scenario(
    'screen edges, DPI, large text and resized windows keep menus accessible',
    (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(960, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => MediaQuery(
            data: MediaQueryData.fromView(
              tester.view,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: Scaffold(
            body: AppContextMenu<String>(
              actions: () => [
                for (var i = 0; i < 14; i++)
                  AppMenuAction(
                    value: '$i',
                    label: '文件操作 $i',
                    icon: Icons.folder,
                  ),
              ],
              onSelected: (_) {},
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await rightClick(tester, const Offset(475, 315));
      final first = tester.getRect(find.byType(PopupMenuItem<String>).first);
      expect(first.left, greaterThanOrEqualTo(0));
      expect(first.right, lessThanOrEqualTo(480));
      tester.view.physicalSize = const Size(720, 560);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('文件操作 13'));
      await tester.pumpAndSettle();
      final last = tester.getRect(find.text('文件操作 13'));
      expect(last.right, lessThanOrEqualTo(360));
      expect(last.bottom, lessThanOrEqualTo(280));
      expect(tester.takeException(), isNull);
    },
  );

  scenario('Android keeps touch long press and has no Windows popup', (
    tester,
  ) async {
    var longPress = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppContextMenu<String>(
            actions: () => [action],
            onSelected: (_) => fail('Windows menu on Android'),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPress: () => longPress++,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    await rightClick(tester, const Offset(80, 80));
    expect(find.text('打开文件'), findsNothing);
    await tester.longPressAt(const Offset(80, 80));
    expect(longPress, 1);
  });
}
