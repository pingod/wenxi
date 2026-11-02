import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/resource_search.dart';
import 'package:asterlink/data/resource_search_api.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/resource_search.dart';
import 'support.dart';

ResourceSearchHit searchHit(
  String id, {
  String password = '',
  String? url,
  String title = 'Python 教程',
  String description = '',
}) => ResourceSearchHit.fromRaw({
  'title': title,
  'share_link': url ?? 'https://pan.quark.cn/s/$id',
  'password': password,
  'description': description,
  'source_name': '资料分享',
});

class SearchApiFixture
    implements ResourceSearchApi, ResourceDiscoveryApi, ResourceCatalogApi {
  SearchApiFixture(this.respond);
  final Stream<ResourceSearchBatch> Function(String, CancelToken) respond;
  final calls = <String>[];
  final cancellations = <CancelToken>[];
  final openCalls = <ResourceSearchHit>[];
  final openCancellations = <CancelToken>[];
  final openSelections = <ResourceSearchFileSelection>[];
  final recommendationCalls = <({List<int> exclude, bool refresh})>[];
  Future<List<ResourceSearchHit>> Function(List<int>, bool)? discover;
  final catalogCalls = <({String section, List<int> exclude})>[];
  Future<ResourceCatalog> Function(String, List<int>)? catalogRespond;
  @override
  Future<ResourceCatalog> catalog({
    String refreshSection = '',
    List<int> exclude = const [],
  }) async {
    catalogCalls.add((section: refreshSection, exclude: exclude));
    return catalogRespond?.call(refreshSection, exclude) ??
        ResourceCatalog(
          popular: await recommendations(
            exclude: exclude,
            refresh: refreshSection.isNotEmpty,
          ),
        );
  }

  @override
  Future<List<ResourceSearchHit>> recommendations({
    List<int> exclude = const [],
    bool refresh = false,
  }) {
    recommendationCalls.add((exclude: exclude, refresh: refresh));
    return discover?.call(exclude, refresh) ?? Future.value([]);
  }

  Future<ResourceSearchOpenResult> Function(
    ResourceSearchHit,
    CancelToken,
    ResourceSearchFileSelection,
  )?
  resolve;
  @override
  Future<ResourceSearchOpenResult> open(
    ResourceSearchHit hit,
    CancelToken cancellation, {
    required ResourceSearchFileSelection selection,
  }) {
    openCalls.add(hit);
    openCancellations.add(cancellation);
    openSelections.add(selection);
    return resolve?.call(hit, cancellation, selection) ??
        Future.value(
          ResourceSearchOpenResult(
            hit: hit,
            mode: 'pool_share',
            transferScope: 'file',
            sourceFileId: selection.fileId,
          ),
        );
  }

  @override
  Stream<ResourceSearchBatch> search(String keyword, CancelToken cancellation) {
    calls.add(keyword);
    cancellations.add(cancellation);
    return respond(keyword, cancellation);
  }
}

