import 'dart:convert';
import '../../core/json.dart';
import 'package.dart';

class SourcePage {
  SourcePage._(this.title, this.items, this.state, this.cursor, this.hasMore);
  final String title;
  final List<SourceResource> items;
  final Json state;
  final Object? cursor;
  final bool hasMore;
  factory SourcePage.fromJson(SourcePackage source, Json result) {
    if (result['items'] is! List ||
        (result['items'] as List).length > 10000 ||
        result['state'] != null && result['state'] is! Map ||
        utf8.encode(jsonEncode(result['state'] ?? {})).length > 16384 ||
        utf8.encode(jsonEncode(result['cursor'])).length > 4096 ||
        result['hasMore'] != null && result['hasMore'] is! bool ||
        result.str('title').length > 512) {
      throw const SourceError('SOURCE_RESULT', '来源返回的列表无效');
    }
    if (result['hasMore'] == true &&
        (!source.operations.containsKey('list') || result['cursor'] == null)) {
      throw const SourceError('SOURCE_RESULT', '来源分页信息不完整');
    }
    final seen = <String>{}, items = <SourceResource>[];
    for (final raw in result['items'] as List) {
      if (raw is! Map) throw const SourceError('SOURCE_RESULT', '来源资源格式无效');
      final item = SourceResource.fromJson(asJson(raw));
      if (!seen.add(item.id)) {
        throw const SourceError('SOURCE_RESULT', '来源返回了重复资源');
      }
      if (item.isDirectory && !source.operations.containsKey('list')) {
        throw const SourceError('SOURCE_RESULT', '来源未提供目录读取能力');
      }
      items.add(item);
    }
    return SourcePage._(
      result.str('title', source.name),
      List.unmodifiable(items),
      result.obj('state'),
      result['cursor'],
      result['hasMore'] == true,
    );
  }
}

class SourceDownload {
  SourceDownload._(this.url, this.headers, this.expiresAt);
  final String url;
  final Map<String, String> headers;
  final int? expiresAt;
  static List<SourceDownload> parse(SourcePackage source, Json result) {
    final urls = result['urls'];
    if (urls is! List || urls.isEmpty || urls.length > 16) {
      throw const SourceError('SOURCE_DOWNLOAD', '来源未返回下载地址');
    }
    return urls
        .map((raw) {
          if (raw is! String && raw is! Map) {
            throw const SourceError('SOURCE_DOWNLOAD', '来源下载地址格式无效');
          }
          final value = raw is String
              ? <String, dynamic>{'url': raw}
              : asJson(raw);
          final url = value['url'];
          if (url is! String) {
            throw const SourceError('SOURCE_DOWNLOAD', '来源下载地址格式无效');
          }
          source.checkedUrl(url, download: true);
          final expires = value['expiresAt'] ?? result['expiresAt'];
          if (expires != null && (expires is! int || expires < 0)) {
            throw const SourceError('SOURCE_DOWNLOAD', '来源下载有效期无效');
          }
          return SourceDownload._(
            url,
            source.checkedHeaders(value['headers'] ?? result['headers']),
            expires as int?,
          );
        })
        .toList(growable: false);
  }
}
