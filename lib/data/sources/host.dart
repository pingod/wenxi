import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:html/parser.dart' as html;
import 'package:enough_convert/enough_convert.dart';
import '../../core/json.dart';
import '../../domain/download_network_policy.dart';
import '../http.dart';
import '../parser_rules/workflow_expression.dart';
import 'package.dart';

typedef SourceFetch = Future<Json> Function(SourcePackage source, Json options);

/// No account storage, filesystem, process or browser handles are exposed.
class SourceHost {
  SourceHost(this.source, {SourceFetch? fetch}) : fetch = fetch ?? request;
  final SourcePackage source;
  final SourceFetch fetch;
  final trace = <Json>[];
  int requests = 0;

  Future<Object?> call(String method, Json args) async {
    RequestScope.checkpoint();
    final capability = method == 'request' ? 'http' : method;
    if (method != 'sleep' &&
        !source.json.obj('requires').containsKey(capability)) {
      throw const SourceError('SOURCE_CAPABILITY', '来源未声明所需能力');
    }
    switch (method) {
      case 'request':
        if (++requests > 120) {
          throw const SourceError('SOURCE_BUDGET', '来源请求次数过多');
        }
        final clock = Stopwatch()..start();
        source.checkedUrl(args.str('url'));
        source.checkedHeaders(args['headers']);
        final result = await fetch(source, args);
        trace.add({
          'operation': 'request',
          'status': result.integer('status'),
          'elapsedMs': clock.elapsedMilliseconds,
        });
        return result;
      case 'html':
      case 'crypto':
      case 'codec':
        return _compute(method, args);
      case 'sleep':
        final ms = args['ms'];
        if (ms is! int || ms < 0 || ms > 10000) {
          throw const SourceError('SOURCE_BUDGET', '来源等待时间无效');
        }
        await RequestScope.wait(Duration(milliseconds: ms));
        return null;
      default:
        throw const SourceError('SOURCE_CAPABILITY', '来源请求了未开放的能力');
    }
  }

