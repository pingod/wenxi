import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../core/json.dart';
import '../domain/resource_search.dart';
import '../domain/models.dart';
import 'resource_search_api.dart';
import 'resource_link_checks.dart';
import 'state_store.dart';

enum ResourceSearchPhase { idle, searching, complete, stopped, failed }

class ResourceSearch extends ChangeNotifier {
  ResourceSearch({
    required this.store,
    required this.api,
    this.linkChecks,
    this.clock = DateTime.now,
    this.budget = const Duration(seconds: 70),
  });
  final StateStore store;
  final ResourceSearchApi api;
  final ResourceLinkChecks? linkChecks;
  final DateTime Function() clock;
  final Duration budget;
  ResourceSearchPhase phase = ResourceSearchPhase.idle;
  String keyword = '', error = '';
  String? cloudFilter;
  List<String> includeTerms = const [], excludeTerms = const [];
  bool get hasKeywordFilters =>
      includeTerms.isNotEmpty || excludeTerms.isNotEmpty;
  final _hits = <String, ResourceSearchHit>{};
  final _cache = <String, (DateTime, List<ResourceSearchHit>)>{};
  CancelToken? _cancellation;
  Timer? _deadline;
  int _generation = 0;
  bool _closed = false;
  bool fromCache = false;
  List<ResourceSearchHit> recommendations = const [];
  bool recommendationsLoading = false, recommendationsLoaded = false;
  String recommendationsError = '';
  int _recommendationGeneration = 0;

  Future<void> loadRecommendations({bool refresh = false}) async {
    final client = api;
    if (_closed ||
        recommendationsLoading ||
        recommendationsLoaded && !refresh ||
        client is! ResourceDiscoveryApi) {
      return;
    }
    final generation = ++_recommendationGeneration;
    recommendationsLoading = true;
    recommendationsError = '';
    notifyListeners();
    try {
      final rows = await (client as ResourceDiscoveryApi).recommendations(
        exclude: refresh
            ? recommendations
                  .map((r) => r.recommendationId)
                  .where((id) => id > 0)
                  .toList()
            : const [],
        refresh: refresh,
      );
      if (_closed || generation != _recommendationGeneration) return;
      recommendations = List.unmodifiable(rows);
      recommendationsLoaded = true;
    } catch (_) {
      if (_closed || generation != _recommendationGeneration) return;
      recommendationsError = '推荐资源暂时加载失败，点击重试';
    } finally {
      if (!_closed && generation == _recommendationGeneration) {
        recommendationsLoading = false;
        notifyListeners();
      }
    }
  }

  bool get searching => phase == ResourceSearchPhase.searching;
  bool get preferSupported =>
      store.data.obj('resourceSearch').boolean('preferSupported', true);
  List<String> get history =>
      (store.data['resourceSearchHistory'] as List? ?? [])
          .whereType<String>()
          .where((e) => e.length <= 120)
          .take(12)
          .toList();
  List<ResourceSearchHit> get allItems => List.unmodifiable(_hits.values);
  static const defaultCloudPriority = [
    CloudPlatform.quark,
    CloudPlatform.uc,
    CloudPlatform.tianyi,
    CloudPlatform.c139,
    CloudPlatform.wopan,
    CloudPlatform.guangya,
    CloudPlatform.xunlei,
    CloudPlatform.pan115,
    CloudPlatform.weiyun,
    CloudPlatform.pikpak,
    CloudPlatform.baidu,
    CloudPlatform.aliyun,
    CloudPlatform.pan123,
    CloudPlatform.lanzou,
    CloudPlatform.ilanzou,
    CloudPlatform.ctfile,
    CloudPlatform.feijipan,
    CloudPlatform.github,
  ];
  List<CloudPlatform> get cloudPriority {
    final saved = store.data.obj('resourceSearch')['cloudPriority'];
    return [
      ...{
        if (saved is List)
          ...saved.whereType<String>().map(CloudPlatform.fromKey).nonNulls,
        ...defaultCloudPriority,
      },
    ];
  }

  Future<void> setCloudPriority(List<CloudPlatform> values) async {
    final order = {
      ...values,
      ...defaultCloudPriority,
    }.map((p) => p.key).toList();
    await store.change((draft) {
      draft['resourceSearch'] = draft.obj('resourceSearch')
        ..['cloudPriority'] = order;
    });
    linkChecks?.clearVisible();
    if (!_closed) notifyListeners();
  }

  List<String> get orderedClouds {
    final names = allItems.map((hit) => hit.cloudName).toSet();
    return [
      for (final platform in cloudPriority)
        if (names.remove(platform.label)) platform.label,
      ...(names.toList()..sort()),
    ];
  }

  List<ResourceSearchHit> get items {
    final values = _hits.values.where((hit) {
      final title = hit.title.toLowerCase();
      return (cloudFilter == null || hit.cloudName == cloudFilter) &&
          includeTerms.every((term) => title.contains(term.toLowerCase())) &&
          !excludeTerms.any((term) => title.contains(term.toLowerCase()));
    }).toList();
    final ranks = {
      for (final (index, platform) in cloudPriority.indexed) platform: index,
    };
    final original = {
      for (final (index, hit) in values.indexed) hit.identity: index,
    };
    values.sort((a, b) {
      final rank = (ranks[a.platform] ?? ranks.length).compareTo(
        ranks[b.platform] ?? ranks.length,
      );
      if (rank != 0) return rank;
      if (preferSupported && a.canParse != b.canParse) {
        return a.canParse ? -1 : 1;
      }
      return original[a.identity]!.compareTo(original[b.identity]!);
    });
    return linkChecks?.orderHits(values) ?? values;
  }

