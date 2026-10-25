import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cloud_command_history.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedLink _link(CloudPlatform platform, {String code = 'A%2B+B'}) =>
    ParsedLink(
      source: 'https://example.test/share',
      url: 'https://example.test/share',
      kind: LinkKind.cloudShare,
      platform: platform,
      passcode: code,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Command history survives an encrypted store reopen with exact command bytes and codes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'command-history-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      final store = await StateStore.open(directory, testKey: key);
      const text = '  原始口令 e\u0301 👩🏽‍💻 + %2B\n';
      await store.change((draft) {
        CloudCommandHistory.record(
          draft,
          _link(CloudPlatform.uc),
          text,
          createdAt: 123,
          title: '分享资料',
          itemCount: 2,
        );
      });
      final encrypted = await store.file!.readAsBytes();
      expect(
        utf8.decode(encrypted, allowMalformed: true),
        isNot(contains(text)),
      );
      final reopened = await StateStore.open(directory, testKey: key);
      final entry = CloudCommandHistory(reopened).all.single;
      expect(entry.text, text);
      expect(entry.platform, CloudPlatform.uc);
      expect(entry.link.passcode, 'A%2B+B');
      expect(entry.title, '分享资料');
      expect(entry.itemCount, 2);
      expect(entry.createdAt, 123);
      store.dispose();
      reopened.dispose();
    },
  );

  test(
    'Commands deduplicate by original text and platform, refresh metadata and retain a bounded recent list',
    () async {
      final store = StateStore.memory();
      addTearDown(store.dispose);
      final history = CloudCommandHistory(store);
      await store.change((draft) {
        for (var i = 0; i <= CloudCommandHistory.limit; i++) {
          CloudCommandHistory.record(
            draft,
            _link(CloudPlatform.quark),
            '口令 $i',
            createdAt: i,
          );
        }
      });
      expect(history.all, hasLength(CloudCommandHistory.limit));
      expect(history.all.last.text, '口令 1');
      final previous = history.all.last;
      await store.change((draft) {
        CloudCommandHistory.record(
          draft,
          _link(CloudPlatform.quark, code: 'NEW+%'),
          '口令 1',
          createdAt: 1000,
          title: '更新后的分享',
        );
        CloudCommandHistory.record(
          draft,
          _link(CloudPlatform.uc),
          '口令 1',
          createdAt: 1001,
        );
      });
      expect(history.all, hasLength(CloudCommandHistory.limit));
      expect(history.all.first.platform, CloudPlatform.uc);
      expect(history.all[1].id, previous.id);
      expect(history.all[1].link.passcode, 'NEW+%');
      expect(history.all[1].title, '更新后的分享');
      expect(history.all.where((entry) => entry.text == '口令 1'), hasLength(2));
      await history.remove(previous.id);
      expect(history.all.first.platform, CloudPlatform.uc);
      expect(
        history.all.where(
          (entry) =>
              entry.platform == CloudPlatform.quark && entry.text == '口令 1',
        ),
        isEmpty,
      );
      await history.clear();
      expect(history.all, isEmpty);
    },
  );

  test(
    'Legacy state without command history opens empty and invalid entries cannot become replayable commands',
    () {
      final store = StateStore.memory({
        'history': [
          {'sourceText': '旧解析记录'},
        ],
        'commandHistory': [
          {
            'id': 'missing-command',
            'platform': 'Uc',
            'link': _link(CloudPlatform.uc).toJson(),
          },
          {
            'id': 'unsupported',
            'platform': 'Baidu',
            'text': '口令',
            'link': _link(CloudPlatform.baidu).toJson(),
          },
          'invalid',
        ],
      });
      addTearDown(store.dispose);
      expect(CloudCommandHistory(store).all, isEmpty);
      expect(store.data.list('history').single.str('sourceText'), '旧解析记录');
    },
  );
}
