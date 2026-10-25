import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../domain/models.dart';
import '../domain/resource_search.dart';

enum ResourceLinkState {
  pending,
  checking,
  valid,
  invalid,
  locked,
  unknown,
  unsupported,
}

class ResourceLinkHealth {
  const ResourceLinkHealth(this.state, {this.message = '', this.checkedAt});
  final ResourceLinkState state;
  final String message;
  final DateTime? checkedAt;
  String get label => switch (state) {
    ResourceLinkState.pending => '待检测',
    ResourceLinkState.checking => '检测中',
    ResourceLinkState.valid => '链接有效',
    ResourceLinkState.invalid => '链接失效',
    ResourceLinkState.locked => '提取码待确认',
    ResourceLinkState.unknown => '暂无法确认',
    ResourceLinkState.unsupported => '暂不支持检测',
  };

  factory ResourceLinkHealth.checked(
    ResourceLinkState state,
    DateTime checkedAt,
  ) => ResourceLinkHealth(
    state,
    checkedAt: checkedAt,
    message: switch (state) {
      ResourceLinkState.valid => '本机网络检测到分享可访问，打开时以网盘实际状态为准。',
      ResourceLinkState.invalid => '网盘明确返回分享失效、被取消或内容为空，可以重新检测。',
      ResourceLinkState.locked => '提取码缺失或未通过验证，可以打开分享后确认提取码。',
      ResourceLinkState.unsupported => '该类型暂未内置检测规则，可继续尝试打开。',
      _ => '当前网络、验证码或网盘访问限制使状态无法确认，可继续尝试打开。',
    },
  );
}

String resourceLinkKey(ResourceSearchHit hit) =>
    '${hit.identity}\u0000${hit.password}';
bool canCheckResourceLink(ResourceSearchHit hit) =>
    hit.link?.kind == LinkKind.cloudShare;
String _provider(ResourceSearchHit hit) =>
    hit.platform?.key ?? Uri.parse(hit.url).host;

abstract class ResourceLinkCheckApi {
  Future<ResourceLinkHealth> check(
    ResourceSearchHit hit,
    CancelToken cancellation,
  );
  void dispose() {}
}

class ResourceLinkCheckLimited implements Exception {}

/// A bounded, viewport-driven queue. Cache entries include the extraction code.
/// Probes never transfer shares. Explicitly invalid links are placed after
/// links that are valid or still being checked.
class ResourceLinkChecks extends ChangeNotifier {
  ResourceLinkChecks(
    this.api, {
    this.clock = DateTime.now,
    this.debounce = const Duration(milliseconds: 180),
    this.concurrency = 3,
  }) : assert(concurrency > 0);
  final ResourceLinkCheckApi api;
  final DateTime Function() clock;
  final Duration debounce;
  final int concurrency;
  final _cache = <String, (DateTime, ResourceLinkHealth)>{};
  final _active = <String, CancelToken>{};
  final _limitedUntil = <String, DateTime>{};
  Map<String, ResourceSearchHit> _visible = {};
  Timer? _debounce, _cooldown;
  bool _closed = false;

  ResourceLinkHealth health(ResourceSearchHit hit) {
    if (!canCheckResourceLink(hit)) {
      return const ResourceLinkHealth(
        ResourceLinkState.unsupported,
        message: '该类型暂未内置检测规则，可继续尝试打开。',
      );
    }
    final key = resourceLinkKey(hit);
    if (_active.containsKey(key)) {
      return const ResourceLinkHealth(ResourceLinkState.checking);
    }
    final cached = _cache[key];
    if (cached != null && clock().isBefore(cached.$1)) return cached.$2;
    final until = _limitedUntil[_provider(hit)];
    if (until != null && clock().isBefore(until)) {
      return const ResourceLinkHealth(
        ResourceLinkState.unknown,
        message: '该网盘检测较频繁，请稍后再试。',
      );
    }
    return const ResourceLinkHealth(ResourceLinkState.pending);
  }