  void filter(String? value) {
    linkChecks?.clearVisible();
    cloudFilter = value;
    notifyListeners();
  }

  void setKeywordFilters({String include = '', String exclude = ''}) {
    linkChecks?.clearVisible();
    List<String> terms(String text) => text
        .trim()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toSet()
        .toList(growable: false);
    includeTerms = terms(include);
    excludeTerms = terms(exclude);
    notifyListeners();
  }

  Future<void> setPreferSupported(bool value) async {
    await store.change((draft) {
      draft['resourceSearch'] = draft.obj('resourceSearch')
        ..['preferSupported'] = value;
    });
    if (!_closed) notifyListeners();
  }

  Future<void> clearHistory() async {
    await store.change((draft) => draft.remove('resourceSearchHistory'));
    if (!_closed) notifyListeners();
  }

  Future<void> search(String query, {bool refresh = false}) async {
    final term = query.trim();
    if (_closed) return;
    if (term.runes.length < 2 || term.length > 120) {
      linkChecks?.clearVisible();
      _deadline?.cancel();
      _generation++;
      _cancellation?.cancel();
      _cancellation = null;
      keyword = term;
      phase = ResourceSearchPhase.failed;
      _hits.clear();
      error = '请输入 2–120 个字符的关键词';
      notifyListeners();
      return;
    }
    if (searching && term == keyword && !refresh) return;
    linkChecks?.clearVisible();
    _cancellation?.cancel();
    _deadline?.cancel();
    final generation = ++_generation, cancellation = CancelToken();
    _cancellation = cancellation;
    keyword = term;
    error = '';
    fromCache = false;
    _hits.clear();
    phase = ResourceSearchPhase.searching;
    notifyListeners();
    // Search history stays in the app's encrypted local state.
    unawaited(
      store
          .change((draft) {
            final recent = (draft['resourceSearchHistory'] as List? ?? [])
                .whereType<String>();
            draft['resourceSearchHistory'] = [
              term,
              ...recent.where((e) => e.toLowerCase() != term.toLowerCase()),
            ].take(12).toList();
          })
          .catchError((Object _) {}),
    );
    final cached = _cache[term.toLowerCase()];
    if (!refresh &&
        cached != null &&
        clock().difference(cached.$1) < const Duration(minutes: 2)) {
      _merge(cached.$2);
      phase = ResourceSearchPhase.complete;
      fromCache = true;
      _cancellation = null;
      notifyListeners();
      return;
    }
    final deadline = Timer(budget, () {
      if (_closed || generation != _generation || !searching) return;
      phase = ResourceSearchPhase.failed;
      error = '搜索耗时较长，已找到的结果已保留';
      _generation++;
      cancellation.cancel('deadline');
      _cancellation = null;
      notifyListeners();
    });
    _deadline = deadline;
    try {
      await for (final batch in api.search(term, cancellation)) {
        if (_closed || generation != _generation) return;
        if (batch.complete) {
          deadline.cancel();
          final previous = Map<String, ResourceSearchHit>.of(_hits);
          _hits.clear();
          _merge(
            batch.items
                .map((hit) => previous[hit.identity]?.merge(hit) ?? hit)
                .toList(),
          );
        } else {
          _merge(batch.items);
        }
        if (batch.complete) {
          phase = ResourceSearchPhase.complete;
          _cache[term.toLowerCase()] = (clock(), allItems);
          while (_cache.length > 12) {
            _cache.remove(_cache.keys.first);
          }
        }
        notifyListeners();
        if (batch.complete) break;
      }
      if (!_closed && generation == _generation && searching) {
        phase = ResourceSearchPhase.failed;
        error = '搜索连接已断开，已找到的结果已保留';
      }
    } catch (e) {
      if (_closed || generation != _generation) return;
      phase = ResourceSearchPhase.failed;
      error = e is AppException ? e.message : '搜索暂时不可用，请检查网络后重试';
    } finally {
      deadline.cancel();
      if (!_closed && generation == _generation) {
        cancellation.cancel('finished');
        _cancellation = null;
        notifyListeners();
      }
    }
  }

  void _merge(List<ResourceSearchHit> items) {
    for (final hit in items) {
      final previous = _hits[hit.identity];
      if (previous != null) {
        _hits[hit.identity] = previous.merge(hit);
      } else if (_hits.length < HttpResourceSearchApi.resultLimit) {
        _hits[hit.identity] = hit;
      }
    }
  }

  void stop() {
    if (!searching || _closed) return;
    _generation++;
    _deadline?.cancel();
    _cancellation?.cancel();
    _cancellation = null;
    phase = ResourceSearchPhase.stopped;
    error = '';
    notifyListeners();
  }

  void showRecommendations() {
    stop();
    keyword = '';
    phase = ResourceSearchPhase.idle;
    error = '';
    _hits.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    linkChecks?.dispose();
    _deadline?.cancel();
    _generation++;
    _cancellation?.cancel();
    super.dispose();
  }
}
