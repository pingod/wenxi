import 'dart:convert';
import '../core/json.dart';
import 'redaction.dart';

/// Native tracing only contains fixed event identifiers, timing and numbers.
/// Revalidate and redact at export too; ignore incomplete crash-time tail writes.
Map<String, String> windowsDiagnosticTraces(Json native, DateTime now) {
  final files = <String, String>{};
  var index = 0;
  for (final trace in native.list('traces').take(8)) {
    final content = trace.str('content');
    if (content.length > 256 * 1024) continue;
    final lines = content.split('\n');
    final valid = <String>[];
    for (final line in lines.take(lines.length - 1)) {
      if (line.isEmpty || line.length > 4096) continue;
      try {
        final record = asJson(jsonDecode(line));
        if (record['time'] is! num || record.str('event').isEmpty) continue;
        final time = DateTime.fromMillisecondsSinceEpoch(
          record.integer('time'),
          isUtc: true,
        );
        if (now.toUtc().difference(time) > const Duration(days: 7)) continue;
        valid.add(jsonEncode(LogRedactor.value(record)));
      } catch (_) {
        // Another complete line can still identify the last successful operation.
      }
    }
    if (valid.isNotEmpty) {
      files['native/windows-trace-${index++}.jsonl'] = '${valid.join('\n')}\n';
    }
  }
  return files;
}
