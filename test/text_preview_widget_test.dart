import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/preview/text_document.dart';
import 'package:asterlink/ui/text_preview.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'code preview supports selection, copy, line wrapping and font size in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const code = 'const message = "中文代码";\nconsole.log(message);\n';
        final doc = decodeTextDocument((
          Uint8List.fromList(utf8.encode(code)),
          'test.js',
          false,
        ));
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = call.arguments['text'];
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
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(body: TextPreview(doc)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SelectionArea), findsOneWidget);
        final line = tester.widget<Text>(
          find.byKey(const Key('text-preview-line-0')),
        );
        expect(line.textSpan!.toPlainText(), code.split('\n').first);
        expect(
          (line.textSpan! as TextSpan).children!.whereType<TextSpan>().any(
            (span) => span.style?.color != null,
          ),
          true,
        );
        await tester.tap(find.byKey(const Key('text-preview-copy')));
        await tester.pumpAndSettle();
        expect(copied, code);
        await tester.tap(find.byKey(const Key('text-preview-wrap')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(find.byKey(const Key('text-preview-line-0')))
              .softWrap,
          true,
        );
        await tester.tap(find.byTooltip('文字大小'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<double>, '18 号'),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(find.byKey(const Key('text-preview-line-0')))
              .style!
              .fontSize,
          18,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'large text uses a lazy list and shows the partial-content notice',
    (tester) async {
      final code = List.generate(15000, (i) => '第 $i 行').join('\n');
      final doc = decodeTextDocument((
        Uint8List.fromList(utf8.encode(code)),
        'demo.txt.zip',
        false,
      ));
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TextPreview(doc))),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('文件较大，仅显示前'), findsOneWidget);
      expect(find.byKey(const Key('text-preview-line-0')), findsOneWidget);
      expect(find.byKey(const Key('text-preview-line-9999')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
