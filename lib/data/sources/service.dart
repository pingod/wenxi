import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as hashes;
import 'package:flutter/foundation.dart';
import '../../core/json.dart';
import '../../domain/models.dart';
import '../http.dart';
import '../parser_rules/hub.dart';
import 'catalog.dart';
import 'host.dart';
import 'package.dart';
import '../../domain/download_network_policy.dart';
import 'results.dart';
import 'runtime.dart';

typedef SourceCatalogFetch = Future<Json> Function(String url, String key);

class SourceSession {
  const SourceSession(this.release, this.input, this.page);
  final SourceRelease release;
  final Json input;
  final SourcePage page;
  String get title => page.title;
  List<SourceResource> get items => page.items;
  Json get state => page.state;
  Object? get cursor => page.cursor;
  bool get hasMore => page.hasMore;
}

class RemoteSources extends ChangeNotifier {
  RemoteSources({
    required this.hub,
    required this.directory,
    this.enabled = true,
    this.runtime = const SourceRuntime(),
    SourceCatalogFetch? fetch,
    this.originFetch,
    this.retainedArchives,
    DateTime Function()? clock,
  }) : fetch = fetch ?? _fetch,
       clock = clock ?? DateTime.now {
    _endpoint = hub.url;
    hub.addListener(_hubChanged);
  }
  final ParserRuleHub hub;
  final Directory directory;
  final bool enabled;
  final SourceRuntime runtime;
  final SourceCatalogFetch fetch;
  final SourceFetch? originFetch;
  final Set<String> Function()? retainedArchives;
  final DateTime Function() clock;
  final _archiveGate = AsyncGate();
  final _scope = RequestScope();
  final _recentArchives = <String, DateTime>{};
  SourceCatalog? _catalog;
  Future<void>? _loading;
  Future<bool>? _refreshing;
  Timer? _timer;
  bool _closed = false;
  DateTime? _lastAttempt;
  late String _endpoint;
  String? lastError;
  String get _identity => hashes.sha256
      .convert(utf8.encode(hub.publicKey))
      .toString()
      .substring(0, 24);
  Directory get _cache => Directory('${directory.path}/sources/$_identity');
  bool get ready =>
      enabled &&
      !_closed &&
      hub.configured &&
      _catalog != null &&
      !clock().isAfter(_catalog!.expiresAt);
  List<SourceRelease> get releases => List.unmodifiable(
    ready
        ? _catalog!.releases.where((r) => r.package.compatible)
        : <SourceRelease>[],
  );
  List<SourceRelease> candidates(String url) {
    final uri = Uri.tryParse(url);
    return uri == null
        ? []
        : releases.where((r) => r.package.matches(uri)).toList();
  }

  Json diagnostics() => {
    'revision': _catalog?.revision,
    'available': releases.length,
    'error': lastError,
  };
  void start() {
    if (!enabled || _closed) return;
    unawaited(refresh());
    _timer ??= Timer.periodic(
      const Duration(minutes: 15),
      (_) => unawaited(refresh()),
    );
  }

  void _hubChanged() {
    if (_closed || hub.url == _endpoint) return;
    _endpoint = hub.url;
    _lastAttempt = null;
    final current = _refreshing;
    if (current == null) {
      unawaited(refresh(force: true));
    } else {
      unawaited(current.then((_) => refresh(force: true)));
    }
  }