void main() {
  test('Tianyi share code is not shown as an extraction password', () {
    final hit = ResourceSearchHit.fromRaw({
      'title': '天翼资源',
      'url': 'https://cloud.189.cn/web/share?code=j6bEZvJRry22',
      'password': 'j6bEZvJRry22',
      'cloud_name': '天翼云盘',
    });
    expect(hit.password, isEmpty);
    expect(hit.link?.passcode, isNull);
    final oldResponse = ResourceSearchHit.fromRaw({
      'title': '天翼资源',
      'url': 'https://cloud.189.cn/web/share?code=j6bEZvJRry22',
      'password': 'j6bEZv',
    });
    expect(oldResponse.password, isEmpty);
  });

  test('Explicit Tianyi accessCode remains available', () {
    final hit = ResourceSearchHit.fromRaw({
      'title': '天翼资源',
      'url': 'https://cloud.189.cn/web/share?code=j6bEZvJRry22&accessCode=aB12',
      'cloud_name': '天翼云盘',
    });
    expect(hit.password, 'aB12');
    expect(hit.link?.passcode, 'aB12');
  });

  test(
    'new pool share uses only its own password and grants refresh during merge',
    () {
      final original = ResourceSearchHit.fromRaw({
        'title': 'Python',
        'url': 'https://pan.quark.cn/s/original',
        'password': 'old1',
        'open_ticket': 'old-ticket',
      });
      final updated = ResourceSearchHit.fromRaw({
        'title': 'Python',
        'url': original.url,
        'open_ticket': 'new-ticket',
      });
      expect(original.merge(updated).openTicket, 'new-ticket');
      for (final data in [
        {'mode': 'temp_share', 'url': 'https://pan.quark.cn/s/new'},
        {'mode': 'temp_share', 'url': 'https://pan.quark.cn/s/new?pwd=nEw2'},
        {
          'mode': 'temp_share',
          'url': 'https://pan.quark.cn/s/new',
          'password': 'nEw2',
        },
      ]) {
        final result = ResourceSearchOpenResult.fromJson(original, data);
        expect(
          result.hit.password,
          data['password'] ?? (data['url']!.contains('?pwd=') ? 'nEw2' : ''),
        );
        expect(result.hit.password, isNot('old1'));
      }
      expect(original.password, 'old1');
    },
  );
  test(
    'magnet results reuse the existing torrent flow and deduplicate trackers',
    () {
      const hash = '1234567890123456789012345678901234567890';
      final one = searchHit('one', url: 'magnet:?xt=urn:btih:$hash&dn=sample');
      final two = searchHit(
        'two',
        url: 'magnet:?xt=urn:btih:$hash&tr=https%3A%2F%2Ftracker.example',
      );
      expect(one.canParse, isTrue);
      expect(one.identity, two.identity);
      expect(one.cloudName, '磁力链接');
    },
  );
  test(
    'split UTF-8, CRLF, comments and multiline SSE data are decoded',
    () async {
      const text =
          ': heartbeat\r\nevent: message\r\ndata: {"type":"update",\r\ndata: "results":[{"title":"电子书","url":"https://pan.quark.cn/s/test"}]}\r\n\r\ndata: {"type":"complete","results":[]}\n\n';
      final chunks = Stream.fromIterable(
        utf8.encode(text).map((byte) => [byte]),
      );
      final events = await decodeSearchEvents(chunks).toList();
      expect(events.length, 2);
      expect(events[0]['results'][0]['title'], '电子书');
      expect(events[1]['type'], 'complete');
    },
  );

  test(
    'JSON fallback uses the public API and preserves explicit password',
    () async {
      final http = FakeHttp(
        (call) => jsonResponse({
          'success': true,
          'results': [
            {
              'title': '教材',
              'url': 'https://pan.quark.cn/s/books',
              'password': 'aB12',
            },
          ],
        }),
      );
      final api = HttpResourceSearchApi(
        http,
        endpoint: 'https://search.example/',
      );
      final token = CancelToken();
      final result = await api.search('Python 教程', token).single;
      token.cancel();
      expect(result.complete, isTrue);
      expect(result.items.single.link!.passcode, 'aB12');
      expect(http.calls.single.uri.path, '/api/v1/search');
      expect(http.calls.single.uri.queryParameters['keyword'], 'Python 教程');
      expect(http.calls.single.uri.queryParameters['limit'], '1000');
      expect(http.calls.single.headers.keys, isNot(contains('X-API-Key')));
    },
  );

  test(
    'canonical identities ignore tracking queries and retain separate shares',
    () {
      final first = searchHit('same');
      final duplicate = searchHit(
        'same?from=channel',
        password: 'aB12',
        description: '完整资料',
      );
      expect(first.identity, duplicate.identity);
      expect(first.identity, isNot(searchHit('another').identity));
      final merged = first.merge(duplicate);
      expect(merged.password, 'aB12');
      expect(merged.link!.passcode, 'aB12');
      expect(merged.copyText, contains('提取码：aB12'));
    },
  );

  test('legacy array results and malformed upstream items are tolerated', () {
    final result = ResourceSearchBatch.fromJson({
      'type': 'complete',
      'results': [
        ['tg', '电子书', 'https://pan.baidu.com/s/1test?pwd=1234', '百度网盘'],
        {'url': 'javascript:alert(1)'},
        {'url': ''},
      ],
    });
    expect(result.items.length, 1);
    expect(result.items.single.password, '1234');
    expect(result.items.single.canParse, isTrue);
  });

  test(
    'incremental duplicates merge, final order replaces provisional order',
    () async {
      final api = SearchApiFixture(
        (_, _) => Stream.fromIterable([
          ResourceSearchBatch([searchHit('one'), searchHit('two')]),
          ResourceSearchBatch([searchHit('one?from=tg', password: '1234')]),
          ResourceSearchBatch([
            searchHit('two'),
            searchHit('one', password: '1234'),
          ], complete: true),
        ]),
      );
      final search = ResourceSearch(store: StateStore.memory(), api: api);
      addTearDown(search.dispose);
      await search.search('Python');
      expect(search.items.map((h) => h.identity), ['Quark:two', 'Quark:one']);
      expect(search.items.last.password, '1234');
      expect(search.phase, ResourceSearchPhase.complete);
      search.filter('百度网盘');
      expect(search.items, isEmpty);
      search.filter(null);
      expect(search.items.length, 2);
      expect(api.calls.length, 1);
    },
  );

  test('a new query cancels the old one and ignores late batches', () async {
    final old = StreamController<ResourceSearchBatch>();
    final api = SearchApiFixture(
      (keyword, _) => keyword == '旧查询'
          ? old.stream
          : Stream.value(
              ResourceSearchBatch([searchHit('new')], complete: true),
            ),
    );
    final search = ResourceSearch(store: StateStore.memory(), api: api);
    addTearDown(search.dispose);
    final previous = search.search('旧查询');
    await Future<void>.delayed(Duration.zero);
    await search.search('新查询');
    expect(api.cancellations.first.isCancelled, isTrue);
    old.add(ResourceSearchBatch([searchHit('old')], complete: true));
    await old.close();
    await previous;
    expect(search.items.single.identity, 'Quark:new');
    expect(search.keyword, '新查询');
  });

  test(
    'title filters combine all include terms and any exclude term locally',
    () async {
      final api = SearchApiFixture(
        (_, _) => Stream.value(
          ResourceSearchBatch([
            searchHit('book', title: 'PYTHON 数据分析 · 电子书'),
            searchHit('video', title: 'Python 数据分析视频课程'),
            searchHit('other', title: 'Python 自动化办公'),
            searchHit(
              'baidu',
              url: 'https://pan.baidu.com/s/1book',
              title: 'Python 数据分析教材',
            ),
          ], complete: true),
        ),
      );
      final search = ResourceSearch(store: StateStore.memory(), api: api);
      addTearDown(search.dispose);
      await search.search('Python');
      search.setKeywordFilters(include: 'python  数据', exclude: '视频 办公');
      expect(search.items.map((hit) => hit.identity), [
        'Quark:book',
        'Baidu:book',
      ]);
      search.filter('百度网盘');
      expect(search.items.single.identity, 'Baidu:book');
      expect(search.allItems.length, 4);
      expect(api.calls.length, 1);
      search.setKeywordFilters();
      search.filter(null);
      expect(search.items.length, 4);
      expect(search.hasKeywordFilters, isFalse);
    },
  );

  test(
    'more than sixty streamed hits survive final ordering and cache',
    () async {
      final hits = List.generate(120, (i) => searchHit('bulk$i'));
      final api = SearchApiFixture(
        (_, _) => Stream.fromIterable([
          ResourceSearchBatch(hits.take(75).toList()),
          ResourceSearchBatch(hits.reversed.toList(), complete: true),
        ]),
      );
      final search = ResourceSearch(store: StateStore.memory(), api: api);
      addTearDown(search.dispose);
      await search.search('Python');
      expect(search.allItems.length, 120);
      expect(search.items.first.identity, 'Quark:bulk119');
      await search.search('python');
      expect(search.items.length, 120);
      expect(api.calls.length, 1);
    },
  );

  test('stopping a query preserves partial results', () async {
    final stream = StreamController<ResourceSearchBatch>();
    final search = ResourceSearch(
      store: StateStore.memory(),
      api: SearchApiFixture((_, _) => stream.stream),
    );
    addTearDown(search.dispose);
    final running = search.search('Python');
    stream.add(ResourceSearchBatch([searchHit('partial')]));
    await Future<void>.delayed(Duration.zero);
    search.stop();
    stream.add(const ResourceSearchBatch([], complete: true));
    await stream.close();
    await running;
    expect(search.phase, ResourceSearchPhase.stopped);
    expect(search.items.single.identity, 'Quark:partial');
  });

  test(
    'stream failure retains results and is never cached as complete',
    () async {
      final api = SearchApiFixture((_, _) async* {
        yield ResourceSearchBatch([searchHit('partial')]);
        throw const AppException('连接中断');
      });
      final search = ResourceSearch(store: StateStore.memory(), api: api);
      addTearDown(search.dispose);
      await search.search('Python');
      expect(search.phase, ResourceSearchPhase.failed);
      expect(search.items.length, 1);
      expect(search.error, '连接中断');
      await search.search('Python');
      expect(api.calls.length, 2);
    },
  );

  test(
    'complete results have bounded cache and case-insensitive history',
    () async {
      final api = SearchApiFixture(
        (_, _) => Stream.value(
          ResourceSearchBatch([searchHit('cached')], complete: true),
        ),
      );
      final search = ResourceSearch(store: StateStore.memory(), api: api);
      addTearDown(search.dispose);
      await search.search('Python');
      await search.search('python');
      expect(search.fromCache, isTrue);
      expect(api.calls.length, 1);
      await search.search('Python', refresh: true);
      expect(api.calls.length, 2);
      await Future<void>.delayed(Duration.zero);
      expect(search.history.length, 1);
      await search.clearHistory();
      expect(search.history, isEmpty);
    },
  );

  test('total budget stops silent streams and preserves partial results', () {
    fakeAsync((time) {
      final stream = StreamController<ResourceSearchBatch>();
      final api = SearchApiFixture((_, _) => stream.stream);
      final search = ResourceSearch(
        store: StateStore.memory(),
        api: api,
        budget: const Duration(seconds: 3),
      );
      unawaited(search.search('Python'));
      stream.add(ResourceSearchBatch([searchHit('partial')]));
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 4));
      expect(search.phase, ResourceSearchPhase.failed);
      expect(search.items.length, 1);
      expect(api.cancellations.single.isCancelled, isTrue);
      search.dispose();
      unawaited(stream.close());
      time.flushMicrotasks();
    });
  });

  test('cloud display priority keeps unsupported results available', () async {
    final api = SearchApiFixture(
      (_, _) => Stream.value(
        ResourceSearchBatch([
          searchHit('other', url: 'https://unknown.example/share/one'),
          searchHit('supported'),
        ], complete: true),
      ),
    );
    final search = ResourceSearch(store: StateStore.memory(), api: api);
    addTearDown(search.dispose);
    await search.search('Python');
    expect(search.items.first.canParse, isTrue);
    expect(search.items.length, 2);
    await search.setPreferSupported(false);
    expect(search.items.first.canParse, isTrue);
    expect(search.items.last.canParse, isFalse);
    expect(search.allItems.first.canParse, isFalse);
  });
}
