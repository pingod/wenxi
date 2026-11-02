import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/resource_link_checks.dart';
import 'package:asterlink/data/resource_search.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/resource_search.dart';
import 'resource_link_check_support.dart';
import 'resource_search_test.dart' show SearchApiFixture;

void main() {
  test(
    'only visible shares are probed, with de-duplication and three concurrent requests',
    () {
      fakeAsync((fake) {
        final api = LinkCheckApiFixture();
        final checks = ResourceLinkChecks(api);
        final hits = List.generate(8, (i) => probeHit('item$i'));
        final magnet = probeHit(
          'bt',
          url: 'magnet:?xt=urn:btih:1234567890123456789012345678901234567890',
        );
        checks.setVisible([...hits.take(6), hits.first, magnet]);
        fake.elapse(const Duration(milliseconds: 179));
        expect(api.calls, isEmpty);
        fake.elapse(const Duration(milliseconds: 1));
        expect(api.calls, hasLength(3));
        expect(checks.health(hits.first).state, ResourceLinkState.checking);
        expect(checks.health(magnet).state, ResourceLinkState.unsupported);
        for (var i = 0; i < 6; i++) {
          expect(
            api.calls
                .where(
                  (c) => !c.cancellation.isCancelled && !c.result.isCompleted,
                )
                .length,
            lessThanOrEqualTo(3),
          );
          api.calls[i].complete(ResourceLinkState.valid);
          fake.flushMicrotasks();
        }
        expect(
          api.calls.map((c) => c.hit.identity).toSet(),
          hits.take(6).map((h) => h.identity).toSet(),
        );
        expect(api.calls, hasLength(6));
        expect(checks.health(hits[7]).state, ResourceLinkState.pending);
        checks.dispose();
        expect(api.disposed, isTrue);
      });
    },
  );

  test(
    'cache includes password, manual recheck bypasses it, expired states are checked again',
    () {
      fakeAsync((fake) {
        final api = LinkCheckApiFixture();
        final checks = ResourceLinkChecks(
          api,
          clock: () => DateTime(2026, 10, 22).add(fake.elapsed),
        );
        final hit = probeHit('book');
        final withPassword = probeHit('book', password: 'aB12');
        checks.setVisible([hit]);
        fake.elapse(const Duration(milliseconds: 180));
        api.calls.single.complete(ResourceLinkState.valid);
        fake.flushMicrotasks();
        checks.clearVisible();
        checks.setVisible([hit]);
        fake.elapse(const Duration(milliseconds: 180));
        expect(api.calls, hasLength(1));
        checks.setVisible([withPassword]);
        fake.elapse(const Duration(milliseconds: 180));
        expect(api.calls, hasLength(2));
        expect(api.calls.last.hit.password, 'aB12');
        api.calls.last.complete(ResourceLinkState.locked);
        fake.flushMicrotasks();
        expect(checks.health(hit).state, ResourceLinkState.valid);
        expect(checks.health(withPassword).state, ResourceLinkState.locked);
        checks.retry(withPassword);
        expect(api.calls, hasLength(3));
        api.calls.last.complete(ResourceLinkState.invalid);
        fake.flushMicrotasks();
        fake.elapse(const Duration(minutes: 3));
        checks.setVisible([withPassword]);
        fake.elapse(const Duration(milliseconds: 180));
        expect(api.calls, hasLength(4));
        checks.dispose();
      });
    },
  );

  test(
    'scroll changes cancel old probes and ignore late results even for the same share',
    () {
      fakeAsync((fake) {
        final api = LinkCheckApiFixture();
        final checks = ResourceLinkChecks(api);
        final one = probeHit('one'), two = probeHit('two');
        checks.setVisible([one]);
        fake.elapse(const Duration(milliseconds: 180));
        final old = api.calls.single;
        checks.setVisible([two]);
        expect(old.cancellation.isCancelled, isTrue);
        fake.elapse(const Duration(milliseconds: 180));
        checks.setVisible([one]);
        expect(api.calls[1].cancellation.isCancelled, isTrue);
        fake.elapse(const Duration(milliseconds: 180));
        expect(api.calls, hasLength(3));
        old.complete(ResourceLinkState.invalid);
        fake.flushMicrotasks();
        expect(checks.health(one).state, ResourceLinkState.checking);
        api.calls.last.complete(ResourceLinkState.valid);
        fake.flushMicrotasks();
        expect(checks.health(one).state, ResourceLinkState.valid);
        checks.dispose();
        api.calls[1].complete(ResourceLinkState.invalid);
        fake.flushMicrotasks();
        expect(fake.pendingTimers, isEmpty);
      });
    },
  );

  test(
    'network errors are unknown and cached briefly instead of marking links invalid or looping',
    () {
      fakeAsync((fake) {
        final api = LinkCheckApiFixture();
        final checks = ResourceLinkChecks(api);
        final hit = probeHit('slow');
        checks.setVisible([hit]);
        fake.elapse(const Duration(milliseconds: 180));
        api.calls.single.result.completeError(
          TimeoutException('private diagnostic URL'),
        );
        fake.flushMicrotasks();
        final health = checks.health(hit);
        expect(health.state, ResourceLinkState.unknown);
        expect(health.message, isNot(contains('private diagnostic')));
        checks.setVisible([hit]);
        fake.elapse(const Duration(seconds: 10));
        expect(api.calls, hasLength(1));
        checks.dispose();
      });
    },
  );

  test('rate limits cool down only that netdisk; other providers continue', () {
    fakeAsync((fake) {
      final api = LinkCheckApiFixture();
      final checks = ResourceLinkChecks(
        api,
        concurrency: 1,
        clock: () => DateTime(2026, 10, 22).add(fake.elapsed),
      );
      final one = probeHit('one'), two = probeHit('two');
      final ali = probeHit('ali', url: 'https://www.alipan.com/s/abc123');
      checks.setVisible([one, two, ali]);
      fake.elapse(const Duration(milliseconds: 180));
      api.calls.single.result.completeError(ResourceLinkCheckLimited());
      fake.flushMicrotasks();
      expect(api.calls, hasLength(2));
      expect(api.calls.last.hit.identity, ali.identity);
      expect(checks.health(two).state, ResourceLinkState.unknown);
      api.calls.last.complete(ResourceLinkState.valid);
      fake.flushMicrotasks();
      checks.retry(two);
      fake.elapse(const Duration(seconds: 59));
      expect(api.calls, hasLength(2));
      fake.elapse(const Duration(seconds: 1));
      expect(api.calls, hasLength(3));
      checks.clearVisible();
      expect(api.calls.last.cancellation.isCancelled, isTrue);
      checks.dispose();
      expect(fake.pendingTimers, isEmpty);
    });
  });

  test(
    'new searches, invalid queries, filters and disposal cancel pending checks',
    () {
      fakeAsync((fake) {
        final api = LinkCheckApiFixture();
        final checks = ResourceLinkChecks(api);
        final hit = probeHit('one');
        final searchApi = SearchApiFixture(
          (_, _) => Stream.value(ResourceSearchBatch([hit], complete: true)),
        );
        final search = ResourceSearch(
          store: StateStore.memory(),
          api: searchApi,
          linkChecks: checks,
        );
        for (final action in <void Function()>[
          () => unawaited(search.search('Python')),
          () => unawaited(search.search('x')),
          () => search.filter('夸克网盘'),
          () => search.setKeywordFilters(include: '教程'),
        ]) {
          checks.setVisible([hit]);
          fake.elapse(const Duration(milliseconds: 180));
          action();
          expect(api.calls.last.cancellation.isCancelled, isTrue);
          fake.flushMicrotasks();
        }
        checks.setVisible([hit]);
        fake.elapse(const Duration(milliseconds: 180));
        search.dispose();
        expect(api.calls.last.cancellation.isCancelled, isTrue);
        expect(api.disposed, isTrue);
        fake.flushMicrotasks();
        expect(fake.pendingTimers, isEmpty);
      });
    },
  );
}
