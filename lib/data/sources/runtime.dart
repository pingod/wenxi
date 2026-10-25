import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'package:asterlink_js/asterlink_js.dart';
import '../../core/json.dart';
import '../http.dart';
import 'package.dart';

typedef SourceHostCall = Future<Object?> Function(String method, Json args);

class SourceRuntime {
  const SourceRuntime({this.libraryPath});
  final String? libraryPath;
  Future<Json> run(
    SourcePackage source,
    String operation,
    Json input,
    SourceHostCall host,
  ) async {
    final scope = RequestScope();
    final parent = RequestScope.current;
    RequestScope.checkpoint();
    final cancel = parent?.whenCancel.asStream().listen((_) => scope.cancel());
    try {
      return await scope.run(() => _run(source, operation, input, host));
    } finally {
      scope.cancel();
      await cancel?.cancel();
    }
  }

  Future<Json> _run(
    SourcePackage source,
    String operation,
    Json input,
    SourceHostCall host,
  ) async {
    if (!source.compatible || !source.operations.containsKey(operation)) {
      throw const SourceError('SOURCE_CAPABILITY', '当前客户端不支持此来源操作');
    }
    if (utf8.encode(jsonEncode(input)).length > 65536) {
      throw const SourceError('SOURCE_INPUT', '来源输入过大');
    }
    final events = ReceivePort(), exits = ReceivePort();
    final messages = StreamIterator<dynamic>(events);
    final finished = Completer<void>();
    exits.listen((_) {
      if (!finished.isCompleted) finished.complete();
    });
    Isolate? worker;
    SendPort? commands;
    final deadline = Stopwatch()..start();
    try {
      worker = await Isolate.spawn(
        _sourceWorker,
        [
          events.sendPort,
          {
            'modules': source.modules,
            'entry': source.entry,
            'operation': source.operations[operation],
            'input': input,
          },
          libraryPath,
        ],
        onExit: exits.sendPort,
        onError: events.sendPort,
        errorsAreFatal: true,
      );
      while (true) {
        RequestScope.checkpoint();
        final left =
            source.timeoutSeconds * 1000 - deadline.elapsedMilliseconds;
        if (left <= 0) {
          throw const SourceError('SOURCE_TIMEOUT', '来源处理超时，请稍后重试');
        }
        final hasMessage = await RequestScope.cancellable(messages.moveNext())
            .timeout(
              Duration(milliseconds: left),
              onTimeout: () =>
                  throw const SourceError('SOURCE_TIMEOUT', '来源处理超时，请稍后重试'),
            );
        if (!hasMessage) {
          throw const SourceError('SCRIPT_UNAVAILABLE', '来源运行时不可用');
        }
        final message = messages.current;
        if (message is SendPort) {
          commands = message;
          continue;
        }
        if (message is! Map) {
          throw const SourceError('SCRIPT_UNAVAILABLE', '来源运行时不可用');
        }
        final packet = asJson(message);
        switch (packet.str('state')) {
          case 'done':
            if (packet['value'] is! Map) {
              throw const SourceError('SOURCE_RESULT', '来源返回格式无效');
            }
            return asJson(packet['value']);
          case 'error':
            final code = packet.str('code');
            throw SourceError(code, switch (code) {
              'SCRIPT_BUDGET' => '来源脚本计算超过限制',
              'SOURCE_NETWORK' => '来源连接失败，请检查网络后重试',
              'SOURCE_TIMEOUT' => '来源连接超时，请稍后重试',
              'SOURCE_HOST' => '来源访问了未声明的地址，请联系维护者更新接入包',
              'SOURCE_CHARSET' => '来源使用了当前客户端不支持的字符编码',
              'SOURCE_RESPONSE' => '来源响应内容超过大小限制',
              _ => '来源脚本执行失败，请更新来源或联系维护者',
            });
          case 'call':
            Object? value;
            var failed = false;
            try {
              value =
                  await RequestScope.cancellable(
                    host(packet.str('method'), packet.obj('args')),
                  ).timeout(
                    Duration(
                      milliseconds:
                          source.timeoutSeconds * 1000 -
                          deadline.elapsedMilliseconds,
                    ),
                    onTimeout: () => throw const SourceError(
                      'SOURCE_TIMEOUT',
                      '来源处理超时，请稍后重试',
                    ),
                  );
            } catch (error) {
              RequestScope.checkpoint();
              if (error is SourceError &&
                  error.code == 'SOURCE_TIMEOUT' &&
                  deadline.elapsedMilliseconds >=
                      source.timeoutSeconds * 1000) {
                rethrow;
              }
              failed = true;
              value = {
                'code': error is SourceError ? error.code : 'SOURCE_REQUEST',
              };
            }
            RequestScope.checkpoint();
            if (utf8.encode(jsonEncode(value)).length > 1048576) {
              throw const SourceError('SOURCE_RESULT', '来源返回内容过大');
            }
            commands!.send([packet.integer('id'), value, failed]);
          default:
            throw const SourceError('SCRIPT_PROTOCOL', '来源运行时响应无效');
        }
      }
    } finally {
      commands?.send(null);
      if (worker != null) {
        await finished.future.timeout(
          const Duration(seconds: 1),
          onTimeout: () {
            worker?.kill(priority: Isolate.immediate);
          },
        );
      }
      await messages.cancel();
      events.close();
      exits.close();
    }
  }
}

Future<void> _sourceWorker(List<dynamic> start) async {
  final out = start[0] as SendPort;
  final receive = ReceivePort();
  final commands = StreamIterator<dynamic>(receive);
  SourceJsBridge? bridge;
  out.send(receive.sendPort);
  try {
    bridge = SourceJsBridge(libraryPath: start[2] as String?);
    bridge.start(asJson(start[1]));
    while (true) {
      final packet = bridge.poll();
      out.send(packet);
      if (packet['state'] != 'call') break;
      if (!await commands.moveNext() || commands.current == null) break;
      final reply = commands.current as List;
      bridge.reply(reply[0] as int, reply[1], failed: reply[2] as bool);
    }
  } catch (_) {
    out.send({'state': 'error', 'code': 'SCRIPT_UNAVAILABLE'});
  } finally {
    bridge?.close();
    await commands.cancel();
    receive.close();
  }
}