  Future<void> load() => _loading ??= () async {
    if (!enabled || hub.publicKey.isEmpty) return;
    try {
      final file = File('${_cache.path}/current.json');
      if (await file.exists() && await file.length() <= 8000000) {
        // An expired signed catalog retains the anti-rollback watermark, but
        // ready remains false until a fresh catalog has been obtained.
        final catalog = SourceCatalog.verify(
          asJson(jsonDecode(await file.readAsString())),
          hub.publicKey,
          clock(),
          archived: true,
        );
        if (_closed) return;
        _catalog = catalog;
        notifyListeners();
      }
    } catch (_) {}
  }();
  Future<bool> refresh({bool force = false}) async {
    if (!enabled || !hub.configured || _closed) return false;
    await load();
    if (_refreshing != null) return _refreshing!;
    if (!force &&
        _lastAttempt != null &&
        clock().difference(_lastAttempt!).inSeconds >= 0 &&
        clock().difference(_lastAttempt!).inSeconds < 60) {
      return false;
    }
    _lastAttempt = clock();
    final endpoint = hub.url, key = hub.apiKey, publicKey = hub.publicKey;
    final action = _scope.run(() async {
      try {
        final envelope = await RequestScope.cancellable(
          fetch(endpoint, key),
        ).timeout(const Duration(seconds: 25));
        final catalog = SourceCatalog.verify(envelope, publicKey, clock());
        if (_closed ||
            endpoint != hub.url ||
            key != hub.apiKey ||
            publicKey != hub.publicKey) {
          return false;
        }
        if (_catalog != null && catalog.revision < _catalog!.revision) {
          throw const SourceError('SOURCE_ROLLBACK', '来源配置版本过旧');
        }
        if (_catalog != null && catalog.revision == _catalog!.revision) {
          String contents(SourceCatalog c) => c.releases
              .map((r) => '${r.package.id}/${r.version}/${r.hash}')
              .join('|');
          if (contents(_catalog!) != contents(catalog)) {
            throw const SourceError('SOURCE_ROLLBACK', '来源配置版本冲突');
          }
        }
        await _cache.create(recursive: true);
        final temp = File('${_cache.path}/current.pending');
        await temp.writeAsString(jsonEncode(envelope), flush: true);
        if (_closed || endpoint != hub.url) return false;
        await temp.rename('${_cache.path}/current.json');
        _catalog = catalog;
        lastError = null;
        notifyListeners();
        return true;
      } catch (error) {
        if (!_closed) {
          lastError = error is SourceError ? error.code : 'SOURCE_NETWORK';
          notifyListeners();
        }
        return false;
      }
    });
    _refreshing = action;
    try {
      return await action;
    } finally {
      if (identical(_refreshing, action)) _refreshing = null;
    }
  }

  void _available(SourceRelease release) {
    if (!releases.any((r) => r.package.id == release.package.id)) {
      throw const SourceError('SOURCE_DISABLED', '此来源已停用或配置已过期，请刷新来源后重试');
    }
  }