  // Host parsing and cryptography also stay off the UI isolate. Cancellation
  // terminates this worker, including a pathological CSS selector.
  static Future<Object?> _compute(String method, Json args) async {
    if (utf8.encode(jsonEncode(args)).length > 1048576) {
      throw const SourceError('SOURCE_BUDGET', '来源运算输入过大');
    }
    final port = ReceivePort();
    Isolate? worker;
    try {
      worker = await Isolate.spawn(
        _computeWorker,
        [port.sendPort, method, args],
        onError: port.sendPort,
        onExit: port.sendPort,
      );
      final reply = await RequestScope.cancellable(port.first).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw const SourceError('SOURCE_BUDGET', '来源运算超过限制'),
      );
      if (reply is! Map || reply['ok'] != true) {
        throw const SourceError('SOURCE_COMPUTE', '来源内容提取或运算失败');
      }
      return reply['value'];
    } finally {
      worker?.kill(priority: Isolate.immediate);
      port.close();
    }
  }

  static bool publicAddress(InternetAddress address) =>
      DownloadNetworkPolicy.publicAddress(address);

  static HttpClient _client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..connectionFactory = (uri, proxyHost, proxyPort) async {
      final addresses = await InternetAddress.lookup(
        uri.host,
      ).timeout(const Duration(seconds: 10));
      RequestScope.checkpoint();
      if (proxyHost != null ||
          addresses.isEmpty ||
          addresses.any((a) => !publicAddress(a))) {
        throw const SourceError('SOURCE_HOST', '来源请求目标不是公网地址');
      }
      final address =
          addresses
              .where((a) => a.type == InternetAddressType.IPv4)
              .firstOrNull ??
          addresses.first;
      // A custom connectionFactory must supply TLS itself. InternetAddress
      // from lookup retains the hostname for SNI and certificate validation.
      return uri.scheme == 'https'
          ? SecureSocket.startConnect(address, uri.port)
          : Socket.startConnect(address, uri.port);
    };

  static (List<int>, String) _body(String encoding, Object? body) {
    switch (encoding) {
      case 'json':
        return (
          utf8.encode(jsonEncode(body)),
          'application/json;charset=utf-8',
        );
      case 'form':
        if (body is! Map) throw const SourceError('SOURCE_BODY', '表单请求体必须为对象');
        return (
          utf8.encode(form(asJson(body))),
          'application/x-www-form-urlencoded;charset=utf-8',
        );
      case 'text':
      case 'base64':
        if (body is! String) {
          throw const SourceError('SOURCE_BODY', '来源请求体必须为字符串');
        }
        return encoding == 'text'
            ? (utf8.encode(body), 'text/plain;charset=utf-8')
            : (base64Decode(body), 'application/octet-stream');
      case 'multipart':
        if (body is! Map) {
          throw const SourceError('SOURCE_BODY', 'multipart 请求体无效');
        }
        final data = asJson(body),
            fields = data.obj('fields'),
            files = data['files'] ?? [];
        if (fields.length > 64 || files is! List || files.length > 16) {
          throw const SourceError('SOURCE_BODY', 'multipart 字段过多');
        }
        final random = Random.secure();
        final boundary =
            'asterlink_${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
        final bytes = BytesBuilder(copy: false);
        void add(String text) => bytes.add(utf8.encode(text));
        String quoted(dynamic value) {
          if (value is! String ||
              value.isEmpty ||
              value.length > 512 ||
              RegExp(r'[\x00-\x1f\x7f"\\]').hasMatch(value)) {
            throw const SourceError('SOURCE_BODY', 'multipart 字段名称无效');
          }
          return value;
        }
        for (final field in fields.entries) {
          if (field.value is! String) {
            throw const SourceError('SOURCE_BODY', 'multipart 字段值必须为字符串');
          }
          add(
            '--$boundary\r\nContent-Disposition: form-data; name="${quoted(field.key)}"\r\n\r\n${field.value}\r\n',
          );
        }
        for (final file in files) {
          if (file is! Map || file['base64'] is! String) {
            throw const SourceError('SOURCE_BODY', 'multipart 文件数据无效');
          }
          final type = file['contentType'] ?? 'application/octet-stream';
          if (type is! String ||
              !RegExp(r'^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$').hasMatch(type)) {
            throw const SourceError('SOURCE_BODY', 'multipart 文件类型无效');
          }
          add(
            '--$boundary\r\nContent-Disposition: form-data; name="${quoted(file['name'])}"; filename="${quoted(file['fileName'])}"\r\nContent-Type: $type\r\n\r\n',
          );
          bytes.add(base64Decode(file['base64']));
          add('\r\n');
        }
        add('--$boundary--\r\n');
        return (bytes.takeBytes(), 'multipart/form-data; boundary=$boundary');
      default:
        throw const SourceError('SOURCE_BODY', '来源请求体编码无效');
    }
  }

  static Future<Json> request(
    SourcePackage source,
    Json options, {
    HttpClient Function()? clientFactory,
  }) async {
    var uri = source.checkedUrl(options.str('url'));
    var method = options.str('method', 'GET').toUpperCase();
    final methods = source.permissions['methods'] as List? ?? ['GET', 'POST'];
    if (!methods.contains(method)) {
      throw const SourceError('SOURCE_METHOD', '来源请求方法未经声明');
    }
    var headers = source.checkedHeaders(options['headers']);
    List<int>? body;
    final encoding = options.str('encoding', 'json');
    if (options.containsKey('body')) {
      if (method == 'GET' || method == 'HEAD') {
        throw const SourceError('SOURCE_BODY', '此请求不能携带请求体');
      }
      final prepared = _body(encoding, options['body']);
      body = prepared.$1;
      if (body.length > 1048576) {
        throw const SourceError('SOURCE_BODY', '来源请求体过大');
      }
      final type = headers.keys
          .where((k) => k.toLowerCase() == 'content-type')
          .firstOrNull;
      if (type == null || encoding == 'multipart') {
        if (type != null) headers.remove(type);
        headers['Content-Type'] = prepared.$2;
      }
    }
    final timeout = options.integer('timeout', 30);
    if (timeout < 1 || timeout > 60) {
      throw const SourceError('SOURCE_TIMEOUT', '来源请求时限无效');
    }
    final client = (clientFactory ?? _client)();
    final token = RequestScope.current;
    final cancel = token?.whenCancel.asStream().listen(
      (_) => client.close(force: true),
    );
    try {
      return await (() async {
        for (var hop = 0; hop < 6; hop++) {
          RequestScope.checkpoint();
          if (!methods.contains(method)) {
            throw const SourceError('SOURCE_METHOD', '来源跳转方法未经声明');
          }
          final request = await client.openUrl(method, uri);
          request.followRedirects = false;
          for (final entry in headers.entries) {
            request.headers.set(entry.key, entry.value);
          }
          if (body != null) request.add(body!);
          final response = await request.close();
          final location = response.headers.value('location');
          if (options['redirects'] == true &&
              {301, 302, 303, 307, 308}.contains(response.statusCode) &&
              location != null) {
            final next = source.checkedUrl(uri.resolve(location).toString());
            if (hop == 5) {
              throw const SourceError('SOURCE_REDIRECT', '来源跳转次数过多');
            }
            if (next.scheme == 'http' && uri.scheme == 'https') {
              throw const SourceError('SOURCE_REDIRECT', '来源跳转降低了连接安全级别');
            }
            if (next.origin != uri.origin) {
              // Custom headers may also carry tokens. Other origins need an
              // explicit request by the source package.
              headers = {
                for (final e in headers.entries)
                  if ({
                    'accept',
                    'accept-language',
                    'user-agent',
                  }.contains(e.key.toLowerCase()))
                    e.key: e.value,
              };
            }
            if (response.statusCode == 303 && method != 'HEAD' ||
                {301, 302}.contains(response.statusCode) && method == 'POST') {
              method = 'GET';
              body = null;
              headers.removeWhere(
                (key, _) => key.toLowerCase().startsWith('content-'),
              );
            }
            if (method != 'GET' && method != 'HEAD') {
              throw const SourceError('SOURCE_REDIRECT', '此请求跳转需要来源显式处理');
            }
            var discarded = 0;
            await for (final part in response) {
              if ((discarded += part.length) > 524288) {
                throw const SourceError('SOURCE_RESPONSE', '来源响应过大');
              }
            }
            uri = next;
            continue;
          }
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in response) {
            RequestScope.checkpoint();
            if (bytes.length + chunk.length > 524288) {
              throw const SourceError('SOURCE_RESPONSE', '来源响应超过 512 KiB');
            }
            bytes.add(chunk);
          }
          final data = bytes.takeBytes(),
              responseHeaders = <String, List<String>>{};
          response.headers.forEach(
            (name, value) => responseHeaders[name] = value,
          );
          if (options['binary'] == true) {
            return {
              'status': response.statusCode,
              'url': uri.toString(),
              'headers': responseHeaders,
              'base64': base64Encode(data),
            };
          }
          final charset = options
              .str('charset', response.headers.contentType?.charset ?? 'utf-8')
              .toLowerCase();
          final text = switch (charset) {
            'utf-8' || 'utf8' => utf8.decode(data, allowMalformed: true),
            'gbk' || 'gb2312' => const GbkCodec().decode(data),
            'latin1' || 'iso-8859-1' => latin1.decode(data),
            _ => throw const SourceError('SOURCE_CHARSET', '来源字符编码不受支持'),
          };
          return {
            'status': response.statusCode,
            'url': uri.toString(),
            'headers': responseHeaders,
            'text': text,
          };
        }
        throw const SourceError('SOURCE_REDIRECT', '来源跳转次数过多');
      })().timeout(
        Duration(seconds: timeout),
        onTimeout: () => throw const SourceError('SOURCE_TIMEOUT', '来源连接超时'),
      );
    } on SourceError {
      rethrow;
    } catch (_) {
      RequestScope.checkpoint();
      throw const SourceError('SOURCE_NETWORK', '来源连接失败，请检查网络');
    } finally {
      await cancel?.cancel();
      client.close(force: true);
    }
  }

  /// Administrator smoke test: read at most 4 KiB, without exporting a URL or
  /// payload. Uses the same download-domain declaration as the client.
  static Future<Json> probeDownload(
    SourcePackage source,
    String url,
    Map<String, String> headers,
  ) async {
    var uri = source.checkedUrl(url, download: true),
        requestHeaders = {...headers};
    final client = _client();
    final cancel = RequestScope.current?.whenCancel.asStream().listen(
      (_) => client.close(force: true),
    );
    try {
      return await (() async {
        for (var hop = 0; hop < 6; hop++) {
          RequestScope.checkpoint();
          final request = await client.getUrl(uri);
          request.followRedirects = false;
          for (final entry in requestHeaders.entries) {
            request.headers.set(entry.key, entry.value);
          }
          request.headers.set('Range', 'bytes=0-4095');
          final response = await request.close();
          final location = response.headers.value('location');
          if ({301, 302, 303, 307, 308}.contains(response.statusCode) &&
              location != null) {
            final next = source.checkedUrl(
              uri.resolve(location).toString(),
              download: true,
            );
            if (next.scheme == 'http' && uri.scheme == 'https') {
              throw const SourceError('SOURCE_REDIRECT', '下载地址跳转无效');
            }
            if (next.origin != uri.origin) {
              requestHeaders = {
                for (final e in requestHeaders.entries)
                  if ({'accept', 'user-agent'}.contains(e.key.toLowerCase()))
                    e.key: e.value,
              };
            }
            var discarded = 0;
            await for (final bytes in response) {
              if ((discarded += bytes.length) > 524288) {
                throw const SourceError('SOURCE_RESPONSE', '下载跳转响应过大');
              }
            }
            uri = next;
            continue;
          }
          if (!{200, 206}.contains(response.statusCode)) {
            throw const SourceError('SOURCE_DOWNLOAD_PROBE', '下载地址暂不可读取');
          }
          var count = 0;
          await for (final bytes in response) {
            count += bytes.length;
            if (count >= 4096) {
              count = 4096;
              break;
            }
          }
          return {'httpStatus': response.statusCode, 'downloadBytes': count};
        }
        throw const SourceError('SOURCE_REDIRECT', '下载地址跳转次数过多');
      })().timeout(const Duration(seconds: 30));
    } finally {
      await cancel?.cancel();
      client.close(force: true);
    }
  }
}