  /// Stable health ordering for a result list. Unknown, locked and checking
  /// states stay in the middle because a network failure must not be treated
  /// as proof that a share is dead.
  List<ResourceSearchHit> orderHits(Iterable<ResourceSearchHit> hits) {
    final values = hits.toList();
    final original = {
      for (final (index, hit) in values.indexed) resourceLinkKey(hit): index,
    };
    int rank(ResourceLinkState state) => switch (state) {
      ResourceLinkState.valid => 0,
      ResourceLinkState.locked ||
      ResourceLinkState.checking ||
      ResourceLinkState.pending ||
      ResourceLinkState.unknown => 1,
      ResourceLinkState.unsupported => 2,
      ResourceLinkState.invalid => 3,
    };
    values.sort((a, b) {
      final result = rank(health(a).state).compareTo(rank(health(b).state));
      return result == 0
          ? original[resourceLinkKey(a)]!.compareTo(
              original[resourceLinkKey(b)]!,
            )
          : result;
    });
    return values;
  }

  void setVisible(Iterable<ResourceSearchHit> hits) {
    if (_closed) return;
    final next = {
      for (final hit in hits.where(canCheckResourceLink).take(50))
        resourceLinkKey(hit): hit,
    };
    if (mapEquals(
      next.map((k, v) => MapEntry(k, v.identity)),
      _visible.map((k, v) => MapEntry(k, v.identity)),
    )) {
      if (_debounce == null &&
          next.values.any(
            (hit) => health(hit).state == ResourceLinkState.pending,
          )) {
        _schedule();
      }
      return;
    }
    _visible = next;
    for (final key in _active.keys.toList()) {
      if (!next.containsKey(key)) _active.remove(key)!.cancel();
    }
    _schedule();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(debounce, () {
      _debounce = null;
      _pump();
    });
  }

  void clearVisible() {
    _debounce?.cancel();
    _debounce = null;
    _cooldown?.cancel();
    _cooldown = null;
    _visible = {};
    for (final token in _active.values) {
      token.cancel();
    }
    _active.clear();
  }

  void retry(ResourceSearchHit hit) {
    if (_closed || !canCheckResourceLink(hit)) return;
    final key = resourceLinkKey(hit);
    if (_active.containsKey(key)) return;
    _cache.remove(key);
    _visible = {..._visible, key: hit};
    _pump();
    notifyListeners();
  }

  void _pump() {
    if (_closed) return;
    _cooldown?.cancel();
    _cooldown = null;
    _limitedUntil.removeWhere((_, until) => !clock().isBefore(until));
    DateTime? wakeAt;
    for (final hit in _visible.values) {
      final until = _limitedUntil[_provider(hit)];
      if (until != null && (wakeAt == null || until.isBefore(wakeAt))) {
        wakeAt = until;
      }
    }
    if (wakeAt != null) _cooldown = Timer(wakeAt.difference(clock()), _pump);
    var started = false;
    for (final entry in _visible.entries) {
      if (_active.length >= concurrency) break;
      if (health(entry.value).state != ResourceLinkState.pending) continue;
      final token = CancelToken();
      _active[entry.key] = token;
      unawaited(_run(entry.key, entry.value, token));
      started = true;
    }
    if (started) notifyListeners();
  }

  Future<void> _run(
    String key,
    ResourceSearchHit hit,
    CancelToken token,
  ) async {
    ResourceLinkHealth result;
    try {
      result = await Future.sync(() => api.check(hit, token));
    } catch (e) {
      result = ResourceLinkHealth(
        ResourceLinkState.unknown,
        checkedAt: clock(),
        message: e is ResourceLinkCheckLimited
            ? '该网盘检测较频繁，请稍后再试。'
            : '本机检测超时或网络异常，可以稍后重新检测。',
      );
      if (!token.isCancelled && e is ResourceLinkCheckLimited) {
        _limitedUntil[_provider(hit)] = clock().add(const Duration(minutes: 1));
      }
    }
    if (_closed || token.isCancelled || !identical(_active[key], token)) return;
    _active.remove(key);
    final ttl = switch (result.state) {
      ResourceLinkState.valid => const Duration(minutes: 10),
      ResourceLinkState.invalid => const Duration(minutes: 3),
      ResourceLinkState.unsupported => const Duration(minutes: 30),
      _ => const Duration(minutes: 1),
    };
    _cache[key] = (clock().add(ttl), result);
    while (_cache.length > 1200) {
      _cache.remove(_cache.keys.first);
    }
    notifyListeners();
    _pump();
  }

  @override
  void dispose() {
    _closed = true;
    clearVisible();
    api.dispose();
    super.dispose();
  }
}