  Future<void> _archive(SourceRelease release) => _archiveGate.run(() async {
    _available(release);
    await _cache.create(recursive: true);
    final file = File('${_cache.path}/archive-${release.catalogId}.json');
    if (!await file.exists()) {
      // Each signed catalog is stored once, shared by all its source packages.
      // Keep catalogs referenced by download tasks and recently opened tasks.
      _recentArchives.removeWhere(
        (_, time) => clock().difference(time).inHours >= 1,
      );
      final keep = {
        ...?_retained(),
        ..._recentArchives.keys,
        release.catalogId,
      };
      var count = 0, total = 0;
      await for (final entry in _cache.list(followLinks: false)) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        final match = RegExp(
          r'^archive-([a-f0-9]{64})\.json$',
        ).firstMatch(name);
        if (match == null) continue;
        if (retainedArchives != null && !keep.contains(match[1])) {
          await entry.delete();
          continue;
        }
        count++;
        total += await entry.length();
      }
      final text = jsonEncode(release.proof), length = utf8.encode(text).length;
      if (count >= 64 || total + length > 64 * 1024 * 1024) {
        throw const SourceError('SOURCE_CACHE', '来源历史缓存已满，请先移除不再需要的下载任务');
      }
      final pending = File('${file.path}.pending');
      await pending.writeAsString(text, flush: true);
      await pending.rename(file.path);
    }
    _recentArchives[release.catalogId] = clock();
  });
  Set<String>? _retained() => retainedArchives?.call();
  Future<SourceRelease> _snapshot(Json origin) async {
    await refresh();
    final id = origin.str('sourceId'),
        hash = origin.str('packageHash'),
        catalogId = origin.str('catalogId');
    final version = origin['packageVersion'];
    if (!SourcePackage.idPattern.hasMatch(id) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(catalogId) ||
        version is! int ||
        version < 1) {
      throw const SourceError('SOURCE_ORIGIN', '来源任务信息无效');
    }
    final file = File('${_cache.path}/archive-$catalogId.json');
    if (!await file.exists() || await file.length() > 8000000) {
      throw const SourceError('SOURCE_ARCHIVE', '原来源版本不可用，请重新解析');
    }
    final catalog = SourceCatalog.verify(
      asJson(jsonDecode(await file.readAsString())),
      hub.publicKey,
      clock(),
      archived: true,
    );
    final release = catalog.releases
        .where(
          (r) =>
              r.package.id == id &&
              r.hash == hash &&
              r.version == version &&
              r.catalogId == catalogId,
        )
        .firstOrNull;
    if (release == null) {
      throw const SourceError('SOURCE_ARCHIVE', '原来源版本不可用，请重新解析');
    }
    _available(release);
    return release;
  }

  Future<Json> execute(
    SourceRelease release,
    String operation,
    Json input,
  ) async {
    RequestScope.checkpoint();
    _available(release);
    final host = SourceHost(release.package, fetch: originFetch);
    final result = await RequestScope.guarded(
      () => runtime.run(release.package, operation, input, host.call),
      () => _available(release),
    );
    _available(release);
    return result;
  }

  SourceSession _session(SourceRelease release, Json input, Json result) =>
      SourceSession(
        release,
        input,
        SourcePage.fromJson(release.package, result),
      );
  Future<SourceSession> open(SourceRelease release, Json input) async {
    return _session(release, input, await execute(release, 'resolve', input));
  }

  Future<SourceSession> list(
    SourceSession session, {
    SourceResource? directory,
    bool next = false,
    String? search,
  }) async {
    final input = {...session.input}
      ..remove('cursor')
      ..remove('state');
    if (directory != null) {
      input.remove('query');
      input['directory'] = directory.json;
    }
    if (next) input['cursor'] = session.cursor;
    if (search != null) input['query'] = search;
    final result = await execute(
      session.release,
      search == null ? 'list' : 'search',
      {...input, 'state': session.state},
    );
    return _session(session.release, input, result);
  }

  Future<Json> detail(SourceSession session, SourceResource resource) =>
      execute(session.release, 'detail', {
        ...session.input,
        'state': session.state,
        'resource': resource.json,
      });
  Future<DownloadSpec> download(
    SourceSession session,
    SourceResource resource, {
    int candidate = 0,
  }) async {
    if (resource.isDirectory) {
      throw const SourceError('SOURCE_RESOURCE', '请选择文件下载');
    }
    await _archive(session.release);
    final result = await execute(session.release, 'download', {
      ...session.input,
      'state': session.state,
      'resource': resource.json,
    });
    final downloads = SourceDownload.parse(session.release.package, result);
    final index = candidate % downloads.length, download = downloads[index];
    return DownloadSpec(
      url: download.url,
      fileName: resource.name,
      expectedSize: resource.size,
      headers: download.headers,
      networkPolicy: DownloadNetworkPolicy.fromJson({
        'hosts': session.release.package.permissions['downloadHosts'],
        'schemes': session.release.package.permissions['schemes'] ?? ['https'],
        'ports': session.release.package.permissions['ports'] ?? [80, 443],
      }),
      source: {
        'kind': 'remoteSource',
        'sourceId': session.release.package.id,
        'packageHash': session.release.hash,
        'packageVersion': session.release.version,
        'catalogId': session.release.catalogId,
        'candidate': index,
        'input': session.input,
        'state': session.state,
        'resource': resource.json,
      },
    );
  }

  static bool owns(DownloadSpec spec) => spec.source?['kind'] == 'remoteSource';
  Future<DownloadSpec> refreshDownload(DownloadSpec previous) async {
    if (!owns(previous)) throw const SourceError('SOURCE_ORIGIN', '来源任务信息无效');
    final origin = previous.source!,
        release = await _snapshot(previous.source!);
    final resource = SourceResource.fromJson(origin.obj('resource'));
    final session = _session(release, origin.obj('input'), {
      'items': [resource.json],
      'state': origin.obj('state'),
    });
    return (await download(
      session,
      resource,
      candidate: origin.integer('candidate') + 1,
    )).copyWith(
      fileName: previous.fileName,
      relativePath: previous.relativePath,
    );
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    hub.removeListener(_hubChanged);
    _scope.cancel();
    try {
      await _refreshing;
    } catch (_) {}
    dispose();
  }

  static Future<Json> _fetch(String endpoint, String key) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    final cancel = RequestScope.current?.whenCancel.asStream().listen(
      (_) => client.close(force: true),
    );
    try {
      return await (() async {
        final request = await client.getUrl(
          Uri.parse('${endpoint.replaceAll(RegExp(r'/+$'), '')}/v1/sources'),
        );
        request.followRedirects = false;
        request.headers.set('Authorization', 'Bearer $key');
        request.headers.set(
          'X-Source-Capabilities',
          SourcePackage.capabilities.entries
              .map((e) => '${e.key}/${e.value}')
              .join(','),
        );
        final response = await request.close();
        if (response.statusCode != 200) {
          throw const SourceError('SOURCE_NETWORK', '来源配置暂不可用');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          RequestScope.checkpoint();
          if (bytes.length + chunk.length > 8000000) {
            throw const SourceError('SOURCE_RESPONSE', '来源配置过大');
          }
          bytes.addAll(chunk);
        }
        final doc = asJson(jsonDecode(utf8.decode(bytes)));
        if (doc['ok'] != true) {
          throw const SourceError('SOURCE_NETWORK', '来源配置暂不可用');
        }
        return doc.obj('data');
      })().timeout(const Duration(seconds: 20));
    } finally {
      await cancel?.cancel();
      client.close(force: true);
    }
  }
}