void _computeWorker(List<dynamic> packet) {
  final out = packet[0] as SendPort;
  try {
    final method = packet[1] as String, args = asJson(packet[2]);
    Object? result;
    if (method == 'html') {
      final text = args.str('text'), selectors = args['selectors'];
      if (utf8.encode(text).length > 1048576 ||
          selectors is! Map ||
          selectors.length > 32) {
        throw const FormatException();
      }
      final doc = html.parse(text), values = <String, dynamic>{};
      var outputBytes = 0;
      for (final entry in selectors.entries) {
        final spec = asJson(entry.value), selector = spec.str('selector');
        final attrs = spec['attributes'] ?? [],
            limit = spec.integer('limit', 1000);
        if (selector.isEmpty ||
            selector.length > 512 ||
            limit < 1 ||
            limit > 2000 ||
            attrs is! List ||
            attrs.length > 16 ||
            attrs.any((a) => a is! String || a.length > 64)) {
          throw const FormatException();
        }
        final rows = <Json>[];
        for (final node in doc.querySelectorAll(selector).take(limit)) {
          final row = {
            'text': node.text.trim(),
            for (final attr in attrs)
              attr as String: node.attributes[attr] ?? '',
          };
          if ((outputBytes += utf8.encode(jsonEncode(row)).length + 2) >
              900000) {
            throw const FormatException();
          }
          rows.add(row);
        }
        values[entry.key.toString()] = rows;
      }
      result = values;
    } else {
      final op = args.str('op');
      final allowed = method == 'crypto'
          ? {'hash', 'hmac', 'aesCbc', 'rsaEncrypt', 'randomHex'}
          : {
              'bytes',
              'utf8',
              'base64',
              'unbase64',
              'hex',
              'unhex',
              'urlEncode',
              'urlDecode',
              'jsonEncode',
              'jsonDecode',
              'urlResolve',
              'urlParse',
            };
      final values = args['args'];
      if (!allowed.contains(op) || values is! List || values.length > 4) {
        throw const FormatException();
      }
      if (op == 'urlResolve' &&
          values.length == 2 &&
          values.every((v) => v is String)) {
        result = Uri.parse(values[0]).resolve(values[1]).toString();
      } else if (op == 'urlParse' &&
          values.length == 1 &&
          values[0] is String) {
        final uri = Uri.parse(values[0]);
        result = {
          'scheme': uri.scheme,
          'host': uri.host,
          'path': uri.path,
          'query': uri.queryParameters,
          'fragment': uri.fragment,
        };
      } else {
        result = WorkflowExpression({}).eval(
          {
            r'$op': op,
            'args': [
              for (var i = 0; i < values.length; i++) {r'$ref': 'input.$i'},
            ],
          },
          {'input': values},
        );
      }
    }
    if (utf8.encode(jsonEncode(result)).length > 1048576) {
      throw const FormatException();
    }
    out.send({'ok': true, 'value': result});
  } catch (_) {
    out.send({'ok': false});
  }
}
