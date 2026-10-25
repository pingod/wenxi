import 'dart:async';
import 'package:dio/dio.dart';
import 'package:asterlink/data/resource_link_checks.dart';
import 'package:asterlink/domain/resource_search.dart';

ResourceSearchHit probeHit(String id, {String password = '', String? url}) =>
    ResourceSearchHit.fromRaw({
      'title': '资料 $id',
      'url': url ?? 'https://pan.quark.cn/s/$id',
      'password': password,
    });

class LinkCheckCall {
  LinkCheckCall(this.hit, this.cancellation);
  final ResourceSearchHit hit;
  final CancelToken cancellation;
  final result = Completer<ResourceLinkHealth>();
  void complete(ResourceLinkState state) => result.complete(
    ResourceLinkHealth.checked(state, DateTime(2026, 10, 22)),
  );
}

class LinkCheckApiFixture extends ResourceLinkCheckApi {
  LinkCheckApiFixture([this.respond]);
  final Future<ResourceLinkHealth> Function(LinkCheckCall)? respond;
  final calls = <LinkCheckCall>[];
  bool disposed = false;
  @override
  Future<ResourceLinkHealth> check(
    ResourceSearchHit hit,
    CancelToken cancellation,
  ) {
    final call = LinkCheckCall(hit, cancellation);
    calls.add(call);
    return respond?.call(call) ?? call.result.future;
  }

  @override
  void dispose() {
    disposed = true;
  }
}
